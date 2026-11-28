//! The one line a fleet hold is shown in (`session hold --fleet`, `--status`, `daemon status`):
//! who set it, why, how long ago, when it lifts, and how many chats it holds. A hold nobody saw
//! idled every chat on a host (2026-11-25), so every read that meets one names it.

use crate::hub::session_hold::FleetHold;

/// `fleet hold on (N chats held), set by BY 2h ago: REASON; lifts in 10h (`acpmux session
/// release --fleet` lifts it now)`.
pub(crate) fn fleet_hold_line(hold: &FleetHold, held: Option<u64>) -> String {
    fleet_hold_line_at(hold, held, crate::store::now_ms())
}

pub(crate) fn fleet_hold_line_at(hold: &FleetHold, held: Option<u64>, now_ms: u64) -> String {
    let mut line = "fleet hold on".to_owned();
    if let Some(n) = held {
        line.push_str(&format!(" ({n} chats held)"));
    }
    line.push_str(&format!(
        ", set by {} {} ago",
        hold.by.as_deref().unwrap_or("an unnamed caller"),
        span(now_ms.saturating_sub(hold.at))
    ));
    if let Some(reason) = hold.reason.as_deref().filter(|r| !r.trim().is_empty()) {
        line.push_str(&format!(": {reason}"));
    }
    match hold.until {
        Some(until) => line.push_str(&format!("; lifts in {}", span(until.saturating_sub(now_ms)))),
        None => line.push_str("; never lifts by itself"),
    }
    line.push_str(" (`acpmux session release --fleet` lifts it now)");
    line
}

/// `45s`, `12m`, `3h05m`, `2d04h`.
fn span(ms: u64) -> String {
    let s = ms / 1000;
    match s {
        0..60 => format!("{s}s"),
        60..3600 => format!("{}m", s / 60),
        3600..86_400 => format!("{}h{:02}m", s / 3600, (s % 3600) / 60),
        _ => format!("{}d{:02}h", s / 86_400, (s % 86_400) / 3600),
    }
}

#[cfg(test)]
#[path = "hold_line_tests.rs"]
mod tests;
