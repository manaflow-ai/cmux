//! A session's own temporary folder, its `TMPDIR`.
//!
//! Two sessions never share one, so one agent's cleanup cannot take another's
//! files (huge-blue, 2026-10-21: two lanes picked the same `~/.cache` folder
//! by name and one's `rm -rf` took the other's live scratch).
//!
//! The folder is `/tmp/acpmux-<uid>/t/<daemon>/<session id>`: the private
//! per-user directory acpmux already keeps its short socket paths in
//! (`config::socket_path`, `agent_host::socket_path`), then one folder per
//! daemon, named by a short hash of its acpmux home, then the session. The
//! path stays short (about 64 bytes with a UUIDv7 id) because tools make
//! sockets under `TMPDIR` and macOS allows 104 bytes for one. Several daemons
//! of one user (the person's, a Chief home's `<home>/acpmux`) share the
//! per-user directory; each one sweeps only its own folder. A daemon's root
//! names its acpmux home (`.home`); a daemon whose home hashes to a root that
//! names another home gets no folder, so two daemons never share a root.
//!
//! The folder lives as long as acpmux knows the session: a purge removes it,
//! and a starting daemon removes every folder in its own root whose session
//! its store no longer has, and the root of any daemon whose acpmux home is
//! gone (`stale`). Nothing goes by age.

use std::ffi::OsString;
use std::path::{Path, PathBuf};

/// The session's folder, in its env beside `TMPDIR`.
pub(crate) const SESSION_TMPDIR_ENV: &str = "ACPMUX_SESSION_TMPDIR";

/// The folder in the per-user directory that holds each daemon's root.
const TMP_SUBDIR: &str = "t";

#[cfg(test)]
thread_local! {
    /// Tests put the per-user directory in a temporary folder of their own.
    static BASE_OVERRIDE: std::cell::RefCell<Option<PathBuf>> =
        const { std::cell::RefCell::new(None) };
}

/// Run `f` with `base` as the per-user directory on this thread (tests only).
#[cfg(test)]
pub(crate) fn with_base<T>(base: &Path, f: impl FnOnce() -> T) -> T {
    BASE_OVERRIDE.with(|b| *b.borrow_mut() = Some(base.to_owned()));
    let out = f();
    BASE_OVERRIDE.with(|b| *b.borrow_mut() = None);
    out
}

/// Debug builds only: the per-user directory of the hermetic tests' daemons
/// and in-process hubs (`tests/support/daemon_env.rs`), in their scratch
/// directory instead of the user's `/tmp/acpmux-<uid>`.
#[cfg(all(debug_assertions, not(test)))]
const TEST_BASE_ENV: &str = "ACPMUX_TEST_SESSION_TMP_BASE";

/// `/tmp/acpmux-<uid>`, the private per-user directory.
#[cfg(not(test))]
pub(crate) fn per_user_base() -> PathBuf {
    #[cfg(debug_assertions)]
    if let Some(base) = std::env::var_os(TEST_BASE_ENV).filter(|v| !v.is_empty()) {
        return PathBuf::from(base);
    }
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    PathBuf::from(format!("/tmp/acpmux-{uid}"))
}

/// Unit tests: the test's own folder ([`with_base`]), else one folder shared
/// by the unit tests (a hub test that starts a session), never the user's.
#[cfg(test)]
pub(crate) fn per_user_base() -> PathBuf {
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    BASE_OVERRIDE
        .with(|b| b.borrow().clone())
        .unwrap_or_else(|| std::env::temp_dir().join(format!("acpmux-unit-session-tmp-{uid}")))
}

/// One daemon's root: `<base>/t/<first 8 hex of fnv1a64(acpmux home)>`.
pub(crate) fn daemon_root(base: &Path, acpmux_home: &Path) -> PathBuf {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for b in acpmux_home.to_string_lossy().bytes() {
        hash ^= b as u64;
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    base.join(TMP_SUBDIR).join(format!("{:08x}", hash >> 32))
}

/// Where the first build (manaflow-ai/cmux#23411) put a session's folder:
/// `<home>/.cache/acpmux/sessions/<session id>` (its `tmp` inside).
pub(crate) fn legacy_root(user_home: &Path) -> PathBuf {
    user_home.join(".cache/acpmux/sessions")
}

/// An id that is one path component.
fn one_component(session_id: &str) -> bool {
    !session_id.is_empty()
        && !matches!(session_id, "." | "..")
        && !session_id.contains(['/', '\\', '\0'])
}

/// A folder name a sweep may take: a session id (a UUID, as acpmux makes them).
fn session_named(name: &str) -> bool {
    name.len() == 36 && uuid::Uuid::try_parse(name).is_ok()
}

/// The session's folder in `daemon_root(base, acpmux_home)`, made 0700 (the
/// same folder again for the same session). None when the id is not one path
/// component, `base` is not a directory private to this user (another owner,
/// a symlink, writable by others: `config::private_state_dir`), or a folder
/// below it is not a real directory of this user's.
#[cfg(unix)]
pub(crate) fn make(base: &Path, acpmux_home: &Path, session_id: &str) -> Option<PathBuf> {
    if !one_component(session_id) {
        return None;
    }
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    {
        use std::os::unix::fs::MetadataExt;
        // Checked before `private_state_dir` may narrow it: another user's
        // directory is never adopted.
        if let Ok(meta) = std::fs::symlink_metadata(base)
            && (meta.uid() != uid || !meta.file_type().is_dir())
        {
            return None;
        }
    }
    crate::config::private_state_dir(base).ok()?;
    let root = daemon_root(base, acpmux_home);
    let t = private_child(base, TMP_SUBDIR, uid)?;
    let daemon = private_child(&t, root.file_name()?.to_str()?, uid)?;
    record_home(&daemon, acpmux_home);
    // Another daemon's root (two homes, one hash): its sweep would take
    // this daemon's folders.
    if recorded_home(&daemon).as_deref() != Some(acpmux_home) {
        return None;
    }
    private_child(&daemon, session_id, uid)
}

/// `parent/name`, made 0700 when missing; only a real directory (lstat, never
/// a symlink) owned by `uid`, narrowed to 0700 if it is wider.
#[cfg(unix)]
fn private_child(parent: &Path, name: &str, uid: u32) -> Option<PathBuf> {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
    let dir = parent.join(name);
    match std::fs::DirBuilder::new().mode(0o700).create(&dir) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(_) => return None,
    }
    let meta = std::fs::symlink_metadata(&dir).ok()?;
    if !meta.file_type().is_dir() || meta.uid() != uid {
        return None;
    }
    if meta.mode() & 0o077 != 0 {
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).ok()?;
    }
    Some(dir)
}

/// The env that gives an agent `dir` as its temporary folder.
/// `agent` reads the agent's environment as it would be without this change.
///
/// `ACPMUX_SESSION_TMPDIR` and `TMPDIR` are `dir`. Clients find their
/// daemons' sockets under `XDG_RUNTIME_DIR`, else `TMPDIR`, else `/tmp`
/// (cmux-tui-platform `runtime_base_dir`, the Rust, Go, Python and
/// TypeScript bindings, chatmux-relay), so an agent without
/// `XDG_RUNTIME_DIR` would look for them in `dir`. With `pin_runtime_dir`
/// (macOS) such an agent also gets `XDG_RUNTIME_DIR` = the base it resolved
/// before (its `TMPDIR`), and `CMUX_BROWSER_HOST_SOCKET` = the browser host
/// socket it resolved before (`$TMPDIR/cmux-<uid>/browser-host.sock`),
/// because that resolver lays its path out differently under
/// `XDG_RUNTIME_DIR` (`cmux/browser-host.sock`). Not under a cmux daemon
/// (`CMUX_TUI_SOCKET`): there cmux-browser-host takes a named socket for the
/// daemon's own host and never starts one, so that agent keeps the
/// `$TMPDIR/cmux/browser-host.sock` it resolves and starts its own host
/// there. A Mac agent without `TMPDIR` keeps it unset: a pinned `/tmp` would
/// move `remote_runtime`'s `/tmp/cmux-rd-<euid>`. Elsewhere (Linux without
/// a runtime dir) `XDG_RUNTIME_DIR` is not pinned: `systemctl --user` and
/// the app servers' socket folder (cmux-tui-core `server_tmp`) read a set
/// `XDG_RUNTIME_DIR` as the systemd runtime dir and refuse `/tmp`; there the
/// agent keeps the shared `TMPDIR` and gets only `ACPMUX_SESSION_TMPDIR`.
///
/// `profile_blank` names a key the profile sets to an empty value: the
/// profile's env is applied after this one, so a pin of that key would not
/// hold, and the agent keeps its `TMPDIR`.
pub(crate) fn env_for(
    dir: &Path,
    agent: impl Fn(&str) -> Option<String>,
    profile_blank: impl Fn(&str) -> bool,
    pin_runtime_dir: bool,
    uid: u32,
) -> Vec<(&'static str, OsString)> {
    let set = |key: &str| agent(key).filter(|v| !v.is_empty());
    let mut out = vec![(SESSION_TMPDIR_ENV, dir.as_os_str().to_owned())];
    if set("XDG_RUNTIME_DIR").is_some() {
        out.push(("TMPDIR", dir.as_os_str().to_owned()));
        return out;
    }
    if !pin_runtime_dir
        || profile_blank("XDG_RUNTIME_DIR")
        || profile_blank("CMUX_BROWSER_HOST_SOCKET")
    {
        return out;
    }
    let Some(tmpdir) = set("TMPDIR") else { return out };
    out.push(("TMPDIR", dir.as_os_str().to_owned()));
    out.push(("XDG_RUNTIME_DIR", tmpdir.clone().into()));
    if set("CMUX_BROWSER_HOST_SOCKET").is_none() && set("CMUX_TUI_SOCKET").is_none() {
        let socket = PathBuf::from(tmpdir).join(format!("cmux-{uid}")).join("browser-host.sock");
        out.push(("CMUX_BROWSER_HOST_SOCKET", socket.into_os_string()));
    }
    out
}

/// Remove `dir` when it is a real directory (lstat: a symlink there is left,
/// and nothing it points at is touched; `remove_dir_all` does not follow
/// symlinks inside it either).
fn remove_dir(dir: &Path) {
    if std::fs::symlink_metadata(dir).is_ok_and(|m| m.file_type().is_dir())
        && let Err(e) = std::fs::remove_dir_all(dir)
    {
        tracing::debug!(dir = %dir.display(), "session tmp folder not removed: {e}");
    }
}

/// `dir` is a real directory (lstat) of this user's that no one else can
/// write or list, so nothing below it can be swapped for a symlink between a
/// listing and a removal.
#[cfg(unix)]
fn private_to_me(dir: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    std::fs::symlink_metadata(dir)
        .is_ok_and(|m| m.file_type().is_dir() && m.uid() == uid && m.mode() & 0o077 == 0)
}

#[cfg(not(unix))]
fn private_to_me(_dir: &Path) -> bool {
    false
}

/// This daemon's root, when it and every folder above it up to the base are
/// [`private_to_me`] and it names `acpmux_home`.
fn own_root(base: &Path, acpmux_home: &Path) -> Option<PathBuf> {
    let root = daemon_root(base, acpmux_home);
    let private = [base, &base.join(TMP_SUBDIR), &root].iter().all(|d| private_to_me(d));
    (private && recorded_home(&root).as_deref() == Some(acpmux_home)).then_some(root)
}

/// `root/<session_id>`, for an id that is one path component.
fn session_dir(root: &Path, session_id: &str) -> Option<PathBuf> {
    one_component(session_id).then(|| root.join(session_id))
}

/// The real directories in `root` (itself a real directory) whose names
/// pass `take`. Files, symlinks and other names are never listed.
fn real_dirs_in(root: &Path, take: &dyn Fn(&str) -> bool) -> Vec<PathBuf> {
    if !std::fs::symlink_metadata(root).is_ok_and(|m| m.file_type().is_dir()) {
        return Vec::new();
    }
    let Ok(entries) = std::fs::read_dir(root) else { return Vec::new() };
    entries
        .flatten()
        // DirEntry::file_type does not follow a symlink.
        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
        .filter(|e| e.file_name().to_str().is_some_and(take))
        .map(|e| e.path())
        .collect()
}

/// The file in a daemon's root that names its acpmux home, so a daemon whose
/// home is gone (its store with it) can have its root removed by another.
const HOME_RECORD: &str = ".home";

/// Name `acpmux_home` in `root`, once (never through a symlink).
#[cfg(unix)]
fn record_home(root: &Path, acpmux_home: &Path) {
    use std::io::Write as _;
    use std::os::unix::fs::OpenOptionsExt as _;
    let path = root.join(HOME_RECORD);
    if std::fs::symlink_metadata(&path).is_ok() {
        return;
    }
    // Written aside and linked into place: a reader never sees half a
    // record, and a second writer never replaces the first.
    let part = root.join(format!("{HOME_RECORD}.{}", uuid::Uuid::now_v7().simple()));
    if let Ok(mut file) =
        std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&part)
    {
        if file.write_all(acpmux_home.as_os_str().as_encoded_bytes()).is_ok() {
            let _ = std::fs::hard_link(&part, &path);
        }
        let _ = std::fs::remove_file(&part);
    }
}

/// The acpmux home a root names, when its record is a regular file.
fn recorded_home(root: &Path) -> Option<PathBuf> {
    let path = root.join(HOME_RECORD);
    let meta = std::fs::symlink_metadata(&path).ok()?;
    if !meta.file_type().is_file() || meta.len() > 4096 {
        return None;
    }
    let text = String::from_utf8(std::fs::read(&path).ok()?).ok()?;
    Some(PathBuf::from(text))
}

/// The session is gone for good: remove its folder in this daemon's root
/// ([`own_root`]) and the first build's folder under `user_home`.
pub(crate) fn remove(base: &Path, acpmux_home: &Path, user_home: Option<&Path>, session_id: &str) {
    if let Some(dir) = own_root(base, acpmux_home).and_then(|root| session_dir(&root, session_id)) {
        remove_dir(&dir);
    }
    if let Some(dir) = user_home.and_then(|h| session_dir(&legacy_root(h), session_id)) {
        remove_dir(&dir);
    }
}

/// [`remove`] for this daemon, from its environment.
#[cfg(unix)]
pub(crate) fn remove_session(session_id: &str) {
    let user_home = std::env::var_os("HOME").filter(|h| !h.is_empty()).map(PathBuf::from);
    remove(&per_user_base(), &crate::config::home(), user_home.as_deref(), session_id);
}

/// What a starting daemon removes, listed before it serves (so no session
/// can start in between) and removed later by [`remove_all`]:
///
/// - in its own root ([`own_root`]), every session folder whose session
///   `known` does not have;
/// - every other daemon's root whose recorded acpmux home (an absolute path)
///   no longer exists (that daemon and its store are gone: a test's, a
///   removed Chief home's), when the per-user directory is private;
/// - in the first build's shared root (every daemon of this user used it,
///   so a session this daemon does not know may be another daemon's live
///   one): only folders of sessions this daemon knows as closed (`closed`).
pub(crate) fn stale(
    base: &Path,
    acpmux_home: &Path,
    user_home: Option<&Path>,
    known: &dyn Fn(&str) -> bool,
    closed: &dyn Fn(&str) -> bool,
) -> Vec<PathBuf> {
    let own = daemon_root(base, acpmux_home);
    let mut out = match own_root(base, acpmux_home) {
        Some(root) => real_dirs_in(&root, &|name| session_named(name) && !known(name)),
        None => Vec::new(),
    };
    let own_name = own.file_name().and_then(|n| n.to_str()).unwrap_or_default().to_owned();
    let daemon_named = |name: &str| {
        name.len() == 8 && name.bytes().all(|b| b.is_ascii_hexdigit()) && name != own_name
    };
    let t = base.join(TMP_SUBDIR);
    let roots = if private_to_me(base) && private_to_me(&t) {
        real_dirs_in(&t, &daemon_named)
    } else {
        Vec::new()
    };
    for root in roots {
        if recorded_home(&root).is_some_and(|home| {
            home.is_absolute()
                && std::fs::symlink_metadata(&home)
                    .is_err_and(|e| e.kind() == std::io::ErrorKind::NotFound)
        }) {
            out.push(root);
        }
    }
    if let Some(home) = user_home {
        out.extend(real_dirs_in(&legacy_root(home), &|name| session_named(name) && closed(name)));
    }
    out
}

/// Remove what [`stale`] listed (each checked again: a real directory only).
pub(crate) fn remove_all(dirs: &[PathBuf]) {
    for dir in dirs {
        remove_dir(dir);
    }
}

/// [`stale`] for this daemon, from its environment.
#[cfg(unix)]
pub(crate) fn stale_for_daemon(
    known: &dyn Fn(&str) -> bool,
    closed: &dyn Fn(&str) -> bool,
) -> Vec<PathBuf> {
    let user_home = std::env::var_os("HOME").filter(|h| !h.is_empty()).map(PathBuf::from);
    stale(&per_user_base(), &crate::config::home(), user_home.as_deref(), known, closed)
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt as _;

    const A: &str = "01a15d7d-b692-76b3-b8de-a9a71809de2a";
    const B: &str = "01a15db7-20cd-7e10-8535-158031297e5c";

    struct Scratch(PathBuf);
    impl Scratch {
        fn new(tag: &str) -> Self {
            let dir = std::env::temp_dir().join(format!(
                "acpmux-session-tmp-{tag}-{}-{}",
                std::process::id(),
                uuid::Uuid::now_v7().simple()
            ));
            std::fs::create_dir_all(&dir).unwrap();
            Scratch(dir)
        }
    }
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn two_sessions_never_share_a_temporary_folder() {
        let s = Scratch::new("two");
        let base = s.0.join("acpmux-501");
        let home = Path::new("/home/someone/state");
        let a = make(&base, home, A).unwrap();
        let b = make(&base, home, B).unwrap();
        assert_ne!(a, b);
        assert_eq!(a, daemon_root(&base, home).join(A));
        assert_eq!(a.parent(), b.parent());
        assert!(a.is_dir() && b.is_dir());
        for dir in [&base, &base.join("t"), &daemon_root(&base, home), &a] {
            assert_eq!(std::fs::metadata(dir).unwrap().permissions().mode() & 0o777, 0o700);
        }
        // The same session again (a restart) gets the same folder.
        assert_eq!(make(&base, home, A), Some(a));
        for bad in ["", ".", "..", "a/b", "../x"] {
            assert!(make(&base, home, bad).is_none(), "{bad:?}");
        }
    }

    #[test]
    fn the_real_path_fits_a_macos_socket_beside_it() {
        // /tmp/acpmux-<uid>/t/<8 hex>/<UUIDv7>/ + a tool's socket name.
        let dir = daemon_root(Path::new("/tmp/acpmux-4294967294"), Path::new("/x")).join(A);
        assert!(dir.as_os_str().len() <= 72, "{}", dir.display());
        assert!(dir.join("tmux-12345/default.sock").as_os_str().len() < 104);
    }

    #[test]
    fn a_base_that_is_not_private_to_this_user_is_refused() {
        let s = Scratch::new("refuse");
        let home = Path::new("/h");
        // Writable by others (and not sticky).
        let open = s.0.join("open");
        std::fs::create_dir(&open).unwrap();
        std::fs::set_permissions(&open, std::fs::Permissions::from_mode(0o777)).unwrap();
        assert!(make(&open, home, A).is_none());
        assert!(!open.join("t").exists());
        // A symlink to a private directory.
        let real = s.0.join("real");
        std::fs::create_dir(&real).unwrap();
        std::fs::set_permissions(&real, std::fs::Permissions::from_mode(0o700)).unwrap();
        let link = s.0.join("link");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        assert!(make(&link, home, A).is_none());
        assert!(!real.join("t").exists());
        // A planted symlink below a private base is not followed.
        let base = s.0.join("base");
        let elsewhere = s.0.join("elsewhere");
        std::fs::create_dir(&elsewhere).unwrap();
        std::fs::create_dir(&base).unwrap();
        std::fs::set_permissions(&base, std::fs::Permissions::from_mode(0o700)).unwrap();
        std::os::unix::fs::symlink(&elsewhere, base.join("t")).unwrap();
        assert!(make(&base, home, A).is_none());
        assert_eq!(std::fs::read_dir(&elsewhere).unwrap().count(), 0);
    }

    #[test]
    fn with_a_runtime_dir_only_tmpdir_changes() {
        let dir = Path::new("/tmp/acpmux-1/t/0/s");
        let agent = |k: &str| (k == "XDG_RUNTIME_DIR").then(|| "/run/user/1".to_owned());
        for pin in [true, false] {
            let env = env_for(dir, agent, |_| false, pin, 1);
            assert_eq!(
                env,
                vec![(SESSION_TMPDIR_ENV, dir.into()), ("TMPDIR", dir.into())],
                "pin={pin}"
            );
        }
    }

    /// The socket bases every client resolves: cmux-tui's runtime base and
    /// the browser host socket (cmux-browser-host `default_socket_path`).
    fn resolved(env: &dyn Fn(&str) -> Option<String>, uid: u32) -> (PathBuf, PathBuf) {
        let set = |k: &str| env(k).filter(|v| !v.is_empty());
        let runtime = set("XDG_RUNTIME_DIR")
            .or_else(|| set("TMPDIR"))
            .map(PathBuf::from)
            .unwrap_or_else(|| "/tmp".into());
        let browser = match set("CMUX_BROWSER_HOST_SOCKET") {
            Some(path) => PathBuf::from(path),
            None => match set("XDG_RUNTIME_DIR") {
                Some(dir) => PathBuf::from(dir).join("cmux"),
                None => set("TMPDIR")
                    .map(PathBuf::from)
                    .unwrap_or_else(|| "/platform-temp".into())
                    .join(format!("cmux-{uid}")),
            }
            .join("browser-host.sock"),
        };
        (runtime, browser)
    }

    #[test]
    fn a_mac_without_a_runtime_dir_resolves_every_socket_as_before() {
        let dir = Path::new("/tmp/acpmux-501/t/0/s");
        let cases: [&[(&str, &str)]; 4] = [
            &[("TMPDIR", "/var/folders/ab/T/")],
            &[],
            &[("TMPDIR", "")],
            &[("TMPDIR", "/var/folders/ab/T/"), ("CMUX_BROWSER_HOST_SOCKET", "/x/b.sock")],
        ];
        for case in cases {
            let before = |k: &str| case.iter().find(|(n, _)| *n == k).map(|(_, v)| v.to_string());
            let changes = env_for(dir, before, |_| false, true, 501);
            let after = |k: &str| {
                changes
                    .iter()
                    .find(|(n, _)| *n == k)
                    .map(|(_, v)| v.to_string_lossy().into_owned())
                    .or_else(|| before(k))
            };
            assert_eq!(after(SESSION_TMPDIR_ENV).as_deref(), dir.to_str());
            if before("TMPDIR").is_some_and(|v| !v.is_empty()) {
                assert_eq!(after("TMPDIR").as_deref(), dir.to_str(), "{case:?}");
            } else {
                // No TMPDIR to pin: nothing but the session's own folder.
                assert_eq!(changes, vec![(SESSION_TMPDIR_ENV, dir.into())], "{case:?}");
            }
            assert_eq!(resolved(&after, 501), resolved(&before, 501), "{case:?}");
        }
        // The base it pins is the agent's own TMPDIR, verbatim.
        let env = env_for(
            dir,
            |k| (k == "TMPDIR").then(|| "/var/folders/ab/T/".into()),
            |_| false,
            true,
            501,
        );
        assert!(env.contains(&("XDG_RUNTIME_DIR", "/var/folders/ab/T/".into())));
    }

    #[test]
    fn under_a_cmux_daemon_the_browser_host_socket_is_not_named() {
        // cmux-browser-host takes a named socket next to CMUX_TUI_SOCKET for
        // the daemon's own host and never starts one; unnamed, the agent
        // resolves a socket of its own and starts its host there.
        let dir = Path::new("/tmp/acpmux-501/t/0/s");
        let before = |k: &str| match k {
            "TMPDIR" => Some("/var/folders/ab/T/".to_owned()),
            "CMUX_TUI_SOCKET" => Some("/var/folders/ab/T/cmux-501/tui.sock".to_owned()),
            _ => None,
        };
        let changes = env_for(dir, before, |_| false, true, 501);
        assert!(!changes.iter().any(|(k, _)| *k == "CMUX_BROWSER_HOST_SOCKET"), "{changes:?}");
        assert!(changes.contains(&("XDG_RUNTIME_DIR", "/var/folders/ab/T/".into())));
        let after = |k: &str| {
            changes
                .iter()
                .find(|(n, _)| *n == k)
                .map(|(_, v)| v.to_string_lossy().into_owned())
                .or_else(|| before(k))
        };
        assert_eq!(resolved(&after, 501).1, Path::new("/var/folders/ab/T/cmux/browser-host.sock"));
    }

    #[test]
    fn linux_without_a_runtime_dir_keeps_the_shared_tmpdir() {
        let dir = Path::new("/tmp/acpmux-1/t/0/s");
        let env = env_for(dir, |k| (k == "TMPDIR").then(|| "/tmp".into()), |_| false, false, 1);
        assert_eq!(env, vec![(SESSION_TMPDIR_ENV, dir.into())]);
        // A profile that blanks XDG_RUNTIME_DIR would undo the pin on a Mac too.
        let env = env_for(dir, |_| None, |k| k == "XDG_RUNTIME_DIR", true, 1);
        assert_eq!(env, vec![(SESSION_TMPDIR_ENV, dir.into())]);
    }

    #[test]
    fn a_daemon_sweeps_only_its_own_unknown_sessions() {
        let s = Scratch::new("sweep");
        let base = s.0.join("acpmux-1");
        let (mine, theirs) = (s.0.join("home/state"), s.0.join("home/chief/acpmux"));
        std::fs::create_dir_all(&mine).unwrap();
        std::fs::create_dir_all(&theirs).unwrap();
        let (mine, theirs) = (mine.as_path(), theirs.as_path());
        assert_ne!(daemon_root(&base, mine), daemon_root(&base, theirs));
        let kept = make(&base, mine, A).unwrap();
        let gone = make(&base, mine, B).unwrap();
        std::fs::write(gone.join("scratch"), b"x").unwrap();
        let other = make(&base, theirs, B).unwrap();
        let root = daemon_root(&base, mine);
        // Not a session name, a file, and a symlink to a folder elsewhere.
        std::fs::create_dir(root.join("notes")).unwrap();
        let file_id = "01a15db7-20cd-7e10-8535-158031297e5d";
        std::fs::write(root.join(file_id), b"x").unwrap();
        let target = s.0.join("target");
        std::fs::create_dir(&target).unwrap();
        std::fs::write(target.join("keep"), b"x").unwrap();
        let link_id = "01a15db7-20cd-7e10-8535-158031297e5e";
        std::os::unix::fs::symlink(&target, root.join(link_id)).unwrap();

        let stale = stale(&base, mine, None, &|id| id == A, &|_| false);
        assert_eq!(stale, vec![gone.clone()]);
        remove_all(&stale);
        assert!(kept.is_dir() && !gone.exists());
        assert!(other.is_dir(), "another daemon's live session folder was swept");
        assert!(root.join("notes").is_dir() && root.join(file_id).is_file());
        assert!(root.join(link_id).symlink_metadata().unwrap().file_type().is_symlink());
        assert!(target.join("keep").is_file());
    }

    #[test]
    fn a_purge_removes_the_folder_and_the_first_builds_one() {
        let s = Scratch::new("purge");
        let base = s.0.join("acpmux-1");
        let home = Path::new("/home/u/state");
        let user = s.0.join("user");
        let dir = make(&base, home, A).unwrap();
        std::fs::write(dir.join("f"), b"x").unwrap();
        let legacy = legacy_root(&user).join(A).join("tmp");
        std::fs::create_dir_all(&legacy).unwrap();
        let legacy_b = legacy_root(&user).join(B).join("tmp");
        std::fs::create_dir_all(&legacy_b).unwrap();
        remove(&base, home, Some(&user), A);
        assert!(!dir.exists() && !legacy_root(&user).join(A).exists());
        assert!(legacy_b.is_dir(), "another session's folder went with this one");
        // A symlink in the session's place is left, and what it names too.
        let target = s.0.join("target");
        std::fs::create_dir(&target).unwrap();
        std::os::unix::fs::symlink(&target, daemon_root(&base, home).join(A)).unwrap();
        remove(&base, home, Some(&user), A);
        assert!(target.is_dir());
        assert!(daemon_root(&base, home).join(A).symlink_metadata().is_ok());
    }

    #[test]
    fn a_daemon_whose_home_is_gone_has_its_root_removed() {
        let s = Scratch::new("orphan");
        let base = s.0.join("acpmux-1");
        let (mine, live, gone) = (s.0.join("mine"), s.0.join("live"), s.0.join("gone"));
        for home in [&mine, &live, &gone] {
            std::fs::create_dir(home).unwrap();
        }
        make(&base, &mine, A).unwrap();
        let live_dir = make(&base, &live, A).unwrap();
        let gone_dir = make(&base, &gone, B).unwrap();
        // A root without a record (an older build's, a stranger's) stays.
        let bare = base.join("t").join("0badc0de");
        std::fs::create_dir(&bare).unwrap();
        std::fs::remove_dir(&gone).unwrap();
        let stale = stale(&base, &mine, None, &|id| id == A, &|_| false);
        assert_eq!(stale, vec![daemon_root(&base, &gone)]);
        remove_all(&stale);
        assert!(!gone_dir.exists() && live_dir.is_dir() && bare.is_dir());
        // Its own root is never taken for a gone one, even with a stale record.
        std::fs::remove_dir(&mine).unwrap();
        assert!(super::stale(&base, &mine, None, &|_| true, &|_| false).is_empty());
    }

    #[test]
    fn nothing_is_swept_or_purged_below_a_base_others_can_change() {
        let s = Scratch::new("unsafe-base");
        let base = s.0.join("acpmux-1");
        let (mine, gone) = (s.0.join("mine"), s.0.join("gone"));
        std::fs::create_dir(&mine).unwrap();
        std::fs::create_dir(&gone).unwrap();
        let a = make(&base, &mine, A).unwrap();
        let b = make(&base, &mine, B).unwrap();
        let theirs = make(&base, &gone, A).unwrap();
        std::fs::remove_dir(&gone).unwrap();
        let own = daemon_root(&base, &mine);
        for widen in [base.clone(), base.join("t"), own.clone()] {
            std::fs::set_permissions(&widen, std::fs::Permissions::from_mode(0o777)).unwrap();
            let listed = stale(&base, &mine, None, &|_| false, &|_| false);
            if widen == own {
                // Only the gone daemon's root, in a base still private.
                assert_eq!(listed, vec![daemon_root(&base, &gone)]);
            } else {
                assert!(listed.is_empty(), "{widen:?}: {listed:?}");
            }
            remove(&base, &mine, None, A);
            assert!(a.is_dir() && b.is_dir() && theirs.is_dir(), "{widen:?}");
            std::fs::set_permissions(&widen, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        // A symlink for `t` (a private base, as a stranger could not make
        // one, but checked the same): nothing it names is listed.
        let s2 = Scratch::new("link-t");
        let base2 = s2.0.join("acpmux-1");
        std::fs::create_dir(&base2).unwrap();
        std::fs::set_permissions(&base2, std::fs::Permissions::from_mode(0o700)).unwrap();
        std::os::unix::fs::symlink(base.join("t"), base2.join("t")).unwrap();
        assert!(stale(&base2, &mine, None, &|_| false, &|_| false).is_empty());
        remove(&base2, &mine, None, A);
        assert!(a.is_dir());
    }

    #[test]
    fn two_homes_with_one_hash_never_share_a_root() {
        let s = Scratch::new("collide");
        let base = s.0.join("acpmux-1");
        let (first, second) = (Path::new("/home/first/state"), Path::new("/home/second/state"));
        let dir = make(&base, first, A).unwrap();
        // The first's root moved to the second home's name: what a hash
        // collision would make.
        let root = daemon_root(&base, first);
        let collided = |home: &Path| {
            let theirs = daemon_root(&base, home);
            if theirs != root {
                std::fs::rename(&root, &theirs).unwrap();
            }
            theirs
        };
        let shared = collided(second);
        assert!(make(&base, second, B).is_none(), "a second home took the first's root");
        // The second daemon neither sweeps nor purges the first's sessions.
        assert!(stale(&base, second, None, &|_| false, &|_| false).is_empty());
        remove(&base, second, None, A);
        assert!(shared.join(A).is_dir() && !dir.exists());
    }

    #[test]
    fn the_home_record_is_written_once() {
        let s = Scratch::new("record");
        let root = s.0.join("root");
        std::fs::create_dir(&root).unwrap();
        record_home(&root, Path::new("/first"));
        record_home(&root, Path::new("/second"));
        assert_eq!(recorded_home(&root).as_deref(), Some(Path::new("/first")));
        // Only the record is left, no part file beside it.
        let names: Vec<_> =
            std::fs::read_dir(&root).unwrap().flatten().map(|e| e.file_name()).collect();
        assert_eq!(names, vec![std::ffi::OsString::from(HOME_RECORD)]);
    }

    #[test]
    fn the_first_builds_shared_folders_go_only_for_closed_sessions_this_daemon_knows() {
        let s = Scratch::new("legacy");
        let base = s.0.join("acpmux-1");
        let user = s.0.join("user");
        let id_c = "01a15db7-20cd-7e10-8535-158031297e5f";
        for id in [A, B, id_c] {
            std::fs::create_dir_all(legacy_root(&user).join(id).join("tmp")).unwrap();
        }
        // A: closed here. B: known and live here. C: another daemon's.
        let known = |id: &str| id == A || id == B;
        let closed = |id: &str| id == A;
        let home = Path::new("/h");
        remove_all(&stale(&base, home, Some(&user), &known, &closed));
        assert!(!legacy_root(&user).join(A).exists());
        assert!(legacy_root(&user).join(B).is_dir());
        assert!(legacy_root(&user).join(id_c).is_dir());
    }
}
