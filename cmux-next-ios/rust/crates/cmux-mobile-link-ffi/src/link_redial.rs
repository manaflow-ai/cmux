//! The phone link's redial policy for Swift's `LinkMachine`
//! (`cmux_mobile_link::reconnect::policy`): the next attempt, its wait, the reset after a stable
//! link, and the stop that hands the next dial to the person. Swift decides none of it.

use std::time::Duration;

use cmux_mobile_link::reconnect::policy::{self, Redial};

/// What the link does after a failed dial or a lost link.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LinkRedial {
    /// Dial again now, as `attempt`.
    Now { attempt: u32 },
    /// Wait `after_ms`, then dial `attempt + 1`; the phase is waiting at `attempt`.
    Wait { attempt: u32, after_ms: u64 },
    /// Stop dialing on its own: waiting at `attempt`, nothing scheduled, Retry offered.
    Stop { attempt: u32 },
}

/// The policy's bounds, for Swift's copy of them (status text, tests).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct LinkRedialLimits {
    /// A link up this long before it dropped starts the backoff over.
    pub stable_after_ms: u64,
    /// Attempts after a lost link that read "Reconnecting"; later ones offer Retry.
    pub reconnecting_attempts: u32,
    /// The last attempt dialed without the person.
    pub max_attempts: u32,
}

impl From<Redial> for LinkRedial {
    fn from(redial: Redial) -> Self {
        match redial {
            Redial::Now { attempt } => LinkRedial::Now { attempt },
            Redial::Wait { attempt, after } => {
                LinkRedial::Wait { attempt, after_ms: u64::try_from(after.as_millis()).unwrap_or(u64::MAX) }
            }
            Redial::Stop { attempt } => LinkRedial::Stop { attempt },
        }
    }
}

fn table(backoff_ms: &[u64]) -> Vec<Duration> {
    backoff_ms.iter().map(|ms| Duration::from_millis(*ms)).collect()
}

/// After dial `attempt` failed, with the machine's backoff table (milliseconds).
#[uniffi::export]
pub fn link_redial_after_failure(backoff_ms: Vec<u64>, attempt: u32) -> LinkRedial {
    policy::after_failure(&table(&backoff_ms), attempt).into()
}

/// After the link dial `connected_attempt` made was lost `up_for_ms` after it connected (none: no
/// clock, counted as stable).
#[uniffi::export]
pub fn link_redial_after_drop(
    backoff_ms: Vec<u64>,
    connected_attempt: u32,
    up_for_ms: Option<u64>,
) -> LinkRedial {
    policy::after_drop(&table(&backoff_ms), connected_attempt, up_for_ms.map(Duration::from_millis)).into()
}

/// The attempt of a dial restarted from `attempt` (news of a new path, the person's Retry, a
/// surface opening, the foreground): one more, never past the cap.
#[uniffi::export]
pub fn link_redial_next_attempt(attempt: u32) -> u32 {
    policy::restart_attempt(attempt)
}

/// The attempt of a dial news starts from a wait at `attempt` (the foreground, a new network
/// path, the Mac's presence): a stopped redial starts over at 1, so stopping never strands the
/// person; otherwise one more.
#[uniffi::export]
pub fn link_redial_news_attempt(attempt: u32) -> u32 {
    policy::news_attempt(attempt)
}

/// The policy's bounds.
#[uniffi::export]
pub fn link_redial_limits() -> LinkRedialLimits {
    LinkRedialLimits {
        stable_after_ms: u64::try_from(policy::STABLE_AFTER.as_millis()).unwrap_or(u64::MAX),
        reconnecting_attempts: policy::RECONNECTING_ATTEMPTS,
        max_attempts: policy::MAX_ATTEMPTS,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const BACKOFF: [u64; 6] = [1000, 2000, 4000, 8000, 15_000, 30_000];

    #[test]
    fn a_short_link_counts_and_a_stable_one_starts_over() {
        assert_eq!(link_redial_after_drop(BACKOFF.to_vec(), 1, Some(0)), LinkRedial::Now { attempt: 2 });
        assert_eq!(
            link_redial_after_drop(BACKOFF.to_vec(), 4, Some(5_000)),
            LinkRedial::Wait { attempt: 4, after_ms: 4000 }
        );
        assert_eq!(link_redial_after_drop(BACKOFF.to_vec(), 4, Some(60_000)), LinkRedial::Now { attempt: 1 });
        assert_eq!(link_redial_after_drop(BACKOFF.to_vec(), 4, None), LinkRedial::Now { attempt: 1 });
    }

    #[test]
    fn failures_back_off_then_stop() {
        assert_eq!(link_redial_after_failure(BACKOFF.to_vec(), 1), LinkRedial::Now { attempt: 2 });
        assert_eq!(
            link_redial_after_failure(BACKOFF.to_vec(), 2),
            LinkRedial::Wait { attempt: 2, after_ms: 1000 }
        );
        let limits = link_redial_limits();
        assert_eq!(
            link_redial_after_failure(BACKOFF.to_vec(), limits.max_attempts),
            LinkRedial::Stop { attempt: limits.max_attempts }
        );
        assert_eq!(link_redial_next_attempt(limits.max_attempts), limits.max_attempts);
        assert_eq!(limits.stable_after_ms, 60_000);
        assert_eq!(link_redial_news_attempt(limits.max_attempts), 1);
        assert_eq!(link_redial_news_attempt(3), 4);
    }
}
