//! `__bg-hook`: Claude Code's PreToolUse hook for `Bash` in the session plugin
//! (`agent_tools.rs`). Leo, 2026-10-27: "also when it comes to hibernation...can't you hibernate
//! the agent but not hibernate the bg tasks?" A `run_in_background` shell ends when the agent
//! hibernates (Claude Code's exit cleanup), so when the chat has the `acpmux` server's
//! `bg_start` (`acpmux_mcp_bg.rs`), the hook turns such a call away and gives the exact call
//! that runs the same command under the daemon, where it outlives the agent.
//!
//! It never strands the agent: when the chat's MCP config (`agent_tools::mcp_config_path`) has
//! no `acpmux` server, plain or behind the `cmux` server's code mode, or anything cannot be read,
//! it says nothing and Claude Code runs the shell as asked.

use serde_json::{Value, json};

pub const HOOK_ARG: &str = "__bg-hook";

/// How the chat reaches `bg_start`, from its Claude Code MCP config.
#[derive(Debug, PartialEq, Eq)]
pub enum Route {
    /// `mcp__acpmux__bg_start`.
    Direct,
    /// `cmux.acpmux_bg_start` in a `cmux_exec` script (code mode, `agent_tools::folded`).
    CodeMode,
}

pub fn route(config: &Value) -> Option<Route> {
    let servers = config.get("mcpServers")?;
    if servers.get(crate::acpmux_mcp::SERVER_NAME).is_some() {
        return Some(Route::Direct);
    }
    let upstreams = servers.pointer("/cmux/env")?.get(crate::agent_tools::UPSTREAMS_ENV)?;
    let upstreams: Value = serde_json::from_str(upstreams.as_str()?).ok()?;
    let folded = upstreams
        .as_array()?
        .iter()
        .any(|s| s["name"].as_str() == Some(crate::acpmux_mcp::SERVER_NAME));
    folded.then_some(Route::CodeMode)
}

/// The hook's answer to one PreToolUse `input`, or None to let the call run.
pub fn decide(input: &Value, route: Option<Route>) -> Option<Value> {
    if input["tool_name"].as_str() != Some("Bash")
        || input.pointer("/tool_input/run_in_background") != Some(&json!(true))
    {
        return None;
    }
    let command = input.pointer("/tool_input/command")?.as_str()?;
    let route = route?;
    let mut args = json!({"command": command});
    if let Some(cwd) = input["cwd"].as_str().filter(|c| !c.is_empty()) {
        args["cwd"] = json!(cwd);
    }
    let call = match route {
        Route::Direct => format!("mcp__acpmux__bg_start {args}"),
        Route::CodeMode => format!("cmux_exec with: return await cmux.acpmux_bg_start({args});"),
    };
    let reason = format!(
        "Not run: in this chat a run_in_background shell ends when the agent hibernates after 2 \
idle minutes. Run the same command as a background task the daemon owns, which keeps running; it \
answers with the task's id, and bg_output reads its output: {call}"
    );
    Some(json!({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))
}

/// The hook process: reads the call on stdin, prints a deny or nothing, and always exits 0.
pub fn main() -> anyhow::Result<()> {
    let mut text = String::new();
    let _ = std::io::Read::read_to_string(&mut std::io::stdin(), &mut text);
    let Ok(input) = serde_json::from_str::<Value>(&text) else { return Ok(()) };
    let route = std::env::var(crate::acpmux_mcp::SESSION_ENV).ok().and_then(|session| {
        let path = crate::agent_tools::mcp_config_path(&crate::config::home(), &session);
        route(&serde_json::from_slice(&std::fs::read(path).ok()?).ok()?)
    });
    if let Some(answer) = decide(&input, route) {
        println!("{answer}");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(background: bool) -> Value {
        json!({"tool_name": "Bash", "cwd": "/work/app",
            "tool_input": {"command": "npm run dev", "run_in_background": background}})
    }

    #[test]
    fn a_background_shell_is_turned_to_bg_start_with_the_same_command_and_folder() {
        let deny = decide(&call(true), Some(Route::Direct)).unwrap();
        let out = &deny["hookSpecificOutput"];
        assert_eq!(out["permissionDecision"], "deny");
        let reason = out["permissionDecisionReason"].as_str().unwrap();
        assert!(
            reason
                .ends_with(r#"mcp__acpmux__bg_start {"command":"npm run dev","cwd":"/work/app"}"#),
            "{reason}"
        );
        let deny = decide(&call(true), Some(Route::CodeMode)).unwrap();
        let reason = deny["hookSpecificOutput"]["permissionDecisionReason"].as_str().unwrap();
        assert!(
            reason.contains(r#"cmux.acpmux_bg_start({"command":"npm run dev","cwd":"/work/app"})"#)
        );
    }

    #[test]
    fn without_the_acpmux_server_or_in_the_foreground_the_shell_runs() {
        assert_eq!(decide(&call(true), None), None);
        assert_eq!(decide(&call(false), Some(Route::Direct)), None);
        let read = json!({"tool_name": "Read", "tool_input": {"run_in_background": true}});
        assert_eq!(decide(&read, Some(Route::Direct)), None);
    }

    #[test]
    fn the_route_comes_from_the_chats_mcp_config() {
        let direct = json!({"mcpServers": {"acpmux": {"command": "acpmux"}}});
        assert_eq!(route(&direct), Some(Route::Direct));
        let ups = json!([{"name": "acpmux"}]).to_string();
        let folded =
            json!({"mcpServers": {"cmux": {"env": {crate::agent_tools::UPSTREAMS_ENV: ups}}}});
        assert_eq!(route(&folded), Some(Route::CodeMode));
        let off =
            json!({"mcpServers": {"cmux": {"env": {crate::agent_tools::UPSTREAMS_ENV: "[]"}}}});
        assert_eq!(route(&off), None);
        assert_eq!(route(&json!({})), None);
    }
}
