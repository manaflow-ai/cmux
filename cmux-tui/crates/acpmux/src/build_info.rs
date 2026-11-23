//! This process's acpmux build id, and the `--version` line that shows it.

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// This process's build id (git short hash and date, acpmux-build-id). The
/// cmux-tui binary and the shipped standalone acpmux (acpmux-standalone)
/// install it at start (`install_build`) and build this crate without the
/// `build-id` feature, so a new stamp does not recompile it. With the feature
/// (this package's own `acpmux` binary, this crate's tests)
/// the stamped value is the default. Without either, `unstamped`.
pub fn build() -> &'static str {
    INSTALLED_BUILD.get().copied().unwrap_or_else(default_build)
}

static INSTALLED_BUILD: std::sync::OnceLock<&'static str> = std::sync::OnceLock::new();

#[cfg(feature = "build-id")]
fn default_build() -> &'static str {
    acpmux_build_id::build()
}
#[cfg(not(feature = "build-id"))]
fn default_build() -> &'static str {
    "unstamped"
}

/// Records this process's build id. The first call wins: a running daemon's
/// build never changes. Call it before anything reads `build()`.
pub fn install_build(build: &'static str) {
    let _ = INSTALLED_BUILD.set(build);
}

/// `<version> (<build>)`, for `--version`.
pub fn version_line() -> &'static str {
    static LINE: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    LINE.get_or_init(|| format!("{} ({})", VERSION, build()))
}

/// Whether a peer's build `peer` lags this machine's build `mine`: the meaning of a peer row's
/// `outdated` (`acpmux machine ls`, auto placement's pass-over, the `machine update` hint).
/// A build id is `<short hash> <YYYY-MM-DD>`: when both carry a date, the peer lags only when its
/// date is earlier (a newer or same-day peer is no stale copy: a NIGHTLY Mac and a lane VM rarely
/// share one hash). Without a date on either side (`unstamped`, a hand build), any difference lags.
pub fn lags(peer: &str, mine: &str) -> bool {
    match (build_date(peer), build_date(mine)) {
        (Some(p), Some(m)) => p < m,
        _ => peer != mine,
    }
}

/// The `YYYY-MM-DD` that ends a build id, if it ends with one.
fn build_date(build: &str) -> Option<&str> {
    let date = build.rsplit(' ').next()?;
    let b = date.as_bytes();
    let shape = b.len() == 10
        && b[4] == b'-'
        && b[7] == b'-'
        && b.iter().enumerate().all(|(i, c)| i == 4 || i == 7 || c.is_ascii_digit());
    (shape && date.len() < build.len()).then_some(date)
}

#[cfg(test)]
mod tests {
    use super::lags;

    // 2026-11-22: cmux16 (a NIGHTLY Mac, b653865c3 2026-11-22) could move none of its idle chats with
    // `session move --host auto`: both cloud peers (bb5e29da6 2026-11-22) were passed over as
    // "outdated peer build (stale disk copy)", since any other build counted as outdated.
    #[test]
    fn a_newer_or_same_day_peer_build_does_not_lag() {
        assert!(!lags("bb5e29da6 2026-11-22", "b653865c3 2026-11-22"));
        assert!(!lags("bb5e29da6 2026-11-23", "b653865c3 2026-11-22"));
        assert!(!lags("b653865c3 2026-11-22", "b653865c3 2026-11-22"));
    }

    #[test]
    fn an_older_peer_build_lags() {
        assert!(lags("a1143d5cc 2026-11-21", "b653865c3 2026-11-22"));
        assert!(lags("a1143d5cc 2026-10-30", "b653865c3 2026-11-02"));
    }

    #[test]
    fn a_build_without_a_date_lags_when_it_differs() {
        assert!(lags("unstamped", "b653865c3 2026-11-22"));
        assert!(lags("b653865c3 2026-11-22", "unstamped"));
        assert!(!lags("unstamped", "unstamped"));
        assert!(lags("bb5e29da6 not-a-date", "b653865c3 2026-11-22"));
    }
}
