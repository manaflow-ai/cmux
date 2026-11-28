use super::*;

#[test]
fn names_agents_as_the_gui_does() {
    assert_eq!(display_name("deepseek"), "DeepSeek");
    assert_eq!(display_name("providers/deepseek"), "DeepSeek");
    assert_eq!(display_name("claude-sr"), "Claude Code");
    assert_eq!(display_name("opencode-v2"), "OpenCode");
    assert_eq!(display_name("my-agent"), "My Agent");
    assert_eq!(known("cmux"), None);
}
