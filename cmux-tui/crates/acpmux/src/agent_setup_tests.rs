use super::*;
use std::collections::BTreeMap;

fn tools(names: &[&str]) -> crate::agent_tools::AgentTools {
    crate::agent_tools::AgentTools {
        servers: names
            .iter()
            .map(|n| crate::agent_tools::McpServer {
                name: (*n).into(),
                command: "/bin/true".into(),
                args: vec![],
                env: vec![],
            })
            .collect(),
        ..Default::default()
    }
}

#[test]
fn each_server_shows_the_text_its_own_server_gives() {
    let sub = server(crate::subsession_mcp::SERVER_NAME);
    assert_eq!(sub["instructions"], crate::subsession_mcp::instructions());
    let names: Vec<&str> = sub["tools"].as_array().unwrap().iter().filter_map(|t| t["name"].as_str()).collect();
    assert!(names.contains(&"start_session"), "{sub}");
    let cloud = server(crate::cloud_repo_mcp::SERVER_NAME);
    assert_eq!(cloud["instructions"], crate::cloud_repo_mcp::INSTRUCTIONS);
    let acpmux = server(crate::acpmux_mcp::SERVER_NAME);
    let all = crate::acpmux_mcp::tools_with_artifacts(false);
    assert_eq!(acpmux["instructions"], json!(crate::acpmux_mcp::instructions(&all)));
    assert!(acpmux["tools"].as_array().unwrap().iter().all(|t| t["description"].is_string()));
    assert_eq!(server("cmux")["instructions"], CMUX_CODE_MODE_INSTRUCTIONS);
    // A server this daemon does not serve is named with no text.
    assert_eq!(server("cmux-cua"), json!({"name": "cmux-cua", "instructions": null, "tools": []}));
}

#[test]
fn the_session_gets_only_its_kept_servers() {
    let all = tools(&["cmux", "acpmux", "cmux-subsessions"]);
    let none = BTreeMap::new();
    assert_eq!(server_names(&all, false, &none, &[]), ["cmux", "acpmux", "cmux-subsessions"]);
    let kept = BTreeMap::from([(crate::agent_tools::SERVERS_ENV.to_owned(), "cmux".to_owned())]);
    assert_eq!(server_names(&all, false, &kept, &[]), ["cmux"]);
    assert!(server_names(&all, true, &none, &[]).is_empty(), "a remote-origin chat gets none");
    assert!(server_names(&all, false, &none, &["--strict-mcp-config".into()]).is_empty());
}

#[test]
fn the_harness_prompt_is_named_never_shown() {
    assert_eq!(harness_prompt("claude")["source"], "Claude Code");
    assert_eq!(harness_prompt("codex")["source"], "Codex");
    assert_eq!(harness_prompt("")["source"], "the harness");
}
