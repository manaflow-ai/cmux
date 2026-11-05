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

pub const CODE_MODE_INSTRUCTIONS: &str = "This chat runs in cmux: a terminal, tab or workspace \
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
mod tests {
    use super::*;
    use crate::agent_tools::{McpServer, OFF_ENV, SERVERS_ENV};
    use std::collections::BTreeMap;

    fn tools() -> AgentTools {
        AgentTools {
            servers: ["cmux", "cmux-cua"]
                .into_iter()
                .map(|name| McpServer {
                    name: name.into(),
                    command: "/private/bin/tool".into(),
                    args: vec!["serve".into()],
                    env: vec![("PRIVATE_TOKEN".into(), "do-not-copy-this-value".into())],
                })
                .collect(),
            plugin_dir: Some("/private/plugin".into()),
            user_plugin_dir: None,
            displays: None,
        }
    }

    #[test]
    fn context_sources_match_the_emitted_mcp_base_and_mode() {
        for all in [false, true] {
            let parts = tools().listing(all).context_parts(false);
            let base = parts.iter().find(|p| p.id == "cmux-source-mcp-base").unwrap();
            let expected = if all { BASE_INSTRUCTIONS } else { CODE_MODE_INSTRUCTIONS };
            let expected = format!("{expected} {ASKING_RULE}");
            assert_eq!(base.text.as_deref(), Some(expected.as_str()));
            assert_eq!(base.tokens, estimated_tokens(&expected));
            assert_eq!(base.source_bytes, Some(expected.len() as u64));
            assert_eq!(base.channel.as_deref(), Some("mcp-instructions"));
            assert!(base.included && !base.editable);
            assert_eq!(base.measurement, "estimated");
            assert_eq!(
                parts
                    .iter()
                    .filter(|p| p.text.as_deref().is_some_and(|s| s.contains(ASKING_RULE)))
                    .count(),
                1
            );
        }
        let mut allowed = tools();
        allowed.servers[0].env.push((MCP_TOOLS_ENV.into(), "agents_snapshot".into()));
        let base = allowed.context_parts(false).remove(0);
        assert_eq!(base.text, Some(format!("{BASE_INSTRUCTIONS} {ASKING_RULE}")));
        assert!(base.label.contains("filtered tool listing"));
    }

    #[test]
    fn context_sources_respect_scope_disabled_servers_and_cua_version() {
        let scoped = tools().scoped(&BTreeMap::from([(SERVERS_ENV.into(), "cmux".into())]));
        assert!(!scoped.context_parts(false).iter().any(|p| p.id == "cmux-source-cua-rule"));
        let off = tools().without_off(&BTreeMap::from([(OFF_ENV.into(), "cmux".into())]));
        assert!(!off.context_parts(false).iter().any(|p| p.id == "cmux-source-mcp-base"));
        assert!(!off.context_parts(false).iter().any(|p| p.id == "cmux-source-cua-rule"));
        let mut bridge = tools();
        bridge.servers[1].env.push((crate::cua_v2::ENDPOINT_DIR_ENV.into(), "/endpoint".into()));
        assert!(!bridge.context_parts(false).iter().any(|p| p.id == "cmux-source-cua-rule"));
        let cue = tools().context_parts(false);
        let cue = cue.iter().find(|p| p.id == "cmux-source-cua-rule").unwrap();
        assert_eq!(cue.text.as_deref(), Some(CUA_RULES));
        assert!(!cue.included); // The runtime decides whether this fragment is loaded.
    }

    #[test]
    fn context_sources_keep_compiled_skill_descriptions_without_bodies_or_credentials() {
        let parts = tools().context_parts(true);
        let skills: Vec<_> = parts.iter().filter(|p| p.source == "cmux-skill-listing").collect();
        let compiled = SKILL_FILES.iter().filter(|(p, _)| p.ends_with("/SKILL.md")).count();
        assert_eq!(skills.len(), compiled);
        assert!(skills.iter().any(|p| p.id.ends_with("skill-cmux-cmux-chat")), "{skills:?}");
        for skill in &skills {
            let text = skill.text.as_deref().unwrap();
            assert!(text.starts_with("name:"));
            assert!(text.contains("\ndescription:"));
            assert!(!text.contains("\n# "));
            assert!(skill.label.contains("/SKILL.md"));
            assert!(!skill.editable);
        }
        let serialized = serde_json::to_string(&parts).unwrap();
        assert!(!serialized.contains("do-not-copy-this-value"));
        assert!(!serialized.contains("/private/"));
        assert!(!serialized.contains("inputSchema"));
        assert!(parts.iter().any(|p| p.source == "cmux-hook" && p.measurement == "unavailable"));
        assert!(!tools().context_parts(false).iter().any(|p| p.source == "cmux-skill-listing"));
        let mut no_plugin = tools();
        no_plugin.plugin_dir = None;
        assert!(!no_plugin.context_parts(true).iter().any(|p| p.source == "cmux-skill-listing"));
        assert!(AgentTools::default().context_parts(true).is_empty());
        let mut meta: crate::store::SessionMeta = serde_json::from_value(serde_json::json!({
            "schema":"acpmux.session.v1", "id":"s", "name":"s", "harness":"claude",
            "cwd":"/repo", "status":"idle", "createdAt":0, "updatedAt":0
        }))
        .unwrap();
        let cfg = crate::config::Config::default();
        let inspectable = |meta: &crate::store::SessionMeta| {
            crate::context_inventory::inventory(meta, &cfg)
                .parts
                .iter()
                .filter(|p| p.id.starts_with("cmux-source-") && p.text.is_some())
                .count()
        };
        let before = inspectable(&meta);
        crate::context_inventory::record_tool_sources(&mut meta, parts.clone());
        let after = inspectable(&meta);
        // The skill descriptions plus the two rule fragments (asking, computer use).
        assert_eq!((before, after), (0, compiled + 2));
        println!(
            "context-source-fixture: inspectable_before={before}, inspectable_after={after}, rows={}, text_parts={}, persisted_bytes={}, skill_description_tokens={}, full_skill_body_tokens={}",
            parts.len(),
            parts.iter().filter(|p| p.text.is_some()).count(),
            serialized.len(),
            skills.iter().map(|p| p.tokens).sum::<u64>(),
            SKILL_FILES
                .iter()
                .filter(|(path, _)| path.ends_with("/SKILL.md"))
                .map(|(_, text)| estimated_tokens(text))
                .sum::<u64>()
        );
    }
}
