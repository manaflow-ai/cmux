//! Moving a Chief between hosts (plans/cmux-next/chief-migration-DESIGN.md).
//!
//! A Chief home (`MUX_HOME`: `optchat/`, `state/`, `tui/`, `acpmux/`, `c/`)
//! is self-contained, so a move is: a checkpoint of everything that is not
//! machine-local (format `cmux-chief-checkpoint/1`: `manifest.json` plus
//! `files/`), sent to the target, restored into an empty home there,
//! checked against the manifest, and then the source is marked moved
//! (`state/moved.json`), which the host refuses to start on. One history,
//! one writer.
//!
//! SQLite files are copied with `VACUUM INTO` (one consistent file without
//! its `-wal`), and every table's row count goes into the manifest; restore
//! checks every hash and count before the home becomes visible.

use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// The checkpoint format this build writes and reads.
pub const FORMAT: &str = "cmux-chief-checkpoint/1";
/// Written on the source after a move: the host refuses to start.
pub const MOVED_FILE: &str = "state/moved.json";
/// Written on the target by a restore: where the Chief came from.
pub const MOVED_IN_FILE: &str = "state/moved-in.json";
/// The app's "start no brain" marker (cmux-tui `cmux chief shutdown`).
pub const SHUTDOWN_FILE: &str = "state/shutdown";
/// The exit code of a host that refuses a moved home.
pub const MOVED_EXIT: i32 = 3;

/// File names that are machine-local wherever they appear: sockets, locks,
/// pids, logs, the move's own markers, live terminal handles.
const LOCAL_NAMES: &[&str] = &[
    "lock",
    "writer.lock",
    "host.stopping",
    "shutdown",
    "moved.json",
    "moved-in.json",
    "workspace-registry.owner-shutdown",
    "inspector.json",
    "engine-resolved.json",
    "login-env.json",
    "harness-health.json",
    "daemon.pid",
    // Each home mints its own agent token (cmux-tui build_adopt/chief.rs).
    "agent-token",
    // Bound to the daemon session name and its live terminals: the target's
    // daemon starts its own (build_adopt/chief.rs SESSION_RUNTIME).
    "workspace-registry.sqlite3",
    "launch-snapshot.json",
];
const LOCAL_SUFFIXES: &[&str] = &[
    ".sock", ".lock", ".flock", ".pid", ".log", "-wal", "-shm", "-journal", ".live",
];
/// Directory names that are machine-local: caches the host rebuilds, the
/// per-session harness configs, launchers, traces, live terminal hosts,
/// acpmux's run state, routes and probes.
const LOCAL_DIRS: &[&str] = &[
    "traces",
    "claude",
    "compactor-claude",
    "compactor-codex",
    "turn-codex",
    "session",
    "bin",
    "codex",
    "run",
    "live-models",
    "router",
    "hosts",
    "session-locks",
    "shell-integration",
    "subagent",
];
/// SQLite stores, copied with `VACUUM INTO`.
const SQLITE_SUFFIXES: &[&str] = &[".sqlite3", ".sqlite"];

/// One file of a checkpoint.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileEntry {
    /// Relative to the home, `/`-separated.
    pub path: String,
    pub size: u64,
    pub sha256: String,
    pub mode: u32,
    /// Row counts per table, for SQLite files.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tables: Option<BTreeMap<String, u64>>,
}

/// Where a checkpoint came from.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Source {
    pub host: String,
    pub os: String,
    pub arch: String,
    pub root: String,
}

/// `manifest.json`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Manifest {
    pub format: String,
    pub source: Source,
    pub created_at: String,
    /// The daemon session directory under `tui/` that belongs to the
    /// source root (renamed for the target's root on restore).
    pub session_dir: Option<String>,
    /// `acpmux/sessions` left out (`--without-transcripts`).
    #[serde(default)]
    pub without_transcripts: bool,
    pub memory: Counts,
    pub conversations: Counts,
    pub files: Vec<FileEntry>,
    /// What the source reached, names only (migrate_reach.rs).
    #[serde(default)]
    pub reach: serde_json::Value,
    /// The memory backup's repository id (`manaflow-ai/chief-memory-<id>`):
    /// it follows the Chief, not the home's path.
    #[serde(default)]
    pub backup_id: Option<String>,
}

/// The counts a person checks a move by.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Counts {
    pub messages: u64,
    #[serde(default)]
    pub nodes: u64,
}

/// What `checkpoint` may do.
#[derive(Clone, Debug, Default)]
pub struct CheckpointOptions {
    /// Leave `acpmux/sessions` (subagent transcripts) out.
    pub without_transcripts: bool,
    /// Take it while a host holds the lock (a backup, never a move).
    pub live: bool,
}

/// `state/moved.json`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Moved {
    pub to: String,
    pub at: String,
    pub checkpoint_sha256: String,
}

/// `cmux-chief-<FNV-1a 32 of the root>`, the Chief's daemon session name
/// (cmux-tui `cli/chief/home.rs` `ChiefHome::session`).
pub fn session_name_for(root: &Path) -> String {
    let mut hash: u32 = 0x811c_9dc5;
    for byte in root.to_string_lossy().as_bytes() {
        hash ^= u32::from(*byte);
        hash = hash.wrapping_mul(0x0100_0193);
    }
    format!("cmux-chief-{hash:08x}")
}

/// The session's state directory name under `tui/` (cmux-tui-core
/// workspace_registry.rs `session_storage_component`).
pub fn session_dir_for(root: &Path) -> String {
    storage_component(&session_name_for(root))
}

fn storage_component(session: &str) -> String {
    let mut readable = String::new();
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    for byte in session.bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0100_0000_01b3);
        if readable.len() < 48 {
            if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_') {
                readable.push(char::from(byte));
            } else {
                readable.push('_');
            }
        }
    }
    if readable.is_empty() {
        readable.push_str("session");
    }
    format!("{readable}-{hash:016x}")
}

/// Whether `rel` (relative, `/`-separated) is machine-local.
pub fn is_machine_local(rel: &str, without_transcripts: bool) -> bool {
    let parts: Vec<&str> = rel.split('/').collect();
    let Some((name, dirs)) = parts.split_last() else {
        return true;
    };
    if without_transcripts && rel.starts_with("acpmux/sessions/") {
        return true;
    }
    if dirs.iter().any(|d| {
        LOCAL_DIRS.contains(d) || d.starts_with("terminal-hosts-") || d.ends_with(".incoming")
    }) {
        return true;
    }
    LOCAL_NAMES.contains(name) || LOCAL_SUFFIXES.iter().any(|s| name.ends_with(s))
}

/// Whether `dir` is absent or an empty directory.
fn absent_or_empty(dir: &Path) -> bool {
    match std::fs::read_dir(dir) {
        Ok(mut entries) => entries.next().is_none(),
        Err(e) => e.kind() == std::io::ErrorKind::NotFound,
    }
}

fn is_sqlite(rel: &str) -> bool {
    SQLITE_SUFFIXES.iter().any(|s| rel.ends_with(s))
}

fn now_rfc3339() -> String {
    chrono::Utc::now()
        .format("%Y-%m-%dT%H:%M:%S%.3fZ")
        .to_string()
}

fn hostname() -> String {
    let mut buf = [0u8; 256];
    // SAFETY: the buffer is valid for its length; gethostname NUL-terminates
    // within it or truncates.
    let rc = unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len()) };
    if rc != 0 {
        return "unknown".into();
    }
    let end = buf.iter().position(|b| *b == 0).unwrap_or(buf.len());
    String::from_utf8_lossy(&buf[..end]).into_owned()
}

fn sha256_file(path: &Path) -> Result<(String, u64), String> {
    let mut file =
        std::fs::File::open(path).map_err(|e| format!("reading {}: {e}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 1 << 16];
    let mut size = 0u64;
    loop {
        let n = file
            .read(&mut buf)
            .map_err(|e| format!("reading {}: {e}", path.display()))?;
        if n == 0 {
            break;
        }
        size += n as u64;
        hasher.update(&buf[..n]);
    }
    Ok((hex(&hasher.finalize()), size))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn mode_of(meta: &std::fs::Metadata) -> u32 {
    use std::os::unix::fs::PermissionsExt;
    meta.permissions().mode() & 0o777
}

/// Row counts of every ordinary table (virtual tables are counted through
/// their shadow tables).
pub fn table_counts(path: &Path) -> Result<BTreeMap<String, u64>, String> {
    let conn = rusqlite::Connection::open_with_flags(
        path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|e| format!("opening {}: {e}", path.display()))?;
    let names: Vec<String> = {
        let mut stmt = conn
            .prepare(
                "SELECT name FROM sqlite_master WHERE type = 'table' \
                 AND name NOT LIKE 'sqlite_%' AND sql NOT LIKE 'CREATE VIRTUAL%' ORDER BY name",
            )
            .map_err(|e| format!("{}: {e}", path.display()))?;
        let rows = stmt
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(|e| format!("{}: {e}", path.display()))?;
        rows.collect::<Result<_, _>>()
            .map_err(|e| format!("{}: {e}", path.display()))?
    };
    let mut counts = BTreeMap::new();
    for name in names {
        let quoted = name.replace('"', "\"\"");
        let n: i64 = conn
            .query_row(&format!("SELECT count(*) FROM \"{quoted}\""), [], |row| {
                row.get(0)
            })
            .map_err(|e| format!("{} {name}: {e}", path.display()))?;
        counts.insert(name, n.max(0) as u64);
    }
    Ok(counts)
}

fn vacuum_into(from: &Path, to: &Path) -> Result<(), String> {
    // Read-write open (no writes): a read-only connection cannot read a
    // WAL whose -shm it may not create, and VACUUM INTO needs none.
    let conn = rusqlite::Connection::open_with_flags(
        from,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|e| format!("opening {}: {e}", from.display()))?;
    conn.busy_timeout(Duration::from_secs(30))
        .map_err(|e| format!("{}: {e}", from.display()))?;
    conn.execute("VACUUM INTO ?1", [to.to_string_lossy().as_ref()])
        .map_err(|e| format!("copying {}: {e}", from.display()))?;
    drop(conn);
    // The copy keeps the source's WAL flag; a rollback journal makes it one
    // self-contained file that opens read-only anywhere.
    let copy = rusqlite::Connection::open(to).map_err(|e| format!("{}: {e}", to.display()))?;
    copy.query_row("PRAGMA journal_mode = DELETE", [], |row| {
        row.get::<_, String>(0)
    })
    .map_err(|e| format!("{}: {e}", to.display()))?;
    Ok(())
}

fn walk(root: &Path, dir: &Path, out: &mut Vec<String>) -> Result<(), String> {
    let mut entries: Vec<_> = std::fs::read_dir(dir)
        .map_err(|e| format!("listing {}: {e}", dir.display()))?
        .filter_map(Result::ok)
        .collect();
    entries.sort_by_key(std::fs::DirEntry::file_name);
    for entry in entries {
        let path = entry.path();
        let kind = entry
            .file_type()
            .map_err(|e| format!("{}: {e}", path.display()))?;
        if kind.is_symlink() {
            continue;
        }
        let rel = path
            .strip_prefix(root)
            .map_err(|e| e.to_string())?
            .to_string_lossy()
            .replace('\\', "/");
        if kind.is_dir() {
            walk(root, &path, out)?;
        } else if kind.is_file() {
            out.push(rel);
        }
    }
    Ok(())
}

fn memory_counts(tables: Option<&BTreeMap<String, u64>>) -> Counts {
    let get = |t: &str| tables.and_then(|m| m.get(t)).copied().unwrap_or(0);
    Counts {
        messages: get("messages"),
        nodes: get("nodes"),
    }
}

/// Takes a checkpoint of `home` into `out` (created; must be absent or
/// empty). Refuses while a host holds the lock unless `options.live`.
pub fn checkpoint(
    home: &Path,
    out: &Path,
    options: &CheckpointOptions,
) -> Result<Manifest, String> {
    let home = std::fs::canonicalize(home).map_err(|e| format!("{}: {e}", home.display()))?;
    if !home.join("optchat").is_dir() {
        return Err(format!(
            "{} is not a Chief home (no optchat/)",
            home.display()
        ));
    }
    let lock = home.join("state").join("host.lock");
    if !options.live && crate::lock::held(&lock) {
        return Err(format!(
            "the Chief host of {} is running: stop it first (cmux chief stop), or pass --stop-host",
            home.display()
        ));
    }
    if !absent_or_empty(out) {
        return Err(format!("{} is not empty", out.display()));
    }
    create_private_dir(&out.join("files"))?;
    let mut rels = Vec::new();
    walk(&home, &home, &mut rels)?;
    let mut files = Vec::new();
    let session_dir = session_dir_for(&home);
    let session_prefix = format!("tui/{session_dir}/");
    for rel in rels {
        if is_machine_local(&rel, options.without_transcripts) {
            continue;
        }
        // Of `tui/`, only the Chief session's folder moves (its conversations,
        // Chiefs, identity, attachments); the root's machine id and receipt
        // pepper belong to the workspace registry, which stays.
        if rel.starts_with("tui/") && !rel.starts_with(&session_prefix) {
            continue;
        }
        let from = home.join(&rel);
        let to = out.join("files").join(&rel);
        if let Some(parent) = to.parent() {
            std::fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
        }
        let meta = std::fs::metadata(&from).map_err(|e| format!("{}: {e}", from.display()))?;
        let tables = if is_sqlite(&rel) {
            vacuum_into(&from, &to)?;
            Some(table_counts(&to)?)
        } else {
            std::fs::copy(&from, &to).map_err(|e| format!("copying {rel}: {e}"))?;
            None
        };
        let (sha256, size) = sha256_file(&to)?;
        files.push(FileEntry {
            path: rel,
            size,
            sha256,
            mode: mode_of(&meta),
            tables,
        });
    }
    let has_session = files
        .iter()
        .any(|f| f.path.starts_with(&format!("tui/{session_dir}/")));
    let find = |p: &str| {
        files
            .iter()
            .find(|f| f.path == p)
            .and_then(|f| f.tables.as_ref())
    };
    let memory = memory_counts(find("optchat/memory.sqlite3"));
    let conversations = Counts {
        messages: find(&format!("tui/{session_dir}/conversations.sqlite3"))
            .and_then(|t| t.get("message"))
            .copied()
            .unwrap_or(0),
        nodes: 0,
    };
    let manifest = Manifest {
        format: FORMAT.into(),
        source: Source {
            host: hostname(),
            os: std::env::consts::OS.into(),
            arch: std::env::consts::ARCH.into(),
            root: home.to_string_lossy().into_owned(),
        },
        created_at: now_rfc3339(),
        session_dir: has_session.then_some(session_dir),
        without_transcripts: options.without_transcripts,
        memory,
        conversations,
        files,
        reach: crate::migrate_reach::collect(),
        backup_id: Some(backup_id(&home)),
    };
    let text = serde_json::to_string_pretty(&manifest).map_err(|e| e.to_string())?;
    write_private(&out.join("manifest.json"), text.as_bytes())?;
    Ok(manifest)
}

fn create_private_dir(dir: &Path) -> Result<(), String> {
    use std::os::unix::fs::DirBuilderExt;
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
        .map_err(|e| format!("creating {}: {e}", dir.display()))
}

fn write_private(path: &Path, bytes: &[u8]) -> Result<(), String> {
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)
        .map_err(|e| format!("writing {}: {e}", path.display()))?;
    file.write_all(bytes)
        .and_then(|()| file.sync_all())
        .map_err(|e| format!("writing {}: {e}", path.display()))
}

/// Reads and checks a checkpoint's manifest.
pub fn read_manifest(dir: &Path) -> Result<Manifest, String> {
    let path = dir.join("manifest.json");
    let text =
        std::fs::read_to_string(&path).map_err(|e| format!("reading {}: {e}", path.display()))?;
    let manifest: Manifest =
        serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))?;
    if manifest.format != FORMAT {
        return Err(format!(
            "checkpoint format {} is not {FORMAT}: update optchat-chief on this host",
            manifest.format
        ));
    }
    Ok(manifest)
}

/// The SHA-256 of a checkpoint's manifest: the checkpoint's identity.
pub fn manifest_sha(dir: &Path) -> Result<String, String> {
    Ok(sha256_file(&dir.join("manifest.json"))?.0)
}

/// Checks every file of a checkpoint against its manifest.
pub fn verify_checkpoint(dir: &Path) -> Result<Manifest, String> {
    let manifest = read_manifest(dir)?;
    for file in &manifest.files {
        if file.path.split('/').any(|p| p == ".." || p.is_empty()) || file.path.starts_with('/') {
            return Err(format!("unsafe path in manifest: {}", file.path));
        }
        let (sha, size) = sha256_file(&dir.join("files").join(&file.path))?;
        if sha != file.sha256 || size != file.size {
            return Err(format!(
                "{} does not match the manifest (sha256 {sha}, size {size}; expected {}, {})",
                file.path, file.sha256, file.size
            ));
        }
    }
    Ok(manifest)
}

/// What a restore did.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Restored {
    pub home: String,
    pub files: usize,
    pub bytes: u64,
    pub memory: Counts,
    pub conversations: Counts,
    pub session_dir: Option<String>,
    /// Text files whose old home path was rewritten to the new one.
    #[serde(default)]
    pub rewritten: usize,
}

fn target_rel(rel: &str, from_session: Option<&str>, to_session: &str) -> String {
    match from_session {
        Some(from) => match rel.strip_prefix(&format!("tui/{from}/")) {
            Some(rest) => format!("tui/{to_session}/{rest}"),
            None => rel.to_owned(),
        },
        None => rel.to_owned(),
    }
}

/// Restores the checkpoint `from` into `home`, which must be absent or an
/// empty directory. Everything is written into a sibling `.incoming`
/// directory, checked, and then renamed into place.
pub fn restore(from: &Path, home: &Path) -> Result<Restored, String> {
    let manifest = verify_checkpoint(from)?;
    if !absent_or_empty(home) {
        return Err(format!(
            "{} is not empty: a move restores only into an empty home",
            home.display()
        ));
    }
    let parent = home
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .ok_or_else(|| format!("{} has no parent directory", home.display()))?;
    std::fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
    let parent = std::fs::canonicalize(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
    let name = home
        .file_name()
        .ok_or_else(|| format!("{} has no name", home.display()))?;
    let final_home = parent.join(name);
    let to_session = session_dir_for(&final_home);
    let staging = parent.join(format!("{}.incoming", name.to_string_lossy()));
    if staging.exists() {
        std::fs::remove_dir_all(&staging).map_err(|e| format!("{}: {e}", staging.display()))?;
    }
    create_private_dir(&staging)?;
    let mut bytes = 0u64;
    for file in &manifest.files {
        let rel = target_rel(&file.path, manifest.session_dir.as_deref(), &to_session);
        let to = staging.join(&rel);
        if let Some(dir) = to.parent() {
            std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        }
        std::fs::copy(from.join("files").join(&file.path), &to)
            .map_err(|e| format!("restoring {rel}: {e}"))?;
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&to, std::fs::Permissions::from_mode(file.mode))
            .map_err(|e| format!("{rel}: {e}"))?;
        if let Some(expected) = &file.tables {
            let got = table_counts(&to)?;
            if &got != expected {
                return Err(format!("{rel}: row counts differ after restore"));
            }
        }
        bytes += file.size;
    }
    let rewritten = rewrite_home_paths(&staging, &manifest.source.root, &final_home)?;
    create_private_dir(&staging.join("optchat"))?;
    write_private(
        &staging.join("optchat").join("reach-source.json"),
        serde_json::to_string_pretty(&manifest.reach)
            .map_err(|e| e.to_string())?
            .as_bytes(),
    )?;
    if let Some(id) = &manifest.backup_id {
        write_private(&staging.join(BACKUP_ID_FILE), format!("{id}\n").as_bytes())?;
    }
    for dir in ["optchat", "state"] {
        create_private_dir(&staging.join(dir))?;
    }
    let moved_in = serde_json::json!({
        "from_host": manifest.source.host,
        "from_root": manifest.source.root,
        "checkpoint_sha256": manifest_sha(from)?,
        "at": now_rfc3339(),
    });
    write_private(
        &staging.join(MOVED_IN_FILE),
        serde_json::to_string_pretty(&moved_in)
            .map_err(|e| e.to_string())?
            .as_bytes(),
    )?;
    if final_home.exists() {
        std::fs::remove_dir(&final_home).map_err(|e| format!("{}: {e}", final_home.display()))?;
    }
    std::fs::rename(&staging, &final_home)
        .map_err(|e| format!("moving {} into place: {e}", staging.display()))?;
    Ok(Restored {
        home: final_home.to_string_lossy().into_owned(),
        files: manifest.files.len(),
        bytes,
        memory: manifest.memory,
        conversations: manifest.conversations,
        session_dir: manifest.session_dir.map(|_| to_session),
        rewritten,
    })
}

/// The memory backup's repository id of a moved-in home.
pub const BACKUP_ID_FILE: &str = "optchat/backup-id";

/// The id of `home`'s memory backup repository: the one it carried in a
/// move, else its own path's (`paths::home_id`), as before moves existed.
pub fn backup_id(home: &Path) -> String {
    std::fs::read_to_string(home.join(BACKUP_ID_FILE))
        .ok()
        .map(|t| t.trim().to_owned())
        .filter(|t| !t.is_empty() && t.chars().all(|c| c.is_ascii_alphanumeric() || c == '-'))
        .unwrap_or_else(|| crate::paths::home_id(home))
}

/// The largest text file whose home path is rewritten (as build_adopt).
const REWRITE_LIMIT: u64 = 4 << 20;

/// In the restored `*.json`, `*.toml` and `*.md` files, the source's home
/// path becomes the target's, so no preset or setting points back into the
/// old machine's home (cmux-tui build_adopt/chief.rs does the same).
/// SQLite files are left alone. Returns how many files changed.
fn rewrite_home_paths(staging: &Path, from_root: &str, final_home: &Path) -> Result<usize, String> {
    let to_root = final_home.to_string_lossy();
    if from_root.is_empty() || from_root == to_root {
        return Ok(0);
    }
    let mut rels = Vec::new();
    walk(staging, staging, &mut rels)?;
    let mut changed = 0;
    for rel in rels {
        if ![".json", ".toml", ".md"].iter().any(|e| rel.ends_with(e)) {
            continue;
        }
        let path = staging.join(&rel);
        let meta = std::fs::metadata(&path).map_err(|e| format!("{rel}: {e}"))?;
        if meta.len() > REWRITE_LIMIT {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        if !text.contains(from_root) {
            continue;
        }
        let mode = mode_of(&meta);
        std::fs::write(&path, text.replace(from_root, &to_root))
            .map_err(|e| format!("{rel}: {e}"))?;
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode))
            .map_err(|e| format!("{rel}: {e}"))?;
        changed += 1;
    }
    Ok(changed)
}

/// Reads `state/moved.json` of `home`.
pub fn moved(home: &Path) -> Option<Moved> {
    let text = std::fs::read_to_string(home.join(MOVED_FILE)).ok()?;
    serde_json::from_str(&text).ok()
}

/// Marks `home` moved to `to`: its host refuses to start.
pub fn mark_moved(home: &Path, to: &str, checkpoint_sha256: &str) -> Result<(), String> {
    create_private_dir(&home.join("state"))?;
    let moved = Moved {
        to: to.into(),
        at: now_rfc3339(),
        checkpoint_sha256: checkpoint_sha256.into(),
    };
    write_private(
        &home.join(MOVED_FILE),
        serde_json::to_string_pretty(&moved)
            .map_err(|e| e.to_string())?
            .as_bytes(),
    )
}

/// The host's refusal line for a moved home, or None.
pub fn refusal(home: &Path) -> Option<String> {
    moved(home).map(|m| {
        format!(
            "this Chief moved to {} at {}: not starting here (optchat-chief move rollback brings it back)",
            m.to, m.at
        )
    })
}

/// Where a move goes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Target {
    /// Another home on this machine.
    Local(PathBuf),
    /// A home on another machine over SSH; None: the same home name under
    /// the remote's `~/.cmux/chief`.
    Ssh { host: String, home: Option<String> },
    /// The Durable-Object-hosted Cloud Chief (`cloud`, `cloud:staging`,
    /// `cloud:https://…`): migrate_cloud.rs.
    Cloud(String),
}

impl Target {
    /// `local:/path`, `ssh:host[:/path]`, or `cloud`.
    pub fn parse(text: &str) -> Result<Target, String> {
        if let Some(path) = text.strip_prefix("local:") {
            return Ok(Target::Local(PathBuf::from(path)));
        }
        if let Some(rest) = text.strip_prefix("ssh:") {
            let (host, home) = match rest.split_once(':') {
                Some((h, p)) => (h, Some(p.to_owned())),
                None => (rest, None),
            };
            if host.is_empty() || host.starts_with('-') {
                return Err(format!("bad ssh target {text}"));
            }
            return Ok(Target::Ssh {
                host: host.into(),
                home: home.filter(|p| !p.is_empty()),
            });
        }
        if text == "cloud" || text.starts_with("cloud:") {
            crate::migrate_cloud::api_base(text)?;
            return Ok(Target::Cloud(text.to_owned()));
        }
        Err(format!(
            "unknown target {text}: use local:/path, ssh:host[:/path] or cloud"
        ))
    }

    fn describe(&self, remote_home: &str) -> String {
        match self {
            Target::Local(p) => format!("local:{}", p.display()),
            Target::Ssh { host, .. } => format!("ssh:{host}:{remote_home}"),
            Target::Cloud(t) => t.clone(),
        }
    }
}

/// How a move runs.
#[derive(Clone, Debug)]
pub struct MoveOptions {
    pub home: PathBuf,
    pub target: Target,
    pub without_transcripts: bool,
    /// Stop a running host (SIGTERM to the lock's pid) instead of refusing.
    pub stop_host: bool,
    /// The optchat-chief on the target (`optchat-chief` on its PATH).
    pub remote_bin: String,
    /// Plan only: preflight and report, nothing written.
    pub dry_run: bool,
    pub drain_timeout: Duration,
    /// The cloud target's session token file (else CMUX_CLOUD_SESSION_TOKEN).
    pub session_token_file: Option<PathBuf>,
    /// The hosted Chief's name.
    pub cloud_name: String,
    /// Make the hosted Chief the account's default Chief.
    pub cloud_default: bool,
}

/// One step of a move, for the report.
#[derive(Clone, Debug, Serialize)]
pub struct Step {
    pub step: String,
    pub ok: bool,
    pub ms: u128,
    pub detail: String,
}

/// A move's report.
#[derive(Clone, Debug, Serialize)]
pub struct MoveReport {
    pub from: String,
    pub to: String,
    pub moved: bool,
    pub dry_run: bool,
    pub steps: Vec<Step>,
    pub memory: Counts,
    pub conversations: Counts,
    pub bytes: u64,
    /// Why the move stopped; None when it finished (or the dry run passed).
    pub error: Option<String>,
    /// The hosted Chief a cloud move made.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cloud: Option<crate::migrate_cloud::CloudMoved>,
}

fn ssh_bin() -> String {
    crate::cli::env("OPTCHAT_MOVE_SSH").unwrap_or_else(|| "ssh".into())
}

/// Single-quotes `s` for a POSIX shell.
fn sh_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

fn ssh(host: &str, script: &str, stdin: Option<&Path>) -> Result<String, String> {
    let mut cmd = Command::new(ssh_bin());
    cmd.args([
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=15",
        host,
        script,
    ]);
    cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
    if stdin.is_some() {
        cmd.stdin(Stdio::piped());
    } else {
        cmd.stdin(Stdio::null());
    }
    let mut child = cmd.spawn().map_err(|e| format!("ssh {host}: {e}"))?;
    let feeder = match (stdin, child.stdin.take()) {
        (Some(dir), Some(pipe)) => {
            let dir = dir.to_owned();
            Some(std::thread::spawn(move || tar_into(&dir, pipe)))
        }
        _ => None,
    };
    let out = child
        .wait_with_output()
        .map_err(|e| format!("ssh {host}: {e}"))?;
    if let Some(feeder) = feeder {
        feeder
            .join()
            .map_err(|_| "tar thread panicked".to_owned())??;
    }
    if !out.status.success() {
        return Err(format!(
            "ssh {host} failed ({}): {}",
            out.status,
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Where the target's own mover is installed when it has none (this binary,
/// same OS and CPU only).
const REMOTE_MOVER: &str = ".cmux/bin/optchat-chief";

/// An optchat-chief on `host` that knows this checkpoint format: `wanted`
/// when it answers, else the one installed at [`REMOTE_MOVER`], else this
/// binary copied there when the host has this machine's OS and CPU.
fn remote_mover(host: &str, wanted: &str) -> Result<String, String> {
    let knows = |bin: &str| {
        ssh(
            host,
            &format!(
                "{} move probe --home /nonexistent-chief-move-probe",
                sh_quote(bin)
            ),
            None,
        )
        .ok()
        .and_then(|out| serde_json::from_str::<serde_json::Value>(out.trim()).ok())
        .is_some_and(|v| v["format"] == FORMAT)
    };
    if knows(wanted) {
        return Ok(wanted.to_owned());
    }
    if knows(REMOTE_MOVER) {
        return Ok(REMOTE_MOVER.to_owned());
    }
    let uname = ssh(host, "uname -sm", None)?;
    // `uname -sm` of this build's platform.
    let here = match (std::env::consts::OS, std::env::consts::ARCH) {
        ("macos", "aarch64") => "Darwin arm64".to_owned(),
        ("macos", arch) => format!("Darwin {arch}"),
        ("linux", arch) => format!("Linux {arch}"),
        (os, arch) => format!("{os} {arch}"),
    };
    if uname.trim() != here {
        return Err(format!(
            "{host} has no optchat-chief that can restore a Chief ({wanted}), and it is {} (this one is {here}):              install one there and pass --remote-bin",
            uname.trim()
        ));
    }
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let install = format!(
        "mkdir -p .cmux/bin && cat > {t}.part && chmod 755 {t}.part && mv {t}.part {t}",
        t = REMOTE_MOVER
    );
    ssh_stdin_file(host, &install, &exe)?;
    if knows(REMOTE_MOVER) {
        Ok(REMOTE_MOVER.to_owned())
    } else {
        Err(format!(
            "installed {REMOTE_MOVER} on {host}, but it does not answer"
        ))
    }
}

/// Runs `script` on `host` with `file` as its standard input.
fn ssh_stdin_file(host: &str, script: &str, file: &Path) -> Result<(), String> {
    let input = std::fs::File::open(file).map_err(|e| format!("{}: {e}", file.display()))?;
    let out = Command::new(ssh_bin())
        .args([
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=15",
            host,
            script,
        ])
        .stdin(input)
        .output()
        .map_err(|e| format!("ssh {host}: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "ssh {host} failed ({}): {}",
            out.status,
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(())
}

/// Streams `dir` as a tar archive into `pipe`.
fn tar_into(dir: &Path, mut pipe: std::process::ChildStdin) -> Result<(), String> {
    let mut tar = Command::new("tar");
    // No AppleDouble files or extended attributes from a Mac source.
    tar.env("COPYFILE_DISABLE", "1");
    #[cfg(target_os = "macos")]
    tar.args(["--no-mac-metadata", "--no-xattrs"]);
    let mut tar = tar
        .arg("-C")
        .arg(dir)
        .args(["-cf", "-", "."])
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|e| format!("tar: {e}"))?;
    let mut out = tar.stdout.take().ok_or("tar: no stdout")?;
    std::io::copy(&mut out, &mut pipe).map_err(|e| format!("sending checkpoint: {e}"))?;
    drop(pipe);
    let status = tar.wait().map_err(|e| format!("tar: {e}"))?;
    if !status.success() {
        return Err(format!("tar failed: {status}"));
    }
    Ok(())
}

fn lock_pid(lock: &Path) -> Option<i32> {
    std::fs::read_to_string(lock)
        .ok()?
        .lines()
        .next()?
        .trim()
        .parse()
        .ok()
}

fn drain(home: &Path, options: &MoveOptions) -> Result<String, String> {
    let lock = home.join("state").join("host.lock");
    write_private(&home.join(SHUTDOWN_FILE), b"chief move\n")?;
    if !crate::lock::held(&lock) {
        return Ok("host not running; app brain start held".into());
    }
    if !options.stop_host {
        let _ = std::fs::remove_file(home.join(SHUTDOWN_FILE));
        return Err(
            "the Chief host is running: stop it (cmux chief stop) or pass --stop-host".into(),
        );
    }
    let pid = lock_pid(&lock).ok_or("the host lock names no pid")?;
    // SAFETY: plain kill(2) with a pid read from our own lock file.
    unsafe {
        libc::kill(pid, libc::SIGTERM);
    }
    let deadline = Instant::now() + options.drain_timeout;
    while crate::lock::held(&lock) {
        if Instant::now() > deadline {
            let _ = std::fs::remove_file(home.join(SHUTDOWN_FILE));
            return Err(format!(
                "the host (pid {pid}) did not stop within the drain timeout"
            ));
        }
        // Bounded wait for the host process to exit after SIGTERM; the lock
        // file is the only signal it gives.
        std::thread::sleep(Duration::from_millis(200));
    }
    Ok(format!("stopped host pid {pid}"))
}

fn timed<T>(
    steps: &mut Vec<Step>,
    name: &str,
    f: impl FnOnce() -> Result<(T, String), String>,
) -> Result<T, String> {
    let start = Instant::now();
    let result = f();
    let ms = start.elapsed().as_millis();
    match result {
        Ok((value, detail)) => {
            steps.push(Step {
                step: name.into(),
                ok: true,
                ms,
                detail,
            });
            Ok(value)
        }
        Err(e) => {
            steps.push(Step {
                step: name.into(),
                ok: false,
                ms,
                detail: e.clone(),
            });
            Err(e)
        }
    }
}

/// Moves the Chief of `options.home` to `options.target`. The report says
/// each step; on an error (`report.error`) the source keeps answering.
pub fn move_chief(options: &MoveOptions) -> MoveReport {
    let home = std::fs::canonicalize(&options.home).unwrap_or_else(|_| options.home.clone());
    let name = home
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "default".into());
    let remote_home = match &options.target {
        Target::Local(p) => p.to_string_lossy().into_owned(),
        Target::Ssh { home: Some(h), .. } => h.clone(),
        Target::Ssh { home: None, .. } => format!(".cmux/chief/{name}"),
        Target::Cloud(_) => String::new(),
    };
    let mut report = MoveReport {
        from: home.to_string_lossy().into_owned(),
        to: options.target.describe(&remote_home),
        moved: false,
        dry_run: options.dry_run,
        steps: Vec::new(),
        memory: Counts::default(),
        conversations: Counts::default(),
        bytes: 0,
        error: None,
        cloud: None,
    };
    macro_rules! fail {
        ($e:expr) => {{
            report.error = Some($e);
            return report;
        }};
    }
    if let Some(m) = moved(&home) {
        let e = format!("this Chief already moved to {}", m.to);
        report.steps.push(Step {
            step: "preflight".into(),
            ok: false,
            ms: 0,
            detail: e.clone(),
        });
        fail!(e);
    }
    // Preflight: the target home is empty and knows the format.
    let preflight = timed(&mut report.steps, "preflight", || match &options.target {
        Target::Local(p) => {
            if absent_or_empty(p) {
                Ok((
                    options.remote_bin.clone(),
                    format!("{} is empty", p.display()),
                ))
            } else {
                Err(format!("{} is not empty", p.display()))
            }
        }
        Target::Ssh { host, .. } => {
            let bin = remote_mover(host, &options.remote_bin)?;
            let script = format!(
                "{} move probe --home {}",
                sh_quote(&bin),
                sh_quote(&remote_home)
            );
            let out = ssh(host, &script, None)?;
            let probe: serde_json::Value = serde_json::from_str(out.trim())
                .map_err(|e| format!("probe answer {out:?}: {e}"))?;
            if probe["format"] != FORMAT {
                return Err(format!(
                    "target optchat-chief reads {}, not {FORMAT}",
                    probe["format"]
                ));
            }
            if probe["empty"] != true {
                return Err(format!("target home {} is not empty", probe["home"]));
            }
            let detail = format!(
                "{} ({} {}, {bin})",
                probe["home"], probe["os"], probe["arch"]
            );
            Ok((bin, detail))
        }
        Target::Cloud(t) => {
            let base = crate::migrate_cloud::api_base(t)?;
            let token = crate::migrate_cloud::session_token(options.session_token_file.as_deref())?;
            let api = crate::migrate_cloud::Api::new(base.clone(), token);
            api.probe_brains()?;
            Ok((
                String::new(),
                format!("{base}: signed in, Cloud Chief brains on"),
            ))
        }
    });
    let remote_bin = match preflight {
        Ok(bin) => bin,
        Err(e) => fail!(e),
    };
    if options.dry_run {
        return report;
    }
    if let Err(e) = timed(&mut report.steps, "drain", || {
        drain(&home, options).map(|d| ((), d))
    }) {
        fail!(e);
    }
    let undo_drain = |home: &Path| {
        let _ = std::fs::remove_file(home.join(SHUTDOWN_FILE));
    };
    let parent = home.parent().unwrap_or(Path::new("/tmp"));
    let tmp = parent.join(format!(".chief-move-{}-{}", name, std::process::id()));
    let _ = std::fs::remove_dir_all(&tmp);
    let check = timed(&mut report.steps, "checkpoint", || {
        let m = checkpoint(
            &home,
            &tmp,
            &CheckpointOptions {
                without_transcripts: options.without_transcripts,
                live: false,
            },
        )?;
        verify_checkpoint(&tmp)?;
        let detail = format!(
            "{} files, {} memory messages, {} conversation messages",
            m.files.len(),
            m.memory.messages,
            m.conversations.messages
        );
        Ok((m, detail))
    });
    let manifest = match check {
        Ok(m) => m,
        Err(e) => {
            let _ = std::fs::remove_dir_all(&tmp);
            undo_drain(&home);
            fail!(e);
        }
    };
    report.memory = manifest.memory.clone();
    report.conversations = manifest.conversations.clone();
    report.bytes = manifest.files.iter().map(|f| f.size).sum();
    let sha = manifest_sha(&tmp).unwrap_or_default();
    if let Target::Cloud(t) = &options.target {
        let copied = timed(&mut report.steps, "transfer+verify", || {
            let base = crate::migrate_cloud::api_base(t)?;
            let token = crate::migrate_cloud::session_token(options.session_token_file.as_deref())?;
            let api = crate::migrate_cloud::Api::new(base, token);
            let moved = crate::migrate_cloud::move_to_cloud(
                &api,
                &tmp,
                &manifest,
                &sha,
                &options.cloud_name,
                options.cloud_default,
            )?;
            let detail = format!(
                "hosted Chief {} ({} history messages, {} memory messages, memory {})",
                moved.chief, moved.history_imported, moved.memory_messages, moved.memory_state
            );
            Ok((moved, detail))
        });
        let _ = std::fs::remove_dir_all(&tmp);
        let moved = match copied {
            Ok(m) => m,
            Err(e) => {
                undo_drain(&home);
                fail!(e);
            }
        };
        let to = format!("cloud:{}/{}", moved.api, moved.chief);
        report.to = to.clone();
        report.cloud = Some(moved);
        if let Err(e) = timed(&mut report.steps, "commit", || {
            mark_moved(&home, &to, &sha).map(|()| ((), format!("source marked moved to {to}")))
        }) {
            undo_drain(&home);
            fail!(e);
        }
        report.moved = true;
        return report;
    }
    let restored = timed(&mut report.steps, "transfer+restore", || {
        match &options.target {
            Target::Local(p) => {
                let r = restore(&tmp, p)?;
                Ok((
                    r.clone(),
                    format!("restored {} files into {}", r.files, r.home),
                ))
            }
            Target::Ssh { host, .. } => {
                let stage = format!("{remote_home}.checkpoint");
                let recv = format!(
                    "rm -rf {s} && mkdir -p -m 700 {s} && tar -C {s} -xf -",
                    s = sh_quote(&stage)
                );
                ssh(host, &recv, Some(&tmp))?;
                let script = format!(
                    "{b} move restore --from {s} --home {h} && rm -rf {s}",
                    b = sh_quote(&remote_bin),
                    s = sh_quote(&stage),
                    h = sh_quote(&remote_home)
                );
                let out = ssh(host, &script, None)?;
                let r: Restored = serde_json::from_str(out.trim())
                    .map_err(|e| format!("restore answer {out:?}: {e}"))?;
                Ok((
                    r.clone(),
                    format!("restored {} files into {host}:{}", r.files, r.home),
                ))
            }
            Target::Cloud(_) => unreachable!("handled above"),
        }
    });
    let _ = std::fs::remove_dir_all(&tmp);
    let restored = match restored {
        Ok(r) => r,
        Err(e) => {
            undo_drain(&home);
            fail!(e);
        }
    };
    let verify = timed(&mut report.steps, "verify", || {
        if restored.memory != manifest.memory || restored.conversations != manifest.conversations {
            return Err(format!(
                "target counts differ: memory {:?} vs {:?}, conversations {:?} vs {:?}",
                restored.memory, manifest.memory, restored.conversations, manifest.conversations
            ));
        }
        if let Target::Ssh { host, .. } = &options.target {
            let script = format!(
                "{} move verify --home {}",
                sh_quote(&remote_bin),
                sh_quote(&restored.home)
            );
            let out = ssh(host, &script, None)?;
            let v: serde_json::Value = serde_json::from_str(out.trim())
                .map_err(|e| format!("verify answer {out:?}: {e}"))?;
            if v["memory"]["messages"] != manifest.memory.messages
                || v["conversations"]["messages"] != manifest.conversations.messages
            {
                return Err(format!("target reads different counts: {v}"));
            }
        } else {
            let v = verify_home(Path::new(&restored.home))?;
            if v.memory != manifest.memory || v.conversations != manifest.conversations {
                return Err(format!("target reads different counts: {v:?}"));
            }
        }
        Ok((
            (),
            format!(
                "{} memory messages, {} conversation messages",
                manifest.memory.messages, manifest.conversations.messages
            ),
        ))
    });
    if let Err(e) = verify {
        undo_drain(&home);
        fail!(e);
    }
    let to = options.target.describe(&restored.home);
    report.to = to.clone();
    if let Err(e) = timed(&mut report.steps, "commit", || {
        mark_moved(&home, &to, &sha).map(|()| ((), format!("source marked moved to {to}")))
    }) {
        undo_drain(&home);
        fail!(e);
    }
    report.moved = true;
    report
}

/// Sends one message to where this home's Chief moved (a cloud move only)
/// and returns its reply: the first-turn check after a move.
fn ask_moved(home: &Path, text: &str, token_file: Option<&Path>) -> Result<String, String> {
    if text.is_empty() {
        return Err("move ask needs --text".into());
    }
    let m = moved(home).ok_or("this home has not moved")?;
    let rest = m
        .to
        .strip_prefix("cloud:")
        .ok_or("move ask reaches a cloud Chief; on an ssh target run `cmux chief --chief-home DIR -p TEXT` there")?;
    let (base, chief) = rest.rsplit_once('/').ok_or("bad cloud target")?;
    let api = crate::migrate_cloud::Api::new(
        base.to_owned(),
        crate::migrate_cloud::session_token(token_file)?,
    );
    let conversation = crate::migrate_cloud::chief_main_conversation(chief);
    crate::migrate_cloud::first_turn(&api, chief, &conversation, text, Duration::from_secs(600))
}

/// Milliseconds since the epoch.
pub fn now_millis() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis())
}

/// Whether the host of `home` is in a turn: the newest trace file's last
/// `turn.start` has no `turn.end` after it.
pub fn turn_running(home: &Path) -> bool {
    let Ok(entries) = std::fs::read_dir(home.join("optchat").join("traces")) else {
        return false;
    };
    let mut files: Vec<PathBuf> = entries.filter_map(Result::ok).map(|e| e.path()).collect();
    files.sort();
    let Some(text) = files.last().and_then(|f| std::fs::read_to_string(f).ok()) else {
        return false;
    };
    let mut running = false;
    for line in text.lines() {
        if line.contains(r#""ev":"turn.start""#) {
            running = true;
        } else if line.contains(r#""ev":"turn.end""#) {
            running = false;
        }
    }
    running
}

/// Waits until the host of `home` has been between turns for 3 s (a move
/// the Chief started from its own turn runs after that turn ends).
pub fn wait_turn_end(home: &Path, limit: Duration) -> Result<(), String> {
    let deadline = Instant::now() + limit;
    let mut idle_since: Option<Instant> = None;
    loop {
        if turn_running(home) {
            idle_since = None;
        } else if idle_since.get_or_insert_with(Instant::now).elapsed() >= Duration::from_secs(3) {
            return Ok(());
        }
        if Instant::now() > deadline {
            return Err("the Chief's turn did not end within the drain timeout".into());
        }
        // Bounded wait on the trace file: the host offers no turn-end signal
        // to another process.
        std::thread::sleep(Duration::from_millis(500));
    }
}

/// Runs this move again as its own process, detached from the caller (a
/// Chief's turn), with `--after-turn --stop-host`; the report goes to
/// `state/move.json`, the output to `state/move.log`.
fn detach(home: &Path, args: &[String]) -> i32 {
    use std::os::unix::process::CommandExt;
    let exe = match std::env::current_exe() {
        Ok(e) => e,
        Err(e) => {
            eprintln!("optchat-chief move: {e}");
            return 1;
        }
    };
    let mut rest: Vec<String> = args.iter().filter(|a| *a != "--detach").cloned().collect();
    for flag in ["--after-turn", "--stop-host"] {
        if !rest.iter().any(|a| a == flag) {
            rest.push(flag.into());
        }
    }
    if !rest
        .iter()
        .any(|a| a == "--home" || a.starts_with("--home="))
    {
        rest.push("--home".into());
        rest.push(home.to_string_lossy().into_owned());
    }
    let _ = create_private_dir(&home.join("state"));
    let log = match std::fs::File::create(home.join("state").join("move.log")) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("optchat-chief move: state/move.log: {e}");
            return 1;
        }
    };
    let mut cmd = Command::new(exe);
    cmd.arg("move").args(&rest).stdin(Stdio::null());
    if let Ok(err) = log.try_clone() {
        cmd.stderr(err);
    }
    cmd.stdout(log);
    // SAFETY: setsid(2) in the child before exec, async-signal-safe: the
    // mover leaves the turn's session, so stopping the turn leaves it running.
    unsafe {
        cmd.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }
    match cmd.spawn() {
        Ok(child) => {
            println!(
                "{}",
                serde_json::json!({
                    "scheduled": true,
                    "pid": child.id(),
                    "report": home.join("state").join("move.json"),
                    "note": "the move starts when this turn ends: answer the person now; the old copy stays for rollback",
                })
            );
            0
        }
        Err(e) => {
            eprintln!("optchat-chief move: {e}");
            1
        }
    }
}

/// What a home holds now (read from its stores).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct HomeCounts {
    pub home: String,
    pub memory: Counts,
    pub conversations: Counts,
    pub session_dir: String,
    pub moved: Option<Moved>,
}

/// Counts what `home` holds, from its live stores.
pub fn verify_home(home: &Path) -> Result<HomeCounts, String> {
    let home = std::fs::canonicalize(home).map_err(|e| format!("{}: {e}", home.display()))?;
    let memory_db = home.join("optchat").join("memory.sqlite3");
    let memory = memory_counts(Some(&table_counts(&memory_db)?));
    let session_dir = session_dir_for(&home);
    let conv = home
        .join("tui")
        .join(&session_dir)
        .join("conversations.sqlite3");
    let conversations = if conv.exists() {
        Counts {
            messages: table_counts(&conv)?.get("message").copied().unwrap_or(0),
            nodes: 0,
        }
    } else {
        Counts::default()
    };
    Ok(HomeCounts {
        home: home.to_string_lossy().into_owned(),
        memory,
        conversations,
        session_dir,
        moved: moved(&home),
    })
}

/// Rolls a move back: the target (when reachable) is marked moved back, the
/// source's markers are removed so it answers again.
pub fn rollback(
    home: &Path,
    remote_bin: &str,
    token_file: Option<&Path>,
) -> Result<String, String> {
    let m = moved(home).ok_or_else(|| format!("{} was not moved", home.display()))?;
    let source = format!("{}:{}", hostname(), home.display());
    let target = m.to.clone();
    if let Some(path) = target.strip_prefix("local:") {
        let path = Path::new(path);
        if crate::lock::held(&path.join("state").join("host.lock")) {
            return Err(format!(
                "the Chief host at {} is running: stop it first",
                path.display()
            ));
        }
        mark_moved(
            path,
            &format!("local:{}", home.display()),
            &m.checkpoint_sha256,
        )?;
    } else if let Some(rest) = target.strip_prefix("cloud:") {
        // `cloud:<api>/<chief>`: the hosted Chief's brain goes off; its copy stays.
        let (api_base, chief) = rest
            .rsplit_once('/')
            .ok_or_else(|| format!("bad target in moved.json: {target}"))?;
        let token = crate::migrate_cloud::session_token(token_file)?;
        crate::migrate_cloud::Api::new(api_base.to_owned(), token).brain_off(chief)?;
    } else if let Some(rest) = target.strip_prefix("ssh:") {
        let (host, path) = rest
            .split_once(':')
            .ok_or_else(|| format!("bad target in moved.json: {target}"))?;
        let script = format!(
            "{} move retire --home {} --to {}",
            sh_quote(remote_bin),
            sh_quote(path),
            sh_quote(&source)
        );
        ssh(host, &script, None)?;
    }
    std::fs::remove_file(home.join(MOVED_FILE)).map_err(|e| e.to_string())?;
    let _ = std::fs::remove_file(home.join(SHUTDOWN_FILE));
    let there = if target.starts_with("cloud:") {
        "its brain is off (the hosted copy stays, with what it learned after the move)"
    } else {
        "is marked moved back (its host will not start)"
    };
    Ok(format!(
        "rolled back: {} answers again; {target} {there}",
        home.display()
    ))
}

/// `optchat-chief move ...`.
pub const USAGE: &str = "optchat-chief move --to local:/path|ssh:HOST[:/path]|cloud[:staging|:URL] [--home DIR] [--stop-host] [--without-transcripts] [--remote-bin PATH]
                   [--dry-run] [--drain-timeout SECS] [--detach] [--after-turn] [--session-token-file FILE] [--name NAME] [--cloud-default]
                                   move this Chief: drain, checkpoint, send, restore, verify, mark the source moved.
                                   --detach: a Chief moving itself: the move runs after its turn ends (report: state/move.json).
                                   cloud: the account's session from CMUX_CLOUD_SESSION_TOKEN or a 0600 file; never printed
optchat-chief move rollback [--home DIR] [--remote-bin PATH]   the source answers again; the target is marked moved back
optchat-chief move checkpoint --out DIR [--home DIR] [--without-transcripts] [--live]
optchat-chief move restore --from DIR --home DIR            into an empty home (prints JSON)
optchat-chief move verify [--home DIR]                      what a home holds (JSON)
optchat-chief move ask --text TEXT [--home DIR] [--session-token-file FILE]  one message to the cloud Chief this home moved to; prints its reply
optchat-chief move reach [--home DIR]                       probe from here what the moved Chief reached before (SSH hosts, tailnet, fleet, model route)
optchat-chief move probe --home DIR                         can this host take a Chief there (JSON)
optchat-chief move retire --home DIR --to WHERE             mark a home moved (its host will not start)";

struct Args {
    words: Vec<String>,
    values: BTreeMap<String, String>,
    switches: Vec<String>,
}

const SWITCHES: &[&str] = &[
    "stop-host",
    "without-transcripts",
    "dry-run",
    "live",
    "json",
    "cloud-default",
    "detach",
    "after-turn",
];

fn parse(args: &[String]) -> Args {
    let mut out = Args {
        words: Vec::new(),
        values: BTreeMap::new(),
        switches: Vec::new(),
    };
    let mut i = 0;
    while i < args.len() {
        let a = &args[i];
        if let Some(key) = a.strip_prefix("--") {
            if SWITCHES.contains(&key) {
                out.switches.push(key.into());
            } else if let Some((k, v)) = key.split_once('=') {
                out.values.insert(k.into(), v.into());
            } else if i + 1 < args.len() {
                out.values.insert(key.into(), args[i + 1].clone());
                i += 1;
            }
        } else {
            out.words.push(a.clone());
        }
        i += 1;
    }
    out
}

fn expand_home(p: &str) -> PathBuf {
    let user_home = std::env::var_os("HOME").map(PathBuf::from);
    match (p.strip_prefix("~/"), user_home) {
        (Some(rest), Some(h)) => h.join(rest),
        (None, Some(h)) if Path::new(p).is_relative() => h.join(p),
        _ => PathBuf::from(p),
    }
}

fn json<T: Serialize>(value: &T) -> String {
    serde_json::to_string(value).unwrap_or_else(|e| format!("{{\"error\":{:?}}}", e.to_string()))
}

/// Runs `move ...` (arguments after `move`); prints and returns the exit code.
pub fn cli(args: &[String]) -> i32 {
    let a = parse(args);
    let has = |s: &str| a.switches.iter().any(|x| x == s);
    let home = a
        .values
        .get("home")
        .or_else(|| a.values.get("mux-home"))
        .map(|p| expand_home(p))
        .unwrap_or_else(crate::paths::mux_home);
    let remote_bin = a
        .values
        .get("remote-bin")
        .cloned()
        .unwrap_or_else(|| "optchat-chief".into());
    let result: Result<String, String> = match a.words.first().map(String::as_str) {
        Some("help") => Ok(USAGE.into()),
        Some("checkpoint") => match a.values.get("out") {
            None => Err(format!("move checkpoint needs --out DIR\n{USAGE}")),
            Some(out) => checkpoint(
                &home,
                Path::new(out),
                &CheckpointOptions {
                    without_transcripts: has("without-transcripts"),
                    live: has("live"),
                },
            )
            .map(|m| {
                json(&serde_json::json!({
                    "files": m.files.len(),
                    "memory": m.memory,
                    "conversations": m.conversations,
                    "session_dir": m.session_dir,
                }))
            }),
        },
        Some("restore") => match a.values.get("from") {
            None => Err(format!("move restore needs --from DIR\n{USAGE}")),
            Some(from) => restore(&expand_home(from), &home).map(|r| json(&r)),
        },
        Some("verify") => verify_home(&home).map(|v| json(&v)),
        Some("reach") => crate::migrate_reach::probe(&home).map(|v| json(&v)),
        Some("ask") => ask_moved(
            &home,
            a.values.get("text").map(String::as_str).unwrap_or(""),
            a.values
                .get("session-token-file")
                .map(|p| expand_home(p))
                .as_deref(),
        ),
        Some("probe") => {
            let empty = absent_or_empty(&home);
            Ok(json(&serde_json::json!({
                "format": FORMAT,
                "home": home.to_string_lossy(),
                "empty": empty,
                "os": std::env::consts::OS,
                "arch": std::env::consts::ARCH,
                "host": hostname(),
            })))
        }
        Some("retire") => match a.values.get("to") {
            None => Err(format!("move retire needs --to WHERE\n{USAGE}")),
            Some(to) => {
                if crate::lock::held(&home.join("state").join("host.lock")) {
                    Err("the Chief host here is running: stop it first".into())
                } else {
                    mark_moved(&home, to, "")
                        .map(|()| format!("{} marked moved to {to}", home.display()))
                }
            }
        },
        Some("rollback") => {
            let file = a.values.get("session-token-file").map(|p| expand_home(p));
            rollback(&home, &remote_bin, file.as_deref())
        }
        Some(other) => Err(format!("unknown move verb {other}\n{USAGE}")),
        None => match a.values.get("to") {
            None => Err(format!("move needs --to TARGET\n{USAGE}")),
            Some(to) => match Target::parse(to) {
                Err(e) => Err(e),
                Ok(target) => {
                    let options = MoveOptions {
                        home: home.clone(),
                        target,
                        without_transcripts: has("without-transcripts"),
                        stop_host: has("stop-host"),
                        remote_bin,
                        dry_run: has("dry-run"),
                        drain_timeout: Duration::from_secs(
                            a.values
                                .get("drain-timeout")
                                .and_then(|s| s.parse().ok())
                                .unwrap_or(1800),
                        ),
                        session_token_file: a
                            .values
                            .get("session-token-file")
                            .map(|p| expand_home(p)),
                        cloud_name: a
                            .values
                            .get("name")
                            .cloned()
                            .unwrap_or_else(|| "Chief".into()),
                        cloud_default: has("cloud-default"),
                    };
                    if has("detach") {
                        return detach(&home, args);
                    }
                    if has("after-turn")
                        && let Err(e) = wait_turn_end(&home, options.drain_timeout)
                    {
                        eprintln!("optchat-chief move: {e}");
                        return 1;
                    }
                    let report = move_chief(&options);
                    let _ = write_private(
                        &home.join("state").join("move.json"),
                        json(&report).as_bytes(),
                    );
                    match report.error.clone() {
                        None => Ok(json(&report)),
                        Some(e) => {
                            println!("{}", json(&report));
                            Err(e)
                        }
                    }
                }
            },
        },
    };
    match result {
        Ok(out) => {
            println!("{out}");
            0
        }
        Err(e) => {
            eprintln!("optchat-chief move: {e}");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_dir_matches_a_real_chief_home() {
        // Lawrence's NIGHTLY Chief home and the directory its daemon made.
        assert_eq!(
            session_dir_for(Path::new("/Users/lawrence/.cmux/chief/default")),
            "cmux-chief-2e448bc2-5091cba499ba5899"
        );
    }

    #[test]
    fn machine_local_paths() {
        for local in [
            "state/host.lock",
            "optchat/tools.sock",
            "optchat/memory.sqlite3-wal",
            "optchat/traces/a.jsonl",
            "optchat/claude/settings.json",
            "c/x/optchat/session/CLAUDE.md",
            "acpmux/run/a",
            "acpmux/login-env.json",
            "tui/terminal-hosts-12/a.live",
            "tui/session-locks/x",
            "state/moved.json",
            "state/shutdown",
            "host.log",
        ] {
            assert!(is_machine_local(local, false), "{local}");
        }
        for kept in [
            "optchat/memory.sqlite3",
            "optchat/chat/main/2026-10-20.jsonl",
            "optchat/person.md",
            "acpmux/sessions/s/events",
            "tui/cmux-chief-1-2/conversations.sqlite3",
        ] {
            assert!(!is_machine_local(kept, false), "{kept}");
        }
        assert!(is_machine_local("acpmux/sessions/s/events", true));
    }

    #[test]
    fn targets_parse() {
        assert_eq!(
            Target::parse("ssh:cmux-lawrence").unwrap(),
            Target::Ssh {
                host: "cmux-lawrence".into(),
                home: None
            }
        );
        assert_eq!(
            Target::parse("ssh:vm:/home/u/.cmux/chief/x").unwrap(),
            Target::Ssh {
                host: "vm".into(),
                home: Some("/home/u/.cmux/chief/x".into())
            }
        );
        assert_eq!(
            Target::parse("local:/tmp/x").unwrap(),
            Target::Local("/tmp/x".into())
        );
        assert_eq!(
            Target::parse("cloud").unwrap(),
            Target::Cloud("cloud".into())
        );
        assert!(Target::parse("cloud:http://evil.example").is_err());
        assert!(Target::parse("ssh:-oProxyCommand=x").is_err());
        assert!(Target::parse("mini").is_err());
    }
}
