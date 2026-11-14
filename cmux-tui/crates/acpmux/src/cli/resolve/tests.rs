use super::*;

/// The refusal names each choice as the command to run, the ambiguous key swapped for it.
#[test]
fn an_ambiguous_name_prints_the_exact_command_for_each_host() {
    let data = json!({"reason": "session_ambiguous", "session": "review", "choices": [
        {"use": "mac-a/review"}, {"use": "hb/0199aaaa-1111"},
    ]});
    let args: Vec<String> =
        ["/usr/local/bin/acpmux", "send", "review", "ship it"].map(String::from).into();
    assert_eq!(
        choice_commands(&args, &data),
        ["acpmux send mac-a/review 'ship it'", "acpmux send hb/0199aaaa-1111 'ship it'"]
    );
    let other: Vec<String> = ["acpmux", "ls"].map(String::from).into();
    assert!(choice_commands(&other, &data).is_empty());
    // An option whose value is the key too keeps it.
    let from: Vec<String> =
        ["acpmux", "send", "--from", "review", "review", "hi"].map(String::from).into();
    assert_eq!(choice_commands(&from, &data)[0], "acpmux send --from review mac-a/review hi");
}

/// `resolve`'s cards: a closed session counts only when no live one matches.
#[test]
fn resolve_cards_skip_closed_sessions_and_refuse_several_live_ones() {
    let closed = json!({"name": "review", "host": "mac-a", "status": "closed",
                            "qualifiedSessionId": "local/m1"});
    let live = json!({"name": "hb/review", "host": "hb", "status": "idle",
                          "qualifiedSessionId": "hb/m3"});
    let other = json!({"name": "cmux16/review", "host": "cmux16", "status": "running",
                           "qualifiedSessionId": "cmux16/m5"});
    let one = [closed.clone(), live.clone()];
    assert_eq!(one_match("review", &one).unwrap()["qualifiedSessionId"], "hb/m3");
    let only_closed = [closed.clone()];
    assert_eq!(one_match("review", &only_closed).unwrap()["qualifiedSessionId"], "local/m1");
    let e = one_match("review", &[closed, live, other]).unwrap_err();
    assert_eq!(e.detail, crate::hub::key_route::AMBIGUOUS);
    assert_eq!(
        e.message,
        "\"review\" names 2 sessions: hb/review, cmux16/review; name one of them"
    );
    assert_eq!(e.data.unwrap()["choices"][1]["use"], "cmux16/review");
}

#[test]
fn a_card_prints_the_latest_reply_not_the_prompt() {
    let s = json!({
        "name": "b/review", "host": "b", "status": "idle",
        "qualifiedSessionId": "b/m1", "sessionId": "m1",
        "harness": "claude", "agentSessionId": "a1", "model": {"modelId": "opus"},
        "cwd": "/w", "gitBranch": "main",
        "lane": {"state": "idle", "title": "fix it"},
        "pullRequests": ["https://github.com/o/r/pull/1"],
        "lastTurn": {"status": "completed", "stopReason": "end_turn"},
        "lastPrompt": "do the thing",
        "lastMessage": {"role": "agent", "text": "done: #1"},
        "link": "https://cmux.com/deeplink/agent?harness=claude&session=a1&host=b",
    });
    let text = card(&s);
    assert!(text.starts_with("b/review  (b, idle)\n"), "{text}");
    assert!(text.contains("  last      done: #1\n"), "{text}");
    assert!(!text.contains("do the thing"), "{text}");
    assert!(text.contains("  model     opus\n"), "{text}");
    assert!(text.contains("  cwd       /w  [main]\n"), "{text}");
    assert!(text.contains("  PRs       https://github.com/o/r/pull/1\n"), "{text}");
    assert!(text.contains("  last turn end_turn\n"), "{text}");
}
