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

pub mod host;
pub mod link;

use anyhow::{Context, Result, anyhow, bail};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::{Path, PathBuf};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// Oldest and newest host protocol this build speaks.
pub const PROTOCOL_MIN: u16 = 1;
pub const PROTOCOL_MAX: u16 = 1;
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
    /// lines as `tap` entries.
    Line { msg: Value },
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
/// bootstrap pipe; never written to disk (it carries the environment).
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
    /// Directory for the record, socket fallback aside.
    pub hosts_dir: PathBuf,
    pub socket: PathBuf,
    /// Bytes of unacknowledged entries before back-pressure.
    pub buffer_cap: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TranslatorSpec {
    pub acp_session_id: String,
    pub mode: String,
    pub model: String,
    pub effort: String,
    /// Claude's own session id when it is known at spawn.
    pub claude_session_id: Option<String>,
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

/// Socket for one host: next to the record when the path is short enough for
/// `sun_path`, else in the private per-user directory acpmux already uses.
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

/// Create `dir` mode 0700 and check that only this user can enter it.
pub fn ensure_private_dir(dir: &Path) -> Result<()> {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt};
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    let meta = std::fs::symlink_metadata(dir)?;
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    if !meta.is_dir() || meta.uid() != uid || meta.mode() & 0o077 != 0 {
        bail!("{} is not a private directory", dir.display());
    }
    Ok(())
}

/// Random lowercase hex.
pub fn random_hex(bytes: usize) -> String {
    use std::io::Read;
    let mut buf = vec![0u8; bytes];
    let mut f = std::fs::File::open("/dev/urandom").expect("urandom");
    f.read_exact(&mut buf).expect("urandom read");
    buf.iter().map(|b| format!("{b:02x}")).collect()
}

/// Every record in `dir`: those this build reads, and those it cannot.
pub fn load_records(dir: &Path) -> Result<(Vec<(PathBuf, HostRecord)>, Vec<UnreadableRecord>)> {
    let mut good = Vec::new();
    let mut bad = Vec::new();
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok((good, bad)),
        Err(e) => return Err(e.into()),
    };
    for entry in entries {
        let path = entry?.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let Some(session_id) = path.file_stem().and_then(|s| s.to_str()).map(str::to_owned) else {
            continue;
        };
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
        let reason = match serde_json::from_slice::<HostRecord>(&bytes) {
            Ok(r) if r.record_version == RECORD_VERSION && r.session_id == session_id => {
                good.push((path, r));
                continue;
            }
            Ok(r) if r.session_id != session_id => "record names another session".to_owned(),
            Ok(r) => format!("record version {}", r.record_version),
            Err(e) => format!("undecodable: {e}"),
        };
        let start_nonce = loose
            .as_ref()
            .and_then(|v| v.get("start_nonce")?.as_str())
            .filter(|n| {
                !n.is_empty()
                    && n.len() <= 128
                    && n.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
            })
            .map(str::to_owned);
        bad.push(UnreadableRecord {
            session_id,
            path,
            record_version: field("record_version"),
            host_pid: field("host_pid").and_then(|p| u32::try_from(p).ok()),
            harness_pid: field("harness_pid").and_then(|p| u32::try_from(p).ok()),
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

/// End a host without speaking its protocol: the path for a host this build
/// cannot adopt, frozen across versions. Signals only the host, and only with
/// proof that the recorded PID is this session's live host: the exact lock
/// its record names (`<session>.<start nonce>.live`) is held. A host ends its
/// harness group on SIGTERM while that group is still its own (it alone knows
/// whether the leader was reaped), then exits. If it does not exit within
/// `TERM_GRACE` it is killed; the dropped lock is the death proof.
/// `Ok(true)` when no such host runs any more. Blocks up to about twice
/// `TERM_GRACE`: call it off the async runtime.
pub fn terminate_unadoptable(
    dir: &Path,
    session_id: &str,
    start_nonce: Option<&str>,
    host_pid: Option<u32>,
) -> Result<bool> {
    use std::os::fd::AsRawFd;
    const TERM_GRACE: std::time::Duration = std::time::Duration::from_secs(3);
    let Some(nonce) = start_nonce else { return Ok(false) };
    if liveness(dir, session_id, nonce) == Liveness::Dead {
        return Ok(true);
    }
    let Some(pid) = host_pid else { return Ok(false) };
    let pid = i32::try_from(pid).context("pid")?;
    let lock = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(live_path(dir, session_id, nonce))?;
    // The death proof: a blocking lock that returns when the host's
    // descriptor closes, on its own thread so the wait has a deadline.
    let (done_tx, done_rx) = std::sync::mpsc::channel();
    let fd = lock.try_clone()?;
    std::thread::spawn(move || {
        loop {
            // SAFETY: a blocking lock on a descriptor this thread owns.
            if unsafe { libc::flock(fd.as_raw_fd(), libc::LOCK_EX) } == 0 {
                let _ = done_tx.send(());
                return;
            }
            if std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted {
                return;
            }
        }
    });
    // SAFETY: the held lock proves `pid` is this session's live host.
    unsafe { libc::kill(pid, libc::SIGTERM) };
    if done_rx.recv_timeout(TERM_GRACE).is_ok() {
        return Ok(true);
    }
    if liveness(dir, session_id, nonce) == Liveness::Live {
        // SAFETY: as above, re-proven just now.
        unsafe { libc::kill(pid, libc::SIGKILL) };
    }
    Ok(done_rx.recv_timeout(TERM_GRACE).is_ok())
}

/// Block until this incarnation's host is dead (its lock drops). Returns at
/// once when the lock file is gone. Call it off the async runtime.
pub fn wait_dead(dir: &Path, session_id: &str, start_nonce: &str) {
    use std::os::fd::AsRawFd;
    let Ok(file) = std::fs::OpenOptions::new().read(true).write(true).open(live_path(
        dir,
        session_id,
        start_nonce,
    )) else {
        return;
    };
    loop {
        // SAFETY: a blocking lock on a descriptor this function owns; it
        // returns when the host's descriptor closes at its death.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } == 0
            || std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted
        {
            return;
        }
    }
}

/// Remove a dead host's record, lock and socket.
pub fn remove_artifacts(dir: &Path, record: &HostRecord) {
    let _ = std::fs::remove_file(record_path(dir, &record.session_id));
    let _ = std::fs::remove_file(live_path(dir, &record.session_id, &record.start_nonce));
    let _ = std::fs::remove_file(&record.socket);
}

/// Write `value` to `path` through a temporary file and a rename.
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
    f.write_all(&serde_json::to_vec(record)?)?;
    f.sync_all()?;
    std::fs::rename(&tmp, path)?;
    Ok(())
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn negotiation_picks_the_highest_common_version_or_none() {
        assert_eq!(negotiate(1, 1), Some(1));
        assert_eq!(negotiate(1, 9), Some(PROTOCOL_MAX));
        assert_eq!(negotiate(2, 9), None);
        assert_eq!(negotiate(0, 0), None);
    }

    #[test]
    fn frames_round_trip_with_their_tags() {
        let rt = tokio::runtime::Builder::new_current_thread().build().unwrap();
        rt.block_on(async {
            let (mut a, mut b) = tokio::io::duplex(1024);
            let frame = HostFrame::Entry {
                h: 7,
                e: Entry::In { msg: serde_json::json!({"jsonrpc":"2.0","method":"x"}) },
            };
            write_frame(&mut a, &frame).await.unwrap();
            let read: HostFrame = read_frame(&mut b).await.unwrap().unwrap();
            assert_eq!(read, frame);
            let json = serde_json::to_value(&frame).unwrap();
            assert_eq!(json["t"], "entry");
            assert_eq!(json["e"]["k"], "in");
        });
    }

    #[test]
    fn records_of_another_version_are_reported_not_dropped() {
        let dir = std::env::temp_dir().join(format!("amx-rec-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("s1.json"),
            serde_json::json!({"record_version": 7, "session_id": "s1", "host_pid": 42})
                .to_string(),
        )
        .unwrap();
        let (good, bad) = load_records(&dir).unwrap();
        assert!(good.is_empty());
        assert_eq!(bad.len(), 1);
        assert_eq!(bad[0].session_id, "s1");
        assert_eq!(bad[0].record_version, Some(7));
        assert_eq!(bad[0].host_pid, Some(42));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
