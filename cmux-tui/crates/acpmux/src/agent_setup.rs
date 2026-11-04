//! What a chat's agent is told beside the person's messages, for the Agent setup viewer
//! (`_acpmux/agent_setup`, `server/requests/agent_setup.rs`). Leo, 2026-11-04: "giving the
//! users a better way to, like, see what's actually happening ... as a viewer ... some people just
//! want to edit it a bit".
//!
//! Three parts, each read from the code that tells the agent, so the viewer cannot drift from it:
//! - the harness's own system prompt, named and never shown (acpmux does not have its text);
//! - each cmux MCP server the session gets (`agent_tools.rs`), with the MCP `instructions` and
//!   the tools its `tools/list` answers, from the server's own functions;
//! - the preset's system prompt, which replaces Claude Code's own (`--system-prompt-file`,
//!   `hub/spawn.rs`) in new sessions of that preset.

use serde_json::{Value, json};

/// The cmux MCP server's instructions in code mode (`cmux mcp serve`, cmux-tui
/// `cli/mcp/code_mode.rs`, which uses this constant). Kept here so the viewer shows it too.
pub const CMUX_CODE_MODE_INSTRUCTIONS: &str = "This chat runs in cmux: a terminal, tab or workspace \
    the person asks for (\"on my right\", \"a new workspace\") is a cmux one, made and run with \
    these tools, not your own shell. cmux tools run through cmux_exec scripts; its \
    description lists the common ones. Selectors take a public id (ws_…, pane_…, tab_…, \
    term_…), a unique prefix, <session>:<id> or an exact name; workspace, screen, pane and tab \
    also take `current` (this chat's own) or `focused` (the one the person looks at). Tools of the chat's \
    other cmux servers (cua_*: computer use on Mac \
    apps; secrets_*, sessions_*, subsessions_*, forum_*) come with their \
    rules in `servers` of a cmux.docs answer: follow them. A change takes idempotency_key: on \
    in_progress, retry with the key from the error; another server's call that fails \
    in_progress has no key and may have run, so check its effect first. Tools never move the \
    person's focus unless the call passes focus: true or the tool's purpose is focus. Name workspaces and tabs to the person \
    by title, never by id. When they must act in a tab (log in, confirm), tab_update {tab, \
    attention: \"reason\"} marks it. In a reply, ![alt](/abs/path.png) shows an image.";

/// The harness's own system prompt: who writes it, and where its maker publishes prompts.
pub fn harness_prompt(family: &str) -> Value {
    match family {
        "claude" => json!({
            "source": "Claude Code",
            "note": "Claude Code's built-in system prompt. It ships inside Claude Code, so it is not shown here; a preset's system prompt replaces it.",
            "link": "https://docs.claude.com/en/release-notes/system-prompts",
        }),
        "codex" => json!({
            "source": "Codex",
            "note": "Codex's built-in instructions. They ship inside Codex, so they are not shown here.",
            "link": "https://github.com/openai/codex",
        }),
        other => json!({
            "source": if other.is_empty() { "the harness" } else { other },
            "note": "The harness's built-in system prompt. It ships inside the harness, so it is not shown here.",
            "link": Value::Null,
        }),
    }
}

/// One cmux MCP server as the agent sees it: its instructions and tools (`name`, `description`).
/// A server this daemon does not serve itself (`cmux-cua`, the agent memory) is named with no text.
pub fn server(name: &str) -> Value {
    let (instructions, tools): (Option<String>, Value) = match name {
        crate::acpmux_mcp::SERVER_NAME => {
            let tools = crate::acpmux_mcp::tools_with_artifacts(
                crate::acpmux_mcp::artifacts::from_config().is_some(),
            );
            (crate::acpmux_mcp::instructions(&tools), tools)
        }
        crate::subsession_mcp::SERVER_NAME => {
            (Some(crate::subsession_mcp::instructions()), crate::subsession_mcp::tools())
        }
        crate::cloud_repo_mcp::SERVER_NAME => {
            (Some(crate::cloud_repo_mcp::INSTRUCTIONS.to_owned()), crate::cloud_repo_mcp::tools())
        }
        crate::offer_mcp::SERVER_NAME => {
            (Some(crate::offer_mcp::INSTRUCTIONS.to_owned()), crate::offer_mcp::tools())
        }
        crate::forum_mcp::SERVER_NAME => (None, crate::forum_mcp::tools()),
        crate::secret_mcp::SERVER_NAME => (None, crate::secret_mcp::tools()),
        // Code mode lists one tool; its description names the common operations.
        "cmux" => (Some(CMUX_CODE_MODE_INSTRUCTIONS.to_owned()), json!([])),
        _ => (None, json!([])),
    };
    let tools: Vec<Value> = tools
        .as_array()
        .into_iter()
        .flatten()
        .map(|t| json!({"name": t["name"], "description": t["description"]}))
        .collect();
    json!({"name": name, "instructions": instructions, "tools": tools})
}

/// The names of the cmux MCP servers a session with `env` and `args` gets from `tools`: none
/// when it is left out (`agent_tools::left_out`), only the kept ones under
/// `ACPMUX_AGENT_TOOL_SERVERS`.
pub fn server_names(
    tools: &crate::agent_tools::AgentTools,
    remote_origin: bool,
    env: &std::collections::BTreeMap<String, String>,
    args: &[String],
) -> Vec<String> {
    if crate::agent_tools::left_out(remote_origin, env, args) {
        return Vec::new();
    }
    let kept: Option<Vec<&str>> = env
        .get(crate::agent_tools::SERVERS_ENV)
        .filter(|v| !v.trim().is_empty())
        .map(|v| v.split(',').map(str::trim).collect());
    tools
        .servers
        .iter()
        .map(|s| s.name.clone())
        .filter(|n| kept.as_ref().is_none_or(|k| k.contains(&n.as_str())))
        .collect()
}

#[cfg(test)]
#[path = "agent_setup_tests.rs"]
mod tests;
