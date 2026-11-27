use super::*;
use serde_json::json;

fn transcript(items: Vec<Item>) -> Transcript {
    let mut t = Transcript::default();
    t.items = items;
    t.layout_dirty_from = usize::MAX;
    t
}

fn user(text: &str) -> Item {
    Item::User { text: text.into(), steer: false, queued: false }
}

#[test]
fn reads_only_known_reasons() {
    let row = json!({"capacityWait": {"reason": "capacity", "resumesAt": 5}});
    assert_eq!(of_row(Some(&row)), Some(json!({"reason": "capacity", "resumesAt": 5})));
    let rate = json!({"capacityWait": {"reason": "rate_limit"}});
    assert!(of_row(Some(&rate)).is_some());
    assert_eq!(of_row(Some(&json!({"capacityWait": {"reason": "context"}}))), None);
    assert_eq!(of_row(Some(&json!({"capacityWait": null}))), None);
    assert_eq!(of_row(Some(&json!({}))), None);
    assert_eq!(of_row(None), None);
}

#[test]
fn about_time_matches_the_gui() {
    // webviews' capacityWait.test.tsx cases first, then the rounding edges.
    assert_eq!(about_time(38.2), "40s");
    assert_eq!(about_time(0.4), "1s");
    assert_eq!(about_time(195.0), "3m 15s");
    assert_eq!(about_time(12.0 * 60.0), "12m");
    assert_eq!(about_time(0.2), "1s");
    assert_eq!(about_time(7.0), "7s");
    assert_eq!(about_time(38.0), "40s");
    assert_eq!(about_time(60.0), "1m");
    assert_eq!(about_time(185.0), "3m");
    assert_eq!(about_time(197.0), "3m 15s");
    assert_eq!(about_time(173.0), "3m");
    assert_eq!(about_time(179.0), "3m");
    assert_eq!(about_time(1500.0), "25m");
    assert_eq!(about_time(7200.0), "2h");
}

#[test]
fn line_counts_down_then_says_any_moment() {
    let wait = json!({"reason": "capacity", "resumesAt": 100_000});
    assert_eq!(line(&wait, 62_000), "Waiting for capacity, about 40s");
    assert_eq!(line(&wait, 99_500), "Waiting for capacity, any moment now");
    assert_eq!(line(&wait, 200_000), "Waiting for capacity, any moment now");
    assert_eq!(line(&json!({"reason": "capacity"}), 1), "Waiting for capacity, any moment now");
}

#[test]
fn holds_only_the_last_turns_error() {
    let mut t = transcript(vec![
        user("one"),
        Item::Error { text: "API Error: 529 old".into() },
        user("two"),
        Item::Error { text: "API Error: Repeated 529 Overloaded errors".into() },
    ]);
    assert_eq!(held_error(&t), None, "no wait, nothing held");
    sync(&mut t, Some(json!({"reason": "capacity"})));
    assert_eq!(held_error(&t), Some(3));
    assert_eq!(t.layout_dirty_from, 3, "only the held error re-lays");

    // A newer prompt with no error of its own: nothing of the old turn is held.
    t.items.push(user("three"));
    assert_eq!(held_error(&t), None);
}

#[test]
fn sync_marks_dirty_on_change_only() {
    let mut t = transcript(vec![user("one"), Item::Error { text: "529".into() }]);
    let wait = Some(json!({"reason": "capacity", "resumesAt": 9}));
    sync(&mut t, wait.clone());
    assert_eq!(t.layout_dirty_from, 1);
    t.layout_dirty_from = usize::MAX;
    sync(&mut t, wait);
    assert_eq!(t.layout_dirty_from, usize::MAX, "same wait: no layout work");
    sync(&mut t, None);
    assert_eq!(t.layout_dirty_from, 1, "the error turns red again");
    assert_eq!(held_error(&t), None);
}

#[test]
fn held_error_draws_calm_with_a_countdown_footer() {
    let c = crate::theme::Chrome::dark();
    let mut t = transcript(vec![
        user("go"),
        Item::Error { text: "API Error: Repeated 529 Overloaded errors".into() },
    ]);
    t.status = "idle".into();
    let text = |t: &Transcript| {
        crate::render::transcript_rows(t, 80, false, false, &Default::default(), &c)
            .iter()
            .map(|r| r.text.clone())
            .collect::<Vec<_>>()
            .join("\n")
    };
    let red = text(&t);
    // A red capacity error leads with the GUI's plain sentence (failure_copy), raw text under it.
    assert!(red.contains("✗ The agent is rate limited or out of capacity."), "{red}");
    assert!(red.contains("API Error: Repeated 529"), "{red}");

    sync(&mut t, Some(serde_json::json!({"reason": "capacity", "resumesAt": 0})));
    let calm = text(&t);
    assert!(!calm.contains('✗'), "never red while acpmux holds the turn: {calm}");
    assert!(calm.contains("◷ Waiting for capacity · The chat goes on by itself."), "{calm}");
    assert!(calm.contains("API Error: Repeated 529"), "the raw error stays, dim: {calm}");
    assert!(calm.contains("◷ Waiting for capacity, any moment now"), "{calm}");
}
