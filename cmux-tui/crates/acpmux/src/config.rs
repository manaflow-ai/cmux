//! Configuration: `$ACPMUX_HOME/config.json`, agent registry, store mode.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};

static HOME_OVERRIDE: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();

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

/// The default state directory, with no ACPMUX_HOME and no override: the
/// person's own daemon home (a hand, which runs its own daemon, protects it).
pub fn default_home() -> PathBuf {
    dirs::home_dir().unwrap_or_else(|| PathBuf::from(".")).join(".acpmux")
}

/// Make one acpmux state directory owner-only, including an existing directory
/// created by an older build under a permissive umask. Refuse links and a
/// directory owned by another user before changing its permissions.
#[cfg(unix)]
pub(crate) fn private_state_dir(dir: &Path) -> Result<()> {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};

    validate_private_state_ancestors(dir)?;
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    validate_private_state_ancestors(dir)?;
    let opened = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(dir)
        .with_context(|| format!("open private state directory {}", dir.display()))?;
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
    refuse_extended_acl(&opened, dir)?;
    if metadata.mode() & 0o077 != 0 {
        opened
            .set_permissions(std::fs::Permissions::from_mode(0o700))
            .with_context(|| format!("make {} owner-only", dir.display()))?;
    }
    let reopened = std::fs::OpenOptions::new()
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
fn validate_private_state_ancestors(dir: &Path) -> Result<()> {
    use std::os::unix::fs::MetadataExt;

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
fn validate_private_state_file(file: &std::fs::File, path: &Path) -> Result<()> {
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
    refuse_extended_acl(file, path)?;
    if metadata.mode() & 0o077 != 0 {
        file.set_permissions(std::fs::Permissions::from_mode(0o600))
            .with_context(|| format!("make {} owner-only", path.display()))?;
    }
    Ok(())
}

/// Open or create an owner-only regular state file for read/write without
/// following a pre-positioned final symlink (daemon.lock).
#[cfg(unix)]
pub(crate) fn private_state_rw(path: &Path) -> Result<std::fs::File> {
    use std::os::unix::fs::OpenOptionsExt;

    let file = std::fs::OpenOptions::new()
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

/// Open or create an owner-only regular state file for append without
/// following a pre-positioned final symlink (daemon.log).
#[cfg(unix)]
pub(crate) fn private_state_append(path: &Path) -> Result<std::fs::File> {
    use std::os::unix::fs::OpenOptionsExt;

    let file = std::fs::OpenOptions::new()
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
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    let cwd = std::env::current_dir().ok();
    let (configured, home) = socket_inputs(configured.as_deref(), &home(), cwd.as_deref());
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
    /// A CLI or TUI without ACP (`protocol = "terminal"` in a profile file):
    /// listed, but run in a terminal tab (`cmux harness run`), never as an
    /// acpmux session.
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

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
#[derive(Default)]
pub enum StoreMode {
    Memory,
    #[default]
    Local,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct StoreConfig {
    #[serde(default)]
    pub mode: StoreMode,
    /// Segment roll size in bytes for the event log.
    #[serde(default = "default_segment_bytes")]
    pub segment_bytes: u64,
    /// Days a closed chat's event log is kept whole (`hub/retention.rs`): after them, the
    /// harness's raw lines and long tool output are removed from it, the chat's messages kept.
    /// Default 14; 0 keeps every log whole.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub closed_log_days: Option<u32>,
}

impl StoreConfig {
    /// How long a closed chat's log is kept whole; None: always.
    pub fn closed_log_retention(&self) -> Option<std::time::Duration> {
        match self.closed_log_days.unwrap_or(14) {
            0 => None,
            days => Some(std::time::Duration::from_secs(u64::from(days) * 86_400)),
        }
    }
}

fn default_segment_bytes() -> u64 {
    8 * 1024 * 1024
}

impl Default for StoreConfig {
    fn default() -> Self {
        Self {
            mode: StoreMode::Local,
            segment_bytes: default_segment_bytes(),
            closed_log_days: None,
        }
    }
}

/// Permission policy applied when no attached client answers.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
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
            other => Err(format!("unknown permission policy: {other}")),
        }
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
    /// other name is refused). Both lists are read when the listener starts.
    #[serde(default, alias = "allowed_hosts", skip_serializing_if = "Vec::is_empty")]
    pub allowed_hosts: Vec<String>,
    /// `tokenRotated`: the saved token was replaced at the first start of a
    /// build that never sends it to a remote-origin connection (earlier
    /// builds did, in `_acpmux/status`). Set, it never rotates again.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub token_rotated: u32,
}

fn is_zero(n: &u32) -> bool {
    *n == 0
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

impl TitlesConfig {
    pub fn is_default(&self) -> bool {
        self == &Self::default()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    #[serde(default)]
    #[serde(alias = "agents")]
    pub harnesses: BTreeMap<String, HarnessProfile>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub peers: BTreeMap<String, PeerConfig>,
    #[serde(default, alias = "defaultAgent")]
    pub default_harness: Option<String>,
    /// More login-shell variables agents get, beyond the allow-list
    /// (`login_env::allowed`): exact names or `PREFIX_*`. Default empty.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub login_env_allow: Vec<String>,
    /// Per-family (or per-profile) session defaults, keyed by family or
    /// profile name: `{"claude": {"model": "claude-opus-5", "effort": "high",
    /// "policy": "approve-edits", "prefer": ["claude-cr", "claude"]}}`.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub defaults: BTreeMap<String, SessionDefaults>,
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
    /// `autoResumeDelaysMs`: the wait before each automatic continuation of a turn a
    /// connection or capacity error cut off (`hub/auto_resume.rs`), one entry per attempt. Default
    /// `[10000, 60000, 300000, 1200000]`; `[]` turns it off. Checked on load: at most 4
    /// entries of 1 s to 1 h; anything else falls back to the default with a warning.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "crate::hub::auto_resume::delays_from_config"
    )]
    pub auto_resume_delays_ms: Option<Vec<u64>>,
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
    /// `vmHost`: this machine is a dedicated agent VM (a Chief's cloud
    /// subagent host, a VM cmux created), so the VM boundary is the sandbox:
    /// a remote chain's Claude Code runs there without Seatbelt
    /// (`hub/remote_sandbox.rs`). Honored off macOS only. Absent: on exactly
    /// when cmux created this VM (`hub/vm_host.rs`); `_acpmux/vm_host` sets it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub vm_host: Option<bool>,
    /// `pool`: hidden pre-created sessions that make a harness switch
    /// instant (`hub/pool/`).
    #[serde(default, skip_serializing_if = "PoolConfig::is_default")]
    pub pool: PoolConfig,
    /// `btw`: side sessions (`hub/btw.rs`): the model they start on, per harness.
    #[serde(default, skip_serializing_if = "BtwConfig::is_default")]
    pub btw: BtwConfig,
    /// `titles`: short titles for chats their harness never titles
    /// (`hub/titles.rs`).
    #[serde(default, skip_serializing_if = "TitlesConfig::is_default")]
    pub titles: TitlesConfig,
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
    pub send_relay: Option<crate::cli::send_relay::SendRelay>,
    /// Where this config was loaded from. A config built in code (tests,
    /// `--memory` runs) has no path and is never written to disk.
    #[serde(skip)]
    pub path: Option<PathBuf>,
    /// Profiles that came from PATH discovery, not the file. `save` leaves
    /// them out so the file keeps only what the user wrote and discovery
    /// stays live.
    #[serde(skip)]
    pub discovered: std::collections::BTreeSet<String>,
    /// `(profile, fallback)` set by discovery, stripped on save.
    #[serde(skip)]
    pub auto_fallback: Option<(String, String)>,
    /// `defaultHarness` was filled in at load, not written by the user.
    #[serde(skip)]
    pub auto_default: bool,
    /// The `defaults.claude.prefer` list discovery filled in, not the user.
    /// `save` drops it only while it is still unchanged.
    #[serde(skip)]
    pub auto_prefer: Option<Vec<String>>,
    /// The dashboard listener could not bind this run, so `websocket` is
    /// not being served. Kept apart so a save does not drop the address.
    #[serde(skip)]
    pub web_unbound: bool,
    /// Loopback page dev server origins from `--allow-dev-origin` (this run
    /// only, never saved).
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
}

impl Config {
    /// `agentStartTimeoutMs`, or its 90 s default.
    pub fn agent_start_timeout(&self) -> std::time::Duration {
        std::time::Duration::from_millis(self.agent_start_timeout_ms.unwrap_or(90_000))
    }

    /// `uploadsMaxAgeDays`, or its 30-day default; None when it is 0 (keep them).
    pub fn uploads_max_age(&self) -> Option<std::time::Duration> {
        match self.uploads_max_age_days.unwrap_or(30) {
            0 => None,
            days => Some(std::time::Duration::from_secs(days.saturating_mul(24 * 60 * 60))),
        }
    }

    /// `silentTurnMs`, or its 90 s default; None when it is 0 (off).
    pub fn silent_turn(&self) -> Option<std::time::Duration> {
        match self.silent_turn_ms.unwrap_or(90_000) {
            0 => None,
            ms => Some(std::time::Duration::from_millis(ms)),
        }
    }

    /// `stalledTurnMs`, or its 10 minute default; None when it is 0 (off).
    pub fn stalled_turn(&self) -> Option<u64> {
        match self.stalled_turn_ms.unwrap_or(600_000) {
            0 => None,
            ms => Some(ms),
        }
    }

    /// `stalledTurnEndMs`, or its 6 h default; None when it is 0 (off).
    pub fn stalled_turn_end(&self) -> Option<std::time::Duration> {
        match self.stalled_turn_end_ms.unwrap_or(6 * 60 * 60 * 1000) {
            0 => None,
            ms => Some(std::time::Duration::from_millis(ms)),
        }
    }

    /// Family of a configured profile.
    pub fn family(&self, profile: &str) -> Option<String> {
        self.harnesses.get(profile).map(|p| derive_family(profile, p))
    }

    /// Families with their profiles, in name order.
    pub fn families(&self) -> BTreeMap<String, Vec<String>> {
        let mut out: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for (name, p) in &self.harnesses {
            out.entry(derive_family(name, p)).or_default().push(name.clone());
        }
        out
    }

    /// The profile for a `-m` head: a family (its `prefer` list, else its
    /// only profile, else the profile named like it), else a profile name.
    /// Anything else, or a family with several profiles and no `prefer`,
    /// is an error that names what exists.
    pub fn resolve_harness(&self, head: &str) -> std::result::Result<String, String> {
        let fams = self.families();
        if let Some(members) = fams.get(head) {
            if let Some(d) = self.defaults.get(head) {
                // An unavailable profile is skipped; the next preference serves.
                // Only the family's own profiles count; a stray name never
                // routes the family to another family's profile.
                if let Some(p) = d.prefer.iter().find(|p| {
                    members.contains(*p)
                        && self.harnesses.contains_key(*p)
                        && !self.unavailable.contains_key(*p)
                }) {
                    return Ok(p.clone());
                }
            }
            if members.len() == 1 {
                return Ok(members[0].clone());
            }
            if members.iter().any(|m| m == head) {
                return Ok(head.to_owned());
            }
            return Err(format!(
                "family {head:?} has several profiles ({}) and no preference; write one of them, or `acpmux defaults {head} prefer=…`",
                members.join(", ")
            ));
        }
        if self.harnesses.contains_key(head) {
            return Ok(head.to_owned());
        }
        Err(format!(
            "unknown harness {head:?}; families: {}; profiles: {}; presets: {}",
            fams.keys().cloned().collect::<Vec<_>>().join(", "),
            self.harnesses.keys().cloned().collect::<Vec<_>>().join(", "),
            if self.presets.is_empty() {
                "none".to_owned()
            } else {
                self.presets.keys().cloned().collect::<Vec<_>>().join(", ")
            }
        ))
    }

    /// Defaults that apply to a profile: the family's entry, then the
    /// `defaults` entry named after the profile, then the profile's own
    /// inline `model`/`effort`/`policy`.
    pub fn defaults_for(&self, profile: &str) -> SessionDefaults {
        let mut d = SessionDefaults::default();
        if let Some(f) = self.family(profile) {
            if let Some(fd) = self.defaults.get(&f) {
                d.overlay(fd);
            }
            if f != profile
                && let Some(pd) = self.defaults.get(profile)
            {
                d.overlay(pd);
            }
        }
        if let Some(p) = self.harnesses.get(profile) {
            d.overlay(&SessionDefaults {
                model: p.model.clone(),
                effort: p.effort.clone(),
                policy: p.policy,
                prefer: vec![],
                env: BTreeMap::new(),
            });
        }
        d
    }

    pub fn path() -> PathBuf {
        home().join("config.json")
    }

    /// Load config. When no file exists, build defaults and try to import
    /// agent profiles from `~/.acpx/config.json` so existing setups keep working.
    pub fn load() -> Result<Self> {
        Self::load_from(&Self::path())
    }

    pub fn load_from(path: &Path) -> Result<Self> {
        Self::load_from_with(path, &ProfileSources::current())
    }

    /// `load_from` with explicit profile file sources.
    pub fn load_from_with(path: &Path, sources: &ProfileSources) -> Result<Self> {
        let path = path.to_owned();
        let mut cfg = match std::fs::symlink_metadata(&path) {
            Ok(_) => {
                let mut text = String::new();
                private_state_file(&path)?
                    .read_to_string(&mut text)
                    .with_context(|| format!("read {}", path.display()))?;
                serde_json::from_str::<Config>(&text)
                    .with_context(|| format!("parse {}", path.display()))?
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Config::default(),
            Err(error) => return Err(error.into()),
        };
        cfg.join_profiles(profiles::load(sources));
        let route = coderouter_claude_route(cfg.coderouter_claude_route.as_deref());
        cfg.join_discovered(discover_harnesses(route.as_deref()));
        if cfg.default_harness.is_none() {
            cfg.auto_default = true;
            // A terminal harness (an installed `muse`, say) runs no ACP
            // session, so it never becomes the default.
            cfg.default_harness = cfg
                .harnesses
                .iter()
                .find(|(_, profile)| profile.kind != HarnessKind::Terminal)
                .map(|(name, _)| name.clone());
        }
        // Installed ACP Registry agents (the cached copy; no network, nothing
        // started), after the default so a registry agent never becomes it
        // while a built-in harness exists.
        if let Some(registry) = crate::registry::load_cached(&home()) {
            let found = crate::registry::discovered(
                &registry,
                crate::registry::platform(),
                &which,
                &|id| cfg.harnesses.contains_key(id),
            );
            // Never the default: a registry agent runs only when picked.
            cfg.join_discovered(found);
        }
        cfg.folder_gate = path.parent().and_then(folder_profiles::FolderGate::for_home);
        cfg.profile_sources = sources.clone();
        cfg.path = Some(path);
        Ok(cfg)
    }

    /// Adds the profiles from profile files and cmux.json. They win over
    /// config.json entries with the same id (kept for `save`).
    pub fn join_profiles(&mut self, loaded: LoadedProfiles) {
        for (id, (profile, meta)) in loaded.profiles {
            if let Some(old) = self.harnesses.insert(id.clone(), profile)
                && !self.profile_meta.contains_key(&id)
            {
                self.shadowed_config.insert(id.clone(), old);
            }
            self.profile_meta.insert(id, meta);
        }
        self.profile_diagnostics.extend(loaded.diagnostics);
    }

    /// Joins discovered harnesses to the configured ones (configured entries
    /// always win) and sets the automatic Claude fallbacks and preference.
    pub fn join_discovered(&mut self, discovered: BTreeMap<String, HarnessProfile>) {
        let cfg = self;
        // Harnesses found on PATH join the configured ones, so installing an
        // adapter such as pi-acp is enough; configured entries always win.
        for (name, profile) in discovered {
            if !cfg.harnesses.contains_key(&name) {
                cfg.discovered.insert(name.clone());
                cfg.harnesses.insert(name, profile);
            }
        }
        // A configured CodeRouter route (`claude-cr`) is the first `claude`
        // preference and the direct login's fallback. The subrouter pool
        // (`claude-sr`) stays a profile a user names; discovery never
        // prefers it or falls back onto it.
        let route = CODEROUTER_CLAUDE_PROFILE;
        if cfg.discovered.contains(route) {
            if let Some(c) = cfg.harnesses.get_mut("claude")
                && c.fallback.is_none()
                && c.kind == HarnessKind::ClaudeStdio
            {
                c.fallback = Some(route.into());
                cfg.auto_fallback = Some(("claude".into(), route.into()));
            }
            // The route falls back to, and `-m claude` prefers, a direct
            // login only on acpmux's own adapter, never an ACP `claude`.
            let has_direct =
                cfg.harnesses.get("claude").is_some_and(|c| c.kind == HarnessKind::ClaudeStdio);
            if let Some(p) = cfg.harnesses.get_mut(route)
                && p.fallback.is_none()
                && has_direct
            {
                p.fallback = Some("claude".into());
            }
            let entry = cfg.defaults.entry("claude".into()).or_default();
            if entry.prefer.is_empty() {
                entry.prefer = [route, "claude"]
                    .iter()
                    .filter(|n| has_direct || **n != "claude")
                    .map(|n| n.to_string())
                    .collect();
                cfg.auto_prefer = Some(entry.prefer.clone());
            }
        }
    }

    /// Where preset directories live (`presets/` next to config.json); None
    /// for an in-code config, which then takes no `systemPrompt`.
    pub fn presets_dir(&self) -> Option<PathBuf> {
        self.path.as_ref().and_then(|p| p.parent()).map(|d| d.join("presets"))
    }

    /// Write back to the file this config came from. No-op for in-code configs.
    pub fn save(&self) -> Result<()> {
        let Some(path) = &self.path else {
            tracing::debug!("config has no file; not saved");
            return Ok(());
        };
        if let Some(parent) = path.parent() {
            private_state_dir(parent)?;
        }
        let mut on_disk = self.clone();
        on_disk
            .harnesses
            .retain(|n, _| !self.discovered.contains(n) && !self.profile_meta.contains_key(n));
        for (n, p) in &self.shadowed_config {
            on_disk.harnesses.insert(n.clone(), p.clone());
        }
        if let Some((p, f)) = &self.auto_fallback
            && let Some(prof) = on_disk.harnesses.get_mut(p)
            && prof.fallback.as_deref() == Some(f.as_str())
        {
            prof.fallback = None;
        }
        if self.auto_default {
            on_disk.default_harness = None;
        }
        if let Some(generated) = &self.auto_prefer
            && let Some(d) = on_disk.defaults.get_mut("claude")
            && d.prefer == *generated
        {
            d.prefer.clear();
            if d.is_empty() {
                on_disk.defaults.remove("claude");
            }
        }
        write_atomic(path, serde_json::to_string_pretty(&on_disk)?.as_bytes())
    }

    pub fn profile(&self, name: &str) -> Option<&HarnessProfile> {
        self.harnesses.get(name)
    }

    /// The web listener this daemon actually serves, if any.
    pub fn web_listener(&self) -> Option<&WebSocketConfig> {
        self.websocket.as_ref().filter(|_| !self.web_unbound)
    }
}

fn is_default_kind(k: &HarnessKind) -> bool {
    *k == HarnessKind::Acp
}

pub fn write_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let tmp = path.with_extension(format!("tmp-{}-{n}", std::process::id()));
    let written = write_then_rename(&tmp, path, bytes);
    // A failed write (a full disk) leaves no partial temporary file to hold
    // the space it ran out of; every retry uses a new name.
    if written.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    written
}

fn write_then_rename(tmp: &Path, path: &Path, bytes: &[u8]) -> Result<()> {
    // Owner-only from creation: these files hold tokens and session data.
    #[cfg(unix)]
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(tmp)
            .with_context(|| format!("write {}", tmp.display()))?;
        f.write_all(bytes).with_context(|| format!("write {}", tmp.display()))?;
        // On disk before the rename: a power loss never leaves an empty
        // session.json (its session id and ACP session id) behind.
        f.sync_all().with_context(|| format!("sync {}", tmp.display()))?;
    }
    // Windows: created with an owner-only access list (`owner_only.rs`).
    #[cfg(windows)]
    {
        use std::io::Write;
        // A file a crashed process left under a reused pid is stale.
        let mut f = match crate::owner_only::create_new(tmp) {
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                std::fs::remove_file(tmp).with_context(|| format!("remove {}", tmp.display()))?;
                crate::owner_only::create_new(tmp)
            }
            other => other,
        }
        .with_context(|| format!("write {}", tmp.display()))?;
        f.write_all(bytes).with_context(|| format!("write {}", tmp.display()))?;
        f.sync_all().with_context(|| format!("sync {}", tmp.display()))?;
    }
    std::fs::rename(tmp, path).with_context(|| format!("rename to {}", path.display()))?;
    // The rename itself is durable once its directory is synced.
    #[cfg(unix)]
    if let Some(dir) = path.parent()
        && let Ok(dir) = std::fs::File::open(dir)
    {
        let _ = dir.sync_all();
    }
    Ok(())
}

mod nested_env;
#[cfg(windows)]
pub(crate) use nested_env::nested_claude_keys;
pub use nested_env::{
    CHIEF_CREDENTIAL_ENV, LAUNCH_CREDENTIAL_ENV, scrub_nested_claude_env,
    scrub_nested_claude_env_for, scrub_nested_claude_env_tokio, scrub_nested_claude_env_tokio_for,
};
pub(crate) use nested_env::{inherited_caller_scoped_keys, is_nested_claude_key};
mod launchers;
pub(crate) use launchers::which;
pub use launchers::{is_subrouter_proxy, subrouter_route, verify_launchers, verify_launchers_with};
mod codex_adapter;
mod discover;
pub use codex_adapter::{CODEX_ACP_PACKAGE, adapter_package_launch, resolve_adapter_package_bin};
pub use discover::{
    CODEROUTER_CLAUDE_PROFILE, CODEROUTER_CLAUDE_ROUTE_ENV, UNIICHAT_PROFILE, add_coderouter_route,
    coderouter_claude_route, discover_harnesses, discover_harnesses_from,
};
mod peer;
pub use peer::PeerConfig;
mod pool;
pub use pool::PoolConfig;
mod btw;
pub use btw::BtwConfig;
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

#[cfg(test)]
mod tests;
