//! Crash injection for the crash tests: `OPTCHAT_FAULT=<point>` makes the
//! process abort the first time it reaches that point, `<point>#<n>` the
//! n-th time, as a power loss or a kill -9 would stop it there. Unset
//! (always, outside tests), `fault` is one cached load.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;

/// The environment variable naming the point to abort at.
pub const FAULT_ENV: &str = "OPTCHAT_FAULT";

/// Aborts the process when `OPTCHAT_FAULT` names `point` (and its count).
pub fn fault(point: &str) {
    static WANTED: OnceLock<Option<(String, u64)>> = OnceLock::new();
    static SEEN: AtomicU64 = AtomicU64::new(0);
    let wanted = WANTED.get_or_init(|| {
        let value = std::env::var(FAULT_ENV).ok().filter(|v| !v.is_empty())?;
        Some(match value.rsplit_once('#') {
            Some((name, n)) => (name.to_owned(), n.parse().unwrap_or(1)),
            None => (value, 1),
        })
    });
    let Some((name, n)) = wanted else {
        return;
    };
    if name == point && SEEN.fetch_add(1, Ordering::SeqCst) + 1 == *n {
        eprintln!("optchat: fault injected at {point} (#{n})");
        // crash-allow: the crash tests ask for this abort; it never runs unless OPTCHAT_FAULT names the point.
        std::process::abort();
    }
}
