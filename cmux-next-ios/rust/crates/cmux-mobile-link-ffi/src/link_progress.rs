//! One link's last progress and the stall verdicts of the waits on it
//! (`cmux_composer_send::progress`): every fixed timeout on the iOS send path is a bound on
//! silence since the later of the wait's start and the link's last progress (Leo, 2026-11-24:
//! "if it's making good progress, it shiukd be allowed to keep going?").
//!
//! Swift feeds `progressed` from what it reads (bytes heard from the Mac, a write taken, an
//! answer, the link reaching a step) and asks a verdict; it decides nothing. The transport can
//! later publish its own last-progress instant through the same `progressed`.
//!
//! Time is the caller's monotonic clock in milliseconds (`now_ms`, from any origin, never going
//! back), the same for every call on one clock. A mutex keeps it `Sync` for uniffi and is held
//! only for the call.

use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use cmux_composer_send::progress::{self, HeldKeysExpiry, LinkProgress, Stall};

/// Why keys held for a detached terminal are dropped.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum HeldKeysExpiryReason {
    /// The terminal's reconnect gave up.
    GaveUp,
    /// The Mac was offline and the link made no progress for the hold.
    Offline,
    /// A key waited past the ceiling.
    Ceiling,
}

#[derive(uniffi::Object)]
pub struct LinkProgressClock {
    progress: Mutex<LinkProgress>,
    /// `now_ms` 0 on the caller's clock.
    origin: Instant,
}

impl LinkProgressClock {
    fn progress(&self) -> MutexGuard<'_, LinkProgress> {
        self.progress.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn at(&self, ms: u64) -> Instant {
        self.origin + Duration::from_millis(ms)
    }

    fn ms(&self, at: Instant) -> u64 {
        u64::try_from(at.saturating_duration_since(self.origin).as_millis()).unwrap_or(u64::MAX)
    }
}

fn millis(d: Duration) -> u64 {
    u64::try_from(d.as_millis()).unwrap_or(u64::MAX)
}

#[uniffi::export]
impl LinkProgressClock {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self { progress: Mutex::new(LinkProgress::new()), origin: Instant::now() }
    }

    /// The link made progress at `now_ms`.
    pub fn progressed(&self, now_ms: u64) {
        let at = self.at(now_ms);
        self.progress().progressed(at);
    }

    /// When the link last made progress, if it has.
    pub fn last_progress_ms(&self) -> Option<u64> {
        let last = self.progress().last()?;
        Some(self.ms(last))
    }

    /// A wait begun at `started_ms`, bounded by `stall_ms` of silence, at `now_ms`: how many more
    /// milliseconds of silence it may take (look again then), or none once it stalled.
    pub fn stall_left_ms(&self, started_ms: u64, stall_ms: u64, now_ms: u64) -> Option<u64> {
        let (started, now) = (self.at(started_ms), self.at(now_ms));
        match self.progress().verdict(started, Duration::from_millis(stall_ms), now) {
            Stall::Moving { left } => Some(millis(left).max(1)),
            Stall::Stalled => None,
        }
    }
}

/// Keys held for a detached terminal, typed `typed_ages_ms` ago: why they go now, or none while
/// they wait. `offline_age_ms`: how long the Mac has been called offline, while it is;
/// `progress_age_ms`: how long since the link's last progress (`LinkProgressClock`), if it made
/// any. `hold_ms` bounds silence on the link while offline; `ceiling_ms` a key's age. Ages, not
/// instants, so the terminal's own clock and the link's need not share an origin.
#[uniffi::export]
pub fn held_keys_expiry(
    typed_ages_ms: Vec<u64>,
    gave_up: bool,
    offline_age_ms: Option<u64>,
    progress_age_ms: Option<u64>,
    hold_ms: u64,
    ceiling_ms: u64,
) -> Option<HeldKeysExpiryReason> {
    // Instants `age` before a `now` placed past every age, so none goes before `base`.
    let oldest = typed_ages_ms.iter().chain(offline_age_ms.iter()).chain(progress_age_ms.iter()).max();
    let base = Instant::now();
    let now = base + Duration::from_millis(oldest.copied().unwrap_or(0));
    let ago = |age: u64| now - Duration::from_millis(age);
    let typed: Vec<Instant> = typed_ages_ms.iter().map(|&age| ago(age)).collect();
    let reason = progress::held_keys_expiry(
        &typed,
        now,
        gave_up,
        offline_age_ms.map(ago),
        progress_age_ms.map(ago),
        Duration::from_millis(hold_ms),
        Duration::from_millis(ceiling_ms),
    )?;
    Some(match reason {
        HeldKeysExpiry::GaveUp => HeldKeysExpiryReason::GaveUp,
        HeldKeysExpiry::Offline => HeldKeysExpiryReason::Offline,
        HeldKeysExpiry::Ceiling => HeldKeysExpiryReason::Ceiling,
    })
}

impl Default for LinkProgressClock {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_wait_on_the_clock_runs_from_its_last_progress() {
        let clock = LinkProgressClock::new();
        assert_eq!(clock.last_progress_ms(), None);
        assert_eq!(clock.stall_left_ms(1_000, 30_000, 1_000), Some(30_000));
        clock.progressed(25_000);
        assert_eq!(clock.last_progress_ms(), Some(25_000));
        // Past the old fixed 30 s, still moving.
        assert_eq!(clock.stall_left_ms(1_000, 30_000, 31_000), Some(24_000));
        assert_eq!(clock.stall_left_ms(1_000, 30_000, 55_000), None);
    }

    #[test]
    fn held_keys_go_after_the_hold_with_no_progress_since() {
        // Typed 12 s ago, offline for 12 s, no progress: past the 10 s hold.
        assert_eq!(
            held_keys_expiry(vec![12_000], false, Some(12_000), None, 10_000, 60_000),
            Some(HeldKeysExpiryReason::Offline)
        );
        // The link moved 5 s ago: held.
        assert_eq!(held_keys_expiry(vec![12_000], false, Some(12_000), Some(5_000), 10_000, 60_000), None);
        assert_eq!(
            held_keys_expiry(vec![61_000], false, None, Some(0), 10_000, 60_000),
            Some(HeldKeysExpiryReason::Ceiling)
        );
        assert_eq!(held_keys_expiry(vec![], true, None, None, 10_000, 60_000), None);
    }
}
