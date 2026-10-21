//! DEV app orphan exit. The app launches this daemon detached, so it
//! outlives the app on purpose: its sessions are durable state. Tagged DEV
//! builds are throwaway, though: scripts quit them or delete their bundles
//! without stopping the daemon, which then runs forever under launchd (23
//! such daemons held two cores of one Mac, 2026-10-21). The dead app's
//! headless owners stay connected, so "no client" never comes; the app's own
//! control socket is the signal.
//!
//! In a DEV build only (the bundle around this executable is
//! `com.cmuxterm.app.debug[.<tag>]`) that names the app's control socket
//! (`CMUX_SOCKET_PATH`, the socket its agents reach the app on), the daemon
//! stops itself, through its ordinary shutdown, once connects to that socket
//! have failed for [`ORPHAN_EXIT_DELAY`] after the app answered at least once,
//! or after its own executable is gone (the bundle was deleted). An app that
//! never listens (socket control off, a socket that failed to start) never
//! stops its daemon. It tries every [`ORPHAN_RECHECK`]: an app sends no event
//! when it exits or is deleted, and one try is a single connect that is
//! closed at once. Release, NIGHTLY and Cloud daemons never start the
//! watcher; neither does any platform but macOS.
//!
//! The shutdown is the SIGTERM one: hosted agents keep running for a next
//! daemon. A Chief's daemon that inherited the app's socket stops the same
//! way once the DEV app is gone.
//!
//! Test seams, debug builds only: `ACPMUX_TEST_DEV_ORPHAN_DELAY_MS` and
//! `ACPMUX_TEST_DEV_ORPHAN_RECHECK_MS` replace the two intervals.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// How long the app's socket may refuse connects before the daemon stops.
pub(crate) const ORPHAN_EXIT_DELAY: Duration = Duration::from_secs(60 * 60);
/// How often the daemon tries the app's socket.
pub(crate) const ORPHAN_RECHECK: Duration = Duration::from_secs(10 * 60);

/// The bundle id prefix of DEV and tagged debug builds.
const DEBUG_BUNDLE_ID: &str = "com.cmuxterm.app.debug";

#[cfg(debug_assertions)]
const TEST_DELAY_ENV: &str = "ACPMUX_TEST_DEV_ORPHAN_DELAY_MS";
#[cfg(debug_assertions)]
const TEST_RECHECK_ENV: &str = "ACPMUX_TEST_DEV_ORPHAN_RECHECK_MS";

/// The watcher's two intervals.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Timing {
    pub(crate) delay: Duration,
    pub(crate) recheck: Duration,
}

impl Timing {
    pub(crate) const STANDARD: Self = Self { delay: ORPHAN_EXIT_DELAY, recheck: ORPHAN_RECHECK };

    /// [`Timing::STANDARD`], or in a debug build the test overrides.
    fn for_daemon() -> Self {
        #[cfg(debug_assertions)]
        {
            let millis = |key: &str| {
                std::env::var(key)
                    .ok()
                    .and_then(|value| value.parse::<u64>().ok())
                    .map(Duration::from_millis)
            };
            Self {
                delay: millis(TEST_DELAY_ENV).unwrap_or(Self::STANDARD.delay),
                recheck: millis(TEST_RECHECK_ENV).unwrap_or(Self::STANDARD.recheck),
            }
        }
        #[cfg(not(debug_assertions))]
        Self::STANDARD
    }
}

/// Whether `bundle_id` is a DEV build's (`com.cmuxterm.app.debug[.<tag>]`).
pub(crate) fn is_dev_bundle(bundle_id: &str) -> bool {
    bundle_id
        .strip_prefix(DEBUG_BUNDLE_ID)
        .is_some_and(|rest| rest.is_empty() || rest.starts_with('.'))
}

/// The `<X>.app` around `exe` (`<X>.app/Contents/...`).
pub(crate) fn containing_app_bundle(exe: &Path) -> Option<PathBuf> {
    exe.ancestors()
        .find(|path| path.extension().is_some_and(|extension| extension == "app"))
        .filter(|bundle| exe.starts_with(bundle.join("Contents")))
        .map(Path::to_path_buf)
}

/// The bundle's `CFBundleIdentifier`, from its Info.plist.
fn bundle_id(bundle: &Path) -> Option<String> {
    let info = plist::Value::from_file(bundle.join("Contents/Info.plist")).ok()?;
    Some(info.as_dictionary()?.get("CFBundleIdentifier")?.as_string()?.to_owned())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Decision {
    /// Try again after this long.
    Wait(Duration),
    /// Stop the daemon.
    Exit,
}

/// The policy. `absent_since` is when the app was first seen gone (a
/// refused connect after it answered once, or a missing executable) since it
/// last answered; `None` while it answers or before it ever did.
pub(crate) fn decide(absent_since: Option<Instant>, now: Instant, timing: Timing) -> Decision {
    let Some(since) = absent_since else { return Decision::Wait(timing.recheck) };
    let absent = now.saturating_duration_since(since);
    if absent >= timing.delay {
        Decision::Exit
    } else {
        Decision::Wait(timing.recheck.min(timing.delay - absent))
    }
}

/// Resolves when this DEV daemon's app has been gone for the delay; never
/// for any other build. The bundle is read here, at once (a deleted bundle
/// has no Info.plist to read later): call it before the ready line.
pub(crate) fn watch() -> impl std::future::Future<Output = ()> + Send + 'static {
    let facts = dev_app_socket().zip(std::env::current_exe().ok());
    async move {
        match facts {
            Some((socket, executable)) => watch_app(socket, executable).await,
            None => std::future::pending().await,
        }
    }
}

async fn watch_app(socket: PathBuf, executable: PathBuf) {
    let timing = Timing::for_daemon();
    tracing::info!(
        socket = %socket.display(),
        "DEV daemon: stops after {:?} with its app's socket refusing connects",
        timing.delay
    );
    let mut answered = false;
    let mut absent_since = None;
    loop {
        let probe = socket.clone();
        let reachable = tokio::task::spawn_blocking(move || app_reachable(&probe)).await;
        let now = Instant::now();
        // A failed task changes nothing.
        if let Ok(reachable) = reachable {
            answered |= reachable;
            if !gone(reachable, answered, executable.exists()) {
                absent_since = None;
            } else if absent_since.is_none() {
                absent_since = Some(now);
            }
        }
        match decide(absent_since, now, timing) {
            Decision::Exit => {
                tracing::info!(
                    socket = %socket.display(),
                    executable_present = executable.exists(),
                    "stopping: the app of this DEV build was gone for {:?}",
                    timing.delay
                );
                return;
            }
            Decision::Wait(after) => tokio::time::sleep(after).await,
        }
    }
}

/// Whether the app counts as gone at one try: its socket refuses after it
/// answered once, or this build's executable was deleted.
pub(crate) fn gone(reachable: bool, answered: bool, executable_present: bool) -> bool {
    !reachable && (answered || !executable_present)
}

/// The app's control socket when this executable sits in a DEV bundle.
fn dev_app_socket() -> Option<PathBuf> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    let socket = std::env::var_os("CMUX_SOCKET_PATH").filter(|path| !path.is_empty())?;
    let exe = std::env::current_exe().ok()?;
    let bundle = containing_app_bundle(&exe)?;
    is_dev_bundle(&bundle_id(&bundle)?).then(|| PathBuf::from(socket))
}

/// Whether the app accepts a connection on its control socket. The
/// connection is closed at once; the app sees a client that sent nothing.
#[cfg(unix)]
fn app_reachable(socket: &Path) -> bool {
    std::os::unix::net::UnixStream::connect(socket).is_ok()
}

#[cfg(not(unix))]
fn app_reachable(_socket: &Path) -> bool {
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    const TIMING: Timing =
        Timing { delay: Duration::from_secs(3600), recheck: Duration::from_secs(600) };

    #[test]
    fn only_debug_bundles_are_dev() {
        assert!(is_dev_bundle("com.cmuxterm.app.debug"));
        assert!(is_dev_bundle("com.cmuxterm.app.debug.23046.global.search.parity"));
        assert!(!is_dev_bundle("com.cmuxterm.app.debugger"));
        assert!(!is_dev_bundle("com.cmuxterm.app.nightly"));
        assert!(!is_dev_bundle("com.cmuxterm.app.nightly.cmux-next"));
        assert!(!is_dev_bundle("com.cmuxterm.app"));
    }

    #[test]
    fn the_bundle_is_the_app_around_the_executable() {
        let exe = Path::new("/tmp/x/cmux DEV t.app/Contents/Resources/bin/acpmux");
        assert_eq!(containing_app_bundle(exe), Some(PathBuf::from("/tmp/x/cmux DEV t.app")));
        assert_eq!(containing_app_bundle(Path::new("/usr/local/bin/acpmux")), None);
        assert_eq!(containing_app_bundle(Path::new("/tmp/x.app")), None);
    }

    #[test]
    fn an_answering_app_keeps_the_daemon() {
        assert_eq!(decide(None, Instant::now(), TIMING), Decision::Wait(TIMING.recheck));
    }

    #[test]
    fn the_daemon_stops_once_the_app_was_gone_for_the_delay() {
        let since = Instant::now();
        assert_eq!(decide(Some(since), since, TIMING), Decision::Wait(TIMING.recheck));
        let late = since + TIMING.delay - Duration::from_secs(60);
        assert_eq!(decide(Some(since), late, TIMING), Decision::Wait(Duration::from_secs(60)));
        assert_eq!(decide(Some(since), since + TIMING.delay, TIMING), Decision::Exit);
    }

    #[test]
    fn an_app_that_never_listened_is_gone_only_with_its_bundle() {
        assert!(!gone(true, true, true), "it answers");
        assert!(!gone(false, false, true), "it never listened: socket control off");
        assert!(gone(false, true, true), "it answered once, now refuses");
        assert!(gone(false, false, false), "its bundle was deleted");
    }

    #[cfg(unix)]
    #[test]
    fn the_app_is_reachable_only_while_it_listens() {
        let dir = std::env::temp_dir().join(format!("amx-orph-unit-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("app.sock");
        assert!(!app_reachable(&socket), "no socket file");
        let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
        assert!(app_reachable(&socket));
        drop(listener);
        assert!(!app_reachable(&socket), "a socket file nobody listens on");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
