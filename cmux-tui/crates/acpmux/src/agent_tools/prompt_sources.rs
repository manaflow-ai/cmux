//! Canonical cmux MCP instruction bytes and compact launch-source inventory.
//! Full tool schemas and skill bodies stay out of persisted session metadata.

use super::{ASKING_RULE, AgentTools, CUA_RULES, MCP_TOOLS_ENV, PLUGIN_NAME, SKILL_FILES};
use crate::context_inventory::{ContextPart, estimated_tokens};

pub const BASE_INSTRUCTIONS: &str = "These tools drive the cmux terminal app and its session daemon. \
    This chat runs in cmux: a terminal, tab or workspace the person asks for is a cmux one, \
    made with these tools, not your own shell. \
    Objects have stable public ids (ws_…, screen_…, pane_…, tab_…, term_…, win_…) that the \
    *_list tools report; a unique prefix works, and <session>:<id> reaches another session. \
    `current` is this chat's own workspace or pane; `focused` is the one the person looks at. \
    A change takes idempotency_key: when a call fails with state in_progress, retry it with the \
    key from the error so it cannot apply twice. Tools never move the user's focus unless the \
    call passes focus: true or the tool's purpose is focus. \
    Name workspaces and tabs to the person by their titles, never by an id they cannot see. \
    When the person must act in a tab (log in, confirm, approve, pick), mark it: tab_update \
    {tab, attention: \"reason\"}; when they ask to go there, tab_focus it. \
    In a cmux chat reply, show UI rather than describe it: ![alt](/abs/path.png), a bare image \
    path or an https image address draws as a thumbnail, and two in one paragraph sit side by side.";

/// It does not open with "This chat runs in cmux": `cmux_exec`'s description, always loaded,
/// says that once.
pub const CODE_MODE_INSTRUCTIONS: &str = "cmux tools run through cmux_exec scripts; its \
    description lists the common ones and what \"a terminal\" or \"this workspace\" means here. Selectors take a public id (ws_…, pane_…, tab_…, \
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

fn source(id: String, kind: &str, label: String, channel: &str) -> ContextPart {
    ContextPart {
        id: format!("cmux-source-{id}"),
        source: format!("cmux-{kind}"),
        label,
        tokens: 0,
        included: false,
        editable: false,
        measurement: "unavailable".into(),
        source_bytes: None,
        channel: Some(channel.into()),
        text: None,
    }
}

fn with_text(mut part: ContextPart, text: &str, included: bool) -> ContextPart {
    part.tokens = estimated_tokens(text);
    part.source_bytes = Some(text.len() as u64);
    part.text = Some(text.to_owned());
    part.measurement = "estimated".into();
    part.included = included;
    part
}

impl AgentTools {
    /// Compact launch inputs, before folding upstreams into the cmux server.
    /// Instruction bytes share the emitter's constants. Descriptions are small;
    /// runtime schemas, credentials, plugin bodies and hook outputs are not copied.
    /// The separately captured cmux guidance owns its own row and tokens.
    pub fn context_parts(&self, claude: bool) -> Vec<ContextPart> {
        let mut parts = Vec::new();
        let cmux = self.servers.iter().find(|server| server.name == "cmux");
        let filtered =
            cmux.is_some_and(|server| server.env.iter().any(|(key, _)| key == MCP_TOOLS_ENV));
        let code_mode = cmux
            .is_some_and(|server| !server.args.iter().any(|arg| arg == "--all-tools") && !filtered);
        if cmux.is_some() {
            let (mode, instructions) = if code_mode {
                ("code mode", CODE_MODE_INSTRUCTIONS)
            } else if filtered {
                ("filtered tool listing", BASE_INSTRUCTIONS)
            } else {
                ("tool listing", BASE_INSTRUCTIONS)
            };
            parts.push(with_text(
                source(
                    "mcp-base".into(),
                    "mcp-instructions",
                    format!("cmux MCP instructions ({mode}; prompt_sources.rs + ASKING_RULE)"),
                    "mcp-instructions",
                ),
                &format!("{instructions} {ASKING_RULE}"),
                true,
            ));
        }
        for server in &self.servers {
            let placement =
                if server.name != "cmux" && cmux.is_some() { "folded into cmux" } else { "stdio" };
            parts.push(source(
                format!("mcp-server-{}", server.name),
                "mcp-catalog",
                format!(
                    "MCP server: {} ({placement}{}; runtime tool schemas unavailable)",
                    server.name,
                    if filtered { "; cmux tool allowlist applies" } else { "" }
                ),
                "mcp-tools",
            ));
        }
        // Only the legacy CUA server folded behind cmux gets this prefix.
        // Code mode reveals it via docs; tool listing may defer it via tool search.
        // Its multiplicity/load status is not known, so it is excluded from totals.
        if cmux.is_some()
            && self.servers.iter().any(|server| {
                server.name == "cmux-cua"
                    && !server.env.iter().any(|(key, _)| key == crate::cua_v2::ENDPOINT_DIR_ENV)
            })
        {
            parts.push(with_text(
                source(
                    "cua-rule".into(),
                    "mcp-instructions",
                    "Computer use rule fragment (agent_tools::CUA_RULES; loaded on demand)".into(),
                    "mcp-tool-description",
                ),
                CUA_RULES,
                false,
            ));
        }
        if claude && let Some(dir) = &self.user_plugin_dir {
            // The person's own skills (`agent_guidance.rs`), as Claude Code lists them.
            for skill in crate::agent_guidance::user_skills(&dir.join("skills")) {
                let text = format!("name: {}\ndescription: {}", skill.name, skill.description);
                parts.push(with_text(
                    source(
                        format!("skill-{}-{}", crate::agent_guidance::USER_PLUGIN_NAME, skill.name),
                        "skill-listing",
                        format!(
                            "Your skill: {}:{}",
                            crate::agent_guidance::USER_PLUGIN_NAME,
                            skill.name
                        ),
                        "skill-listing",
                    ),
                    &text,
                    true,
                ));
            }
        }
        if claude && self.plugin_dir.is_some() {
            for (path, body) in SKILL_FILES {
                let Some(name) = path.strip_suffix("/SKILL.md") else { continue };
                if !self.lists_skill(name) {
                    continue;
                }
                // Store only the exact name/description frontmatter. The harness
                // supplies its own catalog wrapper, hence this is an estimate.
                let Some(frontmatter) =
                    body.strip_prefix("---\n").and_then(|s| s.split_once("\n---").map(|p| p.0))
                else {
                    continue;
                };
                parts.push(with_text(
                    source(
                        format!("skill-{PLUGIN_NAME}-{name}"),
                        "skill-listing",
                        format!("Skill description: {PLUGIN_NAME}:{name} (skills/{path})"),
                        "skill-listing",
                    ),
                    frontmatter,
                    true,
                ));
            }
            parts.push(source(
                "bash-hook".into(),
                "hook",
                "Bash PreToolUse context (bg_hook.rs; generated only when a call is redirected)"
                    .into(),
                "hook-output",
            ));
        }
        parts
    }
}

#[cfg(test)]
mod tests;
