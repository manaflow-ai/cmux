//! Configuration: `$ACPMUX_HOME/config.json`, agent registry, store mode.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::io::Read;
use std::path::{Path, PathBuf};

static HOME_OVERRIDE: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();

pub const V2_SURFACES: [&str; 5] = ["books", "list", "chat", "peers", "start"];

/// The opt-in v2 surfaces. Unknown names are intentionally ignored so a newer
/// config remains readable by an older daemon.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(transparent)]
pub struct V2Surfaces(pub Vec<String>);

impl V2Surfaces {
    pub fn enabled(&self) -> BTreeSet<&str> {
        let mut known = BTreeSet::new();
        for name in &self.0 {
            if V2_SURFACES.contains(&name.as_str()) {
                known.insert(name.as_str());
            } else {
                log_unknown_surface(name);
            }
        }
        if known.contains("chat") || known.contains("start") {
            known.insert("books");
        }
        known
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

fn log_unknown_surface(name: &str) {
    static SEEN: std::sync::OnceLock<std::sync::Mutex<HashSet<String>>> =
        std::sync::OnceLock::new();
    let seen = SEEN.get_or_init(|| std::sync::Mutex::new(HashSet::new()));
    if let Ok(mut names) = seen.lock()
        && names.insert(name.to_owned())
    {
        tracing::warn!(surface = name, "ignoring unknown acpmux.v2 surface");
    }
}

/// Set the state directory for this process, below `ACPMUX_HOME` in
/// precedence. A host binary uses it to keep a tagged build's daemon apart
/// from the user's (`cmux acp` under `CMUX_TAG`). Set once, before `home()`.
pub fn set_home_override(path: PathBuf) {
    let _ = HOME_OVERRIDE.set(path);
}

pub fn home() -> PathBuf {
    if let Ok(v) = std::env::var("ACPMUX_HOME") {
        return PathBuf::from(v);
    }
    if let Some(path) = HOME_OVERRIDE.get() {
        return path.clone();
    }
    default_home()
}

/// The daemon's panic log, `$ACPMUX_HOME/panics.jsonl` (cmux-panic-log):
/// a panic in a request task ends only that task and used to leave just
/// two lines in `daemon.log` (the 2026-10-14 sort panic). The cmux-next
/// app sends new lines to Sentry.
pub fn panic_log_path() -> std::path::PathBuf {
    home().join("panics.jsonl")
}

/// The default state directory, with no ACPMUX_HOME and no override: the
/// person's own daemon home (a hand, which runs its own daemon, protects it).
pub fn default_home() -> PathBuf {
    resolve_supervised_home(&dirs::home_dir().unwrap_or_else(|| PathBuf::from(".")))
}

/// `<account_home>/.acpmux`, or the real directory it links to when it is a symlink to the
/// person's own supervised home (`<account_home>/.acpmux-supervised/<name>`, what a supervised
/// daemon's `ACPMUX_HOME` names). The private-state directory opens with O_NOFOLLOW and the
/// consent check refuses redirection, so both must see the real path. A link anywhere else is
/// returned unresolved and keeps being refused.
pub fn resolve_supervised_home(account_home: &Path) -> PathBuf {
    let link = default_home_in(account_home);
    let is_link = |p: &Path| std::fs::symlink_metadata(p).is_ok_and(|m| m.file_type().is_symlink());
    if !is_link(&link) {
        return link;
    }
    let supervised = account_home.join(".acpmux-supervised");
    if is_link(&supervised) {
        return link;
    }
    let (Ok(real), Ok(account)) =
        (std::fs::canonicalize(&link), std::fs::canonicalize(account_home))
    else {
        return link;
    };
    if real.parent() == Some(account.join(".acpmux-supervised").as_path()) && real.is_dir() {
        real
    } else {
        link
    }
}

/// [`default_home`] for the OS account whose home folder is `account_home`.
pub fn default_home_in(account_home: &Path) -> PathBuf {
    account_home.join(".acpmux")
}

/// Whether a command may start a daemon in `home`, given this process's `ACPMUX_HOME` and
/// `ACPMUX_SOCKET` (`explicit_home`, `configured_socket`) and `home`'s own socket
/// (`own_socket`, [`socket_path_for`] with no configured path). `None` when it may, else why
/// not. A daemon's lock and socket always come from one home:
///
/// - A missing home is created only when it is the default one or this build's own
///   ([`set_home_override`]). Any other missing `ACPMUX_HOME` is most likely a test's removed
///   temporary folder: recreating it started a second daemon beside one still running on the
///   deleted files (cosmic-gray, 2026-10-29).
/// - `ACPMUX_SOCKET` pairs only with an explicit `ACPMUX_HOME`, as in the app
///   (`AcpmuxEnvironment.swift`). Without one, a socket that is not the home's own names
///   another home's daemon: a start here would take this home's lock for that socket, and the
///   command waited out the whole handover budget on a lock another daemon held.
pub(crate) fn autostart_refusal(
    home: &Path,
    explicit_home: bool,
    configured_socket: Option<&Path>,
    own_socket: &Path,
) -> Option<String> {
    let built_in =
        home == default_home() || HOME_OVERRIDE.get().is_some_and(|own| own.as_path() == home);
    if !built_in && std::fs::symlink_metadata(home).is_err() {
        return Some(format!(
            "the acpmux home {} does not exist, and acpmux never creates a missing ACPMUX_HOME to start a daemon there (a removed test folder looks the same); create it, or unset ACPMUX_HOME",
            home.display()
        ));
    }
    match configured_socket {
        Some(socket) if !explicit_home && socket != own_socket => Some(format!(
            "no acpmux daemon answers at {} (ACPMUX_SOCKET), and it is not the socket of this command's home {} ({}): acpmux starts a daemon only where its lock and socket share one home; set ACPMUX_HOME to that daemon's home, or unset ACPMUX_SOCKET",
            socket.display(),
            home.display(),
            own_socket.display()
        )),
        _ => None,
    }
}

/// Set once this daemon's home is gone (`daemon/home_watch.rs`); never cleared.
// 0: present, 1: the home or lock was lost, 2: only the socket was lost. A
// socket disappearing still fences writes, but the home remains ours, so the
// shutdown may safely end hosts whose records were not adopted yet.
static HOME_LOST: std::sync::atomic::AtomicU8 = std::sync::atomic::AtomicU8::new(0);

/// This daemon's home was removed or replaced: from now on it makes no folder and creates or
/// opens no state file for writing under that path, which may be another daemon's home now.
pub(crate) fn mark_home_lost() {
    HOME_LOST.store(1, std::sync::atomic::Ordering::SeqCst);
}

/// Mark only the bound socket as lost. The state fence is still active, but
/// the home and its host records remain this daemon's, so shutdown can clean
/// up an unadopted host.
pub(crate) fn mark_socket_lost() {
    let _ = HOME_LOST.compare_exchange(
        0,
        2,
        std::sync::atomic::Ordering::SeqCst,
        std::sync::atomic::Ordering::SeqCst,
    );
}

/// Whether the home or socket is lost, including an identity change awaiting event delivery.
pub(crate) fn home_lost() -> bool {
    HOME_LOST.load(std::sync::atomic::Ordering::SeqCst) != 0
}

/// Whether the home or lock itself was lost. A socket-only loss leaves the
/// host records owned by this daemon and may be cleaned during shutdown.
pub(crate) fn home_path_lost() -> bool {
    HOME_LOST.load(std::sync::atomic::Ordering::SeqCst) == 1
}

/// The home this daemon holds, as the folder it locked: its device and inode (`daemon.rs`).
static HELD_HOME: std::sync::OnceLock<(u64, u64)> = std::sync::OnceLock::new();

/// The device and inode of `path` itself (never a link's target).
#[cfg(unix)]
fn folder_identity(path: &Path) -> Option<(u64, u64)> {
    use std::os::unix::fs::MetadataExt;
    std::fs::symlink_metadata(path).ok().map(|m| (m.dev(), m.ino()))
}

/// Windows: the folder's file id, its volume serial and file index (never a link's target).
#[cfg(windows)]
fn folder_identity(path: &Path) -> Option<(u64, u64)> {
    crate::owner_only::file_id(path).ok()
}

#[cfg(not(any(unix, windows)))]
fn folder_identity(_path: &Path) -> Option<(u64, u64)> {
    None
}

/// Records [`home`] as the folder this daemon holds, once it holds its lock. A process that
/// never calls it (a CLI command) checks no identity.
pub fn hold_home() {
    let home = home();
    if let Some(identity) = folder_identity(&home) {
        let _ = HELD_HOME.set(identity);
    }
    if let Ok(Some(dir)) = crate::artifacts_fs::Dir::open(&home, Path::new("")) {
        let _ = HELD_HOME_DIR.set(dir);
    }
}

/// The held home ([`hold_home`]) as the open folder, not its path.
static HELD_HOME_DIR: std::sync::OnceLock<crate::artifacts_fs::Dir> = std::sync::OnceLock::new();

/// The held home as the folder this daemon locked, with `path` relative to it: a write made
/// through it ([`crate::artifacts_fs::Dir::write`]) lands in that folder wherever it is now, so a
/// home replaced after [`refuse_lost_home`] passed and before the write never gets it (the
/// window that check leaves open by path). `None`: this process holds no home (a CLI command)
/// or `path` is not under it; such a write goes by path.
pub(crate) fn held_home_dir(path: &Path) -> Option<(&'static crate::artifacts_fs::Dir, PathBuf)> {
    let dir = HELD_HOME_DIR.get()?;
    let relative = path.strip_prefix(home()).ok()?;
    Some((dir, relative.to_path_buf()))
}

/// Whether the held home ([`hold_home`]) is gone or another folder now: read from the folder
/// itself, so it does not wait for the home watch to hear of it.
fn held_home_replaced(home: &Path) -> bool {
    HELD_HOME.get().is_some_and(|held| folder_identity(home) != Some(*held))
}

/// Refuses a write under a lost home: one [`mark_home_lost`] marked, or one no longer the folder
/// this daemon holds ([`hold_home`]), which it then marks. Every write under the home goes
/// through it, so a write after the home was replaced never lands in the replacement, however
/// late the home watch hears of it; a shutdown's last saves never make a removed home again.
/// A replacement between this check and the write itself is not ruled out (by path, POSIX has
/// no write-if-same-folder).
pub(crate) fn refuse_lost_home(path: &Path) -> Result<()> {
    let home = home();
    if !path.starts_with(&home) {
        return Ok(());
    }
    if !home_path_lost() && held_home_replaced(&home) {
        mark_home_lost();
    }
    let checked = if home_lost() {
        Err(anyhow::anyhow!(
            "the acpmux home {} is gone; {} is not written",
            home.display(),
            path.display()
        ))
    } else {
        Ok(())
    };
    #[cfg(test)]
    seams::checked(path, checked.is_ok());
    checked
}

/// Test seams for the forced lost-home races (`lost_home_race_tests.rs`): each holds a writer at
/// one point so the order its race depends on is the test's, not the clock's. Each hook is the
/// setting thread's own (`thread_local!`), set by an `on_*` guard and taken off when it drops:
/// a test runs its writer on a thread it owns, so a hook set by one test never fires in another
/// test running beside it.
#[cfg(test)]
pub(crate) mod seams {
    use std::cell::RefCell;
    use std::path::Path;
    use std::rc::Rc;

    type Checked = Rc<dyn Fn(&Path, bool)>;
    type BeforeRename = Rc<dyn Fn(&Path)>;
    type MidWrite = Rc<dyn Fn(&Path) -> std::io::Result<()>>;

    thread_local! {
        static CHECKED: RefCell<Option<Checked>> = const { RefCell::new(None) };
        static BEFORE_RENAME: RefCell<Option<BeforeRename>> = const { RefCell::new(None) };
        static MID_WRITE: RefCell<Option<MidWrite>> = const { RefCell::new(None) };
    }

    /// While the guard lives, `hook` is called on this thread at the end of each home check
    /// under the home, with the path checked and whether the check passed: after the check,
    /// before the write it guards.
    pub(crate) fn on_checked(hook: impl Fn(&Path, bool) + 'static) -> Guard {
        CHECKED.with(|slot| *slot.borrow_mut() = Some(Rc::new(hook)));
        Guard(Which::Checked)
    }

    /// While the guard lives, `hook` is called on this thread with a file's path once its
    /// temporary copy is written and synced, before that copy is renamed over the file.
    pub(crate) fn on_before_rename(hook: impl Fn(&Path) + 'static) -> Guard {
        BEFORE_RENAME.with(|slot| *slot.borrow_mut() = Some(Rc::new(hook)));
        Guard(Which::BeforeRename)
    }

    /// While the guard lives, `hook` is called on this thread with the path a `home_fs` write
    /// is filling once part of its bytes are written, before the rest: its error fails the
    /// write there, as a full disk would.
    pub(crate) fn on_mid_write(hook: impl Fn(&Path) -> std::io::Result<()> + 'static) -> Guard {
        MID_WRITE.with(|slot| *slot.borrow_mut() = Some(Rc::new(hook)));
        Guard(Which::MidWrite)
    }

    pub(crate) fn mid_write(path: &Path) -> std::io::Result<()> {
        match MID_WRITE.with(|slot| slot.borrow().clone()) {
            Some(hook) => hook(path),
            None => Ok(()),
        }
    }

    pub(crate) fn checked(path: &Path, passed: bool) {
        // Cloned out first: the hook may block, or check again, with the slot free.
        if let Some(hook) = CHECKED.with(|slot| slot.borrow().clone()) {
            hook(path, passed);
        }
    }

    pub(crate) fn before_rename(path: &Path) {
        if let Some(hook) = BEFORE_RENAME.with(|slot| slot.borrow().clone()) {
            hook(path);
        }
    }

    enum Which {
        Checked,
        BeforeRename,
        MidWrite,
    }

    /// Takes its hook off this thread when dropped.
    #[must_use = "the hook is taken off when the guard drops"]
    pub(crate) struct Guard(Which);

    impl Drop for Guard {
        fn drop(&mut self) {
            match self.0 {
                Which::Checked => drop(CHECKED.with(|slot| slot.borrow_mut().take())),
                Which::BeforeRename => drop(BEFORE_RENAME.with(|slot| slot.borrow_mut().take())),
                Which::MidWrite => drop(MID_WRITE.with(|slot| slot.borrow_mut().take())),
            }
        }
    }
}

/// Make one acpmux state directory owner-only, including an existing directory
/// created by an older build under a permissive umask. Refuse links and a
/// directory owned by another user before changing its permissions.
#[cfg(unix)]
pub(crate) fn private_state_dir(dir: &Path) -> Result<()> {
    use std::os::unix::fs::MetadataExt;

    refuse_lost_home(dir)?;
    validate_private_state_ancestors(dir)?;
    // Made and opened through the folder this daemon holds (`home_fs`): a home replaced after
    // the check never gets the folder.
    crate::home_fs::create_dir_all(dir, 0o700)?;
    validate_private_state_ancestors(dir)?;
    let opened = crate::home_fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(dir)
        .with_context(|| format!("open private state directory {}", dir.display()))?;
    validate_private_state_dir(&opened, dir)?;
    let metadata = opened.metadata()?;
    let reopened = crate::home_fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(dir)
        .with_context(|| format!("reopen private state directory {}", dir.display()))?;
    let again = reopened.metadata()?;
    anyhow::ensure!(
        metadata.dev() == again.dev() && metadata.ino() == again.ino(),
        "{} changed while its private permissions were checked",
        dir.display()
    );
    Ok(())
}

/// Checks the open folder itself, so a held parent can validate a child without walking
/// the parent's ancestors again.
#[cfg(unix)]
pub(crate) fn validate_private_state_dir(opened: &std::fs::File, dir: &Path) -> Result<()> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    let metadata = opened.metadata()?;
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    anyhow::ensure!(
        metadata.is_dir() && metadata.uid() == uid,
        "{} is not a state directory owned by this user",
        dir.display()
    );
    anyhow::ensure!(
        metadata.mode() & 0o022 == 0,
        "{}",
        writable_refusal(dir, metadata.mode(), "700")
    );
    refuse_extended_acl(opened, dir)?;
    if metadata.mode() & 0o077 != 0 {
        opened
            .set_permissions(std::fs::Permissions::from_mode(0o700))
            .with_context(|| format!("make {} owner-only", dir.display()))?;
    }
    Ok(())
}

/// Why a state path another account may write is refused, and the exact
/// `chmod` (to `owner_only`, 700 or 600) that fixes it. Such a path is never
/// narrowed here: another account may have changed what is in it, and it came
/// from elsewhere (a `mkdir` or a shell redirect under umask 002), since acpmux
/// makes its own state owner-only whatever the umask.
#[cfg(unix)]
fn writable_refusal(path: &Path, mode: u32, owner_only: &str) -> String {
    let text = path.display().to_string();
    let plain = !text.is_empty()
        && text.bytes().all(|b| b.is_ascii_alphanumeric() || b"/._-+,:@%".contains(&b));
    let word = if plain { text } else { format!("'{}'", text.replace('\'', r"'\''")) };
    format!(
        "{} is writable by another user (mode {:o}): check that nothing in it was changed, then make it owner-only with `chmod {owner_only} {word}`",
        path.display(),
        mode & 0o777
    )
}

/// Every namespace owner above an acpmux state directory must be this user
/// or root, and no other account may replace a child. A root/current-user
/// sticky temporary directory is safe because another account cannot rename
/// this user's entry there.
#[cfg(unix)]
pub(crate) fn validate_private_state_ancestors(dir: &Path) -> Result<()> {
    use std::os::unix::fs::MetadataExt;

    #[cfg(test)]
    startup_seams::ancestor_check(dir);
    let uid = unsafe { libc::getuid() };
    let check = |path: &Path, metadata: &std::fs::Metadata| -> Result<()> {
        anyhow::ensure!(
            metadata.uid() == uid || metadata.uid() == 0,
            "{} is a state path ancestor owned by another user",
            path.display()
        );
        if metadata.file_type().is_dir() && metadata.mode() & 0o022 != 0 {
            anyhow::ensure!(
                metadata.mode() & 0o1000 != 0,
                "{} is a non-sticky writable ancestor of the state directory",
                path.display()
            );
        }
        if metadata.file_type().is_dir() {
            use std::os::unix::fs::OpenOptionsExt;
            let opened = std::fs::OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
                .open(path)?;
            refuse_writable_extended_acl(&opened, path)?;
        }
        Ok(())
    };

    let mut existing = dir.parent().unwrap_or_else(|| Path::new("/"));
    while std::fs::symlink_metadata(existing).is_err() {
        let Some(parent) = existing.parent() else { break };
        existing = parent;
    }
    for path in existing.ancestors() {
        check(path, &std::fs::symlink_metadata(path)?)?;
    }
    let canonical = std::fs::canonicalize(existing)
        .with_context(|| format!("resolve state path ancestor {}", existing.display()))?;
    for path in canonical.ancestors() {
        check(path, &std::fs::symlink_metadata(path)?)?;
    }
    Ok(())
}

/// Open an existing state file without following a final symlink, verify its
/// owner and type, and narrow an older file to mode 0600 before reading it.
#[cfg(unix)]
pub(crate) fn private_state_file(path: &Path) -> Result<std::fs::File> {
    use std::os::unix::fs::OpenOptionsExt;

    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .with_context(|| format!("open private state file {}", path.display()))?;
    validate_private_state_file(&file, path)?;
    Ok(file)
}

#[cfg(unix)]
pub(crate) fn validate_private_state_file(file: &std::fs::File, path: &Path) -> Result<()> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    let metadata = file.metadata()?;
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    anyhow::ensure!(
        metadata.is_file() && metadata.uid() == uid,
        "{} is not a state file owned by this user",
        path.display()
    );
    anyhow::ensure!(
        metadata.mode() & 0o022 == 0,
        "{}",
        writable_refusal(path, metadata.mode(), "600")
    );
    if !acl_checked(&metadata) {
        refuse_extended_acl(file, path)?;
        if metadata.mode() & 0o077 == 0 {
            remember_acl_checked(&metadata);
        }
    }
    if metadata.mode() & 0o077 != 0 {
        file.set_permissions(std::fs::Permissions::from_mode(0o600))
            .with_context(|| format!("make {} owner-only", path.display()))?;
    }
    Ok(())
}

/// The files whose extended ACL was checked, by file and change time: a state file read again
/// (each page of a chat's log opens its segments) is checked once, not on each open. Any change
/// to a file's ACL, mode or owner moves its change time (`ctime`), so a file changed since is
/// checked again. The owner and mode checks above still run on every open: they read the
/// `fstat` the open already needs. Leo's daemon, 2026-11-18: an attach spent a tenth of its
/// reads in `acl_get_fd_np` (`store/segment_starts.rs`).
#[cfg(unix)]
type AclKey = (u64, u64);

#[cfg(unix)]
static ACL_CHECKED: std::sync::Mutex<Option<std::collections::HashMap<AclKey, (i64, i64)>>> =
    std::sync::Mutex::new(None);

/// The most files remembered; past it the memo starts over.
#[cfg(unix)]
const ACL_CHECKED_MAX: usize = 65_536;

#[cfg(unix)]
fn acl_checked(metadata: &std::fs::Metadata) -> bool {
    use std::os::unix::fs::MetadataExt;
    let memo = ACL_CHECKED.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    memo.as_ref()
        .and_then(|memo| memo.get(&(metadata.dev(), metadata.ino())))
        .is_some_and(|&changed| changed == (metadata.ctime(), metadata.ctime_nsec()))
}

#[cfg(unix)]
fn remember_acl_checked(metadata: &std::fs::Metadata) {
    use std::os::unix::fs::MetadataExt;
    let mut memo = ACL_CHECKED.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let memo = memo.get_or_insert_with(Default::default);
    if memo.len() >= ACL_CHECKED_MAX {
        memo.clear();
    }
    memo.insert((metadata.dev(), metadata.ino()), (metadata.ctime(), metadata.ctime_nsec()));
}

/// Open or create an owner-only regular state file for read/write without
/// following a pre-positioned final symlink (daemon.lock).
#[cfg(unix)]
pub(crate) fn private_state_rw(path: &Path) -> Result<std::fs::File> {
    refuse_lost_home(path)?;

    let file = crate::home_fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .with_context(|| format!("open private state file {}", path.display()))?;
    validate_private_state_file(&file, path)?;
    Ok(file)
}

/// Create an owner-only state file without following a pre-positioned final
/// symlink. Callers can distinguish an existing incident archive through the
/// `AlreadyExists` error, so this deliberately does not open existing files.
#[cfg(unix)]
pub(crate) fn private_state_create_new(path: &Path) -> Result<std::fs::File> {
    refuse_lost_home(path)?;

    let file = crate::home_fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .with_context(|| format!("create private state file {}", path.display()))?;
    validate_private_state_file(&file, path)?;
    Ok(file)
}

/// Open or create an owner-only regular state file for append without
/// following a pre-positioned final symlink (daemon.log).
#[cfg(unix)]
pub(crate) fn private_state_append(path: &Path) -> Result<std::fs::File> {
    refuse_lost_home(path)?;

    let file = crate::home_fs::OpenOptions::new()
        .append(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .with_context(|| format!("open private state file {}", path.display()))?;
    validate_private_state_file(&file, path)?;
    Ok(file)
}

/// macOS numeric chmod leaves extended ACL entries intact. Refuse them before
/// trusting old state; accepting and merely deleting one would authenticate
/// bytes another account may already have changed.
#[cfg(target_os = "macos")]
fn refuse_extended_acl(file: &std::fs::File, path: &Path) -> Result<()> {
    use std::os::fd::AsRawFd;

    type Acl = *mut core::ffi::c_void;
    const ACL_TYPE_EXTENDED: libc::c_int = 0x0000_0100;
    unsafe extern "C" {
        fn acl_get_fd_np(fd: libc::c_int, acl_type: libc::c_int) -> Acl;
        fn acl_free(object: *mut core::ffi::c_void) -> libc::c_int;
    }

    // SAFETY: the descriptor is live; the returned ACL is released below.
    let acl = unsafe { acl_get_fd_np(file.as_raw_fd(), ACL_TYPE_EXTENDED) };
    if acl.is_null() {
        let error = std::io::Error::last_os_error();
        // macOS reports ENOENT when the object has no extended ACL.
        return if error.raw_os_error() == Some(libc::ENOENT) { Ok(()) } else { Err(error.into()) };
    }
    // SAFETY: `acl` came from acl_get_fd_np and is released exactly once.
    unsafe { acl_free(acl) };
    anyhow::bail!("{} has an extended ACL", path.display())
}

#[cfg(target_os = "macos")]
fn refuse_writable_extended_acl(file: &std::fs::File, path: &Path) -> Result<()> {
    use std::ffi::CStr;
    use std::os::fd::AsRawFd;

    type Acl = *mut core::ffi::c_void;
    const ACL_TYPE_EXTENDED: libc::c_int = 0x0000_0100;
    unsafe extern "C" {
        fn acl_get_fd_np(fd: libc::c_int, acl_type: libc::c_int) -> Acl;
        fn acl_to_text(acl: Acl, len: *mut libc::ssize_t) -> *mut libc::c_char;
        fn acl_free(object: *mut core::ffi::c_void) -> libc::c_int;
    }

    let acl = unsafe { acl_get_fd_np(file.as_raw_fd(), ACL_TYPE_EXTENDED) };
    if acl.is_null() {
        let error = std::io::Error::last_os_error();
        return if error.raw_os_error() == Some(libc::ENOENT) { Ok(()) } else { Err(error.into()) };
    }
    let mut len = 0;
    let text = unsafe { acl_to_text(acl, &mut len) };
    if text.is_null() {
        unsafe { acl_free(acl) };
        return Err(std::io::Error::last_os_error().into());
    }
    let rendered = unsafe { CStr::from_ptr(text) }.to_string_lossy().to_ascii_lowercase();
    unsafe {
        acl_free(text.cast());
        acl_free(acl);
    }
    let token = |line: &str, wanted: &str| {
        line.split(|c: char| c == ':' || c == ',' || c.is_ascii_whitespace())
            .any(|part| part == wanted)
    };
    let change = [
        "write",
        "append",
        "add_file",
        "add_subdirectory",
        "delete",
        "delete_child",
        "writeattr",
        "writeextattr",
        "writesecurity",
        "chown",
    ];
    let writable = rendered
        .lines()
        .any(|line| token(line, "allow") && change.iter().any(|right| token(line, right)));
    anyhow::ensure!(!writable, "{} has a writable extended ACL", path.display());
    Ok(())
}

#[cfg(all(unix, not(target_os = "macos")))]
fn refuse_writable_extended_acl(_file: &std::fs::File, _path: &Path) -> Result<()> {
    Ok(())
}

#[cfg(all(unix, not(target_os = "macos")))]
fn refuse_extended_acl(_file: &std::fs::File, _path: &Path) -> Result<()> {
    Ok(())
}

/// Windows: owner-only DACL on the directory and children, including a
/// directory an older build made with inherited wider permissions.
#[cfg(windows)]
pub(crate) fn private_state_dir(dir: &Path) -> Result<()> {
    crate::owner_only::private_dir(dir)?;
    Ok(())
}

#[cfg(windows)]
pub(crate) fn private_state_file(path: &Path) -> Result<std::fs::File> {
    Ok(crate::owner_only::open_read(path)?)
}

#[cfg(windows)]
pub(crate) fn private_state_rw(path: &Path) -> Result<std::fs::File> {
    Ok(crate::owner_only::open_rw(path)?)
}

#[cfg(windows)]
pub(crate) fn private_state_create_new(path: &Path) -> Result<std::fs::File> {
    Ok(crate::owner_only::create_new(path)?)
}

#[cfg(windows)]
pub(crate) fn private_state_append(path: &Path) -> Result<std::fs::File> {
    Ok(crate::owner_only::open_append(path)?)
}

/// Unix socket path, by the rule every host and client shares
/// (cmux-agent-pane-policy `environment::socket_path`): `ACPMUX_SOCKET`, else
/// `<home>/acpmux.sock`. A long home, or an absolute `ACPMUX_SOCKET` past the
/// Unix socket limit (a long TMPDIR), falls back to a short path in a private
/// per-user directory under /tmp, derived from the home or the configured
/// path so daemon and clients agree.
#[cfg(unix)]
pub fn socket_path() -> PathBuf {
    let configured = std::env::var("ACPMUX_SOCKET").ok().filter(|v| !v.is_empty());
    socket_path_for(&home(), configured.as_deref())
}

/// Resolve a daemon socket using the same short-path rules as [`socket_path`],
/// for a home and optional configured path supplied by a managed unit.
#[cfg(unix)]
pub(crate) fn socket_path_for(home: &Path, configured: Option<&str>) -> PathBuf {
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    let cwd = std::env::current_dir().ok();
    let (configured, home) = socket_inputs(configured, home, cwd.as_deref());
    let resolved = PathBuf::from(cmux_agent_pane_policy::environment::socket_path(
        configured.as_deref(),
        &home,
        uid,
    ));
    // Another user owns or can write the shared directory: never trust a
    // socket there. The long path fails to bind with a clear error instead.
    let dir = PathBuf::from(format!("/tmp/acpmux-{uid}"));
    if resolved.parent() == Some(dir.as_path()) && !private_dir(&dir, uid) {
        return absolute(configured.map(PathBuf::from).unwrap_or_else(|| home.join("acpmux.sock")));
    }
    absolute(resolved)
}

/// The configured socket and the home [`socket_path`] derives the socket from.
#[cfg(unix)]
fn socket_inputs(
    configured: Option<&str>,
    home: &Path,
    cwd: Option<&Path>,
) -> (Option<String>, PathBuf) {
    // Both absolute before the short alias is derived from them: a started daemon gets them
    // absolute (`daemon/login_placement.rs` `daemon_env`) and must derive the same one.
    let absolute = |p: &Path| match cwd {
        Some(cwd) if p.is_relative() => cwd.join(p),
        _ => p.to_path_buf(),
    };
    let configured = configured.map(|c| absolute(Path::new(c)).to_string_lossy().into_owned());
    (configured, absolute(home))
}

#[cfg(all(test, unix))]
mod autostart_pair_tests {
    use super::*;

    /// A removed test home is never made again for a daemon; the default home still is.
    #[test]
    fn only_the_default_home_is_created_for_a_start() {
        let dir = tempfile::tempdir().unwrap();
        let gone = dir.path().join("removed-test-home");
        let own = gone.join("acpmux.sock");
        let why = autostart_refusal(&gone, true, None, &own).expect("a missing home is refused");
        assert!(why.contains("does not exist"), "{why}");
        assert!(!gone.exists());
        let default = default_home();
        let own = default.join("acpmux.sock");
        assert_eq!(autostart_refusal(&default, false, None, &own), None);
        assert_eq!(autostart_refusal(dir.path(), true, None, &dir.path().join("s.sock")), None);
    }

    /// `ACPMUX_SOCKET` pairs only with an explicit `ACPMUX_HOME` (or is the home's own): the
    /// Chief's socket with no home must not start a daemon under `~/.acpmux`'s lock.
    #[test]
    fn a_socket_pairs_only_with_an_explicit_home_or_its_own() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path();
        let own = home.join("acpmux.sock");
        // Another home's socket, as the Chief's would be.
        let elsewhere = tempfile::tempdir().unwrap();
        let chief_socket = elsewhere.path().join("acpmux.sock");
        let chief = chief_socket.as_path();
        let why = autostart_refusal(home, false, Some(chief), &own).expect("unpaired");
        assert!(why.contains(&chief.display().to_string()), "{why}");
        assert!(why.contains(&own.display().to_string()), "{why}");
        assert_eq!(autostart_refusal(home, true, Some(chief), &own), None);
        assert_eq!(autostart_refusal(home, false, Some(&own), &own), None);
        assert_eq!(autostart_refusal(home, false, None, &own), None);
    }
}

#[cfg(all(test, unix))]
mod socket_input_tests {
    use super::*;

    /// A daemon a command starts is handed its home and socket absolute
    /// (`daemon/login_placement.rs` `daemon_env`): from relative ones, the command must derive
    /// the same socket, short alias included, or it waits on one the daemon never binds.
    #[test]
    fn a_long_relative_home_or_socket_uses_the_same_socket_alias() {
        let cwd = Path::new("/work/a-folder-long-enough-that-its-socket-needs-a-short-alias");
        let long = "x".repeat(80);
        let alias = |configured: Option<&str>, home: &Path, cwd: &Path| {
            let (configured, home) = socket_inputs(configured, home, Some(cwd));
            cmux_agent_pane_policy::environment::socket_path(configured.as_deref(), &home, 501)
        };
        let elsewhere = Path::new("/elsewhere");
        assert_eq!(alias(None, Path::new(&long), cwd), alias(None, &cwd.join(&long), elsewhere));
        let sock = format!("{long}/a.sock");
        let abs_sock = cwd.join(&sock).to_string_lossy().into_owned();
        assert_eq!(
            alias(Some(&sock), Path::new("/h"), cwd),
            alias(Some(&abs_sock), Path::new("/h"), elsewhere)
        );
    }
}

/// A relative `ACPMUX_SOCKET` against this process's folder: the daemon
/// hands the path to harnesses that run in a project folder
/// (`hub/person.rs` `caller_env`), where a relative one names another file.
fn absolute(path: PathBuf) -> PathBuf {
    if path.is_relative() {
        std::env::current_dir().map(|d| d.join(&path)).unwrap_or(path)
    } else {
        path
    }
}

/// Windows: `ACPMUX_SOCKET`, else `<home>\\acpmux.sock`; a long home (AF_UNIX
/// paths are limited to 108 bytes there too) falls back to a short path in an
/// owner-only folder in this user's temp folder, derived from the home path
/// so daemon and clients agree.
#[cfg(windows)]
pub fn socket_path() -> PathBuf {
    if let Some(v) = std::env::var("ACPMUX_SOCKET").ok().filter(|v| !v.is_empty()) {
        return absolute(PathBuf::from(v));
    }
    let preferred = home().join("acpmux.sock");
    if preferred.as_os_str().len() < 96 {
        return preferred;
    }
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for b in home().to_string_lossy().bytes() {
        hash ^= b as u64;
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    let dir = std::env::temp_dir().join("acpmux");
    let path = dir.join(format!("{hash:016x}.sock"));
    if path.as_os_str().len() < 96 && cmux::local_socket::private_directory(&dir).is_ok() {
        return path;
    }
    preferred
}

/// Create `dir` mode 0700 if missing; true only when it is a real directory
/// owned by `uid` that nobody else can enter.
#[cfg(unix)]
fn private_dir(dir: &Path, uid: u32) -> bool {
    // SAFETY: getuid has no preconditions.
    uid == unsafe { libc::getuid() } && private_state_dir(dir).is_ok()
}

/// How acpmux talks to the agent process.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "kebab-case")]
pub enum HarnessKind {
    /// Agent Client Protocol over stdio (default).
    #[default]
    Acp,
    /// Claude Code's own `-p --input-format stream-json` protocol.
    ClaudeStdio,
    /// A CLI or TUI without ACP (`protocol = "terminal"` in a profile file): listed, but run in a
    /// terminal tab (`cmux harness run`), never as an acpmux session.
    Terminal,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct HarnessProfile {
    #[serde(default, skip_serializing_if = "is_default_kind")]
    pub kind: HarnessKind,
    pub argv: Vec<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub env: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// Profile to move a session onto when this one's account reports a
    /// usage or rate limit mid-turn. Discovery sets `claude-cr` for
    /// `claude` only when a CodeRouter route is configured
    /// (`coderouterClaudeRoute`); never the subrouter pool.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fallback: Option<String>,
    /// Model family this profile belongs to (`claude`, `codex`, `opencode`,
    /// `pi`, `gemini`). Derived from the kind and argv when absent. Family
    /// names are what `defaults` and `-u FAMILY` resolve against.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub family: Option<String>,
    /// Models this harness can run, declared here when the harness reports
    /// none over ACP (or reports too many): shown in pickers and `daemon
    /// models` ahead of the reported catalog. A string or `{id, name}`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub models: Vec<DeclaredModel>,
    /// Defaults for this profile, the same as a `defaults` entry named
    /// after it; kept inline so one block describes a harness completely.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub policy: Option<PermissionPolicy>,
}

/// A model in a profile's `models` list: `"id"` or `{"id": …, "name": …}`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(untagged)]
pub enum DeclaredModel {
    Id(String),
    Full {
        id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        name: Option<String>,
    },
}

impl DeclaredModel {
    pub fn id(&self) -> &str {
        match self {
            DeclaredModel::Id(s) => s,
            DeclaredModel::Full { id, .. } => id,
        }
    }
    pub fn name(&self) -> &str {
        match self {
            DeclaredModel::Id(s) => s,
            DeclaredModel::Full { id, name } => name.as_deref().unwrap_or(id),
        }
    }
}

impl HarnessProfile {
    /// The hex SHA-256 of what starts the harness: its argv and env, never its name, models,
    /// defaults or kind (how acpmux speaks to it, which an adopted agent's host answers for
    /// itself). A session keeps the digest its agent started from (`SessionMeta::launch_digest`),
    /// and a profile reload that changes it respawns the agent at its turn end
    /// (`hub/profile_respawn.rs`). A hash, so the env's values are not kept.
    pub fn launch_digest(&self) -> String {
        // A list and a BTreeMap of strings: the JSON is stable.
        let launch = serde_json::json!({"argv": self.argv, "env": self.env});
        crate::sha256::sha256_hex(launch.to_string().as_bytes())
    }
}

/// Session defaults for a family or a single profile (`defaults` in
/// config.json). Precedence at `session/new`: explicit request, then the
/// profile's own entry, then its family's entry, then the daemon defaults.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct SessionDefaults {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub policy: Option<PermissionPolicy>,
    /// Profiles to use, in order, when a session asks for this family:
    /// `["claude-cr", "claude"]` sends `-m claude` to the CodeRouter route
    /// first. Absent: the family's only profile, else the profile named
    /// like the family, else the request is refused.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub prefer: Vec<String>,
    /// Extra environment for every process in the family (an API base URL,
    /// a router key variable). The profile's own `env` wins on conflicts.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub env: BTreeMap<String, String>,
    /// `permissionMode`: the permission mode a new chat of this family or
    /// profile starts in, over the daemon-wide `defaultPermissionMode`
    /// (`hub/start_mode.rs`): `fullAccess` (alias `yolo`), `standard` or `ask`.
    #[serde(default, alias = "permission_mode", skip_serializing_if = "Option::is_none")]
    pub permission_mode: Option<String>,
}

impl SessionDefaults {
    pub fn overlay(&mut self, top: &SessionDefaults) {
        if top.model.is_some() {
            self.model = top.model.clone();
        }
        if top.effort.is_some() {
            self.effort = top.effort.clone();
        }
        if top.policy.is_some() {
            self.policy = top.policy;
        }
        if !top.prefer.is_empty() {
            self.prefer = top.prefer.clone();
        }
        for (k, v) in &top.env {
            self.env.insert(k.clone(), v.clone());
        }
        if top.permission_mode.is_some() {
            self.permission_mode = top.permission_mode.clone();
        }
    }
    pub fn is_empty(&self) -> bool {
        *self == SessionDefaults::default()
    }
}

/// The family a profile belongs to: its explicit `family`, else derived
/// from the harness kind and the argv basenames, else the first word of
/// the profile name (`claude-sr` → `claude`, `fake-pool` → `fake`).
pub fn derive_family(name: &str, profile: &HarnessProfile) -> String {
    if let Some(f) = &profile.family {
        return f.clone();
    }
    if profile.kind == HarnessKind::ClaudeStdio {
        return "claude".into();
    }
    let words: Vec<String> = profile
        .argv
        .iter()
        .map(|a| {
            Path::new(a).file_name().map(|f| f.to_string_lossy().to_lowercase()).unwrap_or_default()
        })
        .collect();
    // A fork is its own family (omp, prime): `-m pi` never lands on one.
    for (needle, family) in [
        ("codex", "codex"),
        ("opencode", "opencode"),
        ("gemini", "gemini"),
        ("pi-acp", "pi"),
        ("omp", "omp"),
        ("prime-agent", "prime"),
        ("claude", "claude"),
    ] {
        if words.iter().any(|w| w.contains(needle)) {
            return family.into();
        }
    }
    name.split(['-', '_', '.']).next().unwrap_or(name).to_lowercase()
}

/// The harness store a profile's conversations live in, which adopt reads (`adopt::find`):
/// its family when that names one, else `claude` for any Claude Code profile (`claude-sr2`,
/// a router's), whatever family it declares. All of those run Claude Code on one store layout.
pub fn store_family(name: &str, profile: &HarnessProfile) -> String {
    let family = derive_family(name, profile);
    if !matches!(family.as_str(), "claude" | "codex" | "opencode")
        && profile.kind == HarnessKind::ClaudeStdio
    {
        return "claude".into();
    }
    family
}

/// Which agent store a fork through an earlier turn copies (`hub/fork_at.rs`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TurnCut {
    /// Claude Code's transcript (`claude -p`, Claude Code's own protocol).
    Claude,
    /// Codex's rollout (codex-acp, which forks a thread only at its end).
    Codex,
}

/// How profile `name` forks through an earlier turn; None when its agent
/// forks only at a chat's end.
pub fn turn_cut(name: &str, profile: &HarnessProfile) -> Option<TurnCut> {
    match profile.kind {
        HarnessKind::ClaudeStdio => Some(TurnCut::Claude),
        HarnessKind::Acp if derive_family(name, profile) == "codex" => Some(TurnCut::Codex),
        _ => None,
    }
}

/// Permission policy applied when no attached client answers. Read from config.json through
/// `FromStr`: a value this build does not know (one a newer build added and saved, read after a
/// rollback) reads as `ask` rather than failing the whole config, which stopped the daemon.
#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq, Default)]
#[serde(rename_all = "kebab-case")]
pub enum PermissionPolicy {
    /// Ask attached clients; wait without limit when none is attached.
    #[default]
    Ask,
    ApproveAll,
    ApproveReads,
    /// Reads plus edits auto-approved; shell, delete and move still ask.
    /// Claude Code's "accept edits" without needing Claude's own mode.
    ApproveEdits,
    DenyAll,
    /// A reviewer's read-only shell: what approve-reads approves runs unasked (reads, searches
    /// and read-only shell commands such as `git log`, `git diff`, `grep`, `rg`, `ls`, `cat`,
    /// `sed -n`, `hub/shell_readonly.rs`), and every other tool call is denied at once, so a
    /// session with no person to ask never waits.
    Review,
}

impl std::str::FromStr for PermissionPolicy {
    type Err = String;
    fn from_str(s: &str) -> std::result::Result<Self, Self::Err> {
        match s {
            "ask" => Ok(Self::Ask),
            "approve-all" | "yolo" => Ok(Self::ApproveAll),
            "approve-reads" => Ok(Self::ApproveReads),
            "approve-edits" | "accept-edits" => Ok(Self::ApproveEdits),
            "deny-all" => Ok(Self::DenyAll),
            "review" => Ok(Self::Review),
            other => Err(format!("unknown permission policy: {other}")),
        }
    }
}

impl<'de> Deserialize<'de> for PermissionPolicy {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> std::result::Result<Self, D::Error> {
        let text = String::deserialize(d)?;
        Ok(text.parse().unwrap_or_else(|_| {
            tracing::warn!("permission policy {text:?} is not one this build knows; using ask");
            Self::Ask
        }))
    }
}

impl std::fmt::Display for PermissionPolicy {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let s = match self {
            Self::Ask => "ask",
            Self::ApproveAll => "approve-all",
            Self::ApproveReads => "approve-reads",
            Self::ApproveEdits => "approve-edits",
            Self::DenyAll => "deny-all",
            Self::Review => "review",
        };
        f.write_str(s)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct WebSocketConfig {
    pub listen: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token: Option<String>,
    /// Browser origins allowed besides the listener's own and the agent
    /// pane's (for example a page dev server). `null` is never allowed.
    #[serde(default, alias = "allowed_origins", skip_serializing_if = "Vec::is_empty")]
    pub allowed_origins: Vec<String>,
    /// `Host` names allowed besides loopback (a proxy that keeps a public
    /// name, or the name peers dial on a non-loopback `listen`, where every
    /// other name is refused). Both lists apply from the next connection after
    /// `_acpmux/reload_config` (`acpmux config --set` and `acpmux web --tailnet` send it).
    #[serde(default, alias = "allowed_hosts", skip_serializing_if = "Vec::is_empty")]
    pub allowed_hosts: Vec<String>,
    /// `tokenRotated`: the saved token was replaced at the first start of a
    /// build that never sends it to a remote-origin connection (earlier
    /// builds did, in `_acpmux/status`). Set, it never rotates again.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub token_rotated: u32,
    /// `allowInsecureNetwork`: bind a network (non-loopback) `listen`
    /// address. The listener speaks plain ws://, so the token crosses that
    /// network in clear; without it such an address stops the daemon
    /// (`server/ws_auth.rs`). `--insecure-network-listen` is the same for
    /// one run.
    #[serde(default, alias = "allow_insecure_network", skip_serializing_if = "is_false")]
    pub allow_insecure_network: bool,
}

fn is_zero(n: &u32) -> bool {
    *n == 0
}

fn is_false(b: &bool) -> bool {
    !*b
}

fn default_palette_prefix() -> String {
    "/".into()
}
fn default_skill_prefix() -> String {
    "$".into()
}
fn default_leader() -> String {
    "ctrl+x".into()
}
fn default_leader_timeout_ms() -> u64 {
    2000
}

/// TUI interaction settings. These deliberately live in acpmux's config so
/// the same preferences apply to the native TUI and future clients.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct TuiConfig {
    /// Prefix that opens the command palette/command line (`/` by default).
    #[serde(default = "default_palette_prefix")]
    pub palette_prefix: String,
    /// Additional accepted command prefixes, for example `[":"]`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub palette_aliases: Vec<String>,
    /// Prefix for inline skills (`$` by default).
    #[serde(default = "default_skill_prefix")]
    pub skill_prefix: String,
    /// Sequential leader key, such as `ctrl+x`, `ctrl+space`, or `none`.
    #[serde(default = "default_leader")]
    pub leader: String,
    #[serde(default = "default_leader_timeout_ms")]
    pub leader_timeout_ms: u64,
    /// App action -> key or key sequence; arrays and comma-separated alternatives are accepted.
    #[serde(default)]
    pub keybinds: BTreeMap<String, serde_json::Value>,
    /// Extra skill roots, relative to the selected project or absolute.
    #[serde(default)]
    pub skill_paths: Vec<String>,
}

impl Default for TuiConfig {
    fn default() -> Self {
        Self {
            palette_prefix: default_palette_prefix(),
            palette_aliases: vec![],
            skill_prefix: default_skill_prefix(),
            leader: default_leader(),
            leader_timeout_ms: default_leader_timeout_ms(),
            keybinds: BTreeMap::new(),
            skill_paths: vec![],
        }
    }
}

/// `artifacts` in the config: the agent artifact tools (`acpmux_mcp_artifacts.rs`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct ArtifactsConfig {
    /// `enabled`: `false` keeps the artifact tools from every agent. Unset or `true`: they are
    /// offered whenever this daemon has a cmux sign-in (`meshRelay.tokenCommand`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enabled: Option<bool>,
    /// `baseUrl`: the cmux-platform origin to use. Taken only when it is a platform Worker
    /// (https `*.debussy.workers.dev`) or loopback http, so the sign-in goes nowhere else.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_url: Option<String>,
}

impl ArtifactsConfig {
    pub fn is_default(&self) -> bool {
        self == &Self::default()
    }
}

/// `titles` in the config: how a chat its harness never titles gets one.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct TitlesConfig {
    /// `generate`: title such a chat after its first user message. Default on; a thin first
    /// message may get one refresh after its first turn.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub generate: Option<bool>,
    /// `command`: an argv that reads the request on stdin and prints the
    /// title. Env `ACPMUX_TITLE_COMMAND` (one program) wins. Unset: the
    /// chat's own Claude Code profile, with `model`; another harness's chat
    /// then keeps its first-prompt title.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<Vec<String>>,
    /// `model`: the Claude model of the default command. Default `haiku`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
}

/// Host-wide limits applied to every Linux session scope, and the CPU class
/// of every macOS session's harness. These are daemon settings, rather than
/// spawn environment, so a CLI can set them without crossing the app-only
/// spawn-env gate.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct SessionResourceConfig {
    /// Per-session memory ceiling in MiB. Unset uses half of host memory.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub memory_mb: Option<u64>,
    /// Per-session swap ceiling in MiB. Unset uses one quarter of host swap.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub swap_mb: Option<u64>,
    /// `tasksMax`: each session scope's cap on processes and threads
    /// together; 0 is no cap. Wins over `ACPMUX_SESSION_TASKS_MAX`. Unset:
    /// that env, else 4096.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tasks_max: Option<u64>,
    /// `sessionsTasksMax`: the cap on processes and threads of all sessions
    /// together (`acpmuxsessions.slice`); 0 is no cap. Wins over
    /// `ACPMUX_SESSIONS_TASKS_MAX`. Unset: that env, else a quarter of the
    /// kernel's `threads-max`, between 16384 and 262144.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sessions_tasks_max: Option<u64>,
    /// `lanes`: the host's lane cap each session's default memory ceiling is sized from
    /// (RAM / lanes x 2, `session_budget.rs`). Unset: `ACPMUX_HOST_LANES`, else this host's
    /// fleet-registry.json `lanes.max_lanes`, else none (half the RAM). 0 is unset.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lanes: Option<u64>,
    /// `diskMb`: each session's disk budget in MiB, which the daemon's watcher measures
    /// (`hub/session_budget_watch.rs`); 0 is off. Unset: `ACPMUX_SESSION_DISK_MB`, else the
    /// registry's `lanes.disk_per_lane_gb`, else a tenth of the home filesystem (2 to 64 GiB).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub disk_mb: Option<u64>,
    /// `cpuClass`: the CPU class a macOS session's harness runs at once its
    /// start is over (it starts at normal), `dynamic`, `background` or `normal` (`cpu_class.rs`). Env `ACPMUX_SESSION_CPU_CLASS`
    /// overrides it, a profile's env overrides both. Unset: `normal`, a terminal shell's
    /// priority and disk tier (`cpu_class::default_for`). `dynamic` is opt-in and yields only
    /// during measured contention.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cpu_class: Option<crate::cpu_class::CpuClass>,
}

impl SessionResourceConfig {
    pub fn is_default(&self) -> bool {
        self == &Self::default()
    }
}

/// Experimental transports. Labs switches are deliberately opt-in and keep
/// the normal peer route unchanged until a caller explicitly enables them.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TransportConfig {
    /// Enable the userspace WireGuard transport. Disabled by default: when
    /// false no UDP socket is bound by acpmux.
    #[serde(default)]
    pub wireguard: bool,
    /// Static Labs mesh interface; ignored while wireguard is disabled.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wireguard_static: Option<crate::wireguard::StaticConfig>,
}

impl TitlesConfig {
    pub fn is_default(&self) -> bool {
        self == &Self::default()
    }
}

/// Opt-in synchronization of local agent memories and artifacts with cmux-platform.
/// The feature is disabled unless `enabled` is explicitly set to true.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ArtifactsSyncConfig {
    #[serde(default)]
    pub enabled: bool,
    /// cmux-platform origin. Defaults to the development Worker.
    #[serde(default = "default_artifacts_base_url")]
    pub base_url: String,
    /// Poll period for callers that run the sync loop. A loop must still have
    /// an explicit stop condition; this value only controls its cadence.
    #[serde(default = "default_artifacts_poll_interval_ms")]
    pub poll_interval_ms: u64,
}

fn default_artifacts_base_url() -> String {
    "https://cmux-platform-development.debussy.workers.dev".into()
}

fn default_artifacts_poll_interval_ms() -> u64 {
    30_000
}

impl Default for ArtifactsSyncConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            base_url: default_artifacts_base_url(),
            poll_interval_ms: default_artifacts_poll_interval_ms(),
        }
    }
}

impl ArtifactsSyncConfig {
    pub fn is_default(&self) -> bool {
        self == &Self::default()
    }
}

/// The fleet memory mount (`memory_mount.rs`): `~/.cmux/memory/{private,team}` kept in sync with
/// the memory store on cmux-platform. On by default on a machine joined to cmux Cloud ("autocloud
/// default on"); `"memory": {"sync": false}` turns it off.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct MemorySyncConfig {
    /// Unset: on. `false`: the daemon never syncs (`acpmux memory sync` still does, by hand).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sync: Option<bool>,
    /// The mount's root, `~/.cmux/memory` when unset.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dir: Option<PathBuf>,
}

impl MemorySyncConfig {
    pub fn is_default(&self) -> bool {
        self == &Self::default()
    }
}

/// Persisted cmux-added prompt overrides. The `user` value applies to every new
/// session on this daemon; project entries are keyed by a canonical working directory.
/// Harness-owned prompts never live here: this store contains only text the user explicitly
/// added through the Context viewer.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct ContextOverrides {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user: Option<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub projects: BTreeMap<String, String>,
    /// Overrides of a verified preset prompt, kept separate for each preset name.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub preset_prompts: BTreeMap<String, ContextPromptOverrides>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct ContextPromptOverrides {
    pub user: Option<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub projects: BTreeMap<String, String>,
}

impl ContextPromptOverrides {
    pub fn for_project(&self, cwd: &Path) -> Option<&str> {
        self.projects
            .get(&ContextOverrides::project_key(cwd))
            .map(String::as_str)
            .or(self.user.as_deref())
    }
}

impl ContextOverrides {
    pub fn is_empty(&self) -> bool {
        self.user.is_none() && self.projects.is_empty() && self.preset_prompts.is_empty()
    }

    pub fn project_key(cwd: &Path) -> String {
        std::fs::canonicalize(cwd).unwrap_or_else(|_| cwd.to_owned()).to_string_lossy().into_owned()
    }

    pub fn for_project(&self, cwd: &Path) -> Option<(&str, &str)> {
        let key = Self::project_key(cwd);
        self.projects
            .get(&key)
            .map(|text| ("project", text.as_str()))
            .or_else(|| self.user.as_deref().map(|text| ("user", text)))
    }

    pub fn set(
        &mut self,
        scope: &str,
        cwd: Option<&Path>,
        text: Option<String>,
    ) -> Result<(), String> {
        match scope {
            "user" => self.user = text,
            "project" => {
                let cwd = cwd.ok_or("cwd is required for a project override")?;
                let key = Self::project_key(cwd);
                if let Some(text) = text {
                    self.projects.insert(key, text);
                } else {
                    self.projects.remove(&key);
                }
            }
            _ => return Err("scope must be user or project".into()),
        }
        Ok(())
    }

    pub fn set_preset(
        &mut self,
        preset: &str,
        scope: &str,
        cwd: Option<&Path>,
        text: Option<String>,
    ) -> Result<(), String> {
        if scope != "user" && scope != "project" {
            return Err("scope must be user or project".into());
        }
        if scope == "project" && cwd.is_none() {
            return Err("cwd is required for a project override".into());
        }
        let values = self.preset_prompts.entry(preset.into()).or_default();
        match scope {
            "user" => values.user = text,
            "project" => {
                let key = Self::project_key(cwd.ok_or("cwd is required for a project override")?);
                if let Some(text) = text {
                    values.projects.insert(key, text);
                } else {
                    values.projects.remove(&key);
                }
            }
            _ => return Err("scope must be user or project".into()),
        }
        if values.user.is_none() && values.projects.is_empty() {
            self.preset_prompts.remove(preset);
        }
        Ok(())
    }
}

/// `personHold` (`hub/person_hold.rs`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct PersonHoldConfig {
    /// The chats, by name, whose person's prompts wait.
    #[serde(default)]
    pub sessions: Vec<String>,
    /// How long, in ms, from the first prompt's arrival. Default 30000; 0 turns it off.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ms: Option<u64>,
}

/// `pageRule` (`hub/inbox_page_rule.rs`): the coordinator list. Another agent's message to one of
/// these chats starts a turn only when it is a page (a block or question from a session, a
/// first-seen FIRE or program block, a message from or tagged for the person); the rest waits
/// for the next notice, at most `inbox.rs` `FLUSH_MS`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct PageRuleConfig {
    /// The chats, by name (`NAME`, or `HOST/NAME` as fleet-registry.json `coordinators` writes
    /// them), that only a page wakes.
    #[serde(default)]
    pub sessions: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    /// Opt-in agent service v2 surfaces (`books`, `list`, `chat`, `peers`, `start`).
    #[serde(rename = "acpmux.v2", default, skip_serializing_if = "V2Surfaces::is_empty")]
    pub acpmux_v2: V2Surfaces,
    #[serde(default)]
    #[serde(alias = "agents")]
    pub harnesses: BTreeMap<String, HarnessProfile>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub peers: BTreeMap<String, PeerConfig>,
    /// Optional platform artifact and memory synchronization.
    #[serde(default, skip_serializing_if = "ArtifactsSyncConfig::is_default")]
    pub artifacts_sync: ArtifactsSyncConfig,
    #[serde(default, skip_serializing_if = "MemorySyncConfig::is_default")]
    pub memory: MemorySyncConfig,
    /// Opt-in cmux-platform wake-on-message integration. Absent/disabled keeps
    /// the normal peer route and send behavior unchanged.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub machine_wake: Option<MachineWakeConfig>,
    /// `peerWake`: `{"argv": [...]}`, the command run once when a message for a session on a
    /// peer finds its link down (`Peer::wake`), with the peer's name appended: the machine
    /// layer's resume for whatever provider the peer's machine is on (a paused VM, a
    /// stopped VM). Unset (the default): only the route's own ProxyCommand sees the wake
    /// mark (`peer_wanted.rs` WAKE_ENV), as before.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub peer_wake: Option<PeerWake>,
    /// The read replica and write journal for paused machines (`crate::write_journal`). Off
    /// unless `writeJournal.enabled` is true; off changes nothing.
    #[serde(default, skip_serializing_if = "WriteJournalConfig::is_default")]
    pub write_journal: WriteJournalConfig,
    #[serde(default, alias = "defaultAgent")]
    pub default_harness: Option<String>,
    /// User and project cmux-added context shown in the Context viewer and captured for new sessions.
    #[serde(default, skip_serializing_if = "ContextOverrides::is_empty")]
    pub context_overrides: ContextOverrides,
    /// More login-shell variables agents get, beyond the allow-list
    /// (`login_env::allowed`): exact names or `PREFIX_*`. Default empty.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub login_env_allow: Vec<String>,
    /// Per-family (or per-profile) session defaults, keyed by family or
    /// profile name: `{"claude": {"model": "claude-opus-5", "effort": "high",
    /// "policy": "approve-edits", "prefer": ["claude-cr", "claude"]}}`.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub defaults: BTreeMap<String, SessionDefaults>,
    /// Host-wide resource limits for new Linux session scopes.
    #[serde(default, skip_serializing_if = "SessionResourceConfig::is_default")]
    pub session: SessionResourceConfig,
    /// Named bundles for `-p NAME`: `{"deepseek": {"harness": "opencode",
    /// "model": "opencode-go/deepseek-v4-pro", "effort": "low"}}`.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub presets: BTreeMap<String, Preset>,
    #[serde(default)]
    pub store: StoreConfig,
    #[serde(default)]
    pub permission_policy: PermissionPolicy,
    /// `defaultPermissionMode`: the permission mode a new chat starts in
    /// (`hub/start_mode.rs`): `fullAccess`, `standard` or `ask`. Absent: the
    /// cmux setting `agents.defaultPermissionMode`, else `fullAccess`. For
    /// acpmux without the cmux app, and for hermetic tests. A
    /// `lastPermissionMode` an older build wrote beside it is ignored and
    /// dropped at the next save.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_permission_mode: Option<String>,
    /// `holdAgentStartsToStarter`: a chat an agent starts from its shell (`acpmux new|run`,
    /// `cmux agents chat new`, a local `_acpmux/dispatch`) naming no mode or policy takes its
    /// starter's limits (`hub/start_mode.rs`, "Inherit"). Off (the default, user 2026-11-03):
    /// it starts at the person's configured start level and default policy, as a start with no
    /// starter does; a starter in full access still passes it on, and a sub-session is always
    /// held to its parent.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub hold_agent_starts_to_starter: bool,
    /// `composerMaxRows`: most rows the TUI composer grows to before it
    /// scrolls. Env `ACPMUX_COMPOSER_ROWS` overrides. Default 12.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub composer_max_rows: Option<u16>,
    /// `notifyCommand`: shell command the daemon runs when a session needs a
    /// permission or ends a turn while nobody is attached. Gets ACPMUX_EVENT,
    /// ACPMUX_SESSION_ID, ACPMUX_SESSION_NAME and ACPMUX_TEXT in its env.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notify_command: Option<String>,
    /// `uploadsMaxAgeDays`: files dropped into a chat (`_acpmux/file_put`) are deleted once
    /// older than this many days (`hub/file_uploads.rs`). Default 30; 0 keeps them.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub uploads_max_age_days: Option<u64>,
    /// `agentStartTimeoutMs`: the longest one agent start (spawn or adopt,
    /// `initialize`, session load or new, config replay) may take. Past it
    /// the request fails with a `deadline_exceeded` error and the agent is
    /// ended. Default 90000.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_start_timeout_ms: Option<u64>,
    /// Free bytes on acpmux's disk under which `daemon status` says `disk.low`
    /// (`recovery.rs`; 1 GiB when unset).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub disk_low_bytes: Option<u64>,
    /// `agentInbox` (default true): another agent's plain send goes into the chat's inbox, never
    /// a turn or a steer of its own (`hub/inbox.rs`). false puts it back on the queue as before:
    /// a switch to roll the inbox back without a new build.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_inbox: Option<bool>,
    /// `personHold`: the chats whose person's prompts wait a while to go in together, unless the
    /// small model reads one as urgent (`hub/person_hold.rs`). Unset: none wait.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub person_hold: Option<PersonHoldConfig>,
    /// `pageRule`: the coordinator chats only a page wakes (`hub/inbox_page_rule.rs`). Unset:
    /// none, every chat wakes as before.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub page_rule: Option<PageRuleConfig>,
    /// `mcpStore`: the machine's one store of MCP connections, shared with every Chief
    /// (cmux-mcp-connect `shared`). Unset: `$CMUX_MCP_HOME`, else `$ACPMUX_HOME/mcp`.
    #[serde(rename = "mcpStore", default, skip_serializing_if = "Option::is_none")]
    pub mcp_store: Option<std::path::PathBuf>,
    /// `silentTurnMs`: how long a turn may go with no sign of its model at work
    /// (no message, thought, tool call, plan, request or model harness line;
    /// the agent's own bookkeeping does not count) before the chat logs
    /// `turn_silent`, so a client can say the model has not answered
    /// (`hub/silent_turn.rs`).
    /// Default 90000; 0 turns it off.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub silent_turn_ms: Option<u64>,
    /// `stalledTurnMs`: how long a running turn may go with no tool call in
    /// flight and no sign of its model at work before its lane says it has
    /// stalled (`lane.stalledSince`, `hub/views.rs`). A long build in one tool
    /// call never stalls. Default 600000; 0 turns it off.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stalled_turn_ms: Option<u64>,
    /// `stalledTurnEndMs`: how long a running turn may go with no sign of its model at work (as
    /// `silentTurnMs` counts them, also across a daemon restart) before acpmux ends it as failed,
    /// `detail` `stalled` (`hub/stalled_turn.rs`); four times that inside a tool call that has
    /// not ended. Only a turn nobody holds: no client attached,
    /// no permission waiting, and its recorded owner (a sub-session's parent, a `spawnedBy` tag)
    /// gone or not busy. Default 21600000 (6 h); 0 turns it off.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stalled_turn_end_ms: Option<u64>,
    /// `queueMaxPrompts`: the most prompts one chat holds waiting for their turn (`hub/queue.rs`).
    /// One more is refused with `queue.full` before anything is copied or written, so a client
    /// that sends faster than the agent runs cannot grow the queue, its log and every later
    /// restore without bound (manaflow-ai/cmuxterm-hq#2930). Default 1000; 0 is no limit.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub queue_max_prompts: Option<u64>,
    /// `queueMaxBytes`: the most bytes of prompt content one chat's waiting prompts hold
    /// (`hub/queue.rs`); a prompt that would pass it is refused with `queue.bytes`. An uploaded
    /// image small enough to go inline for the model counts with its bytes; any other uploaded
    /// file goes by its path and counts only that (`prompt_uploads.rs`). Default 268435456
    /// (256 MiB); 0 is no limit.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub queue_max_bytes: Option<u64>,
    /// `autoResumeDelaysMs`: the wait before each automatic continuation of a turn a
    /// connection or capacity error cut off (`hub/auto_resume.rs`), one entry per attempt, so its
    /// length is how many attempts run, a chain of daemon restarts included. Default
    /// twelve exponential waits from 10 s capped at 20 min (about two hours); `[]` turns it off.
    /// A provider reset hint extends the wait when needed. Checked on load: at most 12
    /// entries of 1 s to 1 h; anything else falls back to the default with a warning.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "crate::hub::auto_resume::delays_from_config"
    )]
    pub auto_resume_delays_ms: Option<Vec<u64>>,
    /// `capacityFallbackAfter`: after this many capacity attempts on one cut prompt (HTTP 529,
    /// "overloaded"), the next runs on a smaller model of the same harness, and the chat's own
    /// model comes back once a turn there ends well (`hub/auto_resume/capacity_failover.rs`).
    /// 0 never switches. Unset: Settings' `agents.autoRetry.capacityFallbackAfter`, default 1.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub capacity_fallback_after: Option<u64>,
    /// `autoResumeDiskFreeBytes`: how much free space a chat a full disk cut waits for before
    /// it goes on (`hub/auto_resume/disk_wait.rs`). Default 16 MiB.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auto_resume_disk_free_bytes: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub websocket: Option<WebSocketConfig>,
    #[serde(default)]
    pub tui: TuiConfig,
    /// `webAskingModes`: more asking modes per family (`server/remote_guard.rs`).
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub web_asking_modes: BTreeMap<String, Vec<String>>,
    /// `webRoots`: folders a Web connection may use (`server/remote_guard.rs`).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub web_roots: Vec<String>,
    /// `vmHost`: `false` refuses a caller's VM boundary here, so every remote
    /// chain's Claude Code runs in the sandbox (`hub/vm_host.rs`,
    /// `hub/vm_boundary.rs`). It never turns the boundary on: the agent can
    /// write this file, so `true` means the same as absent.
    /// `_acpmux/vm_host {on: false}` writes `false`, `{on: true}` removes it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub vm_host: Option<bool>,
    /// `autoCloudEnroll`: this machine's AutoCloud enrollment as `_acpmux/autocloud_enroll` last
    /// set it (`autocloud_enroll.rs`); absent, the settings key `cloud.autoCloudEnroll` decides.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auto_cloud_enroll: Option<serde_json::Value>,
    /// `pool`: hidden pre-created sessions that make a harness switch instant (`hub/pool/`).
    #[serde(default, skip_serializing_if = "PoolConfig::is_default")]
    pub pool: PoolConfig,
    /// `btw`: side sessions (`hub/btw.rs`): the model they start on, per harness.
    #[serde(default, skip_serializing_if = "BtwConfig::is_default")]
    pub btw: BtwConfig,
    /// `titles`: short titles for chats their harness never titles (`hub/titles.rs`).
    #[serde(default, skip_serializing_if = "TitlesConfig::is_default")]
    pub titles: TitlesConfig,
    /// `usageWarnings`: when a session's usage gets a visible warning (`hub/usage_warnings.rs`).
    #[serde(default, skip_serializing_if = "UsageWarningsConfig::is_default")]
    pub usage_warnings: UsageWarningsConfig,
    /// `autoEvacuate`: idle chats leave this machine on their own while it stays over its budget
    /// (`hub/auto_evacuate.rs`). Off unless `autoEvacuate.enabled` is true.
    #[serde(default, skip_serializing_if = "AutoEvacuateConfig::is_default")]
    pub auto_evacuate: AutoEvacuateConfig,
    /// Labs-only transport switches (`transport.wireguard`, which needs `wireguardStatic`). The
    /// hub carrier does not need them.
    #[serde(default)]
    pub transport: TransportConfig,
    /// `remoteDaemon`: the loopback `host:port` of this machine's cmux-tui remote daemon
    /// (`cmux --headless --remote-ws 127.0.0.1:PORT`), which this person's other machines reach
    /// through the hub carrier (`cmux remote exec|cp|connect --via-machine`). Unset (the
    /// default): no circuit reaches it. A joined machine also needs its "control" consent
    /// (`cmux_tui_service.rs`). Set with `acpmux config --set remote_daemon=127.0.0.1:PORT`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remote_daemon: Option<String>,
    /// `laneGhBroker`: the lane-gh broker's unix socket on this machine (its `socket`, e.g.
    /// `~/.cache/lane-gh-broker/broker.sock`), which the person's other machines reach as a
    /// carrier service, each its own `client-<machine>.sock` beside it (RFD 0127 cut 2,
    /// `hub_carrier_broker.rs`). Unset (the default): no stream reaches it. Set with
    /// `acpmux config --set lane_gh_broker=PATH`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lane_gh_broker: Option<String>,
    /// `directPort`: the TCP port of this machine's direct carrier path (Weft move 2,
    /// `hub_carrier_direct.rs`). Set, the carrier also listens on it and dials the person's other
    /// machines on it first when their name resolves to a private address (one GCP region's VPC),
    /// with the relay as the fallback. The same Noise XX and node keys as a relay circuit admit a
    /// connection, so it lets in no one the relay would not. Unset (the default): no dial by name,
    /// but the carrier listens on a port of its own and punches a direct path to a machine on
    /// another network (`hub_carrier_punch.rs`), the relay meanwhile and when no punch connects;
    /// 0: relay only (so does `ACPMUX_DIRECT_PUNCH=0`).
    /// Set with `acpmux config --set direct_port=PORT`; the carrier takes it at its start.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub direct_port: Option<u16>,
    /// `coderouterClaudeRoute`: the CodeRouter CLI subcommand that runs
    /// Claude Code through a CodeRouter route. When it is set (env
    /// `ACPMUX_CODEROUTER_CLAUDE_ROUTE` wins) and `coderouter` or `cr` is on
    /// PATH, discovery adds the `claude-cr` profile and `-m claude` prefers
    /// it. Unset (the default): no CodeRouter profile, and `claude` is the
    /// user's own login. The binary names no route.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub coderouter_claude_route: Option<String>,
    /// `sendRelay`: `{"argv": [...]}`, the command `acpmux send` hands a message to when its
    /// target names no session here and no peer lists it (`cli/send_relay.rs`). Unset (the
    /// default): such a send is refused as before.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub send_relay: Option<SendRelay>,
    /// `newRelay`: `{"argv": [...]}`, the command `acpmux new --machine HOST` hands the start to
    /// when this daemon refuses it because HOST names no peer (`cli/new_relay.rs`). Unset (the
    /// default): such a start is refused as before.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub new_relay: Option<NewRelay>,
    /// `meshRelay`: `{"url", "tokenCommand", "controlFrom", "teamMessaging"}`, the team hub this
    /// daemon heartbeats its sessions to, takes messages for them from, and sends a message to a
    /// name nobody here resolves through (`mesh_http.rs`, `server/mesh_relay.rs`). Unset (the
    /// default): no relay. `teamMessaging` (team addresses and inboxes) is on unless `false`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mesh_relay: Option<crate::mesh_relay_config::MeshRelayConfig>,
    /// `artifacts`: the agent tools that save to and search the person's cmux artifacts
    /// (`acpmux_mcp_artifacts.rs`). On whenever `meshRelay` holds a cmux sign-in;
    /// `{"enabled": false}` turns them off, `baseUrl` names another cmux-platform deployment.
    #[serde(default, skip_serializing_if = "ArtifactsConfig::is_default")]
    pub artifacts: ArtifactsConfig,
    /// Where this config was loaded from. A config built in code (tests,
    /// `--memory` runs) has no path and is never written to disk.
    #[serde(skip)]
    pub path: Option<PathBuf>,
    /// Profiles that came from PATH discovery, not the file. `save` leaves them out so the file
    /// keeps only what the user wrote and discovery stays live.
    #[serde(skip)]
    pub discovered: std::collections::BTreeSet<String>,
    /// `(profile, fallback)` set by discovery, stripped on save.
    #[serde(skip)]
    pub auto_fallback: Option<(String, String)>,
    /// `defaultHarness` was filled in at load, not written by the user.
    #[serde(skip)]
    pub auto_default: bool,
    /// No config.json was there at load (`hub/policy_source.rs`: absence proves nothing).
    #[serde(skip)]
    pub file_missing: bool,
    /// This machine is a cmux Cloud VM (`cloud_host.rs`), read at load: a chat here never fails
    /// over onto the local CodeRouter, and a sign-in failure says only how to sign it in.
    #[serde(skip)]
    pub cloud_host: bool,
    /// The `defaults.claude.prefer` list discovery filled in, not the user.
    /// `save` drops it only while it is still unchanged.
    #[serde(skip)]
    pub auto_prefer: Option<Vec<String>>,
    /// The dashboard listener could not bind this run, so `websocket` is
    /// not being served. Kept apart so a save does not drop the address.
    #[serde(skip)]
    pub web_unbound: bool,
    /// Loopback page dev server origins from `--allow-dev-origin` (this run only, never saved).
    #[serde(skip)]
    pub dev_origins: Vec<String>,
    /// The listener's token for this run when `--token` gave one: the
    /// dashboard link uses it, and it is never saved over `websocket.token`.
    #[serde(skip)]
    pub web_token_override: Option<String>,
    /// Profiles whose launcher failed its start-up check, with the reason.
    /// They stay configured (sessions on them keep their history) but no
    /// family preference or fallback routes new work to them.
    #[serde(skip)]
    pub unavailable: BTreeMap<String, String>,
    /// Display, capability, auth and sessions data of the profiles that came
    /// from profile files or cmux.json (`config/profiles.rs`), by id. Those
    /// profiles are never written to config.json.
    #[serde(skip)]
    pub profile_meta: BTreeMap<String, ProfileMeta>,
    /// Problems in the profile sources, for `harness list`, doctor and Settings.
    #[serde(skip)]
    pub profile_diagnostics: Vec<ProfileDiagnostic>,
    /// config.json entries a profile file replaced; `save` keeps them.
    #[serde(skip)]
    pub shadowed_config: BTreeMap<String, HarnessProfile>,
    /// Where folder profiles' trust and enable records are read (H4,
    /// `config/folder_profiles.rs`); None (an in-code config): no folder profiles.
    #[serde(skip)]
    pub folder_gate: Option<folder_profiles::FolderGate>,
    /// The profile file sources this config was loaded from; a reload and
    /// the hot-reload watcher read the same ones.
    #[serde(skip)]
    pub profile_sources: ProfileSources,
    /// What this process last read from or wrote to the file: a save writes only what changed
    /// since, so another writer's change is kept (`config/save_merge.rs`).
    #[serde(skip)]
    pub saved: save_merge::SavedBase,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct MachineWakeConfig {
    #[serde(default)]
    pub enabled: bool,
    pub base_url: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token: Option<String>,
}

/// `writeJournal` in config.json: off by default; new, and not yet a default anyone asked for.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct WriteJournalConfig {
    #[serde(default)]
    pub enabled: bool,
    /// RFD 0144 piece 2: also answer the app's and phone's file tree, file and search reads of a
    /// paused machine from its replica and journal, with no wake. Needs `enabled`; off by default.
    #[serde(default)]
    pub serve_paused_reads: bool,
}

impl WriteJournalConfig {
    pub fn is_default(&self) -> bool {
        self == &Self::default()
    }
}

/// `peerWake`: the wake command's argv; `Peer::wake` appends the peer's name.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct PeerWake {
    pub argv: Vec<String>,
}

/// `sendRelay`: the relay command's argv; the CLI appends the session and `-`. `lsArgv`, when
/// set, prints the other machines' live sessions as `{"sessions": [...]}` (see the module doc of
/// `cli/send_relay.rs`, which re-exports it).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct SendRelay {
    pub argv: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ls_argv: Option<Vec<String>>,
}

/// `newRelay`: the relay command's argv; the CLI appends `--machine HOST` and the caller's other
/// `new` words (see the module doc of `cli/new_relay.rs`, which re-exports it).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct NewRelay {
    pub argv: Vec<String>,
}

mod config_impl;

fn is_default_kind(k: &HarnessKind) -> bool {
    *k == HarnessKind::Acp
}

pub fn write_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    // A copy of this file still waiting for the disk writer is older: it never lands after this.
    crate::disk_writer::settle(path);
    write_atomic_now(path, bytes)
}

/// [`write_atomic`] on the disk writer's thread (`disk_writer.rs`): the caller never waits on the
/// disk, and newer bytes for `path` replace older ones still waiting. A failed write is logged,
/// not returned: only for a file holding the latest state of something its next write (or a
/// rebuild) makes up for, never one a caller must know is on disk before it goes on.
pub fn write_atomic_later(path: &Path, bytes: Vec<u8>) {
    crate::disk_writer::write_later(path, bytes);
}

/// [`write_atomic`] with no wait for the disk writer: the writer's own write.
pub(crate) fn write_atomic_now(path: &Path, bytes: &[u8]) -> Result<()> {
    refuse_lost_home(path)?;
    write_atomic_synced(path, bytes)
}

/// [`write_atomic`] for a writer that checked `path` with [`refuse_lost_home`] itself before
/// preparing its folder: a second check would refuse a home replaced since the first, which the
/// writer's held folder (`home_fs`) already keeps the file out of.
pub(crate) fn write_atomic_checked(path: &Path, bytes: &[u8]) -> Result<()> {
    crate::disk_writer::settle(path);
    write_atomic_synced(path, bytes)
}

fn write_atomic_synced(path: &Path, bytes: &[u8]) -> Result<()> {
    // Sync before rename so a power loss cannot leave empty chat metadata behind.
    write_atomic_with(path, bytes, |file, tmp| {
        #[cfg(test)]
        startup_seams::sync(tmp);
        // The fault harness's slow disk (`cmux-fault` `disk.rs`) slows these syncs too.
        #[cfg(debug_assertions)]
        crate::store::disk_fault::sync();
        file.sync_all().with_context(|| format!("sync {}", tmp.display()))
    })?;
    // The rename itself is durable once its directory is synced.
    if let Some(dir) = path.parent() {
        #[cfg(test)]
        startup_seams::sync(dir);
        let _ = crate::home_fs::sync_dir(dir);
    }
    Ok(())
}

/// Only for checked, rebuildable copies. A lost copy is rebuilt from its source.
/// The rename still keeps concurrent readers from seeing a partial write.
pub(crate) fn write_atomic_unsynced(path: &Path, bytes: &[u8]) -> Result<()> {
    refuse_lost_home(path)?;
    write_atomic_with(path, bytes, |_, _| Ok(()))
}

/// The write [`write_atomic`] and [`write_atomic_unsynced`] make once `path` is checked.
fn write_atomic_with(
    path: &Path,
    bytes: &[u8],
    sync: impl FnOnce(&std::fs::File, &Path) -> Result<()>,
) -> Result<()> {
    // One name per file and process, every write (`dead_temps`: each new name is one more
    // path fseventsd keeps); this process's writers of it take turns.
    let tmp = path.with_extension(format!("tmp-{}", std::process::id()));
    let written = {
        let _turn = crate::dead_temps::hold(&tmp);
        let written = write_then_rename(&tmp, path, bytes, sync);
        // A failed write (a full disk) leaves no partial temporary file to hold
        // the space it ran out of.
        if written.is_err() {
            let _ = crate::home_fs::remove_file(&tmp);
        }
        written
    };
    // A writer stopped between its copy's open and its rename (a daemon stopped mid-write)
    // never removed its copy: the next write of the file does.
    crate::dead_temps::remove_beside(path);
    written
}

fn write_then_rename(
    tmp: &Path,
    path: &Path,
    bytes: &[u8],
    sync: impl FnOnce(&std::fs::File, &Path) -> Result<()>,
) -> Result<()> {
    // Owner-only from creation: these files hold tokens and session data.
    // Through the folder this daemon holds (`home_fs`): a home replaced after the check never
    // gets the file; it lands in the folder this daemon locked, wherever it is now.
    #[cfg(unix)]
    {
        use std::io::Write;
        let mut f = crate::home_fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(tmp)
            .with_context(|| format!("write {}", tmp.display()))?;
        f.write_all(bytes).with_context(|| format!("write {}", tmp.display()))?;
        sync(&f, tmp)?;
        crate::home_fs::before_rename(path);
    }
    // Windows: created with an owner-only access list (`owner_only.rs`).
    #[cfg(windows)]
    {
        use std::io::Write;
        // A file a crashed process left under a reused pid is stale.
        let mut f = match crate::owner_only::create_new(tmp) {
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                crate::home_fs::remove_file(tmp)
                    .with_context(|| format!("remove {}", tmp.display()))?;
                crate::owner_only::create_new(tmp)
            }
            other => other,
        }
        .with_context(|| format!("write {}", tmp.display()))?;
        f.write_all(bytes).with_context(|| format!("write {}", tmp.display()))?;
        sync(&f, tmp)?;
    }
    crate::home_fs::rename(tmp, path).with_context(|| format!("rename to {}", path.display()))?;
    Ok(())
}

mod nested_env;
pub(crate) use nested_env::inherited_caller_scoped_keys;
#[cfg(windows)]
pub(crate) use nested_env::nested_claude_keys;
pub use nested_env::{
    CHIEF_CREDENTIAL_ENV, LAUNCH_CREDENTIAL_ENV, scrub_nested_claude_env,
    scrub_nested_claude_env_for, scrub_nested_claude_env_tokio, scrub_nested_claude_env_tokio_for,
};
pub use nested_env::{is_caller_scoped_key, is_nested_claude_key};
mod launchers;
pub use launchers::{is_subrouter_proxy, subrouter_route, verify_launchers, verify_launchers_with};
pub(crate) use launchers::{user_program, which, which_in};
mod codex_adapter;
mod discover;
pub use codex_adapter::{CODEX_ACP_PACKAGE, adapter_package_launch, resolve_adapter_package_bin};
pub use discover::{
    CHIEF_FAMILY, CHIEF_PROFILE, CMUX_ROUTER_MODEL_SETTING, CMUX_ROUTER_PROFILE,
    CODEROUTER_CLAUDE_PROFILE, CODEROUTER_CLAUDE_ROUTE_ENV, UNIICHAT_PROFILE, add_chief,
    add_cmux_router, add_cmux_router_with, add_coderouter_route, cmux_router_model_setting,
    coderouter_claude_route, discover_harnesses, discover_harnesses_from, discoverable,
};
mod peer;
pub use peer::PeerConfig;
mod save_merge;
mod start_check;
mod store_config;
pub use store_config::{StoreConfig, StoreMode};
mod pool;
pub use pool::{PoolConfig, spare_personal_enabled};
mod btw;
pub use btw::BtwConfig;
mod auto_evacuate;
mod usage_warnings;
pub use auto_evacuate::AutoEvacuateConfig;
pub use usage_warnings::{ContextLimit, FALLBACK_CONTEXT_TOKENS, UsageLimits, UsageWarningsConfig};
pub mod folder_profiles;
pub mod harness_icon;
pub mod profiles;
pub use profiles::{
    Diagnostic as ProfileDiagnostic, LoadedProfiles, ProfileMeta, ProfileSource, ProfileSources,
};
pub mod chief_builtins;
mod preset_args;
pub use preset_args::{
    Preset, SYSTEM_PROMPT_FILE, check_preset_args, check_preset_dir_name, checked_system_prompt,
    parse_preset_args, remove_preset_dir, write_system_prompt,
};

/// The stored spelling of a permission mode a person typed: `fullAccess`
/// (also `yolo`, `full-access`, `bypassPermissions`), `standard` or `ask`.
/// Exact words only: any other spelling (`Ask`) is `None`, which a reader
/// takes as `standard`, never full access.
pub fn normalize_permission_mode(value: &str) -> Option<&'static str> {
    match value {
        "fullAccess" | "yolo" | "full-access" | "bypassPermissions" => Some("fullAccess"),
        "standard" => Some("standard"),
        "ask" => Some("ask"),
        _ => None,
    }
}

/// `${cwd}`, `${home}`, `${model}` and a leading `~/` in a profile env value or argv word.
pub fn expand_env_value(
    value: &str,
    cwd: &std::path::Path,
    home: &std::path::Path,
    model: &str,
) -> String {
    let mut out = value
        .replace("${cwd}", &cwd.to_string_lossy())
        .replace("${home}", &home.to_string_lossy())
        .replace("${model}", model);
    if let Some(rest) = out.strip_prefix("~/") {
        out = format!("{}/{rest}", home.to_string_lossy());
    }
    out
}

#[cfg(test)]
mod save_merge_tests;
#[cfg(test)]
mod tests;

#[cfg(test)]
pub(crate) mod startup_seams;

/// A `remoteDaemon` address: a socket address on loopback, the only place a circuit may reach.
pub fn loopback_daemon_address(value: &str) -> Result<std::net::SocketAddr> {
    let address: std::net::SocketAddr = value
        .trim()
        .parse()
        .with_context(|| format!("remote_daemon must be a loopback host:port, not `{value}`"))?;
    anyhow::ensure!(
        address.ip().is_loopback() && address.port() != 0,
        "remote_daemon must be a loopback host:port with a port (127.0.0.1:PORT or [::1]:PORT)"
    );
    Ok(address)
}

/// `web_url` opening one session: `?session=<id>` before the fragment.
pub fn web_url_for_session(url: &str, session: &str) -> String {
    let (base, fragment) = url.split_once('#').map_or((url, None), |(b, f)| (b, Some(f)));
    let joiner = if base.contains('?') { '&' } else { '?' };
    match fragment {
        Some(f) => format!("{base}{joiner}session={session}#{f}"),
        None => format!("{base}{joiner}session={session}"),
    }
}

#[cfg(test)]
mod web_url_tests {
    use super::web_url_for_session;

    #[test]
    fn a_session_link_puts_the_session_in_the_query_and_keeps_the_fragment() {
        let url = web_url_for_session("http://127.0.0.1:1/#token=t", "s1");
        assert_eq!(url, "http://127.0.0.1:1/?session=s1#token=t");
        assert_eq!(web_url_for_session("http://h/", "s1"), "http://h/?session=s1");
        assert_eq!(
            web_url_for_session("http://h/?a=1#token=t", "s"),
            "http://h/?a=1&session=s#token=t"
        );
    }
}
