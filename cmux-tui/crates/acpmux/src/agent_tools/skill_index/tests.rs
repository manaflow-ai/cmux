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
