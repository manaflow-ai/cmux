use super::*;

#[test]
fn index_ids_and_the_acpmux_claude_harness_both_parse() {
    let claude = parse_key("claude:s-1").unwrap();
    assert_eq!((claude.harness, claude.session_id.as_str()), (AdapterKind::ClaudeCode, "s-1"));
    assert_eq!(parse_key("claude-code:s-1").unwrap().harness, AdapterKind::ClaudeCode);
    assert_eq!(parse_key("codex:s-2").unwrap().harness, AdapterKind::Codex);
    assert_eq!(key_text(&claude), "claude-code:s-1");
    assert!(parse_key("claude:").is_none());
    assert!(parse_key("aider:s-3").is_none());
    assert!(parse_key("no-colon").is_none());
}
