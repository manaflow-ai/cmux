# cmux-next: keep this app's bundled `cmux` first on PATH after the user's
# startup files (BundledCLIEnvironment.swift). fish reads vendor_conf.d before
# config.fish, so a one-shot fish_prompt handler moves the bundled bin dir
# back to the front once config.fish has run. The app added this directory to
# XDG_DATA_DIRS and named it in CMUX_CLI_FISH_XDG_DIR; remove both so programs
# started in the terminal do not see them.
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
end
