//! The Chief's send-agents skill (https://github.com/manaflow-ai/cmux/issues/52990):
//! "send Claude" and "send Codex" start agent chats in the app, each in its own
//! `<issue#>: <liner>` workspace at the top, Claude on Opus 5.5 at medium effort
//! (https://github.com/manaflow-ai/cmux/issues/57789), an issue filed first, and every
//! agent is told to open its pull request in the right split and keep going until it is
//! ready. It names no one person's setup.

use optchat_chief::skills;

fn shipped() -> String {
    let dir = tempfile::tempdir().unwrap();
    let shared = skills::shared_dir(&dir.path().join("default"));
    let written = skills::install_builtin(&shared).unwrap();
    assert!(written.contains(&"send-agents".to_owned()), "{written:?}");
    let loaded = skills::load(&shared, &skills::chief_dir(&dir.path().join("default")));
    let skill = loaded
        .iter()
        .find(|s| s.name == "send-agents")
        .expect("send-agents loads");
    assert!(
        skill.description.contains("send Claude"),
        "{}",
        skill.description
    );
    // Words, not line breaks: rewrapping the skill keeps the tests green.
    let text = std::fs::read_to_string(&skill.path).unwrap();
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[test]
fn the_send_agents_skill_ships_with_the_whole_recipe() {
    let text = shipped();
    for needle in [
        "cmux --json agents chat new --top --harness claude --model claude-opus-5-5",
        "--effort medium",
        "Claude runs on Opus 5.5 at medium effort",
        "--harness codex",
        "file one first (`gh issue create`)",
        "never the person's raw prompt",
        "exactly `<issue#>: <3-5 word liner>`",
        "never a `#`",
        "`PR #<number>: <3-5 words>`",
        "Never `cmux workspace create` first (it adds a terminal)",
        "no helper chat, subagent or workspace",
        "cmux --json workspace list",
        "Never start a second agent on the same issue.",
        "move --index 0",
        "cmux --json agents chat state <chat>",
        "cmux://workspace/ws_",
        "never start other agent chats or workspaces",
        "right split of your own workspace",
        "split --right --ratio 0.5",
        "Keep going until the pull request is ready",
        "quit it once you are done verifying",
        "Never move the person's focus.",
        "check it against real data",
        "`feat-cmux-next` whose change was verified",
        "squash-merge it (`gh pr merge <n> --squash`)",
        "Pull requests to any other branch wait for the person.",
        "close the workspace you made for it",
    ] {
        assert!(text.contains(needle), "send-agents lacks {needle:?}");
    }
}

#[test]
fn the_send_agents_skill_names_no_person() {
    let text = shipped();
    for word in [
        "sr2",
        "gpt-",
        "--dangerously-skip-permissions",
        "Austin",
        "Andrii",
        "Stanford",
        "Ramp",
        "cmuxterm-hq",
        "/Users/",
    ] {
        assert!(!text.contains(word), "send-agents names {word:?}");
    }
}
