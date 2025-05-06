#!/usr/bin/env zsh

__lzsh_get_distribution_name() {
  if [[ "$(uname)" == "Darwin" ]]; then
    echo "$(sw_vers -productName) $(sw_vers -productVersion)" 2>/dev/null
  else
    echo "$(cat /etc/*-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2)"
  fi
}

__lzsh_get_os_prompt_injection() {
  local os=$(__lzsh_get_distribution_name)
  if [[ -n "$os" ]]; then
    echo " for $os"
  else
    echo ""
  fi
}

# Set default LLM provider
LZSH_LLM_PROVIDER=${LZSH_LLM_PROVIDER:-"openai"}

__lzsh_preflight_check() {
  emulate -L zsh
  
  if [[ "$LZSH_LLM_PROVIDER" == "openai" && -z "$OPENAI_API_KEY" ]]; then
    echo ""
    echo "Error: OPENAI_API_KEY is not set"
    echo "Get your API key from https://platform.openai.com/account/api-keys and then run:"
    echo "export OPENAI_API_KEY=<your API key>"
    zle reset-prompt
    return 1
  fi
  
  if [[ "$LZSH_LLM_PROVIDER" == "claude" && -z "$ANTHROPIC_API_KEY" ]]; then
    echo ""
    echo "Error: ANTHROPIC_API_KEY is not set"
    echo "Get your API key from https://console.anthropic.com/ and then run:"
    echo "export ANTHROPIC_API_KEY=<your API key>"
    zle reset-prompt
    return 1
  fi

  if ! command -v jq &> /dev/null; then
    echo ""
    echo "Error: jq is not installed"
    zle reset-prompt
    return 1
  fi

  if ! command -v curl &> /dev/null && ! command -v wget &> /dev/null; then
    echo ""
    echo "Error: curl or wget is not installed"
    zle reset-prompt
    return 1
  fi
}

__lzsh_llm_api_call() {
  emulate -L zsh
  # calls the llm API, shows a nice spinner while it's running 
  # called without a subshell to stay in the widget context, returns the answer in $generated_text variable
  local intro="$1"
  local prompt="$2"
  local progress_text="$3"

  local response_file=$(mktemp)
  local pid=0
  
  set +m
  
  # Format data and make API call based on provider
  if [[ "$LZSH_LLM_PROVIDER" == "openai" ]]; then
    local escaped_prompt=$(echo "$prompt" | jq -R -s '.')
    local escaped_intro=$(echo "$intro" | jq -R -s '.')
    local data='{"messages":[{"role": "system", "content": '"$escaped_intro"'},{"role": "user", "content": '"$escaped_prompt"'}],"model":"gpt-4o","max_tokens":256,"temperature":0}'
    
    if command -v curl &> /dev/null; then
      { curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $OPENAI_API_KEY" -d "$data" https://api.openai.com/v1/chat/completions > "$response_file" } &>/dev/null &
    else
      { wget -qO- --header="Content-Type: application/json" --header="Authorization: Bearer $OPENAI_API_KEY" --post-data="$data" https://api.openai.com/v1/chat/completions > "$response_file" } &>/dev/null &
    fi
    pid=$!
  elif [[ "$LZSH_LLM_PROVIDER" == "claude" ]]; then
    local escaped_prompt=$(echo "$prompt" | jq -R -s '.')
    local escaped_intro=$(echo "$intro" | jq -R -s '.')
    local data='{"model":"claude-3-7-sonnet-20250219","max_tokens":512,"temperature":0,"system":'"$escaped_intro"',"messages":[{"role":"user","content":'"$escaped_prompt"'}]}'

    if command -v curl &> /dev/null; then
      { curl -s -X POST -H "Content-Type: application/json" -H "anthropic-version: 2023-06-01" -H "x-api-key: $ANTHROPIC_API_KEY" -d "$data" https://api.anthropic.com/v1/messages > "$response_file" } &>/dev/null &
    else
      { wget -qO- --header="Content-Type: application/json" --header="anthropic-version: 2023-06-01" --header="x-api-key: $ANTHROPIC_API_KEY" --post-data="$data" https://api.anthropic.com/v1/messages > "$response_file" } &>/dev/null &
      fi
    pid=$!
  else
    zle -M "Error: Unknown LLM provider $LZSH_LLM_PROVIDER"
    return 1
  fi

  # Display a spinner while the API request is running in the background
  local spinner=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  while true; do
    for i in "${spinner[@]}"; do
      if ! kill -0 $pid 2> /dev/null; then
        break 2
      fi

      zle -R "$i $progress_text"
      sleep 0.1
    done
  done

  wait $pid
  if [ $? -ne 0 ]; then
    zle -M "Error: API request failed"
    return 1
  fi

  local response=$(cat "$response_file")
  # explicit rm invocation to avoid user shell overrides
  command rm "$response_file"

  # Parse response based on provider
  if [[ "$LZSH_LLM_PROVIDER" == "openai" ]]; then
    local error=$(echo -E $response | jq -r '.error.message')
    generated_text=$(echo -E $response | jq -r '.choices[0].message.content' | tr '\n' '\r' | sed -e $'s/^[ \r`]*//; s/[ \r`]*$//' | tr '\r' '\n')
    
    if [ $? -ne 0 ]; then
      zle -M "Error: Invalid API response format"
      return 1
    fi

    if [[ -n "$error" && "$error" != "null" ]]; then
      zle -M "API error: $error"
      return 1
    fi
  elif [[ "$LZSH_LLM_PROVIDER" == "claude" ]]; then
    local error=$(echo -E $response | jq -r '.error.message')
    generated_text=$(echo -E $response | jq -r '.content[0].text' | tr '\n' '\r' | sed -e $'s/^[ \r`]*//; s/[ \r`]*$//' | tr '\r' '\n')
    
    if [ $? -ne 0 ]; then
      zle -M "Error: Invalid API response format"
      return 1
    fi

    if [[ -n "$error" && "$error" != "null" ]]; then
      zle -M "API error: $error"
      return 1
    fi
  fi
}

# Read user query and generates a zsh command
__lazyshell_complete() {
  emulate -L zsh
  __lzsh_preflight_check || return 1

  local buffer_context="$BUFFER"
  local cursor_position=$CURSOR

  # Read user input
  # Todo: use zle to read input
  local REPLY
  autoload -Uz read-from-minibuffer
  read-from-minibuffer '> Query: '
  BUFFER="$buffer_context"
  CURSOR=$cursor_position


  local os=$(__lzsh_get_os_prompt_injection)
  local intro="You are a zsh autocomplete script. All your answers are a single command$os, and nothing else. You do not need to wrap the command in backticks. You do not write any human-readable explanations. If you cannot provide a response, start your response with \`#\`."
  if [[ -z "$buffer_context" ]]; then
    local prompt="$REPLY"
  else
    local prompt="Alter zsh command \`$buffer_context\` to comply with query \`$REPLY\`"
  fi

  __lzsh_llm_api_call "$intro" "$prompt" "Query: $REPLY"
  if [ $? -ne 0 ]; then
    return 1
  fi

  # if response starts with '#' it means GPT failed to generate the command
  if [[ "$generated_text" == \#* ]]; then
    zle -M "$generated_text"
    return 1
  fi

  # Replace the current buffer with the generated text
  BUFFER="$generated_text"
  CURSOR=$#BUFFER
}

# Explains the current zsh command
__lazyshell_explain() {
  emulate -L zsh
  __lzsh_preflight_check || return 1

  local buffer_context="$BUFFER"

  local os=$(__lzsh_get_os_prompt_injection)
  local intro="You are a zsh command explanation assistant$os. You write short and concise explanations what a given zsh command does, including the arguments. You answer with no line breaks."
  local prompt="$buffer_context"

  __lzsh_llm_api_call "$intro" "$prompt" "Fetching Explanation..."
  if [ $? -ne 0 ]; then
    return 1
  fi

  zle -R "# $generated_text"
  read -k 1
}

# Check for required API keys based on provider
if [[ "$LZSH_LLM_PROVIDER" == "openai" && -z "$OPENAI_API_KEY" ]]; then
  echo "Warning: OPENAI_API_KEY is not set"
  echo "Get your API key from https://platform.openai.com/account/api-keys and then run:"
  echo "export OPENAI_API_KEY=<your API key>"
fi

if [[ "$LZSH_LLM_PROVIDER" == "claude" && -z "$ANTHROPIC_API_KEY" ]]; then
  echo "Warning: ANTHROPIC_API_KEY is not set"
  echo "Get your API key from https://console.anthropic.com/ and then run:"
  echo "export ANTHROPIC_API_KEY=<your API key>"
fi

# Add command to toggle between providers
__lazyshell_toggle_provider() {
  emulate -L zsh
  if [[ "$LZSH_LLM_PROVIDER" == "openai" ]]; then
    LZSH_LLM_PROVIDER="claude"
    zle -M "Switched to Claude API"
  else
    LZSH_LLM_PROVIDER="openai"
    zle -M "Switched to OpenAI API"
  fi
}

# Bind the __lazyshell_complete function to the Alt-g hotkey
# Bind the __lazyshell_explain function to the Alt-e hotkey
# Bind the __lazyshell_toggle_provider function to the Alt-t hotkey
zle -N __lazyshell_complete
zle -N __lazyshell_explain
zle -N __lazyshell_toggle_provider
bindkey '^G' __lazyshell_complete
bindkey '^E' __lazyshell_explain
bindkey '^T' __lazyshell_toggle_provider

typeset -ga ZSH_AUTOSUGGEST_CLEAR_WIDGETS
ZSH_AUTOSUGGEST_CLEAR_WIDGETS+=( __lazyshell_explain )
