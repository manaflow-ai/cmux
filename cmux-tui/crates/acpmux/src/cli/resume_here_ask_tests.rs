use super::*;

fn pending(pid: &str, title: &str) -> Value {
    json!({"permissionId": pid, "request": {
    "toolCall": {"toolCallId": "t1", "title": title, "kind": "execute",
                 "rawInput": {"command": "touch /tmp/x"}},
    "options": [
        {"optionId": "yes", "name": "Allow", "kind": "allow_once"},
        {"optionId": "always", "name": "Always allow", "kind": "allow_always"},
        {"optionId": "no", "name": "Reject", "kind": "reject_once"},
    ]}})
}

/// A pending permission prints its title, its command and its options numbered; a number
/// answers it with that option; what else is typed asks again.
#[test]
fn a_pending_permission_shows_numbered_and_a_number_answers_it() {
    let mut ask = Ask::default();
    assert_eq!(ask.pending(&[]), None);
    assert!(!ask.asking());
    let shown = ask.pending(&[pending("p1", "Bash")]).expect("the question shows");
    assert!(shown.contains("permission needed:\x1b[0m Bash\n"), "{shown}");
    assert!(shown.contains("    touch /tmp/x\n"), "{shown}");
    assert!(shown.contains("  1. Allow\n  2. Always allow\n  3. Reject\n"), "{shown}");
    assert!(shown.contains("only the cmux app can allow (1, 2)"), "{shown}");
    assert!(ask.asking());
    // The same pending list again prints nothing.
    assert_eq!(ask.pending(&[pending("p1", "Bash")]), None);
    assert_eq!(ask.pick("x\n"), Err("type a number from 1 to 3 and Enter\n".into()));
    assert_eq!(ask.pick("4\n"), Err("type a number from 1 to 3 and Enter\n".into()));
    assert_eq!(ask.pick(" 3\n"), Ok(Answer { permission_id: "p1".into(), option_id: "no".into() }));
    // Its decision lands: the terminal says what it answered, and stops reading.
    assert_eq!(ask.pending(&[]).as_deref(), Some("answered: Reject\n"));
    assert!(!ask.asking());
    assert_eq!(ask.pick("1\n"), Err(String::new()));
}

/// One answered in the chat is no longer asked here; the next pending one shows.
#[test]
fn a_permission_answered_in_the_chat_is_withdrawn_and_the_next_shows() {
    let mut ask = Ask::default();
    ask.pending(&[pending("p1", "Bash"), pending("p2", "Edit")]);
    let next = ask.pending(&[pending("p2", "Edit")]).expect("changed");
    assert!(next.starts_with("answered in the chat\n"), "{next}");
    assert!(next.contains("permission needed:\x1b[0m Edit\n"), "{next}");
    assert_eq!(ask.pick("1"), Ok(Answer { permission_id: "p2".into(), option_id: "yes".into() }));
}

/// An allow the daemon refuses (only the cmux app may allow) says to switch to Chat, and the
/// question stays up; a later answer from the chat reads as the chat's.
#[test]
fn a_refused_allow_names_the_chat_and_keeps_the_question() {
    let mut ask = Ask::default();
    ask.pending(&[pending("p1", "Bash")]);
    ask.pick("1").unwrap();
    let refused = crate::client::DaemonError(crate::hub::person::person_required("allowing"));
    let text = ask.refused(&refused.into());
    assert!(text.contains("switch this pane to Chat"), "{text}");
    assert!(ask.asking());
    assert_eq!(ask.pending(&[]).as_deref(), Some("answered in the chat\n"));
}

/// An agent question is answered in the chat: no numbers here.
#[test]
fn a_question_points_to_the_chat() {
    let mut ask = Ask::default();
    let mut q = pending("p1", "Which color?");
    q["request"]["toolCall"]["_meta"] = json!({"acpmux": {"question": {"items": []}}});
    let shown = ask.pending(&[q]).unwrap();
    assert!(shown.contains("answer it in the chat"), "{shown}");
    assert!(!shown.contains("1. Allow"), "{shown}");
    assert!(!ask.asking());
}
