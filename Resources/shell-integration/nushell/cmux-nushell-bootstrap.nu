# cmux nushell bootstrap
# Injected by cmux as the `-e` payload of the spawned login shell, which runs
# after the user's env.nu/config.nu/login.nu. Keep every non-comment line a
# self-contained statement: the Swift spawn path strips comments and blank
# lines and joins the rest with '; ' into a single line (and appends a
# `source` of cmux-nushell-integration.nu with the bundle path baked in).
#
# User config commonly rebuilds PATH with its own prepends, which shadows the
# per-surface cmux-cli-shims directory cmux front-loaded at spawn (the claude
# wrapper that injects session tracking + notification hooks). Re-front every
# shim entry, preserving the relative order of everything else — nushell's
# equivalent of the zsh integration's "keep the bundled wrapper ahead of later
# PATH mutations". Also normalizes PATH back to a list when user config left
# it a colon-joined string.
def --env _cmux_refront_cli_shims [] { if ($env.CMUX_SURFACE_ID? | default "") == "" { return }; let raw = ($env.PATH? | default []); let entries = if ($raw | describe | str starts-with "list") { $raw } else { $raw | split row (char esep) }; let shims = ($entries | where {|p| $p | str contains "cmux-cli-shims" }); $env.PATH = ($shims ++ ($entries | where {|p| not ($p | str contains "cmux-cli-shims") })) }
_cmux_refront_cli_shims
