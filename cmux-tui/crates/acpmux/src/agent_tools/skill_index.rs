//! cmux's own skills for an agent that gets no Claude Code plugin (Codex and the other ACP
//! harnesses). Claude Code lists them from the session plugin (`--plugin-dir`); every other
//! harness gets their names, descriptions and paths in the first-turn context, the way it gets
//! the person's own skills (`agent_guidance::first_turn_text`), and reads a SKILL.md from the
//! session plugin's folder when one applies. Nothing is written to the person's own skill
//! folders (`~/.codex/skills`, `~/.agents/skills`).

use std::collections::BTreeMap;

use super::{AgentTools, SKILL_FILES};
use crate::agent_guidance::UserSkill;

/// Skills about one MCP server's tools, and that server: a session without the server is not
/// told about the skill (a Linux or Cloud chat has no computer use; a chat without
/// `cmux-secrets` has no `request_elevation`).
const SKILL_SERVERS: &[(&str, &str)] =
    &[("cmux-cua", crate::cua_v2::SERVER_NAME), ("cmux-sudo", crate::secret_mcp::SERVER_NAME)];

/// Not indexed: `cmux-chat`'s rules are `AGENT_GUIDANCE` itself, already in the same block.
const NOT_INDEXED: &[&str] = &["cmux-chat"];

impl AgentTools {
    /// The session plugin's skills these servers have the tools for, in [`SKILL_FILES`] order,
    /// each with its folder in the plugin. Empty without a plugin folder.
    pub fn skill_index(&self) -> Vec<UserSkill> {
        let Some(plugin) = &self.plugin_dir else { return Vec::new() };
        SKILL_FILES
            .iter()
            .filter_map(|(path, text)| {
                let name = path.strip_suffix("/SKILL.md")?;
                if NOT_INDEXED.contains(&name) {
                    return None;
                }
                let needs = SKILL_SERVERS.iter().find(|(skill, _)| *skill == name);
                if needs.is_some_and(|(_, server)| !self.servers.iter().any(|s| s.name == *server))
                {
                    return None;
                }
                let (_, description) = crate::agent_guidance::frontmatter(text)?;
                let dir = plugin.join("skills").join(name);
                dir.join("SKILL.md").is_file().then(|| UserSkill {
                    name: name.to_owned(),
                    description,
                    dir,
                })
            })
            .collect()
    }
}

/// The index for a new session whose profile env is `env`, read now. A session that gets no
/// tools (a remote origin, `ACPMUX_AGENT_TOOLS=0`) gets no index either, like Claude Code's
/// plugin ([`super::left_out`]). The profile's kept servers apply; a per-workspace display is
/// picked only at spawn, so it does not decide here whether computer use is listed.
pub fn for_new_session(remote_origin: bool, env: &BTreeMap<String, String>) -> Vec<UserSkill> {
    if super::left_out(remote_origin, env, &[]) {
        return Vec::new();
    }
    let mut tools = super::current();
    tools.displays = None;
    tools.scoped(env).skill_index()
}

#[cfg(test)]
mod tests {
    use super::super::{McpServer, materialize};
    use super::*;

    fn server(name: &str) -> McpServer {
        McpServer { name: name.into(), command: "/bin/true".into(), args: vec![], env: vec![] }
    }

    /// Codex is told about the cmux skills whose tools it has, at their paths in the session
    /// plugin, and never about `cmux-chat`, whose rules its guidance already carries.
    #[test]
    fn the_index_lists_the_skills_the_sessions_tools_serve() {
        let state = tempfile::tempdir().unwrap();
        let plugin = materialize(state.path(), |_| true).unwrap();
        let full = AgentTools {
            servers: vec![
                server("cmux"),
                server(crate::cua_v2::SERVER_NAME),
                server(crate::secret_mcp::SERVER_NAME),
            ],
            plugin_dir: Some(plugin.clone()),
            ..Default::default()
        };
        let names = |tools: &AgentTools| -> Vec<String> {
            tools.skill_index().into_iter().map(|s| s.name).collect()
        };
        assert_eq!(
            names(&full),
            ["cmux-browser", "cmux-cua", "cmux-customization", "cmux-live", "acpmux", "cmux-sudo"]
        );
        for skill in full.skill_index() {
            assert_eq!(skill.dir, plugin.join("skills").join(&skill.name));
            assert!(skill.dir.join("SKILL.md").is_file(), "{skill:?}");
            assert!(!skill.description.is_empty() && !skill.description.starts_with('"'));
        }
        let bare = AgentTools { servers: vec![server("cmux")], ..full.clone() };
        assert_eq!(
            names(&bare),
            ["cmux-browser", "cmux-customization", "cmux-live", "acpmux"],
            "no computer use or secrets server, no cmux-cua or cmux-sudo"
        );
        assert!(AgentTools { plugin_dir: None, ..full }.skill_index().is_empty());
    }

    #[test]
    fn a_session_without_tools_gets_no_index() {
        assert!(for_new_session(true, &BTreeMap::new()).is_empty(), "remote origin");
        let off = BTreeMap::from([(super::super::SWITCH_ENV.to_owned(), "0".to_owned())]);
        assert!(for_new_session(false, &off).is_empty(), "ACPMUX_AGENT_TOOLS=0");
    }
}
