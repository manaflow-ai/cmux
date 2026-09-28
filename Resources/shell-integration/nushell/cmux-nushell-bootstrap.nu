# cmux nushell bootstrap
# Injected by cmux as the `-e` payload of the spawned login shell, which runs
# after the user's env.nu/config.nu/login.nu. Keep every non-comment line a
# self-contained statement: the Swift spawn path strips comments and blank
# lines and joins the rest with '; ' into a single line (and appends a
# `source` of cmux-nushell-integration.nu with the bundle path baked in).
#
# User config commonly rebuilds PATH with its own prepends, which shadows the
# per-surface cmux-cli-shims directory cmux front-loaded at spawn (the claude
# wrapper that injects session tracking + notification hooks). Re-front that
# directory, preserving the relative order of everything else — nushell's
# equivalent of the zsh integration's "keep the bundled wrapper ahead of later
# PATH mutations". The app sets $CMUX_AGENT_COMMAND_SHIM_ROOT whenever any
# agent shim exists and $CMUX_CLAUDE_WRAPPER_SHIM_ROOT only for the Claude
# shim, so both are candidates. Also normalizes PATH back to a list when user
# config left it a colon-joined string.
#
# The shim root can sit in a shared temporary directory, so it moves only when
# it is a real directory (not a symlink) owned by this user. nushell has no
# owner check of its own; stat, which does not follow a symlink here, reports
# the type and owner. When that can't be confirmed, PATH keeps its order.
def _cmux_owned_shim_root [root: string] { if not ($root | str starts-with "/") { return false }; try { let found = (^/usr/bin/stat -f "%HT:%u" -- $root | complete); let uid = (^/usr/bin/id -u | complete); $found.exit_code == 0 and $uid.exit_code == 0 and ($found.stdout | str trim) == $"Directory:($uid.stdout | str trim)" } catch { false } }
def --env _cmux_refront_cli_shims [] { if ($env.CMUX_SURFACE_ID? | default "") == "" { return }; let raw = ($env.PATH? | default []); let entries = if ($raw | describe | str starts-with "list") { $raw } else { $raw | split row (char esep) }; let roots = ([($env.CMUX_AGENT_COMMAND_SHIM_ROOT? | default ""), ($env.CMUX_CLAUDE_WRAPPER_SHIM_ROOT? | default "")] | uniq | where {|r| ($r in $entries) and (_cmux_owned_shim_root $r) }); $env.PATH = ($roots ++ ($entries | where {|p| $p not-in $roots })) }
_cmux_refront_cli_shims
