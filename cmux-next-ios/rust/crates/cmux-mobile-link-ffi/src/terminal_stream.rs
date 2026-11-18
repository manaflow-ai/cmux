//! When a phone's terminal page keeps its Mac output stream open.
//!
//! Leo, 2026-11-14: "surely we don't need to stream the f***ing thing". A
//! terminal page nobody looks at receives nothing: past a short grace its
//! attach channel closes (the phone keeps its Ghostty grid and last frame as
//! the cache), and shown again it attaches once, which replays the Mac's
//! screen as it is now. Output with nobody watching costs the phone 0 bytes.
//!
//! The decision is this module's; Swift (`TerminalStreamGate`,
//! CmuxMobileTerminal) feeds it the page's states and times and applies the
//! answer to the session (`TerminalSession.setStreaming`).
//!
//! - On screen, taking input, in the foreground app: stream.
//! - Off screen (another tab, the workspace grid or list, mid-swipe) in the
//!   foreground: stream for [`OFF_SCREEN_GRACE_MS`], then stop. A quick tab
//!   flip, a peek at the grid or a swipe across tabs comes back inside it and
//!   finds the page live, with no attach and no replay.
//! - On screen when the app left the foreground (another app, the lock
//!   screen): stream for [`BACKGROUND_GRACE_MS`], the same 45 s the page keeps
//!   its size claim on the Mac (`TerminalSizeClaimDebounce.backgroundDelay`),
//!   so an app switch or a lock and unlock inside it changes nothing.
//! - Off screen and in the background: the off-screen grace, counted from
//!   when the page left the screen (the background never lengthens it).

/// How long a page off screen in the foreground keeps streaming. The size
/// claim is released after 1 s; 3 s keeps a tab flip, a peek at the grid
/// and a swipe across tabs (each well under 2 s) live, and costs at most 3 s
/// of a hidden page's output.
pub const OFF_SCREEN_GRACE_MS: u64 = 3_000;

/// How long a page on screen keeps streaming after the app left the
/// foreground: the Mac's size lease (`size-lease-v1`), which the page's size
/// claim keeps for as long.
pub const BACKGROUND_GRACE_MS: u64 = 45_000;

/// A terminal page's states. Times are milliseconds since the state began,
/// on one monotonic clock Swift picks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct TerminalStreamFacts {
    /// The page is on screen, settled and taking input.
    pub page_shown: bool,
    /// The app is in the foreground.
    pub app_active: bool,
    /// Since the page left the screen (`None` while it is shown).
    pub off_screen_ms: Option<u64>,
    /// Since the app left the foreground (`None` while it is active).
    pub background_ms: Option<u64>,
}

/// What the session does now, and when to ask again.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct TerminalStreamPlan {
    /// Keep (or open) the output stream; false: close it, keep the cache.
    pub stream: bool,
    /// Ask again this many milliseconds from now, with no new state
    /// (`None`: nothing changes until a state does).
    pub recheck_in_ms: Option<u64>,
}

fn after_grace(elapsed: Option<u64>, grace: u64) -> TerminalStreamPlan {
    let elapsed = elapsed.unwrap_or(0);
    if elapsed >= grace {
        TerminalStreamPlan { stream: false, recheck_in_ms: None }
    } else {
        TerminalStreamPlan { stream: true, recheck_in_ms: Some(grace - elapsed) }
    }
}

/// Whether the page's output stream stays open now (see the module docs).
#[uniffi::export]
pub fn terminal_stream_plan(facts: TerminalStreamFacts) -> TerminalStreamPlan {
    if !facts.page_shown {
        return after_grace(facts.off_screen_ms, OFF_SCREEN_GRACE_MS);
    }
    if !facts.app_active {
        return after_grace(facts.background_ms, BACKGROUND_GRACE_MS);
    }
    TerminalStreamPlan { stream: true, recheck_in_ms: None }
}

#[cfg(test)]
mod tests {
    use super::{TerminalStreamFacts, TerminalStreamPlan, terminal_stream_plan};

    fn facts(shown: bool, active: bool, off: Option<u64>, bg: Option<u64>) -> TerminalStreamFacts {
        TerminalStreamFacts { page_shown: shown, app_active: active, off_screen_ms: off, background_ms: bg }
    }

    const fn plan(stream: bool, recheck: Option<u64>) -> TerminalStreamPlan {
        TerminalStreamPlan { stream, recheck_in_ms: recheck }
    }

    #[test]
    fn a_page_streams_only_while_someone_can_see_it() {
        let table: &[(&str, TerminalStreamFacts, TerminalStreamPlan)] = &[
            ("shown in the foreground", facts(true, true, None, None), plan(true, None)),
            // Off screen in the foreground: 3 s, then nothing.
            ("just left the screen", facts(false, true, Some(0), None), plan(true, Some(3_000))),
            ("a quick tab flip", facts(false, true, Some(1_200), None), plan(true, Some(1_800))),
            ("one tick before the grace", facts(false, true, Some(2_999), None), plan(true, Some(1))),
            ("at the grace", facts(false, true, Some(3_000), None), plan(false, None)),
            ("long off screen", facts(false, true, Some(600_000), None), plan(false, None)),
            // A page never shown (built for a card): its grace runs from its build.
            ("never shown, no time yet", facts(false, true, None, None), plan(true, Some(3_000))),
            // On screen when the app left: the size claim's 45 s.
            ("just backgrounded", facts(true, false, None, Some(0)), plan(true, Some(45_000))),
            ("an app switch", facts(true, false, None, Some(20_000)), plan(true, Some(25_000))),
            ("at 45 s in the background", facts(true, false, None, Some(45_000)), plan(false, None)),
            ("locked overnight", facts(true, false, None, Some(36_000_000)), plan(false, None)),
            // Off screen and in the background: the off-screen grace, from when it left.
            (
                "off screen, then backgrounded",
                facts(false, false, Some(1_000), Some(500)),
                plan(true, Some(2_000)),
            ),
            (
                "off screen past the grace, backgrounded",
                facts(false, false, Some(3_000), Some(10)),
                plan(false, None),
            ),
        ];
        for (name, facts, want) in table {
            assert_eq!(terminal_stream_plan(*facts), *want, "{name}");
        }
    }

    #[test]
    fn a_recheck_always_lands_on_the_decision_it_waits_for() {
        // Asking again after `recheck_in_ms` with the same states stops the stream.
        for start in [facts(false, true, Some(0), None), facts(true, false, None, Some(0))] {
            let first = terminal_stream_plan(start);
            assert!(first.stream);
            let wait = first.recheck_in_ms.unwrap_or_default();
            let later = TerminalStreamFacts {
                off_screen_ms: start.off_screen_ms.map(|ms| ms + wait),
                background_ms: start.background_ms.map(|ms| ms + wait),
                ..start
            };
            assert_eq!(terminal_stream_plan(later), plan(false, None));
        }
    }
}
