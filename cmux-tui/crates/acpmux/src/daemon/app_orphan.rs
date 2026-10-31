//! App orphan exit. The app launches this daemon detached, so it outlives
//! the app on purpose: its sessions are durable state. A daemon whose app is
//! gone for good is not, though: scripts quit tagged DEV builds or delete
//! their bundles without stopping the daemon (23 such daemons held two cores
//! of one Mac, 2026-10-21), and a person who deletes a NIGHTLY or Release app,
//! or moves to another channel and deletes the old one, kept its daemon
//! running under launchd forever. The dead app's headless owners stay
//! connected, so "no client" never comes.
//!
//! For a daemon run from a cmux app bundle (the bundle around this executable
//! is `com.cmuxterm.app[.<channel>]`, or the macOS update clone of one,
//! `<X>.app.bundle`), the daemon stops itself, through its ordinary shutdown,
//! once its app was gone for [`ORPHAN_EXIT_DELAY`]:
//!
//! - Every channel: no name links to its own executable any more. The bundle
//!   was deleted, an update or a rebuild wrote a new binary over it. A daemon
//!   run from an update clone (whose file keeps its name there) counts its
//!   executable gone once the app it cloned is gone from `/Applications`.
//! - DEV builds (`com.cmuxterm.app.debug[.<tag>]`) that name the app's
//!   control socket (`CMUX_SOCKET_PATH`, the socket its agents reach the app
//!   on) also stop once connects to that socket fail after the app answered
//!   at least once: a quit tag build is throwaway. A same-tag DEV rebuilt
//!   elsewhere listens on the same socket, so the executable decides even
//!   while the socket answers. NIGHTLY and Release daemons outlive a quit app
//!   (remote peers and phones still reach their sessions); only a gone
//!   executable stops them.
//!
//! An app that never listens (socket control off, a socket that failed to
//! start) never stops a daemon whose executable is unchanged. It tries every
//! [`ORPHAN_RECHECK`]: an app sends no event when it exits or is deleted, and
//! one try is a single connect that is closed at once. No platform but macOS
//! starts the watcher, nor a daemon run from outside a cmux bundle (a
//! checkout's binary, `CMUX_NEXT_ACPMUX_BIN`, `~/.local/bin/acpmux`).
//!
//! Its agents: when a DEV daemon's executable is gone, or a NIGHTLY or
//! Release one's app is gone from its install path (deleted, or another app
//! there now), the shutdown ends the daemon's hosted agents too: no build of
//! it is left to adopt them. When the app only quit, or a NIGHTLY or Release
//! update replaced its binary with the same app's next build, it is the
//! SIGTERM handoff: the agents keep running, as the app's Quit keeps them,
//! for the next launch to adopt (an update normally hands the daemon off at
//! once, `AcpmuxVersionHandoff`; this covers an update installed on quit and
//! not opened since). A Chief's daemon run from the app's bundle stops the
//! same way.
//!
//! Test seams, debug builds only: `ACPMUX_TEST_APP_ORPHAN_DELAY_MS` and
//! `ACPMUX_TEST_APP_ORPHAN_RECHECK_MS` replace the two intervals.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// How long the app's socket may refuse connects before the daemon stops.
pub(crate) const ORPHAN_EXIT_DELAY: Duration = Duration::from_secs(60 * 60);
/// How often the daemon tries the app's socket.
pub(crate) const ORPHAN_RECHECK: Duration = Duration::from_secs(10 * 60);

/// The bundle id of a Release build, and the prefix of every other channel's.
const APP_BUNDLE_ID: &str = "com.cmuxterm.app";
/// The bundle id prefix of DEV and tagged debug builds.
const DEBUG_BUNDLE_ID: &str = "com.cmuxterm.app.debug";

#[cfg(debug_assertions)]
const TEST_DELAY_ENV: &str = "ACPMUX_TEST_APP_ORPHAN_DELAY_MS";
#[cfg(debug_assertions)]
const TEST_RECHECK_ENV: &str = "ACPMUX_TEST_APP_ORPHAN_RECHECK_MS";

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

/// Whether `bundle_id` is any cmux app's (`com.cmuxterm.app[.<channel>]`).
pub(crate) fn is_cmux_bundle(bundle_id: &str) -> bool {
    bundle_id
        .strip_prefix(APP_BUNDLE_ID)
        .is_some_and(|rest| rest.is_empty() || rest.starts_with('.'))
}

/// The app bundle around `exe` (`<X>.app/Contents/...`, or macOS's update
/// clone of one, `.../code_sign_clone.<nonce>/<X>.app.bundle/Contents/...`).
pub(crate) fn containing_app_bundle(exe: &Path) -> Option<PathBuf> {
    exe.ancestors()
        .find(|path| {
            path.extension().is_some_and(|extension| extension == "app")
                || path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name.ends_with(".app.bundle"))
        })
        .filter(|bundle| exe.starts_with(bundle.join("Contents")))
        .map(Path::to_path_buf)
}

/// Where the app of `bundle` is installed: the bundle itself, or for macOS's
/// update clone of an app (`<X>.app.bundle` in a `code_sign_clone.<nonce>`
/// folder) the app it cloned, `/Applications/<X>.app`.
pub(crate) fn install_path(bundle: &Path) -> PathBuf {
    let clone = bundle.file_name().and_then(|name| name.to_str()).and_then(|name| {
        let installed = name.strip_suffix(".bundle")?;
        let nonce = bundle.parent()?.file_name()?.to_str()?;
        nonce.starts_with("code_sign_clone.").then(|| Path::new("/Applications").join(installed))
    });
    clone.unwrap_or_else(|| bundle.to_path_buf())
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

/// Resolves when this daemon's cmux app has been gone for the delay, with whether its agents
/// end too (see the module doc); never for a daemon outside a cmux bundle. The bundle is read
/// and the executable opened here, at once (a deleted bundle has no Info.plist to read later,
/// and one deleted before the first poll would be missed): call it before the ready line.
pub(crate) fn watch() -> impl std::future::Future<Output = bool> + Send + 'static {
    // One read of the executable's path, opened at once: a second read could name a rebuild
    // that replaced it in between, and the watch would hold that one.
    let facts = std::env::current_exe().ok().and_then(|exe| {
        let opened = std::fs::File::open(&exe);
        // A binary already unlinked (a rebuild in the instant before the open): gone from the
        // start, or the watch could never see it go. Only "not found": any other refusal (a
        // binary it may not read) is never taken for gone.
        let missing = matches!(&opened, Err(e) if e.kind() == std::io::ErrorKind::NotFound);
        let executable = Executable(opened.ok(), missing);
        // Gone is read only after a failed Info.plist read: a bundle deleted between the open
        // and that read has an executable gone by then, so it is still watched.
        let app = App::of(&exe, || executable.gone())?;
        Some((app, executable))
    });
    async move {
        match facts {
            Some((app, executable)) => watch_app(app, executable).await,
            None => std::future::pending().await,
        }
    }
}

/// The cmux app around this daemon's executable, read once at start.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct App {
    /// The app bundle the executable runs from.
    pub(crate) bundle: PathBuf,
    pub(crate) bundle_id: String,
    /// A DEV build's control socket (`CMUX_SOCKET_PATH`): its refusals count as the app gone.
    /// None for every other channel, and for a DEV build started without one.
    pub(crate) socket: Option<PathBuf>,
}

impl App {
    /// The app around `exe`. A bundle deleted before its Info.plist was read is still watched,
    /// as an app of unknown id: its executable is `gone` (asked only after the read failed, so
    /// a deletion between the open and the read counts), so it stops (an empty `bundle_id`;
    /// see [`App::ends_agents`]).
    fn of(exe: &Path, gone: impl FnOnce() -> bool) -> Option<Self> {
        if !cfg!(target_os = "macos") {
            return None;
        }
        Self::in_bundle(containing_app_bundle(exe)?, gone)
    }

    /// The app of `bundle`, read now; see [`App::of`].
    fn in_bundle(bundle: PathBuf, gone: impl FnOnce() -> bool) -> Option<Self> {
        match bundle_id(&bundle) {
            Some(id) => Self::new(bundle, id, app_socket_env()),
            None if gone() => Some(Self { bundle, bundle_id: String::new(), socket: None }),
            None => None,
        }
    }

    /// The app of a bundle with `bundle_id`, given the daemon's `CMUX_SOCKET_PATH`; None when
    /// it is not a cmux app.
    pub(crate) fn new(bundle: PathBuf, bundle_id: String, socket: Option<PathBuf>) -> Option<Self> {
        if !is_cmux_bundle(&bundle_id) {
            return None;
        }
        let socket = socket.filter(|_| is_dev_bundle(&bundle_id));
        Some(Self { bundle, bundle_id, socket })
    }

    /// For a daemon run from macOS's update clone of an app, whose file keeps its name in the
    /// clone whatever happens to the app: whether the app it cloned is gone from its install
    /// path (deleted, or another app there). False for every other bundle.
    fn clone_orphaned(&self) -> bool {
        let install = install_path(&self.bundle);
        install != self.bundle && bundle_id(&install).as_deref() != Some(self.bundle_id.as_str())
    }

    fn is_dev(&self) -> bool {
        is_dev_bundle(&self.bundle_id)
    }

    /// Whether this app's agents end with a daemon that stops with its executable `gone`:
    /// a DEV build's whenever its executable is gone, any other channel's only when its install
    /// path holds no app of its bundle id any more (`installed` is that path's bundle id: none
    /// once deleted). An update of the same app keeps them for its next launch to adopt.
    /// An app of unknown id (deleted before its Info.plist was read) ends them only when its
    /// install path holds no app at all.
    pub(crate) fn ends_agents(&self, gone: bool, installed: Option<&str>) -> bool {
        if self.bundle_id.is_empty() {
            return gone && installed.is_none();
        }
        gone && (self.is_dev() || installed != Some(self.bundle_id.as_str()))
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

    /// One already unlinked when the daemon started (see `watch`): always gone.
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

async fn watch_app(app: App, executable: Executable) -> bool {
    let timing = Timing::for_daemon();
    match &app.socket {
        Some(socket) => tracing::info!(
            socket = %socket.display(),
            bundle = %app.bundle.display(),
            "DEV daemon: stops after {:?} with its app's socket refusing connects or its executable gone",
            timing.delay
        ),
        None => tracing::info!(
            bundle = %app.bundle.display(),
            "daemon: stops after {:?} with its executable gone",
            timing.delay
        ),
    }
    let mut answered = false;
    let mut absent_since = None;
    loop {
        // No socket to try: only the executable decides.
        let reachable = match app.socket.clone() {
            Some(probe) => tokio::task::spawn_blocking(move || app_reachable(&probe)).await.ok(),
            None => Some(true),
        };
        let now = Instant::now();
        // A failed task changes nothing.
        if let Some(reachable) = reachable {
            answered |= reachable;
            if !gone(reachable, answered, executable.gone() || app.clone_orphaned()) {
                absent_since = None;
            } else if absent_since.is_none() {
                absent_since = Some(now);
            }
        }
        match decide(absent_since, now, timing) {
            Decision::Exit => {
                let deleted = executable.gone() || app.clone_orphaned();
                let install = install_path(&app.bundle);
                let installed = bundle_id(&install);
                let end_agents = app.ends_agents(deleted, installed.as_deref());
                tracing::info!(
                    bundle = %app.bundle.display(),
                    executable_gone = deleted,
                    installed = installed.as_deref().unwrap_or("none"),
                    end_agents,
                    "stopping: the app of this daemon was gone for {:?}",
                    timing.delay
                );
                return end_agents;
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
    fn every_channel_is_a_cmux_bundle() {
        for id in [
            "com.cmuxterm.app",
            "com.cmuxterm.app.nightly",
            "com.cmuxterm.app.nightly.cmux-next",
            "com.cmuxterm.app.debug.orphan",
        ] {
            assert!(is_cmux_bundle(id), "{id}");
        }
        assert!(!is_cmux_bundle("com.cmuxterm.appx"));
        assert!(!is_cmux_bundle("com.example.app"));
    }

    #[test]
    fn only_a_dev_app_watches_its_socket() {
        let socket = Some(PathBuf::from("/tmp/app.sock"));
        let app = |id: &str| App::new(PathBuf::from("/A/x.app"), id.into(), socket.clone());
        assert_eq!(app("com.cmuxterm.app.debug.t").unwrap().socket, socket);
        assert_eq!(
            app("com.cmuxterm.app.nightly").unwrap().socket,
            None,
            "NIGHTLY outlives a quit"
        );
        assert_eq!(app("com.cmuxterm.app").unwrap().socket, None, "Release outlives a quit");
        assert_eq!(app("com.example.app"), None, "not a cmux app: no watch");
    }

    #[test]
    fn a_deleted_app_ends_its_agents_an_updated_one_keeps_them() {
        let app = |id: &str| App::new(PathBuf::from("/A/x.app"), id.into(), None).unwrap();
        let nightly = app("com.cmuxterm.app.nightly");
        assert!(nightly.ends_agents(true, None), "deleted");
        assert!(nightly.ends_agents(true, Some("com.cmuxterm.app")), "another app at its path");
        assert!(!nightly.ends_agents(true, Some("com.cmuxterm.app.nightly")), "updated in place");
        assert!(!nightly.ends_agents(false, None), "its executable is still there");
        let release = app("com.cmuxterm.app");
        assert!(release.ends_agents(true, None));
        assert!(!release.ends_agents(true, Some("com.cmuxterm.app")));
        // Deleted before its Info.plist was read: an unknown id.
        let unknown =
            App { bundle: PathBuf::from("/A/x.app"), bundle_id: String::new(), socket: None };
        assert!(unknown.ends_agents(true, None));
        assert!(!unknown.ends_agents(true, Some("com.cmuxterm.app")), "an app is installed there");
        assert!(!unknown.ends_agents(false, None));
        // A DEV rebuild ends them: no build of it is left to adopt them.
        let dev = app("com.cmuxterm.app.debug.t");
        assert!(dev.ends_agents(true, Some("com.cmuxterm.app.debug.t")));
        assert!(!dev.ends_agents(false, None));
    }

    #[test]
    fn an_update_clone_watches_the_app_it_cloned() {
        let clone = Path::new(
            "/private/var/folders/a/b/T/com.cmuxterm.app.nightly.code_sign_clone/code_sign_clone.9gP34C/cmux NIGHTLY.app.bundle",
        );
        let exe = clone.join("Contents/Resources/bin/acpmux");
        assert_eq!(containing_app_bundle(&exe).as_deref(), Some(clone));
        assert_eq!(install_path(clone), Path::new("/Applications/cmux NIGHTLY.app"));
        let app = Path::new("/Applications/cmux NIGHTLY.app");
        assert_eq!(install_path(app), app);
        // A bundle named like a clone outside a clone folder is its own install.
        let lookalike = Path::new("/tmp/x/cmux NIGHTLY.app.bundle");
        assert_eq!(install_path(lookalike), lookalike);
        let own = App::new(app.to_path_buf(), "com.cmuxterm.app.nightly".into(), None).unwrap();
        assert!(!own.clone_orphaned(), "an installed app is never a clone");
        // The clone of an app no longer installed (none at this path on a test host).
        let cloned = App::new(
            clone.to_path_buf(),
            "com.cmuxterm.app.nightly.orphan-test-absent".into(),
            None,
        )
        .unwrap();
        assert!(cloned.clone_orphaned(), "the app it cloned is gone");
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
        // Not opened at the start: never gone, unless marked gone then (a binary unlinked).
        assert!(!Executable::open(&dir.join("missing")).gone());
        assert!(Executable::open(&dir.join("missing")).gone_at_start().gone());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_bundle_deleted_between_the_open_and_the_plist_read_is_still_watched() {
        let dir = std::env::temp_dir().join(format!("amx-orph-plist-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let bundle = dir.join("cmux.app");
        let macos = bundle.join("Contents/MacOS");
        std::fs::create_dir_all(&macos).unwrap();
        let exe = macos.join("acpmux");
        std::fs::write(&exe, b"one").unwrap();
        let executable = Executable::open(&exe);
        // No Info.plist yet and the executable still there: not a cmux app it can tell.
        assert_eq!(App::in_bundle(bundle.clone(), || executable.gone()), None);
        std::fs::write(
            bundle.join("Contents/Info.plist"),
            br#"<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.cmuxterm.app.nightly</string></dict></plist>"#,
        )
        .unwrap();
        let app = App::in_bundle(bundle.clone(), || executable.gone()).unwrap();
        assert_eq!(app.bundle_id, "com.cmuxterm.app.nightly");
        // Opened, then the bundle deleted before its Info.plist was read: gone is asked after
        // the failed read, so the app is watched with an unknown id and stops.
        std::fs::remove_dir_all(&bundle).unwrap();
        let app = App::in_bundle(bundle.clone(), || executable.gone()).expect("watched");
        assert_eq!(app.bundle_id, "");
        assert!(app.ends_agents(executable.gone(), None));
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
