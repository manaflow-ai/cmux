use super::*;

#[test]
fn the_answer_becomes_the_harness_command() {
    let answer = json!({"resume": {"argv": ["claude", "--resume", "a b"], "cwd": "/tmp",
        "env": {"CLAUDE_CONFIG_DIR": "/h/.claude"}}});
    let r = Resume::from_answer(&answer).unwrap();
    assert_eq!(r.argv, ["claude", "--resume", "a b"]);
    assert_eq!(r.cwd.as_deref(), Some("/tmp"));
    assert_eq!(r.line(), "CLAUDE_CONFIG_DIR=/h/.claude claude --resume 'a b'");
    assert!(Resume::from_answer(&json!({"resume": {"argv": []}})).is_err());
}
