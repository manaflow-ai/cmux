use super::*;

fn turn(who: &str, text: &str) -> AgentTurn {
    AgentTurn { who: who.to_owned(), text: text.to_owned() }
}

fn user(seq: u64, text: &str) -> Value {
    json!({"seq": seq, "dir": "mux", "kind": "user_message", "msg": {"text": text}})
}

fn chunk(seq: u64, text: &str) -> Value {
    json!({"seq": seq, "dir": "in", "kind": "session/update", "msg": {"method": "session/update",
        "params": {"update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}}})
}

fn tool(seq: u64) -> Value {
    json!({"seq": seq, "dir": "in", "kind": "session/update", "msg": {"method": "session/update",
        "params": {"update": {"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "ls"}}}})
}

#[test]
fn the_text_keeps_the_newest_three_turns_with_who_spoke() {
    let turns = [turn("You", "one"), turn("Claude", "two"), turn("You", "three"), turn("Claude", "four")];
    let text = agent_screen(&turns).unwrap();
    assert_eq!(text, "Claude\ntwo\n\nYou\nthree\n\nClaude\nfour");
}

#[test]
fn empty_turns_give_no_text() {
    assert_eq!(agent_screen(&[]), None);
    assert_eq!(agent_screen(&[turn("You", "  "), turn("Claude", "\n")]), None);
    // An empty turn is not one of the three.
    let text =
        agent_screen(&[turn("You", "a"), turn("Claude", "b"), turn("You", "c"), turn("Claude", "")]).unwrap();
    assert!(text.starts_with("You\na"), "{text}");
}

#[test]
fn long_lines_wrap_to_eighty_columns_at_a_space() {
    let words = "word ".repeat(60);
    let text = agent_screen(&[turn("Claude", &words)]).unwrap();
    for line in text.lines() {
        assert!(line.chars().count() <= AGENT_SCREEN_COLS, "{line:?}");
    }
    assert!(text.lines().skip(1).all(|l| !l.starts_with(' ') && !l.ends_with(' ')));
    // A word longer than a row is cut hard.
    let rows = wrap(&"x".repeat(200), AGENT_SCREEN_COLS);
    assert_eq!(rows.iter().map(|r| r.chars().count()).collect::<Vec<_>>(), vec![80, 80, 40]);
}

#[test]
fn the_text_holds_at_most_four_kib_on_a_character_boundary() {
    for fill in ["a", "é", "日本", "🦀"] {
        let huge = fill.repeat(20_000);
        let turns = [turn("You", &huge), turn("Claude", &huge), turn("You", &huge)];
        let text = agent_screen(&turns).unwrap();
        assert!(text.len() <= MAX_AGENT_SCREEN_BYTES, "{fill}: {}", text.len());
        // Each of the three turns keeps its name and its share.
        assert_eq!(text.matches("\n\n").count(), 2, "{fill}");
        assert!(text.contains('…'));
        let one = agent_screen(&[turn("Claude", &huge)]).unwrap();
        assert!(one.len() <= MAX_AGENT_SCREEN_BYTES && one.len() > MAX_AGENT_SCREEN_BYTES / 2, "{fill}");
    }
}

#[test]
fn records_make_turns_of_the_persons_messages_and_the_agents_replies() {
    let records = [
        user(1, "fix the build"),
        chunk(2, "Looking"),
        tool(3),
        chunk(4, " at it."),
        user(5, "thanks"),
        chunk(6, "Done."),
        json!({"seq": 7, "dir": "in", "kind": "session/update.replay", "msg": {"method": "session/update",
            "params": {"update": {"sessionUpdate": "agent_message_chunk", "content": {"text": "old"}}}}}),
    ];
    assert_eq!(
        turns_of(&records, "Codex"),
        vec![
            turn("You", "fix the build"),
            turn("Codex", "Looking at it."),
            turn("You", "thanks"),
            turn("Codex", "Done.")
        ]
    );
}

#[test]
fn the_session_comes_from_the_fields_the_exposure_rule_reads() {
    assert_eq!(agent_session(&json!({"agent_session": "s1"})).as_deref(), Some("s1"));
    assert_eq!(
        agent_session(&json!({"conversation": {"agent_session": {"session": "s2"}}})).as_deref(),
        Some("s2")
    );
    assert_eq!(
        agent_session(&json!({"extra": {"conversation": {"agent_session": {"session": "s3"}}}})).as_deref(),
        Some("s3")
    );
    assert_eq!(agent_session(&json!({"session": "terminal-registry"})), None);
    assert_eq!(agent_name(&json!({"agent": "Claude"})), "Claude");
    assert_eq!(agent_name(&json!({"agent_session": {"session": "s", "harness": "codex"}})), "Codex");
    assert_eq!(agent_name(&json!({"conversation": {"agent_session": {"harness": "claude"}}})), "Claude");
    assert_eq!(agent_name(&json!({})), "Agent");
}
