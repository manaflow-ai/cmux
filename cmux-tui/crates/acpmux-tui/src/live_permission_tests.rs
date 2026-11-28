use super::*;

fn asking(status: &str) -> Transcript {
    let mut t = Transcript::default();
    t.items.push(Item::Permission {
        id: "p1".into(),
        title: "Run rm -rf build".into(),
        options: vec![("a".into(), "Allow".into(), "allow_once".into())],
        decided: None,
        question: None,
    });
    t.status = status.into();
    t
}

/// cmux#41497: an ask is drawn only while acpmux reports the chat running or waiting.
#[test]
fn an_ask_left_by_an_ended_turn_is_not_offered() {
    assert!(live_permission(&asking("waiting")).is_some());
    assert!(live_permission(&asking("running")).is_some());
    assert!(live_permission(&asking("")).is_some());
    assert!(live_permission(&asking("idle")).is_none());
    assert!(live_permission(&asking("error")).is_none());
}
