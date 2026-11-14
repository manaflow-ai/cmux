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
    use std::os::unix::fs::MetadataExt;
    let dir = parent.join(name);
    match crate::home_fs::create_dir(&dir, 0o700) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(_) => return None,
    }
    let meta = std::fs::symlink_metadata(&dir).ok()?;
    if !meta.file_type().is_dir() || meta.uid() != uid {
        return None;
    }
    if meta.mode() & 0o077 != 0 {
        crate::home_fs::set_mode(&dir, 0o700).ok()?;
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
        && let Err(e) = crate::home_fs::remove_dir_all(dir)
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
    let path = root.join(HOME_RECORD);
    if std::fs::symlink_metadata(&path).is_ok() {
        return;
    }
    // Written aside and linked into place: a reader never sees half a
    // record, and a second writer never replaces the first.
    let part = root.join(format!("{HOME_RECORD}.{}", uuid::Uuid::now_v7().simple()));
    if let Ok(mut file) =
        crate::home_fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&part)
    {
        if file.write_all(acpmux_home.as_os_str().as_encoded_bytes()).is_ok() {
            let _ = crate::home_fs::hard_link(&part, &path);
        }
        let _ = crate::home_fs::remove_file(&part);
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
mod tests;
