//! The redial policy: which attempt the next dial is, how long it waits, when a lost link starts
//! the backoff over, and when the machine stops dialing on its own and waits for the person.
//!
//! Pure (no clock, no I/O): the caller says how long the link was up. Swift's `LinkMachine` calls
//! it over uniffi (`cmux-mobile-link-ffi`, `link_redial_*`), and [`super::step`] calls it too, so
//! the phone and the port decide the same way.
//!
//! Why (Leo's endless reattach, 2026-11-24): a link that connected and then dropped, or failed its
//! first probe, redialed at attempt 1 every time. The attempt never grew, so the backoff never grew,
//! "Reconnecting" never turned into a failure with Retry, and the loop ran for as long as the app
//! was open. The rule here is acpmux's peer link's (`peer_link.rs`, `Link::down`): a drop counts as a
//! failed attempt unless the link had stayed up for [`STABLE_AFTER`].

use std::time::Duration;

use super::{BACKOFF, SILENT_RETRIES};

/// A link up this long before it dropped was stable: the next dial is a first one again (attempt 1,
/// at once). Shorter, the drop counts as a failed attempt. acpmux's `PeerLinkTimings::stable_after`.
pub const STABLE_AFTER: Duration = Duration::from_secs(60);

/// Attempts after a lost link that still read "Reconnecting"; from the next one the person is
/// offered Retry (Swift `LiveCoordinator.reconnectingAttempts`).
pub const RECONNECTING_ATTEMPTS: u32 = 6;

/// The last attempt the machine dials on its own. A failure of this one stops the redial: the
/// phase stays waiting with no retry scheduled, Retry is offered, and the next dial comes from
/// the person (Retry, opening a surface of the Mac, the app coming to the foreground) or from
/// news that the path changed (the network, the Mac's presence). With [`BACKOFF`] that is about
/// three minutes of 30 s retries after Retry is first offered.
pub const MAX_ATTEMPTS: u32 = 12;

/// What the machine does after a failed dial or a lost link.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Redial {
    /// Dial again now, as `attempt`.
    Now { attempt: u32 },
    /// Wait `after`, then dial `attempt + 1`; the phase is waiting at `attempt`.
    Wait { attempt: u32, after: Duration },
    /// No more dials on its own: the phase is waiting at `attempt` with nothing scheduled.
    Stop { attempt: u32 },
}

/// The delay before the dial after a failed `attempt`:
/// `backoff[min(max(attempt - 1 - SILENT_RETRIES, 0), count - 1)]`. An empty table waits zero.
pub fn retry_delay(backoff: &[Duration], attempt: u32) -> Duration {
    let index = attempt.saturating_sub(1).saturating_sub(SILENT_RETRIES) as usize;
    backoff.get(index).or(backoff.last()).copied().unwrap_or(Duration::ZERO)
}

/// After dial `attempt` failed: the first [`SILENT_RETRIES`] redial at once and say nothing; then
/// each waits its backoff; past [`MAX_ATTEMPTS`] nothing more is dialed on its own.
pub fn after_failure(backoff: &[Duration], attempt: u32) -> Redial {
    let attempt = attempt.max(1);
    if attempt <= SILENT_RETRIES {
        return Redial::Now { attempt: attempt + 1 };
    }
    if attempt >= MAX_ATTEMPTS {
        return Redial::Stop { attempt };
    }
    Redial::Wait { attempt, after: retry_delay(backoff, attempt) }
}

/// After the link the dial `connected_attempt` made dropped (or failed a probe) `up_for` after it
/// connected. Stable ([`STABLE_AFTER`]) or unknown: a first dial, at once. Shorter: the drop is a
/// failure of `connected_attempt`, so the next dial is the attempt after it and waits its backoff.
pub fn after_drop(backoff: &[Duration], connected_attempt: u32, up_for: Option<Duration>) -> Redial {
    match up_for {
        Some(up) if up < STABLE_AFTER => after_failure(backoff, connected_attempt),
        _ => Redial::Now { attempt: 1 },
    }
}

/// A dial restarted under news that its path changed (the network, the Mac's presence) counts as
/// an attempt, so a stream of that news cannot hold the attempt in place; it never passes
/// [`MAX_ATTEMPTS`], so the news always gets its dial.
pub fn restart_attempt(attempt: u32) -> u32 {
    attempt.saturating_add(1).min(MAX_ATTEMPTS)
}

/// The dial the person's Retry (or a surface opening) or a due retry starts from a wait at
/// `attempt`, stopped or not: one dial. Never past [`MAX_ATTEMPTS`], so its failure stops again at once and
/// Retry stays offered.
pub fn resume_attempt(attempt: u32) -> u32 {
    restart_attempt(attempt)
}

/// The dial news starts from a wait at `attempt`: the app back in the foreground, the phone's
/// network path changed, the Mac's presence came back. A stopped redial ([`MAX_ATTEMPTS`]) starts
/// over with every attempt, so stopping never strands the person: the next path or the person's
/// return tries again with no tap. Otherwise one more ([`restart_attempt`]).
pub fn news_attempt(attempt: u32) -> u32 {
    if attempt >= MAX_ATTEMPTS { 1 } else { restart_attempt(attempt) }
}

/// Whether a wait at `attempt` after a lost link offers Retry ("Can't reach"), not "Reconnecting".
pub fn offers_retry(attempt: u32) -> bool {
    attempt > RECONNECTING_ATTEMPTS
}

/// The default table, for callers with none of their own.
pub fn default_backoff() -> &'static [Duration] {
    &BACKOFF
}

#[cfg(test)]
mod tests {
    use super::*;

    fn b() -> &'static [Duration] {
        default_backoff()
    }

    #[test]
    fn a_first_failure_redials_at_once_then_backoff_grows_to_its_last_step() {
        assert_eq!(after_failure(b(), 1), Redial::Now { attempt: 2 });
        let waits: Vec<u64> = (2..MAX_ATTEMPTS)
            .map(|a| match after_failure(b(), a) {
                Redial::Wait { attempt, after } => {
                    assert_eq!(attempt, a);
                    after.as_secs()
                }
                other => panic!("attempt {a}: {other:?}"),
            })
            .collect();
        assert_eq!(waits, [1, 2, 4, 8, 15, 30, 30, 30, 30, 30]);
    }

    #[test]
    fn failures_stop_at_the_cap() {
        assert_eq!(after_failure(b(), MAX_ATTEMPTS), Redial::Stop { attempt: MAX_ATTEMPTS });
        assert_eq!(after_failure(b(), MAX_ATTEMPTS + 5), Redial::Stop { attempt: MAX_ATTEMPTS + 5 });
    }

    #[test]
    fn a_drop_after_a_stable_link_starts_over_and_a_short_one_counts() {
        // peer_link.rs `Link::down`: 61 s up is stable, 8 s is not.
        assert_eq!(after_drop(b(), 7, Some(Duration::from_secs(61))), Redial::Now { attempt: 1 });
        assert_eq!(after_drop(b(), 7, Some(STABLE_AFTER)), Redial::Now { attempt: 1 });
        assert_eq!(
            after_drop(b(), 3, Some(Duration::from_secs(8))),
            Redial::Wait { attempt: 3, after: Duration::from_secs(2) }
        );
        // The first short link redials at once, as a first failed dial does.
        assert_eq!(after_drop(b(), 1, Some(Duration::ZERO)), Redial::Now { attempt: 2 });
        // A caller with no clock keeps the old rule: every drop starts over.
        assert_eq!(after_drop(b(), 9, None), Redial::Now { attempt: 1 });
    }

    #[test]
    fn a_link_that_dies_at_once_every_time_reaches_retry_then_stops() {
        // Connect, fail the first probe, repeat: the attempt grows by one each time, Retry is
        // offered, and the loop ends.
        let mut attempt = 1;
        let mut offered_at = None;
        for cycle in 1..=50 {
            match after_drop(b(), attempt, Some(Duration::from_millis(300))) {
                Redial::Now { attempt: next } => attempt = next,
                Redial::Wait { attempt: waiting, .. } => {
                    if offers_retry(waiting) && offered_at.is_none() {
                        offered_at = Some(cycle);
                    }
                    attempt = waiting + 1;
                }
                Redial::Stop { attempt: stopped } => {
                    assert!(offers_retry(stopped));
                    assert_eq!(stopped, MAX_ATTEMPTS);
                    assert_eq!(offered_at, Some(7), "Retry first offered on the 7th lost link");
                    assert_eq!(cycle as u32, MAX_ATTEMPTS, "stopped after {MAX_ATTEMPTS} lost links");
                    return;
                }
            }
        }
        panic!("the redial never stopped");
    }

    #[test]
    fn news_restarts_count_but_never_pass_the_cap() {
        assert_eq!(restart_attempt(1), 2);
        assert_eq!(restart_attempt(MAX_ATTEMPTS - 1), MAX_ATTEMPTS);
        assert_eq!(restart_attempt(MAX_ATTEMPTS), MAX_ATTEMPTS);
        assert_eq!(resume_attempt(MAX_ATTEMPTS + 3), MAX_ATTEMPTS);
        let mut attempt = 1;
        for _ in 0..1000 {
            attempt = restart_attempt(attempt);
        }
        assert_eq!(attempt, MAX_ATTEMPTS);
    }

    #[test]
    fn news_after_a_stop_starts_every_attempt_over() {
        assert_eq!(news_attempt(MAX_ATTEMPTS), 1);
        assert_eq!(news_attempt(MAX_ATTEMPTS + 2), 1);
        assert_eq!(news_attempt(3), 4);
        // From the fresh start the whole backoff runs again before the next stop.
        let mut attempt = news_attempt(MAX_ATTEMPTS);
        let mut lost = 1;
        loop {
            match after_drop(b(), attempt, Some(Duration::ZERO)) {
                Redial::Now { attempt: next } => attempt = next,
                Redial::Wait { attempt: waiting, .. } => attempt = waiting + 1,
                Redial::Stop { .. } => break,
            }
            lost += 1;
        }
        assert_eq!(lost, MAX_ATTEMPTS);
    }

    #[test]
    fn retry_is_offered_after_the_reconnecting_attempts() {
        assert!(!offers_retry(RECONNECTING_ATTEMPTS));
        assert!(offers_retry(RECONNECTING_ATTEMPTS + 1));
    }

    #[test]
    fn an_empty_table_waits_zero() {
        assert_eq!(retry_delay(&[], 5), Duration::ZERO);
    }
}
