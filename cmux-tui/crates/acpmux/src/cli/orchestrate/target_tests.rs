#[test]
fn splits_on_the_first_slash_only() {
    assert_eq!(super::split_target("claude"), ("claude".into(), None));
    assert_eq!(super::split_target("claude/opus"), ("claude".into(), Some("opus".into())));
    assert_eq!(
        super::split_target("opencode/zai/glm-5.1"),
        ("opencode".into(), Some("zai/glm-5.1".into()))
    );
    assert_eq!(
        super::split_target("pi/openrouter/deepseek/deepseek-v4"),
        ("pi".into(), Some("openrouter/deepseek/deepseek-v4".into()))
    );
    assert_eq!(super::split_target("codex/"), ("codex".into(), None));
}
