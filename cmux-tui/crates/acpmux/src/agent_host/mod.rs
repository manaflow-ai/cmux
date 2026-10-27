//! Agent hosts: one `__agent-host` process per running agent session, so an
//! agent outlives the acpmux daemon that started it (an update, a crash, a
//! restart) and a new daemon adopts it. The same model as cmux terminal hosts
//! (plans/cmux-next/durable-sessions.md section 2).
//!
//! The host owns the harness process group, its stdio pipes and, for Claude
//! stream-json harnesses, the translator, so every host speaks plain ACP to
//! its controller. It numbers every line it moves (`hseq`) and keeps each
//! entry until the controller acknowledges that the entry is in the session
//! log, so a controller that dies mid-turn loses nothing: its successor
//! resumes after the last entry it logged.
//!
//! Wire (`agent-host/1`): length-prefixed JSON frames (`u32` big-endian length,
//! then one JSON object with a `t` tag) on a 0600 Unix socket. The controller
//! opens with [`ControllerFrame::Hello`]; the host answers
//! [`HostFrame::HostHello`] or [`HostFrame::Incompatible`]. Discovery records
//! are JSON files next to the socket, written atomically, with a liveness
//! lock file the host holds for its whole life.

#[cfg(unix)]
pub mod host;
/// Windows port: the agent host process comes in a later landing.
#[cfg(not(unix))]
pub mod host {
    pub fn main() -> anyhow::Result<()> {
        Err(crate::platform::unsupported("the agent host"))
    }
}
pub mod link;
pub mod program_wait;
#[cfg(unix)]
pub(crate) mod record_watch;
pub(crate) mod scope;
pub mod sweep;
#[cfg(unix)]
pub(crate) mod tree;
mod wait;
pub use wait::{
    BOOTSTRAP_BUDGET, HostTimeout, QUERY_BUDGET, dead, death_watches, wait_dead_async,
    wait_dead_within, within, within_on,
};

use anyhow::{Context, Result, anyhow, bail};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::{Path, PathBuf};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// Oldest and newest host protocol this build speaks.
pub const PROTOCOL_MIN: u16 = 1;
pub const PROTOCOL_MAX: u16 = 2;
/// The protocol from which a `line` may ask for a receipt (`WRITTEN_METHOD`).
pub const RECEIPT_VERSION: u16 = 2;
/// The receipt for a `line` (protocol 2): a `tap` entry (`dir = out`) carrying this
/// notification, `{receipt, written}`, once its lines are written to the harness (`written:
/// true`) or can never be (its stdin closed: `false`). An entry, not a frame of its own, so it
/// is retained until acknowledged, replayed to the next controller, and known to every build.
pub const WRITTEN_METHOD: &str = "_acpmux/host_written";
/// Discovery record schema this build writes and reads.
pub const RECORD_VERSION: u32 = 1;
/// Largest frame either side accepts.
pub const MAX_FRAME: usize = 64 << 20;
/// Bytes of unacknowledged entries a host keeps before it stops reading the
/// harness's stdout. Back-pressure, never a drop.
pub const DEFAULT_BUFFER_CAP: usize = 64 << 20;
/// Argument that selects the host mode of the acpmux binary.
pub const HOST_ARG: &str = "__agent-host";

/// Controller to host.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum ControllerFrame {
    Hello {
        min: u16,
        max: u16,
        /// Owner token from the record, lowercase hex.
        token: String,
        controller_build: String,
    },
    /// Send every retained entry after `after`, then live entries.
    Resume { after: u64 },
    /// One ACP message for the harness. The host translates it when the
    /// harness speaks Claude stream-json, writes it, and echoes the written
    /// lines as `tap` entries. `receipt` (protocol 2): the host logs its
    /// receipt (`WRITTEN_METHOD`) once every line of it is written to the harness.
    Line {
        msg: Value,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        receipt: Option<u64>,
    },
    /// Entries up to `h` are in the controller's log; the host may drop them.
    Ack { h: u64 },
    /// End the harness process group: SIGTERM, then SIGKILL after `grace_ms`.
    Terminate { grace_ms: u64 },
    /// The controller is going away; the host answers `detach_ack` after
    /// every prior frame and keeps the harness running.
    Detach,
    /// Ask for the translator's state (Claude stream-json harnesses).
    Query { id: u64 },
}

/// Host to controller.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum HostFrame {
    HostHello {
        version: u16,
        host_build: String,
        incarnation: String,
        harness_pid: Option<u32>,
        /// Last entry sequence assigned.
        last_h: u64,
        /// Last entry the controller acknowledged.
        acked_h: u64,
        /// Largest numeric JSON-RPC request id the controller sent the
        /// harness through this host, so a new controller never reuses one.
        max_out_id: i64,
        /// The harness exit code once it exited (`Some(None)` = killed).
        exited: Option<Option<i32>>,
    },
    Incompatible {
        min: u16,
        max: u16,
        host_build: String,
    },
    Entry {
        h: u64,
        e: Entry,
    },
    DetachAck,
    TerminateAck,
    /// Another owner connection took over this host.
    Superseded,
    /// Answer to `query`; all fields are null for a native ACP harness.
    QueryReply {
        id: u64,
        claude_session_id: Option<String>,
        modes: Option<Value>,
        config_options: Option<Value>,
    },
}

/// One retained, numbered event. Each entry becomes exactly one record in
/// the controller's session log (`hostSeq = h`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "k", rename_all = "snake_case")]
pub enum Entry {
    /// Log only: a line written to the harness (`dir = out`) or a raw Claude
    /// line kept beside its translation (`dir = in`).
    Tap { dir: TapDir, msg: Value },
    /// An ACP message from the harness: logged, then dispatched.
    In { msg: Value },
    /// One stderr line.
    Err { line: String },
    /// The harness process group ended.
    Exit { code: Option<i32> },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TapDir {
    In,
    Out,
}

impl Entry {
    /// Retained size, for the buffer cap.
    pub fn weight(&self) -> usize {
        match self {
            Entry::Tap { msg, .. } | Entry::In { msg } => msg.to_string().len() + 32,
            Entry::Err { line } => line.len() + 32,
            Entry::Exit { .. } => 32,
        }
    }
}

/// What the controller asks the host to run. Sent once on the private
/// bootstrap pipe; never written to disk (it carries the environment), but
/// for the caller token the host keeps in its record (`HostRecord::caller_token`).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SpawnSpec {
    pub session_id: String,
    pub program: String,
    pub args: Vec<String>,
    /// The complete environment of the harness (the host clears its own).
    pub env: Vec<(String, String)>,
    pub cwd: PathBuf,
    /// Present when the harness speaks Claude stream-json.
    pub translator: Option<TranslatorSpec>,
    /// The harness is `codex app-server`, bridged in the host
    /// (`codex_app_server.rs`). Decided from the profile's command line
    /// before its CODEX_PATH picks the binary, whatever that binary is named.
    #[serde(default)]
    pub codex_bridge: bool,
    /// Directory for the record, socket fallback aside.
    pub hosts_dir: PathBuf,
    pub socket: PathBuf,
    /// Bytes of unacknowledged entries before back-pressure.
    pub buffer_cap: usize,
    /// The local router's owner FIFO of the daemon's home; the host holds
    /// a write end for its whole life (`daemon::router_owner_fifo`).
    #[serde(default)]
    pub router_owner_fifo: Option<PathBuf>,
    /// The folder the harness must exec in, by identity: a sub-session's checked folder
    /// (`cwd_pin.rs`). The host's harness spawn fails when `cwd` leads elsewhere by then.
    #[serde(default)]
    pub cwd_pin: Option<crate::cwd_pin::CwdPin>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TranslatorSpec {
    pub acp_session_id: String,
    pub mode: String,
    pub model: String,
    pub effort: String,
    /// Claude Code's fast mode at spawn (the session's `fast-mode` option).
    #[serde(default)]
    pub fast: bool,
    /// Claude's own session id when it is known at spawn.
    pub claude_session_id: Option<String>,
}

impl SpawnSpec {
    /// The session's caller token in the harness env, which the host keeps in its record.
    pub fn caller_token(&self) -> Option<String> {
        let key = crate::hub::person::CALLER_TOKEN_ENV;
        self.env.iter().find(|(k, _)| k == key).map(|(_, v)| v.clone())
    }
}

/// The host's answer on the bootstrap pipe.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum BootstrapReply {
    Ready { record: HostRecord },
    SpawnFailed { message: String },
}

/// Discovery record `<hosts_dir>/<session id>.json`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostRecord {
    pub record_version: u32,
    pub session_id: String,
    pub incarnation: String,
    pub host_pid: u32,
    /// Random per process; names the liveness lock file.
    pub start_nonce: String,
    pub harness_pid: Option<u32>,
    pub owner_token: String,
    /// The session's caller token its harness started with (`hub/person.rs`
    /// (a)): the next daemon run that adopts this host knows the agent and
    /// its MCP servers by it. Owner-only like `owner_token`, which grants
    /// more (the harness's own stdio). None: a host of an older build.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub caller_token: Option<String>,
    pub protocol_min: u16,
    pub protocol_max: u16,
    pub host_build: String,
    pub socket: PathBuf,
}

/// A record file that this build cannot read, and what it could parse.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnreadableRecord {
    pub session_id: String,
    pub path: PathBuf,
    pub record_version: Option<u64>,
    pub host_pid: Option<u32>,
    pub harness_pid: Option<u32>,
    /// `start_nonce` when it is lowercase hex: it names the live lock.
    pub start_nonce: Option<String>,
    pub reason: String,
}

/// Hosts directory of this acpmux home.
pub fn hosts_dir() -> PathBuf {
    crate::config::home().join("hosts")
}

pub fn record_path(dir: &Path, session_id: &str) -> PathBuf {
    dir.join(format!("{session_id}.json"))
}

fn live_path(dir: &Path, session_id: &str, nonce: &str) -> PathBuf {
    dir.join(format!("{session_id}.{nonce}.live"))
}

/// Where host `record`'s live lock may be: the pool, then the hosts directory (a pooled host's
/// lock moves there when a session takes it, so a move between the two is not missed), then its
/// socket's directory, its own when the path was short enough.
pub fn live_lock_dirs(record: &HostRecord) -> Vec<PathBuf> {
    let hosts = hosts_dir();
    let mut dirs = vec![pool_dir(&hosts), hosts];
    if let Some(own) = record.socket.parent().filter(|d| !dirs.iter().any(|x| x == d)) {
        dirs.push(own.to_path_buf());
    }
    dirs
}

/// Whether host incarnation `nonce` of `session_id` keeps its live lock in `dir`.
pub fn live_lock_exists(dir: &Path, session_id: &str, nonce: &str) -> bool {
    live_path(dir, session_id, nonce).exists()
}

/// Socket for one host: next to the record when the path is short enough for
/// `sun_path`, else in the private per-user directory acpmux already uses.
#[cfg(unix)]
pub fn socket_path(dir: &Path, session_id: &str) -> PathBuf {
    let preferred = dir.join(format!("{session_id}.sock"));
    if preferred.as_os_str().len() < 100 {
        return preferred;
    }
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for b in dir.to_string_lossy().bytes() {
        hash ^= b as u64;
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    PathBuf::from(format!("/tmp/acpmux-{uid}")).join(format!("{hash:016x}-{session_id}.sock"))
}
/// Windows port: host sockets are `cmux::local_socket` paths there, with
/// their own length rule (a later landing).
#[cfg(not(unix))]
pub fn socket_path(dir: &Path, session_id: &str) -> PathBuf {
    dir.join(format!("{session_id}.sock"))
}

/// Create `dir` mode 0700 and check that only this user can enter it.
#[cfg(unix)]
pub fn ensure_private_dir(dir: &Path) -> Result<()> {
    crate::config::private_state_dir(dir)
}
/// Windows: an owner-only access list, made or checked (`owner_only.rs`).
#[cfg(windows)]
pub fn ensure_private_dir(dir: &Path) -> Result<()> {
    Ok(crate::owner_only::private_dir(dir)?)
}

/// Random lowercase hex; an error when the OS random generator fails.
pub fn random_hex(bytes: usize) -> Result<String> {
    let mut buf = vec![0u8; bytes];
    getrandom::fill(&mut buf).map_err(|e| anyhow!("the OS random generator: {e}"))?;
    Ok(buf.iter().map(|b| format!("{b:02x}")).collect())
}

/// Every record in `dir`: those this build reads, and those it cannot.
pub fn load_records(dir: &Path) -> Result<(Vec<(PathBuf, HostRecord)>, Vec<UnreadableRecord>)> {
    let mut good = Vec::new();
    let mut bad = Vec::new();
    match std::fs::symlink_metadata(dir) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok((good, bad)),
        Err(e) => return Err(e.into()),
        Ok(_) => crate::config::private_state_dir(dir)?,
    }
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok((good, bad)),
        Err(e) => return Err(e.into()),
    };
    for entry in entries {
        let entry = entry?;
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let Some(session_id) = path.file_stem().and_then(|s| s.to_str()).map(str::to_owned) else {
            continue;
        };
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            let kind = entry.file_type()?;
            let metadata = entry.metadata()?;
            // SAFETY: getuid has no preconditions.
            let uid = unsafe { libc::getuid() };
            if !kind.is_file() || metadata.uid() != uid || metadata.mode() & 0o077 != 0 {
                bad.push(UnreadableRecord {
                    session_id,
                    path,
                    record_version: None,
                    host_pid: None,
                    harness_pid: None,
                    start_nonce: None,
                    reason: "record is not an owner-only regular file".into(),
                });
                continue;
            }
        }
        let bytes = match std::fs::read(&path) {
            Ok(b) => b,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(e) => {
                bad.push(UnreadableRecord {
                    session_id,
                    path,
                    record_version: None,
                    host_pid: None,
                    harness_pid: None,
                    start_nonce: None,
                    reason: format!("unreadable: {e}"),
                });
                continue;
            }
        };
        let loose = serde_json::from_slice::<Value>(&bytes).ok();
        let field = |name: &str| loose.as_ref().and_then(|v| v.get(name)?.as_u64());
        let mut expected_sockets = vec![socket_path(dir, &session_id)];
        // Taking a pooled host moves its record and liveness lock into the
        // main hosts directory, but its already-bound socket stays in pool/.
        if dir.file_name().and_then(|name| name.to_str()) != Some(POOL_DIR_NAME) {
            expected_sockets.push(socket_path(&pool_dir(dir), &session_id));
        }
        let expected_socket =
            |path: &Path| expected_sockets.iter().any(|expected| expected == path);
        let identity_ok = loose.as_ref().is_some_and(|value| {
            value.get("session_id").and_then(Value::as_str) == Some(session_id.as_str())
                && value
                    .get("socket")
                    .and_then(Value::as_str)
                    .map(Path::new)
                    .is_some_and(expected_socket)
        });
        let reason = match serde_json::from_slice::<HostRecord>(&bytes) {
            Ok(r)
                if r.record_version == RECORD_VERSION
                    && r.session_id == session_id
                    && expected_socket(&r.socket) =>
            {
                good.push((path, r));
                continue;
            }
            Ok(r) if r.session_id != session_id => "record names another session".to_owned(),
            Ok(r) if !expected_socket(&r.socket) => "record names another socket".to_owned(),
            Ok(r) => format!("record version {}", r.record_version),
            Err(e) => format!("undecodable: {e}"),
        };
        let start_nonce = if identity_ok {
            loose
                .as_ref()
                .and_then(|v| v.get("start_nonce")?.as_str())
                .filter(|n| {
                    !n.is_empty()
                        && n.len() <= 128
                        && n.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
                })
                .map(str::to_owned)
        } else {
            None
        };
        bad.push(UnreadableRecord {
            session_id,
            path,
            record_version: field("record_version"),
            host_pid: identity_ok
                .then(|| field("host_pid"))
                .flatten()
                .and_then(|p| u32::try_from(p).ok()),
            harness_pid: identity_ok
                .then(|| field("harness_pid"))
                .flatten()
                .and_then(|p| u32::try_from(p).ok()),
            start_nonce,
            reason,
        });
    }
    good.sort_by(|a, b| a.0.cmp(&b.0));
    bad.sort_by(|a, b| a.path.cmp(&b.path));
    Ok((good, bad))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Liveness {
    Live,
    Dead,
    Unknown,
}

/// Probe the lock the host holds for its whole life. `Dead` is proof tied
/// to this incarnation even when the PID has been reused.
#[cfg(unix)]
pub fn liveness(dir: &Path, session_id: &str, start_nonce: &str) -> Liveness {
    use std::os::fd::AsRawFd;
    let path = live_path(dir, session_id, start_nonce);
    let file = match std::fs::OpenOptions::new().read(true).write(true).open(&path) {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Liveness::Dead,
        Err(_) => return Liveness::Unknown,
    };
    loop {
        // SAFETY: flock on a descriptor this function owns.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
            // SAFETY: same descriptor; release the probe at once.
            unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_UN) };
            return Liveness::Dead;
        }
        match std::io::Error::last_os_error().raw_os_error() {
            Some(libc::EINTR) => continue,
            Some(code) if code == libc::EWOULDBLOCK || code == libc::EAGAIN => {
                return Liveness::Live;
            }
            _ => return Liveness::Unknown,
        }
    }
}
/// Windows port: the host's liveness lock is `LockFileEx` there (a later
/// landing); no host runs yet, so nothing is proven.
#[cfg(not(unix))]
pub fn liveness(_dir: &Path, _session_id: &str, _start_nonce: &str) -> Liveness {
    Liveness::Unknown
}

/// End a host without speaking its protocol: the path for a host this build
/// cannot adopt, frozen across versions. Signals the host only with proof
/// that the recorded PID is this session's live host: the exact lock its
/// record names (`<session>.<start nonce>.live`) is held. A host ends its
/// harness group on SIGTERM while that group is still its own (it alone knows
/// whether the leader was reaped), then exits. If it does not exit within
/// `TERM_GRACE` it is killed, and the processes that ran under it (taken by
/// pid and start time before the kill) are killed too; the dropped lock is
/// the death proof. `Ok(true)` when no such host runs any more. Blocks up to
/// about twice `TERM_GRACE` plus two process-table reads: call it off the
/// async runtime.
#[cfg(unix)]
pub fn terminate_unadoptable(
    dir: &Path,
    session_id: &str,
    start_nonce: Option<&str>,
    host_pid: Option<u32>,
) -> Result<bool> {
    const TERM_GRACE: std::time::Duration = std::time::Duration::from_secs(3);
    let Some(nonce) = start_nonce else { return Ok(false) };
    if liveness(dir, session_id, nonce) == Liveness::Dead {
        return Ok(true);
    }
    let Some(pid) = host_pid else { return Ok(false) };
    let pid = i32::try_from(pid).context("pid")?;
    // The death proof: the host's lock drops when it exits. A watch that
    // starts after the exit takes the free lock at once, so none is missed;
    // waits on one host share one watch thread.
    let dead_within = |budget| wait_dead_within(dir, session_id, nonce, budget);
    if liveness(dir, session_id, nonce) != Liveness::Live {
        return Ok(liveness(dir, session_id, nonce) == Liveness::Dead);
    }
    // SAFETY: the held lock proves `pid` is this session's live host.
    unsafe { libc::kill(pid, libc::SIGTERM) };
    if dead_within(TERM_GRACE) {
        return Ok(true);
    }
    if liveness(dir, session_id, nonce) == Liveness::Live {
        // A host that does not end on SIGTERM (wedged or stopped) cannot end
        // its harness: take the processes under it (by pid and start time)
        // while the lock still proves `pid` is the host, and end them after
        // it, so no harness runs on without an owner.
        let under = tree::descendants(&[pid as u32]);
        // SAFETY: as above, re-proven just now.
        unsafe { libc::kill(pid, libc::SIGKILL) };
        let dead = dead_within(TERM_GRACE);
        tree::kill_still_running(&under);
        return Ok(dead);
    }
    Ok(dead_within(TERM_GRACE))
}
/// Windows port: hosts come in a later landing.
#[cfg(not(unix))]
pub fn terminate_unadoptable(
    _dir: &Path,
    _session_id: &str,
    _start_nonce: Option<&str>,
    _host_pid: Option<u32>,
) -> Result<bool> {
    Err(crate::platform::unsupported("agent hosts"))
}

/// Remove a dead host's record, lock and socket.
pub fn remove_artifacts(dir: &Path, record: &HostRecord) {
    let _ = std::fs::remove_file(record_path(dir, &record.session_id));
    let _ = std::fs::remove_file(live_path(dir, &record.session_id, &record.start_nonce));
    let _ = std::fs::remove_file(&record.socket);
}

/// Whether the record file at `path` names the host incarnation `nonce`. A
/// record that exists but cannot be read counts as this host's (never end
/// or delete on a doubt); a missing one does not.
pub fn names_this_host(path: &Path, nonce: &str) -> bool {
    match std::fs::read(path) {
        Ok(bytes) => serde_json::from_slice::<HostRecord>(&bytes)
            .ok()
            .is_none_or(|record| record.start_nonce == nonce),
        Err(e) => e.kind() != std::io::ErrorKind::NotFound,
    }
}

/// A host's own exit: its record and socket only while the record still
/// names it (a newer host of the same session owns them then), and its lock
/// last. A daemon takes the missing lock file as the death proof
/// (`terminate_unadoptable`) and may then start a fresh host under the same
/// session id at once: by then this host touches none of its files.
pub fn remove_own_artifacts(dir: &Path, record: &HostRecord) {
    let path = record_path(dir, &record.session_id);
    if names_this_host(&path, &record.start_nonce) && path.exists() {
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_file(&record.socket);
    }
    let _ = std::fs::remove_file(live_path(dir, &record.session_id, &record.start_nonce));
}

/// Hosts of pooled sessions (hidden sessions nobody took yet,
/// `hub/pool/`) keep their record, lock and socket in this subdirectory, so
/// no reader of the hosts directory (adoption, `live_host_sessions`, the
/// quit census) sees them. A daemon that starts ends every host left here.
pub const POOL_DIR_NAME: &str = "pool";

/// The pooled-host directory under `hosts`.
pub fn pool_dir(hosts: &Path) -> PathBuf {
    hosts.join(POOL_DIR_NAME)
}

/// A session took a pooled host: move its lock, then its record, from the
/// pool directory `from` into the hosts directory `to`, where adoption finds
/// it. The host keeps its lock (`flock` follows the open file, not the name)
/// and its socket (the record names it).
pub fn promote(from: &Path, to: &Path, record: &HostRecord) -> Result<()> {
    ensure_private_dir(to)?;
    let id = &record.session_id;
    std::fs::rename(
        live_path(from, id, &record.start_nonce),
        live_path(to, id, &record.start_nonce),
    )
    .context("move the pooled host's lock")?;
    std::fs::rename(record_path(from, id), record_path(to, id))
        .context("move the pooled host's record")?;
    Ok(())
}

/// A host started in the pool directory `dir` may have been promoted: end
/// the promoted record when it is still this host's, then the promoted lock
/// (last, as in [`remove_own_artifacts`]: its absence is the death proof).
pub fn remove_promoted(dir: &Path, record: &HostRecord) {
    if dir.file_name().and_then(|n| n.to_str()) != Some(POOL_DIR_NAME) {
        return;
    }
    let Some(hosts) = dir.parent() else { return };
    let path = record_path(hosts, &record.session_id);
    let ours = std::fs::read(&path)
        .ok()
        .and_then(|b| serde_json::from_slice::<HostRecord>(&b).ok())
        .is_some_and(|r| r.start_nonce == record.start_nonce);
    if ours {
        let _ = std::fs::remove_file(&path);
    }
    let _ = std::fs::remove_file(live_path(hosts, &record.session_id, &record.start_nonce));
}

/// Write `value` to `path` through a temporary file and a rename.
#[cfg(unix)]
pub fn write_record_atomic(path: &Path, record: &HostRecord) -> Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let tmp = path.with_extension(format!("tmp-{}", std::process::id()));
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&tmp)
        .with_context(|| format!("create {}", tmp.display()))?;
    let written = (|| -> Result<()> {
        f.write_all(&serde_json::to_vec(record)?)?;
        f.sync_all()?;
        std::fs::rename(&tmp, path)?;
        Ok(())
    })();
    if written.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    written
}
/// Windows port: host records are owner-only files there (a later landing).
#[cfg(not(unix))]
pub fn write_record_atomic(_path: &Path, _record: &HostRecord) -> Result<()> {
    Err(crate::platform::unsupported("agent host records"))
}

pub async fn write_frame<W: AsyncWriteExt + Unpin, T: Serialize>(
    w: &mut W,
    frame: &T,
) -> Result<()> {
    let body = serde_json::to_vec(frame)?;
    if body.len() > MAX_FRAME {
        bail!("frame of {} bytes is over the limit", body.len());
    }
    let mut buf = Vec::with_capacity(body.len() + 4);
    buf.extend_from_slice(&(body.len() as u32).to_be_bytes());
    buf.extend_from_slice(&body);
    w.write_all(&buf).await?;
    w.flush().await?;
    Ok(())
}

/// Next frame, or `None` on a clean end of stream.
pub async fn read_frame<R: AsyncReadExt + Unpin, T: for<'de> Deserialize<'de>>(
    r: &mut R,
) -> Result<Option<T>> {
    let mut len = [0u8; 4];
    match r.read_exact(&mut len).await {
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e.into()),
    }
    let len = u32::from_be_bytes(len) as usize;
    if len > MAX_FRAME {
        return Err(anyhow!("frame of {len} bytes is over the limit"));
    }
    let mut body = vec![0u8; len];
    r.read_exact(&mut body).await?;
    Ok(Some(serde_json::from_slice(&body)?))
}

/// Pick the highest protocol version both sides speak.
pub fn negotiate(min: u16, max: u16) -> Option<u16> {
    let low = min.max(PROTOCOL_MIN);
    let high = max.min(PROTOCOL_MAX);
    (low <= high).then_some(high)
}
