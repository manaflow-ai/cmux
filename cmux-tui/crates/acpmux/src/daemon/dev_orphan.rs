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
//! stops itself, through its ordinary shutdown, once its app was gone for
//! [`ORPHAN_EXIT_DELAY`]: connects to that socket fail after the app answered
//! at least once, or no name links to its own executable any more (the bundle
//! was deleted, or a rebuild wrote a new binary over it),
//! whatever the socket says: a same-tag DEV rebuilt elsewhere listens on the
//! same socket. An app that never listens (socket control off, a socket that
//! failed to start) never stops a daemon whose executable is unchanged. It
//! tries every [`ORPHAN_RECHECK`]: an app sends no event when it exits or is
//! deleted, and one try is a single connect that is closed at once. Release,
//! NIGHTLY and Cloud daemons never start the watcher; neither does any
//! platform but macOS, nor a daemon run from outside an app bundle (a
//! checkout's binary, `CMUX_NEXT_ACPMUX_BIN`): no bundle names it a DEV one.
//!
//! A bundle deleted in the instant between the daemon's exec and its read of
//! the bundle's Info.plist cannot be told from a Release or NIGHTLY bundle
//! being replaced, so it is never watched (as on a daemon without this file).
//!
//! The app counts as alive while anything accepts a connect on its socket:
//! the watch cannot tell the app from another process that binds that path
//! after it quits. A same-tag DEV rebuilt elsewhere is that case, and it is
//! covered by the executable check; another program binding the app's
//! private socket path is not.
//!
//! When the executable is gone, the shutdown ends the daemon's hosted agents
//! too: no build of it is left to adopt them. When the app only quit (its
//! executable is still there), it is the SIGTERM handoff: the agents keep
//! running, as the app's Quit keeps them, for the next launch to adopt. A
//! Chief's daemon that inherited the app's socket stops the same way once the
//! DEV app is gone.
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
/// refused connect after it answered once, or a changed executable) since it
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

/// Resolves when this DEV daemon's app has been gone for the delay, with whether its
/// executable is gone too (then its agents end: see the module doc); never for any other
/// build. The bundle is read and the executable opened here, at once (a deleted bundle has no
/// Info.plist to read later, and one deleted before the first poll would be missed): call it
/// before the ready line.
pub(crate) fn watch() -> impl std::future::Future<Output = bool> + Send + 'static {
    // One read of the executable's path, opened at once: a second read could name a rebuild
    // that replaced it in between, and the watch would hold that one.
    let facts = std::env::current_exe().ok().and_then(|exe| {
        let opened = std::fs::File::open(&exe);
        let socket = dev_app_socket(&exe)?;
        // A DEV bundle whose binary was already unlinked (a rebuild in the instant before the
        // open): gone from the start, or the watch could never see it go. Only "not found":
        // any other refusal (a binary it may not read) is never taken for gone.
        let missing = matches!(&opened, Err(e) if e.kind() == std::io::ErrorKind::NotFound);
        Some((socket, Executable(opened.ok(), missing)))
    });
    async move {
        match facts {
            Some((socket, executable)) => watch_app(socket, executable).await,
            None => std::future::pending().await,
        }
    }
}

/// This daemon's executable, held open from the start. It is gone once no name links to it
/// any more: the bundle was deleted, or a rebuild wrote a new binary over its name. Never when
/// the app is moved or renamed (the file keeps its name elsewhere), touched or re-signed in
/// place (the same file).
///
/// Only the link count is read, never the device, inode, size or mtime recorded at start, and
/// that is deliberate. A rebuild never rewrites a binary in place: overwriting a signed Mach-O
/// keeps the kernel's cached code signature for that inode and kills what runs from it, so every
/// build path removes the old file before it copies the new one in
/// (`scripts/install-cmux-tui-client.sh`, `scripts/cmux-next/bundle-cmux-tui.sh`), which leaves
/// this file with no name. A write in place is therefore not a new build, and a size or mtime
/// check would stop a live app's daemon, and end its agents, after a touch or a re-sign.
pub(crate) struct Executable(Option<std::fs::File>, bool);

impl Executable {
    #[cfg(test)]
    pub(crate) fn open(path: &Path) -> Self {
        Self(std::fs::File::open(path).ok(), false)
    }

    /// One already unlinked when a DEV daemon started (see `watch`): always gone.
    #[cfg(test)]
    fn gone_at_start(self) -> Self {
        Self(self.0, true)
    }

    /// Whether no name links to the file any more (deleted, or replaced by a new file at its
    /// name). A write in place keeps it (see the type's doc). One that could not be opened at
    /// the start is never gone.
    pub(crate) fn gone(&self) -> bool {
        if self.1 {
            return true;
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            self.0.as_ref().and_then(|f| f.metadata().ok()).is_some_and(|m| m.nlink() == 0)
        }
        #[cfg(not(unix))]
        false
    }
}

async fn watch_app(socket: PathBuf, executable: Executable) -> bool {
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
            if !gone(reachable, answered, executable.gone()) {
                absent_since = None;
            } else if absent_since.is_none() {
                absent_since = Some(now);
            }
        }
        match decide(absent_since, now, timing) {
            Decision::Exit => {
                let deleted = executable.gone();
                tracing::info!(
                    socket = %socket.display(),
                    executable_gone = deleted,
                    "stopping: the app of this DEV build was gone for {:?}",
                    timing.delay
                );
                return deleted;
            }
            Decision::Wait(after) => tokio::time::sleep(after).await,
        }
    }
}

/// Whether the app counts as gone at one try: this build's executable was
/// deleted or replaced (whatever the socket says: another build of the same
/// tag may listen there now), or its socket refuses after it answered once.
pub(crate) fn gone(reachable: bool, answered: bool, executable_gone: bool) -> bool {
    executable_gone || (!reachable && answered)
}

/// The app's control socket when this executable sits in a DEV bundle.
fn dev_app_socket(exe: &Path) -> Option<PathBuf> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    let socket = app_socket_env()?;
    let bundle = containing_app_bundle(exe)?;
    is_dev_bundle(&bundle_id(&bundle)?).then_some(socket)
}

/// The app's control socket this daemon was started with (`CMUX_SOCKET_PATH`).
fn app_socket_env() -> Option<PathBuf> {
    std::env::var_os("CMUX_SOCKET_PATH").filter(|path| !path.is_empty()).map(PathBuf::from)
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
        assert!(!gone(true, true, false), "it answers");
        assert!(!gone(false, false, false), "it never listened: socket control off");
        assert!(gone(false, true, false), "it answered once, now refuses");
        assert!(gone(false, false, true), "its bundle was deleted");
    }

    #[test]
    fn a_gone_executable_is_gone_even_while_the_socket_answers() {
        assert!(gone(true, true, true), "a same-tag DEV rebuilt elsewhere listens there");
        assert!(gone(true, false, true));
    }

    #[cfg(unix)]
    #[test]
    fn the_executable_is_gone_when_deleted_or_replaced_never_when_moved_or_touched() {
        let dir = std::env::temp_dir().join(format!("amx-orph-id-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let exe = dir.join("acpmux");
        std::fs::write(&exe, b"one").unwrap();
        let executable = Executable::open(&exe);
        assert!(!executable.gone());
        // Written in place (touched, re-signed, or its bytes rewritten): by design the same
        // file, not a new build. No build writes a binary in place (see `Executable`); a
        // size or mtime check would stop a live app's daemon on a touch or a re-sign.
        std::fs::write(&exe, b"one, signed").unwrap();
        assert!(!executable.gone(), "written in place");
        // The app moved: its file keeps a name elsewhere.
        let moved = dir.join("moved");
        std::fs::rename(&exe, &moved).unwrap();
        assert!(!executable.gone(), "moved");
        // A rebuild writes a new binary over that name.
        let next = dir.join("acpmux.next");
        std::fs::write(&next, b"build two").unwrap();
        std::fs::rename(&next, &moved).unwrap();
        assert!(executable.gone(), "replaced");
        // Deleted.
        std::fs::write(&exe, b"three").unwrap();
        let third = Executable::open(&exe);
        std::fs::remove_file(&exe).unwrap();
        assert!(third.gone(), "deleted");
        // Not opened at the start: never gone, unless marked gone then (a DEV binary unlinked).
        assert!(!Executable::open(&dir.join("missing")).gone());
        assert!(Executable::open(&dir.join("missing")).gone_at_start().gone());
        let _ = std::fs::remove_dir_all(&dir);
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
