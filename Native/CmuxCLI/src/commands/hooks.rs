//! Agent hook command implementation.
//!
//! The hook entry point is intentionally small and boring: hook processes are
//! short lived, and all lifecycle state belongs to the app's ordered delivery
//! queue.  This module owns argument validation, bounded stdin handling and
//! wire shaping; it does not maintain a second session store.  That keeps the
//! Rust CLI and the Swift app on one lifecycle authority while allowing hooks
//! to fail open when cmux is unavailable.

use std::collections::BTreeMap;
use std::io::{self, Read};

use serde_json::{Map, Value, json};

use crate::{Context, Result};

const MAX_HOOK_INPUT_BYTES: usize = 1 << 20;
const MAX_QUEUED_PAYLOAD_BYTES: usize = 64 << 10;
const MAX_RELAY_PAYLOAD_BYTES: usize = 4 << 10;
const FEED_WAIT_SECONDS: u64 = 120;

/// Agent integrations currently shipped by cmux.  The installer modules own
/// their generated files; this table is the stable discovery surface shared by
/// `hooks --json` and shell completion.
const AGENTS: &[(&str, &str, &[&str])] = &[
    // Claude is wrapper-injected rather than installed in a provider config,
    // but remains a first-class hook source for queue/feed commands.
    (
        "claude",
        "Claude Code",
        &["SessionStart", "UserPromptSubmit", "Stop", "Notification"],
    ),
    (
        "codex",
        "Codex",
        &["SessionStart", "UserPromptSubmit", "Stop"],
    ),
    (
        "grok",
        "Grok",
        &[
            "SessionStart",
            "UserPromptSubmit",
            "Stop",
            "Notification",
            "SessionEnd",
        ],
    ),
    ("opencode", "OpenCode", &[]),
    ("pi", "Pi", &[]),
    ("omp", "OMP", &[]),
    ("campfire", "Campfire", &[]),
    ("amp", "Amp", &[]),
    (
        "cursor",
        "Cursor",
        &[
            "beforeSubmitPrompt",
            "stop",
            "afterAgentResponse",
            "beforeShellExecution",
            "afterShellExecution",
            "postToolUseFailure",
        ],
    ),
    (
        "gemini",
        "Gemini",
        &["SessionStart", "BeforeAgent", "AfterAgent", "SessionEnd"],
    ),
    ("kiro", "Kiro", &["agentSpawn", "userPromptSubmit", "stop"]),
    (
        "antigravity",
        "Antigravity",
        &[
            "SessionStart",
            "PreInvocation",
            "Stop",
            "turn-completion",
            "Notification",
            "SessionEnd",
        ],
    ),
    (
        "rovodev",
        "Rovo Dev",
        &["on_complete", "on_error", "on_tool_permission"],
    ),
    (
        "hermes-agent",
        "Hermes Agent",
        &[
            "on_session_start",
            "pre_llm_call",
            "post_llm_call",
            "pre_approval_request",
            "post_approval_response",
            "on_session_end",
            "on_session_finalize",
            "on_session_reset",
        ],
    ),
    (
        "copilot",
        "Copilot",
        &["SessionStart", "Stop", "Notification", "SessionEnd"],
    ),
    (
        "codebuddy",
        "CodeBuddy",
        &["SessionStart", "Stop", "Notification", "SessionEnd"],
    ),
    (
        "factory",
        "Factory",
        &["SessionStart", "Stop", "Notification", "SessionEnd"],
    ),
    (
        "qoder",
        "Qoder",
        &["SessionStart", "Stop", "Notification", "SessionEnd"],
    ),
    (
        "kimi",
        "Kimi",
        &["SessionStart", "UserPromptSubmit", "Stop"],
    ),
];

const GENERIC_QUEUED: &[&str] = &[
    "session-start",
    "prompt-submit",
    "stop",
    "notification",
    "agent-response",
    "approval-response",
    "shell-exec",
    "shell-done",
    "shell-failed",
    "session-end",
    "session-finalize",
];

fn normalize(s: &str) -> String {
    s.trim().to_ascii_lowercase()
}

fn agent_known(name: &str) -> bool {
    let n = normalize(name);
    AGENTS.iter().any(|(id, _, _)| *id == n)
        || matches!(n.as_str(), "rovo" | "agy" | "cursor-agent")
}

fn canonical_agent(name: &str) -> String {
    match normalize(name).as_str() {
        "rovo" => "rovodev".to_string(),
        "agy" => "antigravity".to_string(),
        "cursor-agent" => "cursor".to_string(),
        other => other.to_string(),
    }
}

fn queued_supported(agent: &str, subcommand: &str) -> bool {
    let agent = canonical_agent(agent);
    let subcommand = normalize(subcommand);
    if GENERIC_QUEUED.iter().any(|value| *value == subcommand) {
        return true;
    }
    matches!(agent.as_str(), "amp" if matches!(subcommand.as_str(), "title-update" | "lifecycle"))
        || matches!(agent.as_str(), "claude" if matches!(subcommand.as_str(), "pre-tool-use" | "push-notification" | "feed"))
        || matches!(agent.as_str(), "codex" if matches!(subcommand.as_str(), "pre-tool-use" | "post-tool-use"))
}

fn read_bounded_stdin(limit: usize) -> Result<String> {
    let mut bytes = Vec::new();
    let mut input = io::stdin().lock().take((limit + 1) as u64);
    input
        .read_to_end(&mut bytes)
        .map_err(|e| crate::CliError::new("stdin", e.to_string()))?;
    if bytes.len() > limit {
        return Err(crate::CliError::new(
            "input_too_large",
            format!("hook input exceeds {limit} bytes"),
        ));
    }
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

fn json_object(raw: &str) -> Map<String, Value> {
    serde_json::from_str::<Value>(raw)
        .ok()
        .and_then(|value| value.as_object().cloned())
        .unwrap_or_default()
}

fn bounded_payload(raw: &str, max_bytes: usize) -> String {
    if raw.as_bytes().len() <= max_bytes {
        return raw.to_string();
    }
    // Preserve valid JSON where possible.  The app's compactor treats this as
    // a diagnostic fallback and never relies on unbounded hook text.
    let mut object = json_object(raw);
    object.retain(|key, _| {
        matches!(
            key.as_str(),
            "session_id"
                | "sessionId"
                | "event"
                | "hook_event_name"
                | "hookEventName"
                | "cwd"
                | "working_directory"
        )
    });
    serde_json::to_string(&object).unwrap_or_else(|_| "{}".to_string())
}

fn environment() -> Value {
    let mut env = BTreeMap::new();
    for (key, value) in std::env::vars() {
        // Hook payloads are sent to the app, so only preserve cmux identity and
        // agent process keys.  Provider tokens and arbitrary user secrets must
        // never cross the socket boundary.
        if key.starts_with("CMUX_")
            && (key == "CMUX_SOCKET_PATH"
                || key == "CMUX_WORKSPACE_ID"
                || key == "CMUX_SURFACE_ID"
                || key == "CMUX_AGENT_HOOK_ROUTE_SNAPSHOT"
                || key.ends_with("_PID"))
        {
            if value.as_bytes().len() <= 256 && !value.contains('\0') {
                env.insert(key, value);
            }
        }
    }
    json!(env)
}

fn catalog(ctx: &Context) -> Result<Option<i32>> {
    let agents: Vec<Value> = AGENTS
        .iter()
        .map(|(id, display, events)| json!({"name": id, "display_name": display, "events": events, "commands": ["install", "uninstall"]}))
        .collect();
    let value = json!({"schema_version": 1, "command": "hooks", "agents": agents, "queued_subcommands": GENERIC_QUEUED});
    if ctx.json || ctx.envelope {
        ctx.emit(&value)?;
    } else {
        ctx.print("Supported agent hooks:")?;
        for (id, display, _) in AGENTS {
            ctx.print(format!("  {id:<14} {display}"))?;
        }
    }
    Ok(Some(0))
}

fn enqueue(ctx: &Context, args: &[String]) -> Result<Option<i32>> {
    if args.len() != 2 {
        return Err(crate::CliError::usage(
            "Usage: cmux hooks enqueue <agent> <subcommand>",
        ));
    }
    let agent = canonical_agent(&args[0]);
    let subcommand = normalize(&args[1]);
    if !agent_known(&agent) || !queued_supported(&agent, &subcommand) {
        return Err(crate::CliError::new(
            "unsupported_hook",
            format!("Unsupported queued hook: {agent} {subcommand}"),
        ));
    }
    let raw = read_bounded_stdin(MAX_HOOK_INPUT_BYTES)?;
    // The relay transport is represented as a local `host:port` endpoint by
    // the shared transport layer.  Avoid forwarding filesystem/process
    // evidence when that endpoint is selected, matching Swift's
    // `SocketClient.isRelayBacked` gate.
    let socket_hint_owned = ctx
        .socket
        .clone()
        .or_else(|| std::env::var("CMUX_SOCKET_PATH").ok())
        .unwrap_or_default();
    let socket_hint = socket_hint_owned.as_str();
    let relay = !socket_hint.starts_with('/') && socket_hint.rsplit_once(':').is_some();
    let max = if relay {
        MAX_RELAY_PAYLOAD_BYTES
    } else {
        MAX_QUEUED_PAYLOAD_BYTES
    };
    let mut params = json!({
        "agent": agent,
        "subcommand": subcommand,
        "payload": bounded_payload(&raw, max),
        "relay_backed": relay,
        "environment": environment(),
    });
    if let Some(object) = params.as_object_mut() {
        if !relay {
            if let Ok(path) = std::env::var("CMUX_SOCKET_PATH") {
                object.insert("socket_path".into(), Value::String(path));
            }
        }
    }
    let _ = ctx.rpc("agent.hook.enqueue", params)?;
    ctx.emit(&json!({}))?;
    Ok(Some(0))
}

fn classify_feed(source: &str, event: &str, tool: &str) -> (String, bool) {
    let event = normalize(event);
    let source = normalize(source);
    if matches!(
        event.as_str(),
        "permissionrequest" | "permission_request" | "on_tool_permission" | "pre_approval_request"
    ) {
        // Codex owns the approval UI.  Its PermissionRequest hook is a
        // native-prompt notification, not a second blocking cmux decision.
        if source == "codex" || source == "hermes-agent" {
            return ("PreToolUse".into(), false);
        }
        return (
            if tool == "ExitPlanMode" || tool == "AskUserQuestion" {
                tool.to_string()
            } else {
                "PermissionRequest".into()
            },
            true,
        );
    }
    if matches!(
        event.as_str(),
        "posttooluse"
            | "post_tool_use"
            | "post_tool_call"
            | "afteragentshell"
            | "afterShellExecution"
    ) {
        return ("PostToolUse".into(), false);
    }
    let wire = if matches!(
        event.as_str(),
        "userpromptsubmit" | "prompt_submit" | "pre_llm_call"
    ) {
        "UserPromptSubmit"
    } else if matches!(
        event.as_str(),
        "stop" | "afteragent" | "afteragentsresponse" | "post_llm_call" | "on_complete"
    ) {
        "Stop"
    } else if matches!(event.as_str(), "subagentstart" | "subagent_start") {
        "SubagentStart"
    } else if matches!(event.as_str(), "subagentstop" | "subagent_stop") {
        "SubagentStop"
    } else if matches!(
        event.as_str(),
        "sessionstart" | "session_start" | "on_session_start"
    ) {
        "SessionStart"
    } else if matches!(
        event.as_str(),
        "sessionend" | "session_end" | "on_session_end"
    ) {
        "SessionEnd"
    } else {
        "PreToolUse"
    };
    let actionable = source == "hermes-agent" && event == "pre_approval_request";
    (wire.into(), actionable)
}

fn feed(ctx: &Context, args: &[String]) -> Result<Option<i32>> {
    let source = args
        .windows(2)
        .find(|pair| pair[0] == "--source")
        .map(|pair| pair[1].as_str())
        .unwrap_or("");
    if source.is_empty() {
        return Err(crate::CliError::usage(
            "Usage: cmux hooks feed --source <agent> [--event <event>]",
        ));
    }
    let event_arg = args
        .windows(2)
        .find(|pair| pair[0] == "--event")
        .map(|pair| pair[1].as_str());
    let raw = read_bounded_stdin(MAX_HOOK_INPUT_BYTES)?;
    let object = json_object(&raw);
    let event = object
        .get("hook_event_name")
        .or_else(|| object.get("event"))
        .and_then(Value::as_str)
        .or(event_arg)
        .unwrap_or("");
    let tool = object
        .get("tool_name")
        .or_else(|| object.get("toolName"))
        .and_then(Value::as_str)
        .unwrap_or("");
    let (wire, actionable) = classify_feed(source, event, tool);
    let mut event_object = object;
    event_object.insert("hook_event_name".into(), Value::String(wire));
    event_object.insert("_source".into(), Value::String(normalize(source)));
    let response = ctx.rpc("feed.push", json!({"event": event_object, "wait_timeout_seconds": if actionable { FEED_WAIT_SECONDS } else { 0 }}))?;
    if actionable {
        ctx.emit(&response)?;
    } else {
        ctx.emit(&json!({}))?;
    }
    Ok(Some(0))
}

/// Handle the `hooks` namespace.  Install/uninstall and provider-specific
/// lifecycle execution return `None` until their dedicated Rust modules land;
/// the root dispatcher then uses the compatibility adapter for those paths.
pub fn run(ctx: &Context, command: &str, args: &[String]) -> Result<Option<i32>> {
    if command != "hooks" {
        return Ok(None);
    }
    let Some(first) = args.first().map(|s| normalize(s)) else {
        return catalog(ctx);
    };
    match first.as_str() {
        "help" | "--help" | "-h" | "catalog" | "capabilities" => catalog(ctx),
        "enqueue" => enqueue(ctx, &args[1..]),
        "feed" => feed(ctx, &args[1..]),
        "setup" | "uninstall" => Ok(None),
        agent if agent_known(agent) => {
            // Most lifecycle/status hooks use the app-owned ordered queue.
            // Routing them here removes the old Swift process from the hot
            // path while preserving the direct decision hooks below.
            if let Some(subcommand) = args.get(1).map(String::as_str)
                && queued_supported(agent, subcommand)
            {
                return enqueue(ctx, &[agent.to_string(), subcommand.to_string()]);
            }
            // Provider-specific direct hooks (Claude decisions, Cursor shell
            // approval, Codex transcript monitor/auto-name) still need the
            // app's process-binding and notification runtime. Returning None
            // lets the compatibility adapter handle those until their socket
            // methods are available in the app protocol.
            Ok(None)
        }
        _ => Err(crate::CliError::new(
            "unknown_hooks_target",
            format!("Unknown hooks target: {first}"),
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aliases_and_queue_policy_match_swift() {
        assert_eq!(canonical_agent("rovo"), "rovodev");
        assert!(queued_supported("codex", "Stop"));
        assert!(queued_supported("claude", "pre-tool-use"));
        assert!(!queued_supported("claude", "permission-request"));
    }

    #[test]
    fn oversized_payload_keeps_identity() {
        let raw = format!(
            r#"{{"session_id":"s","event":"Stop","text":"{}"}}"#,
            "x".repeat(5000)
        );
        let compact = bounded_payload(&raw, 128);
        assert!(compact.contains("session_id"));
        assert!(compact.as_bytes().len() < raw.as_bytes().len());
    }

    #[test]
    fn feed_unknown_events_fail_neutral() {
        assert_eq!(
            classify_feed("future-agent", "new_event", "Bash"),
            ("PreToolUse".into(), false)
        );
        assert_eq!(
            classify_feed("claude", "PermissionRequest", "Bash"),
            ("PermissionRequest".into(), true)
        );
        assert_eq!(
            classify_feed("claude", "PermissionRequest", "AskUserQuestion"),
            ("AskUserQuestion".into(), true)
        );
        assert_eq!(
            classify_feed("codex", "PermissionRequest", "Bash"),
            ("PreToolUse".into(), false)
        );
    }
}
