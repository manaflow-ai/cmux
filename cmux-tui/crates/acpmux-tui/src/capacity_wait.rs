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
#[path = "capacity_wait_tests.rs"]
mod tests;
