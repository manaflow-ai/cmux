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
# The root must be owned and not writable by another user. Both its lexical
# and resolved ancestry must be owned by this user/root and not writable by
# others, except sticky shared directories such as /tmp. A directory's owner
# can replace children even with the sticky bit, so owner checks also apply.
def _cmux_shim_metadata [path: string] { let bsd = (^/usr/bin/stat -f "%HT:%u:%Mp%Lp" -- $path | complete); let found = if $bsd.exit_code == 0 { $bsd } else { ^/usr/bin/stat -c "%F:%u:%a" -- $path | complete }; if $found.exit_code != 0 { error make {msg: "unavailable directory metadata"} }; let fields = ($found.stdout | str trim | split row ":"); if ($fields | length) != 3 { error make {msg: "invalid directory metadata"} }; {kind: ($fields | get 0), owner: ($fields | get 1), mode: ($fields | get 2 | into int --radix 8)} }
def _cmux_shim_chain_safe [root: string, uid: string] { mut current = $root; loop { let meta = (_cmux_shim_metadata $current); if $meta.owner not-in ["0" $uid] { return false }; if $meta.kind in ["Directory" "directory"] { if (($meta.mode | bits and 18) != 0) and (($meta.mode | bits and 512) == 0) { return false } } else if $meta.kind not-in ["Symbolic Link" "symbolic link"] { return false }; if $current == "/" { return true }; let parent = ($current | path dirname); if $parent == $current { return false }; $current = $parent } }
def _cmux_owned_shim_root [root: string] { if not ($root | str starts-with "/") { return false }; try { let identity = (^/usr/bin/id -u | complete); if $identity.exit_code != 0 { return false }; let uid = ($identity.stdout | str trim); let meta = (_cmux_shim_metadata $root); if ($meta.kind not-in ["Directory" "directory"]) or ($meta.owner != $uid) or (($meta.mode | bits and 18) != 0) { return false }; (_cmux_shim_chain_safe $root $uid) and (_cmux_shim_chain_safe ($root | path expand --strict) $uid) } catch { false } }
def --env _cmux_refront_cli_shims [] { if ($env.CMUX_SURFACE_ID? | default "") == "" { return }; let raw = ($env.PATH? | default []); let entries = if ($raw | describe | str starts-with "list") { $raw } else { $raw | split row (char esep) }; let roots = ([($env.CMUX_AGENT_COMMAND_SHIM_ROOT? | default ""), ($env.CMUX_CLAUDE_WRAPPER_SHIM_ROOT? | default "")] | uniq | where {|r| ($r in $entries) and (_cmux_owned_shim_root $r) }); $env.PATH = ($roots ++ ($entries | where {|p| $p not-in $roots })) }
_cmux_refront_cli_shims
