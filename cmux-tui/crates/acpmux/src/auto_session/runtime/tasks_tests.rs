use super::*;

#[test]
fn a_harness_name_is_what_the_store_takes() {
    assert_eq!(harness_name("claude"), "claude");
    assert_eq!(harness_name("Claude Code"), "claudecode");
    assert_eq!(harness_name("-odd"), "agent");
    assert_eq!(harness_name(""), "agent");
    assert_eq!(harness_name(&"x".repeat(40)).len(), 32);
}
