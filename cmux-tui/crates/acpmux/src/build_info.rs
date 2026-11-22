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

/// Whether a peer that runs the build `remote` lags the build `local`: what `outdated` means on
/// a peer row (`acpmux machine ls`, placement's `peer_down`, the update hint). A build id is
/// `<hash>[+dirty.<fingerprint>] <UTC date>` (acpmux-build-id), so a peer lags when its date is
/// earlier. A newer peer, or another build from the same day, does not: before this, any build
/// but this one's was outdated, so a sender a few hours behind the fleet passed over every
/// newer peer as a "stale disk copy" (2026-11-22: `session move --machine auto` from a NIGHTLY
/// three hours behind the fleet passed over 44 newer hosts) and its update hint offered to put
/// its older build on them. A build id without a date
/// (`unstamped`, an old peer's) lags whenever it differs.
pub fn lags(remote: &str, local: &str) -> bool {
    if remote == local {
        return false;
    }
    match (build_date(remote), build_date(local)) {
        (Some(r), Some(l)) => r < l,
        _ => true,
    }
}

/// The UTC date (`YYYY-MM-DD`) that ends a build id, when it has one.
fn build_date(build: &str) -> Option<&str> {
    let date = build.rsplit(' ').next()?;
    let shape = date.len() == 10
        && date
            .bytes()
            .enumerate()
            .all(|(i, b)| if i == 4 || i == 7 { b == b'-' } else { b.is_ascii_digit() });
    (shape && build.contains(' ')).then_some(date)
}

/// `<version> (<build>)`, for `--version`.
pub fn version_line() -> &'static str {
    static LINE: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    LINE.get_or_init(|| format!("{} ({})", VERSION, build()))
}

#[cfg(test)]
mod tests {
    use super::lags;

    #[test]
    fn only_an_older_build_lags() {
        let local = "dc165ee78 2026-11-22";
        assert!(!lags(local, local));
        assert!(!lags("b3fdb4e74 2026-11-22", local), "same day, another commit: not outdated");
        assert!(!lags("b3fdb4e74 2026-11-23", local), "a newer peer is not outdated");
        assert!(lags("acc1f8581 2026-11-21", local), "an older day lags");
        assert!(lags("acc1f8581+dirty.ab12 2026-11-21", local));
        assert!(lags("unstamped", local), "no date: any other build lags");
        assert!(lags("b3fdb4e74 2026-11-21", "unstamped"));
        assert!(!lags("unstamped", "unstamped"));
    }
}
