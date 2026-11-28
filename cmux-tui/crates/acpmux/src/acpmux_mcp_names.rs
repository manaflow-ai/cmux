//! The acpmux MCP server's name and the env var naming its session (`acpmux_mcp.rs`), read by
//! the code that lists, configures and serves it.

/// The server's name in a harness's MCP config: Claude Code shows its tools as
/// `mcp__cmux-agent__<tool>`.
pub const SERVER_NAME: &str = "cmux-agent";
/// The names the same server had before: an older chat's transcript, a person's own config entry
/// or another daemon's launch still says `mcp__acpmux__<tool>`. Every matcher takes these too.
pub const LEGACY_SERVER_NAMES: &[&str] = &["acpmux"];
/// The prefix the folding `cmux` server gives this server's tools (`cmux.acpmux_send`,
/// `mcp__cmux__acpmux_bg_start`): unchanged by the rename, since presets' tool allowlists and
/// code-mode scripts name the folded tools.
pub const FOLD_PREFIX: &str = "acpmux";
/// The session the tools act for, set in this server's env with its caller token.
pub const SESSION_ENV: &str = "ACPMUX_SESSION_ID";

/// Whether `name` is this server, under its name or one it had before.
pub fn is_server_name(name: &str) -> bool {
    name == SERVER_NAME || LEGACY_SERVER_NAMES.contains(&name)
}

/// Names persisted before the rename still identify the same server.
pub fn same_server(left: &str, right: &str) -> bool {
    left == right || (is_server_name(left) && is_server_name(right))
}

/// The tool a Claude Code MCP call name (`mcp__cmux-agent__send`, `mcp__acpmux__send`) runs on
/// this server, or None for any other call.
pub fn tool_of(call: &str) -> Option<&str> {
    let rest = call.strip_prefix("mcp__")?;
    let (server, tool) = rest.split_once("__")?;
    is_server_name(server).then_some(tool)
}

/// Whether a person's own MCP config entry (`{command, args}`) starts this server: an
/// `acpmux-mcp` run of acpmux or cmux. A leftover entry like that under a legacy name would start
/// a second copy next to cmux's own, so the chat names its entry after the person's instead.
pub fn runs_this_server(entry: &serde_json::Value) -> bool {
    let program = entry.get("command").and_then(serde_json::Value::as_str).unwrap_or("");
    let program = program.rsplit(['/', '\\']).next().unwrap_or(program);
    let program = program.strip_suffix(".exe").unwrap_or(program);
    let known = matches!(program, "acpmux" | "acpmux-debug-cli" | "cmux-tui-acpmux" | "cmux");
    let serves = entry
        .get("args")
        .and_then(serde_json::Value::as_array)
        .is_some_and(|a| a.iter().any(|v| v.as_str() == Some("acpmux-mcp")));
    let multicall = program == "cmux-tui"
        && entry
            .get("args")
            .and_then(serde_json::Value::as_array)
            .is_some_and(|args| args.first().and_then(serde_json::Value::as_str) == Some("acp"));
    (known || multicall) && serves
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn both_names_are_this_server() {
        assert!(is_server_name("cmux-agent"));
        assert!(is_server_name("acpmux"));
        assert!(!is_server_name("cmux"));
        assert_eq!(tool_of("mcp__cmux-agent__send"), Some("send"));
        assert_eq!(tool_of("mcp__acpmux__bg_start"), Some("bg_start"));
        assert_eq!(tool_of("mcp__cmux__acpmux_send"), None);
        assert_eq!(tool_of("Bash"), None);
    }

    #[test]
    fn a_leftover_entry_that_runs_the_server_is_ours() {
        assert!(runs_this_server(
            &json!({"command": "/usr/local/bin/acpmux", "args": ["acpmux-mcp"]})
        ));
        assert!(runs_this_server(&json!({"command": "cmux", "args": ["acpmux-mcp"]})));
        assert!(!runs_this_server(&json!({"command": "acpmux", "args": ["forum-mcp"]})));
        assert!(!runs_this_server(&json!({"command": "npx", "args": ["acpmux-mcp"]})));
    }

    #[test]
    fn leftover_multicall_and_standalone_binaries_are_recognized() {
        for command in ["/opt/cmux/cmux-tui-acpmux", r"C:\cmux\cmux-tui-acpmux.exe"] {
            assert!(runs_this_server(&json!({"command": command, "args": ["acpmux-mcp"]})));
        }
        assert!(runs_this_server(
            &json!({"command": "/opt/cmux/cmux-tui", "args": ["acp", "acpmux-mcp"]})
        ));
        assert!(!runs_this_server(
            &json!({"command": "/opt/cmux/cmux-tui", "args": ["acpmux-mcp"]})
        ));
        assert!(!runs_this_server(
            &json!({"command": "/opt/cmux/cmux-tui", "args": ["acp", "forum-mcp"]})
        ));
    }
}
