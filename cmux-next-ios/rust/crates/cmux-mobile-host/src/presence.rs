//! Whether the person is at this Mac, so a phone push for something the Mac
//! already shows can stay on the Mac.
//!
//! With `CMUX_MOBILE_PUSH_WHEN_AWAY=1`, a finished turn, a failed turn, a
//! Chief reply and a terminal notification go to the phones only when this Mac
//! has had no keyboard, mouse or trackpad input for [`PRESENT_WITHIN`]. A
//! question or a permission request always goes: the agent is stopped until
//! someone answers, and the person may have stepped away a moment ago. The
//! setting is off by default, so pushes are unchanged until it is turned on.
//!
//! The idle clock is CoreGraphics' `CGEventSourceSecondsSinceLastEventType`
//! for the combined session state, which counts input from every device in the
//! logged-in session. When the clock cannot be read (not macOS, or a process
//! outside the person's GUI session), the person counts as away and the push
//! goes, so no push is ever lost to a failed read.

use std::time::Duration;

/// Input this recent means the person is at the Mac.
pub const PRESENT_WITHIN: Duration = Duration::from_secs(120);

/// Whether `CMUX_MOBILE_PUSH_WHEN_AWAY=1` is set.
pub fn when_away_enabled() -> bool {
    std::env::var("CMUX_MOBILE_PUSH_WHEN_AWAY").is_ok_and(|v| v.trim() == "1")
}

/// Kinds the Mac shows the person itself, which a phone push only repeats
/// while they are at it. Asks (`question`, `permission`) are never in this set.
pub fn repeats_the_mac(kind: &str) -> bool {
    matches!(kind, "completed" | "failed" | "chief" | "terminal")
}

/// Whether a push of `kind` stays on the Mac: the setting is on, the kind is
/// one the Mac shows, and the Mac had input within [`PRESENT_WITHIN`]
/// (`idle` None, unreadable, means away).
pub fn stays_on_mac(enabled: bool, kind: &str, idle: Option<Duration>) -> bool {
    enabled && repeats_the_mac(kind) && idle.is_some_and(|idle| idle < PRESENT_WITHIN)
}

/// Time since this Mac's last keyboard, mouse or trackpad input; None when it
/// cannot be read.
#[cfg(target_os = "macos")]
pub fn idle() -> Option<Duration> {
    #[link(name = "CoreGraphics", kind = "framework")]
    unsafe extern "C" {
        fn CGEventSourceSecondsSinceLastEventType(state: i32, event_type: u32) -> f64;
    }
    const COMBINED_SESSION_STATE: i32 = 0; // kCGEventSourceStateCombinedSessionState
    const ANY_INPUT_EVENT: u32 = u32::MAX; // kCGAnyInputEventType
    // SAFETY: a pure query with plain integer arguments; it returns a double.
    let seconds = unsafe { CGEventSourceSecondsSinceLastEventType(COMBINED_SESSION_STATE, ANY_INPUT_EVENT) };
    (seconds.is_finite() && seconds >= 0.0).then(|| Duration::from_secs_f64(seconds))
}

/// Not macOS: unreadable, so the person counts as away.
#[cfg(not(target_os = "macos"))]
pub fn idle() -> Option<Duration> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    const RECENT: Option<Duration> = Some(Duration::from_secs(5));
    const LONG_AGO: Option<Duration> = Some(Duration::from_secs(600));

    #[test]
    fn a_finished_turn_stays_on_a_mac_in_use() {
        for kind in ["completed", "failed", "chief", "terminal"] {
            assert!(stays_on_mac(true, kind, RECENT), "{kind}");
        }
    }

    #[test]
    fn an_ask_always_reaches_the_phone() {
        for kind in ["question", "permission"] {
            assert!(!stays_on_mac(true, kind, RECENT), "{kind}");
        }
    }

    #[test]
    fn an_idle_mac_sends_everything() {
        assert!(!stays_on_mac(true, "completed", LONG_AGO));
        assert!(!stays_on_mac(true, "completed", Some(PRESENT_WITHIN)));
    }

    #[test]
    fn an_unreadable_clock_counts_as_away() {
        assert!(!stays_on_mac(true, "completed", None));
    }

    #[test]
    fn off_by_default_changes_nothing() {
        assert!(!stays_on_mac(false, "completed", RECENT));
    }

    #[test]
    fn an_unknown_kind_is_sent() {
        assert!(!stays_on_mac(true, "review", RECENT));
    }
}
