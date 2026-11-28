use super::*;

#[test]
fn codex_is_told_its_own_computer_use_comes_first() {
    let codex = json!({"clientInfo": {"name": "codex-mcp-client", "version": "1"}});
    assert!(defers_to_own_computer_use(&codex));
    assert_eq!(initialize(&codex)["instructions"], DEFER_INSTRUCTIONS);
    let listed = tools_list(true);
    for tool in listed["tools"].as_array().unwrap() {
        assert!(tool["description"].as_str().unwrap().starts_with(DEFER_PREFIX));
    }
    // Codex whose own Computer Use is off (served with --primary):
    // cmux Computer Use is its Computer Use, not a second choice.
    assert!(!client_defers(&codex, true));
    assert_eq!(initialize_with(&codex, false)["instructions"], tools::INSTRUCTIONS);
    let claude = json!({"clientInfo": {"name": "claude-code", "version": "2"}});
    assert!(!defers_to_own_computer_use(&claude));
    assert!(!client_defers(&claude, false));
    assert_eq!(initialize(&claude)["instructions"], tools::INSTRUCTIONS);
    assert!(
        !tools_list(false)["tools"][0]["description"].as_str().unwrap().starts_with(DEFER_PREFIX)
    );
}
