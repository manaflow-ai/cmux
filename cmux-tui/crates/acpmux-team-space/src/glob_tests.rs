use super::matches;

#[test]
fn segment_and_tree_stars() {
    assert!(matches("cmux-tui/crates/acpmux/**", "cmux-tui/crates/acpmux/src/hub/inbox.rs"));
    assert!(matches("cmux-tui/crates/acpmux/**", "cmux-tui/crates/acpmux"));
    assert!(!matches("cmux-tui/crates/acpmux/**", "cmux-tui/crates/acpmux-core/src/lib.rs"));
    assert!(matches("cmux-tui/crates/*/Cargo.toml", "cmux-tui/crates/acpmux/Cargo.toml"));
    assert!(!matches("cmux-tui/crates/*/Cargo.toml", "cmux-tui/crates/a/b/Cargo.toml"));
    assert!(matches("label:forum*", "label:Forum-hosted"));
    assert!(matches("?ebviews/**", "webviews/src/x.tsx"));
    assert!(!matches("label:forum", "label:forums"));
    assert!(matches("**", "anything/at/all"));
}
