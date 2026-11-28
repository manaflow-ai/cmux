use super::*;

#[test]
fn names_discovery_adds_are_discoverable_and_others_are_not() {
    for name in ["claude", "codex", "gemini", "opencode", "claude-sr"] {
        assert!(discoverable(name), "{name}");
    }
    for name in ["claud", "chief", "unii", "my-profile", ""] {
        assert!(!discoverable(name), "{name}");
    }
}
