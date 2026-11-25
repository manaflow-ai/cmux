# cmux-next: keep this app's bundled `cmux` first on PATH after the user's
# startup files (BundledCLIEnvironment.swift). fish reads vendor_conf.d before
# config.fish, so a one-shot fish_prompt handler moves the bundled bin dir
# back to the front once config.fish has run. The app added this directory to
# XDG_DATA_DIRS and named it in CMUX_CLI_FISH_XDG_DIR; remove both so programs
# started in the terminal do not see them.
#
# A terminal started with saved output (the classic session import) names its
# replay file in CMUX_RESTORE_SCROLLBACK_FILE: a one-shot fish_prompt handler
# prints it once above the first prompt and removes it. Only a file in the
# app's private cmux-next-scrollback folder is printed or removed.
set -g __cmux_replay_file "$CMUX_RESTORE_SCROLLBACK_FILE"
set -e CMUX_RESTORE_SCROLLBACK_FILE
if set -q CMUX_CLI_FISH_XDG_DIR
    set -l __cmux_cli_dirs (string split : -- "$XDG_DATA_DIRS")
    set -l __cmux_cli_kept
    for __cmux_cli_entry in $__cmux_cli_dirs
        test "$__cmux_cli_entry" = "$CMUX_CLI_FISH_XDG_DIR"; or set -a __cmux_cli_kept $__cmux_cli_entry
    end
    if test (count $__cmux_cli_kept) -gt 0
        set -gx XDG_DATA_DIRS (string join : -- $__cmux_cli_kept)
    else
        set -e XDG_DATA_DIRS
    end
    set -e CMUX_CLI_FISH_XDG_DIR
end

# A terminal of an incognito workspace (CMUX_TUI_INCOGNITO, set by the daemon)
# keeps no history; the daemon also exports fish_private_mode. It is turned
# on again at every prompt, after config.fish (fish reads it per command).
if set -q CMUX_TUI_INCOGNITO; and test -n "$CMUX_TUI_INCOGNITO"
    set -g fish_private_mode 1
    function __cmux_tui_incognito_history --on-event fish_prompt
        set -g fish_private_mode 1
    end
end

if status is-interactive
    function __cmux_cli_path_first --on-event fish_prompt
        functions -e __cmux_cli_path_first
        set -l cli "$CMUX_BUNDLED_CLI_PATH"
        if test -n "$cli" -a -x "$cli"
            set -l dir (string replace -r '/[^/]*$' '' -- $cli)
            set -l rest
            for entry in $PATH
                test "$entry" = "$dir"; or set -a rest $entry
            end
            set -gx PATH $dir $rest
        end
    end
    # cmux-tui's agent shim directory (`codex` and `claude` that add this
    # terminal's hooks) goes back to the front before each command line:
    # config.fish and prompt hooks often prepend the directory of the real
    # agent, and Codex runs its hooks in a shared daemon that cannot see this
    # terminal's environment, so only the shim can route them. The daemon's
    # own integration defines the same function; the later definition wins.
    function __cmux_tui_agent_shims_first --on-event fish_preexec
        set -l dir "$CMUX_TUI_AGENT_SHIMS"
        if test -n "$dir" -a -d "$dir"; and test "$PATH[1]" != "$dir"
            set -l rest
            for entry in $PATH
                test "$entry" = "$dir"; or set -a rest $entry
            end
            set -gx PATH $dir $rest
        end
    end
    function __cmux_replay_first --on-event fish_prompt
        functions -e __cmux_replay_first
        set -l file $__cmux_replay_file
        set -e __cmux_replay_file
        if test -n "$file" -a -f "$file"; and string match -q -- '*/cmux-next-scrollback' (string replace -r '/[^/]*$' '' -- $file)
            /bin/cat -- $file 2>/dev/null
            /bin/rm -f -- $file 2>/dev/null
        end
    end
end
