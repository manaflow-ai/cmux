//! `__bg-hook`: Claude Code's PreToolUse hook for `Bash` in the session plugin
//! (`agent_tools.rs`). Leo, 2026-10-27: "also when it comes to hibernation...can't you hibernate
//! the agent but not hibernate the bg tasks?" A `run_in_background` shell ends when the agent
//! hibernates (Claude Code's exit cleanup), so when the chat has the `acpmux` server's
//! `bg_start` (`acpmux_mcp_bg.rs`), the hook turns such a call away and gives the exact call
//! that runs the same command under the daemon, where it outlives the agent.
//!
//! It never strands the agent: when the chat's MCP config (`agent_tools::mcp_config_path`) has
//! no `acpmux` server, plain or behind the `cmux` server's code mode, or anything cannot be read,
//! it says nothing and Claude Code runs the shell as asked. A configured server may still be
//! unusable (it failed to start), so it turns a command away only once: the same call again
//! runs as asked, and the deny says so. The commands turned away and not yet repeated are kept
//! beside the config (`<config>.bg-denied`, one hash a line, the newest [`PENDING`], under a
//! lock so parallel calls never lose one), one file per chat, removed with the config.

use cmux_json::JsonSet as _;
use serde_json::{Value, json};

pub const HOOK_ARG: &str = "__bg-hook";

/// How the chat reaches `bg_start`, from its Claude Code MCP config.
#[derive(Debug, PartialEq, Eq)]
pub enum Route {
    /// `mcp__acpmux__bg_start`: the server stands on its own.
    Direct,
    /// `mcp__cmux__acpmux_bg_start`: folded behind `cmux`, which lists every tool
    /// (`--all-tools`) or the ones a preset allows ([`crate::agent_tools::MCP_TOOLS_ENV`]).
    Listed,
    /// `cmux.acpmux_bg_start` in a `cmux_exec` script: folded behind `cmux`'s code mode.
    CodeMode,
}

/// The cmux server's name for `bg_start` behind it (`cmux mcp serve`'s upstream prefix).
const FOLDED_TOOL: &str = "acpmux_bg_start";

pub fn route(config: &Value) -> Option<Route> {
    let servers = config.get("mcpServers")?;
    if servers.get(crate::acpmux_mcp::SERVER_NAME).is_some() {
        return Some(Route::Direct);
    }
    let cmux = servers.get("cmux")?;
    let env = |k: &str| cmux.pointer("/env")?.get(k)?.as_str();
    let upstreams: Value = serde_json::from_str(env(crate::agent_tools::UPSTREAMS_ENV)?).ok()?;
    let folded = upstreams
        .as_array()?
        .iter()
        .any(|s| s.get("name").and_then(Value::as_str) == Some(crate::acpmux_mcp::SERVER_NAME));
    if !folded {
        return None;
    }
    // A preset's allowlist: cmux lists only those tools and refuses every other call.
    if let Some(allowed) = env(crate::agent_tools::MCP_TOOLS_ENV) {
        return allowed.split(',').any(|t| t.trim() == FOLDED_TOOL).then_some(Route::Listed);
    }
    let all = cmux
        .get("args")
        .and_then(Value::as_array)
        .is_some_and(|a| a.iter().any(|a| a == "--all-tools"));
    Some(if all { Route::Listed } else { Route::CodeMode })
}

/// The most denied calls a chat's file remembers; an older one is denied again on its repeat.
const PENDING: usize = 64;

/// Where the hook keeps the commands it turned away, beside the chat's MCP config.
pub fn denied_path(config: &std::path::Path) -> std::path::PathBuf {
    let mut name = config.as_os_str().to_owned();
    name.push(".bg-denied");
    name.into()
}

/// The hook's answer to one PreToolUse `input`, or None to let the call run.
pub fn decide(input: &Value, route: Option<Route>) -> Option<Value> {
    if input.get("tool_name").and_then(Value::as_str) != Some("Bash")
        || input.pointer("/tool_input/run_in_background") != Some(&json!(true))
    {
        return None;
    }
    let command = input.pointer("/tool_input/command")?.as_str()?;
    let route = route?;
    let mut args = json!({"command": command});
    if let Some(cwd) = input.get("cwd").and_then(Value::as_str).filter(|c| !c.is_empty()) {
        args.set("cwd", json!(cwd));
    }
    let call = match route {
        Route::Direct => format!("mcp__acpmux__bg_start {args}"),
        Route::Listed => format!("mcp__cmux__{FOLDED_TOOL} {args}"),
        Route::CodeMode => format!("cmux_exec with: return await cmux.acpmux_bg_start({args});"),
    };
    let reason = format!(
        "Not run: in this chat a run_in_background shell ends when the agent hibernates after 2 \
idle minutes. Run the same command as a background task the daemon owns, which keeps running; it \
answers with the task's id, and bg_output reads its output: {call} If that tool is not available, send this same Bash call again and it runs as asked."
    );
    Some(json!({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))
}

/// The hook process: reads the call on stdin, prints a deny or nothing, and always exits 0.
/// `home` is the daemon's (`agent_tools::bg_hooks` passes it), where the chat's MCP config is.
pub fn main(home: Option<std::path::PathBuf>) -> anyhow::Result<()> {
    let mut text = String::new();
    let _ = std::io::Read::read_to_string(&mut std::io::stdin(), &mut text);
    let Ok(input) = serde_json::from_str::<Value>(&text) else { return Ok(()) };
    let Ok(session) = std::env::var(crate::acpmux_mcp::SESSION_ENV) else { return Ok(()) };
    let home = home.unwrap_or_else(crate::config::home);
    let config = crate::agent_tools::mcp_config_path(&home, &session);
    let route = std::fs::read(&config)
        .ok()
        .and_then(|raw| serde_json::from_slice(&raw).ok())
        .and_then(|c: Value| route(&c));
    let Some(answer) = decide(&input, route) else { return Ok(()) };
    // The same call turned away just before runs as asked (the replacement may be unusable).
    // Keyed by what the call runs, not its per-call ids.
    let what = json!([input.get("cwd"), input.get("tool_input")]);
    let key = crate::sha256::sha256_hex(what.to_string().as_bytes());
    // Unrecorded, a repeat could not get through: then the call runs.
    if first_time(&denied_path(&config), &key).unwrap_or(false) {
        println!("{answer}");
    }
    Ok(())
}

/// Whether `key` is new to the chat's denied calls: then it is added (true); a repeat is taken
/// out (false). Under an exclusive lock on the file, so parallel hooks of one chat never drop
/// each other's entries.
#[cfg(unix)]
fn first_time(path: &std::path::Path, key: &str) -> std::io::Result<bool> {
    use std::io::{Read, Seek, Write};
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    // SAFETY: flock on a descriptor this function owns; closing it releases the lock.
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    let mut text = String::new();
    file.read_to_string(&mut text)?;
    let mut keys: Vec<&str> = text.lines().filter(|k| !k.is_empty()).collect();
    let new = match keys.iter().position(|k| *k == key) {
        Some(at) => {
            keys.remove(at);
            false
        }
        None => {
            keys.push(key);
            true
        }
    };
    let keep = keys.get(keys.len().saturating_sub(PENDING)..).unwrap_or_default();
    file.set_len(0)?;
    file.rewind()?;
    file.write_all(keep.iter().map(|k| format!("{k}\n")).collect::<String>().as_bytes())?;
    Ok(new)
}
#[cfg(not(unix))]
fn first_time(_path: &std::path::Path, _key: &str) -> std::io::Result<bool> {
    Ok(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent_tools::{MCP_TOOLS_ENV, UPSTREAMS_ENV};

    fn call(background: bool) -> Value {
        json!({"tool_name": "Bash", "cwd": "/work/app",
            "tool_input": {"command": "npm run dev", "run_in_background": background}})
    }

    fn reason(route: Route) -> String {
        let deny = decide(&call(true), Some(route)).unwrap();
        assert_eq!(deny["hookSpecificOutput"]["permissionDecision"], "deny");
        deny["hookSpecificOutput"]["permissionDecisionReason"].as_str().unwrap().to_owned()
    }

    #[test]
    fn a_background_shell_is_turned_to_bg_start_with_the_same_command_and_folder() {
        let args = r#"{"command":"npm run dev","cwd":"/work/app"}"#;
        assert!(reason(Route::Direct).contains(&format!("mcp__acpmux__bg_start {args} ")));
        assert!(reason(Route::Listed).contains(&format!("mcp__cmux__acpmux_bg_start {args} ")));
        assert!(reason(Route::CodeMode).contains(&format!("cmux.acpmux_bg_start({args})")));
    }

    #[test]
    fn without_the_acpmux_server_or_in_the_foreground_the_shell_runs() {
        assert_eq!(decide(&call(true), None), None);
        assert_eq!(decide(&call(false), Some(Route::Direct)), None);
        let read = json!({"tool_name": "Read", "tool_input": {"run_in_background": true}});
        assert_eq!(decide(&read, Some(Route::Direct)), None);
    }

    /// The route is the one the chat's cmux server really offers: code mode, every tool, or a
    /// preset's allowlist, which may leave bg_start out (then nothing replaces the shell).
    #[test]
    fn the_route_comes_from_the_chats_mcp_config() {
        let direct = json!({"mcpServers": {"acpmux": {"command": "acpmux"}}});
        assert_eq!(route(&direct), Some(Route::Direct));
        let ups = json!([{"name": "acpmux"}]).to_string();
        let cmux =
            |args: Value, env: Value| json!({"mcpServers": {"cmux": {"args": args, "env": env}}});
        let serve = json!(["mcp", "serve"]);
        assert_eq!(route(&cmux(serve.clone(), json!({UPSTREAMS_ENV: ups}))), Some(Route::CodeMode));
        let all = json!(["mcp", "serve", "--all-tools"]);
        assert_eq!(route(&cmux(all, json!({UPSTREAMS_ENV: ups}))), Some(Route::Listed));
        let allowed =
            |tools: &str| cmux(serve.clone(), json!({UPSTREAMS_ENV: ups, MCP_TOOLS_ENV: tools}));
        assert_eq!(route(&allowed("render, acpmux_bg_start")), Some(Route::Listed));
        assert_eq!(route(&allowed("render,agents_snapshot")), None);
        assert_eq!(route(&cmux(serve.clone(), json!({UPSTREAMS_ENV: "[]"}))), None);
        assert_eq!(route(&json!({})), None);
    }
}
