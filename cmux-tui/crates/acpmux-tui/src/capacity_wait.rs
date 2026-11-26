//! A terminal chat waiting for capacity draws what the GUI chat draws (RFD model-overload-smoothing
//! §3.8). Leo, 2026-11-24: "fix 529s properly with better designs", then "in terminals and guis
//! alike perhaps terminal simply needs to also have the fixes and enhancements".
//!
//! acpmux decides the wait (`acpmux/src/hub/capacity_wait.rs`, the session row's `capacityWait`)
//! and continues the cut turn by itself. The GUI pane (`webviews/.../capacityWait.ts`) draws it as
//! one calm line, "Waiting for capacity, about 40s", with the raw "API Error: 529 …" only under
//! Details, never the failure red. The TUI drew the red error card with nothing saying it goes on.
//! Here it draws the same: the held turn's error becomes a calm note, and the footer counts down.

use acpmux::transcript::{Item, Transcript};
use serde_json::Value;

/// The row's `capacityWait`, or None when it has none (or an older acpmux sent an unknown reason).
pub(crate) fn of_row(row: Option<&Value>) -> Option<Value> {
    let wait = row?.get("capacityWait")?;
    matches!(wait.get("reason").and_then(Value::as_str), Some("capacity" | "rate_limit"))
        .then(|| wait.clone())
}

/// The last turn's error item: an `Error` after the last sent prompt. That is the turn acpmux
/// continues (the row's `turnId` is the latest cut turn; the transcript keys no turn ids).
fn last_turn_error(t: &Transcript) -> Option<usize> {
    let from = t
        .items
        .iter()
        .rposition(|i| matches!(i, Item::User { queued: false, .. }))
        .map_or(0, |u| u + 1);
    (from..t.items.len()).rev().find(|&i| matches!(t.items.get(i), Some(Item::Error { .. })))
}

/// The error item acpmux holds and goes on from: drawn calm, never red. None without a wait.
pub(crate) fn held_error(t: &Transcript) -> Option<usize> {
    t.capacity_wait.as_ref()?;
    last_turn_error(t)
}

/// Put the row's wait on its transcript. A change re-lays the held error and the footer only.
pub(crate) fn sync(t: &mut Transcript, wait: Option<Value>) {
    if t.capacity_wait == wait {
        return;
    }
    t.capacity_wait = wait;
    let from = last_turn_error(t).unwrap_or(t.items.len());
    t.layout_dirty_from = t.layout_dirty_from.min(from);
}

/// "40s", "3m 15s", "about 2 h": the GUI's `aboutTime`, rounded as the wait grows.
pub(crate) fn about_time(seconds: f64) -> String {
    if seconds < 10.0 {
        return format!("{}s", seconds.ceil().max(1.0) as u64);
    }
    if seconds < 60.0 {
        return format!("{}s", ((seconds / 5.0).ceil() * 5.0) as u64);
    }
    if seconds < 600.0 {
        let m = (seconds / 60.0).floor() as u64;
        let s = (((seconds % 60.0) / 15.0).round() * 15.0) as u64;
        return match s {
            0 => format!("{m}m"),
            60 => format!("{}m", m + 1),
            s => format!("{m}m {s}s"),
        };
    }
    if seconds < 5400.0 {
        return format!("{}m", (seconds / 60.0).round() as u64);
    }
    format!("{}h", (seconds / 3600.0).round() as u64)
}

/// The wait's line at `now` (epoch ms): "Waiting for capacity, about 40s", or "…, any moment
/// now" once its time passed or while acpmux has not decided it yet. The GUI's `capacityEta`.
pub(crate) fn line(wait: &Value, now: u64) -> String {
    let left = wait
        .get("resumesAt")
        .and_then(Value::as_u64)
        .filter(|&at| at > 0)
        .map(|at| (at as f64 - now as f64) / 1000.0);
    match left {
        Some(left) if left > 1.0 => format!("Waiting for capacity, about {}", about_time(left)),
        _ => "Waiting for capacity, any moment now".to_owned(),
    }
}

/// The note the held error card shows in place of the raw harness error.
pub(crate) const GOES_ON: &str = "The chat goes on by itself.";

#[cfg(test)]
mod tests {
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
        assert!(red.contains("✗ API Error"), "{red}");

        sync(&mut t, Some(serde_json::json!({"reason": "capacity", "resumesAt": 0})));
        let calm = text(&t);
        assert!(!calm.contains('✗'), "never red while acpmux holds the turn: {calm}");
        assert!(calm.contains("◷ Waiting for capacity · The chat goes on by itself."), "{calm}");
        assert!(calm.contains("API Error: Repeated 529"), "the raw error stays, dim: {calm}");
        assert!(calm.contains("◷ Waiting for capacity, any moment now"), "{calm}");
    }
}
