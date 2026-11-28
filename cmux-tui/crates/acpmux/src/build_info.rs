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
        && b.get(4) == Some(&b'-')
        && b.get(7) == Some(&b'-')
        && b.iter().enumerate().all(|(i, c)| i == 4 || i == 7 || c.is_ascii_digit());
    (shape && date.len() < build.len()).then_some(date)
}

#[cfg(test)]
#[path = "build_info_tests.rs"]
mod tests;
