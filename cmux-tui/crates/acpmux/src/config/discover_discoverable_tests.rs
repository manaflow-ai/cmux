use super::*;

#[test]
fn names_discovery_adds_are_discoverable_and_others_are_not() {
    for name in ["claude", "codex", "gemini", "opencode", "cmux", "claude-sr", "claude-cr"] {
        assert!(discoverable(name), "{name}");
    }
    for name in ["claud", "chief", "unii", "my-profile", ""] {
        assert!(!discoverable(name), "{name}");
    }
}
