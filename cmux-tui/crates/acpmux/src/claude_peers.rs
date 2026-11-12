//! Claude Code sessions acpmux did not start, reached the way Claude Code sessions reach each
//! other (Leo 2026-11-08: "we can also think ab better ways for acpmux to talk to desktop
//! claudes/codexes").
//!
//! Every running Claude Code (a terminal, the desktop app's Code tab, an SDK host) registers
//! itself in `<CLAUDE_CONFIG_DIR>/sessions/<pid>.json`: its session id, cwd, `entrypoint`
//! (`claude-desktop`, `cli`, `sdk-cli`, ...), name, and the Unix socket its inbox listens on
//! (`messagingSocketPath`). The socket takes newline-delimited JSON: an auth line with the
//! session's peer token, read from the 0600 key file it publishes beside the entry
//! (`<pid>.<sha256 of the socket path>.key`), then a `user` line. The session runs that message
//! as a turn, even while idle, and writes it to its transcript as a `peer` user line with the
//! `uuid` it was sent with and the sender's pid the kernel verified.
//!
//! acpmux uses this to:
//! - list live desktop sessions as watched chats (`server/desktop_bridge.rs`), their provenance
//!   read from the registry entry the session wrote, never typed by a sender;
//! - deliver a prompt into one (`hub/bridge.rs`): the watch then shows the turn it ran.
//!
//! Off unless `agents.desktopBridge.enabled` is true in the settings file.

use serde_json::Value;
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// The settings key that turns the bridge on.
pub const ENABLED_KEY: &str = "agents.desktopBridge.enabled";
/// The settings key listing the entrypoints listed as chats (default: the Claude desktop app's).
/// Codex threads are listed by originator from the same list: `codex_desktop` (`codex_desktop.rs`)
/// lists the Codex desktop app's.
pub const ENTRYPOINTS_KEY: &str = "agents.desktopBridge.entrypoints";
/// The entrypoint Claude Code records for a session the Claude desktop app runs.
pub const DESKTOP_ENTRYPOINT: &str = "claude-desktop";

/// Longest a delivery waits to connect and write.
const IO_TIMEOUT: Duration = Duration::from_secs(5);
/// A registry entry or key file larger than this is not Claude Code's.
const MAX_FILE: u64 = 64 << 10;

/// One live registered Claude Code session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Peer {
    pub pid: u32,
    pub session_id: String,
    pub cwd: Option<PathBuf>,
    pub entrypoint: Option<String>,
    pub kind: Option<String>,
    pub name: Option<String>,
    pub version: Option<String>,
    pub socket: Option<PathBuf>,
}

/// Turns the bridge on for this process's tests, which must not write the settings file.
#[cfg(test)]
pub static TEST_ENABLED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Whether the bridge is on, read from the settings file at each use.
pub fn enabled() -> bool {
    #[cfg(test)]
    if TEST_ENABLED.load(std::sync::atomic::Ordering::SeqCst) {
        return true;
    }
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => {
            crate::user_settings::value(&doc, ENABLED_KEY).and_then(|v| v.as_bool()) == Some(true)
        }
        _ => false,
    }
}

/// The entrypoints whose sessions are listed (`ENTRYPOINTS_KEY`, else the desktop app's).
pub fn listed_entrypoints() -> Vec<String> {
    let doc = match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => doc,
        _ => Value::Null,
    };
    with_test_listing(entrypoints_of(&doc))
}

#[cfg(not(test))]
fn with_test_listing(listed: Vec<String>) -> Vec<String> {
    listed
}

/// The tests that turn the bridge on list the Codex desktop app's threads too.
#[cfg(test)]
fn with_test_listing(mut listed: Vec<String>) -> Vec<String> {
    if TEST_ENABLED.load(std::sync::atomic::Ordering::SeqCst) {
        listed.push(crate::codex_desktop::DESKTOP_ORIGINATOR.to_owned());
    }
    listed
}

fn entrypoints_of(doc: &Value) -> Vec<String> {
    let named: Vec<String> = crate::user_settings::value(doc, ENTRYPOINTS_KEY)
        .and_then(|v| {
            v.as_array().map(|a| a.iter().filter_map(|e| e.as_str().map(str::to_owned)).collect())
        })
        .unwrap_or_default();
    if named.is_empty() { vec![DESKTOP_ENTRYPOINT.to_owned()] } else { named }
}

/// The registry folder of the Claude store at `config` (a `CLAUDE_CONFIG_DIR`).
pub fn registry(config: &Path) -> PathBuf {
    config.join("sessions")
}

/// The entry `path` names, when it is a `<pid>.json` whose process still runs.
fn read_entry(path: &Path) -> Option<Peer> {
    let stem = path.file_stem()?.to_str()?;
    if path.extension()?.to_str()? != "json" || !stem.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    // A stale entry (its pid gone) is skipped before it is read: a busy machine keeps thousands.
    let pid: u32 = stem.parse().ok()?;
    if !crate::adopt_live::registered_runs(pid, None) {
        return None;
    }
    if std::fs::metadata(path).ok()?.len() > MAX_FILE {
        return None;
    }
    let record: Value = serde_json::from_slice(&std::fs::read(path).ok()?).ok()?;
    let peer = parse_entry(&record)?;
    // The entry names a message's sender (hub/desktop_bridge.rs): only while its process is the
    // one that wrote it, never a later process under a reused pid.
    (peer.pid.to_string() == stem
        && crate::adopt_live::registered_proven(
            peer.pid,
            record.get("startedAt").and_then(Value::as_u64),
        ))
    .then_some(peer)
}

/// A registry record's fields (no liveness check).
pub fn parse_entry(record: &Value) -> Option<Peer> {
    let text = |key: &str| record.get(key).and_then(Value::as_str).map(str::to_owned);
    Some(Peer {
        pid: u32::try_from(record.get("pid")?.as_u64()?).ok()?,
        session_id: text("sessionId").filter(|s| !s.is_empty())?,
        cwd: text("cwd").map(PathBuf::from),
        entrypoint: text("entrypoint"),
        kind: text("kind"),
        name: text("name"),
        version: text("version"),
        socket: text("messagingSocketPath").map(PathBuf::from),
    })
}

/// Every live session registered in the store at `config`. Only `<pid>.json` entries whose pid
/// runs are read; a crashed session's stale entry is skipped.
pub fn live(config: &Path) -> Vec<Peer> {
    let Ok(dir) = std::fs::read_dir(registry(config)) else { return Vec::new() };
    dir.flatten().filter_map(|e| read_entry(&e.path())).collect()
}

/// The live session registered with Claude Code session id `id`.
pub fn find(config: &Path, id: &str) -> Option<Peer> {
    live(config).into_iter().find(|p| p.session_id == id)
}

/// The key file Claude Code publishes for `pid`'s inbox at `socket`.
pub fn key_file(config: &Path, pid: u32, socket: &Path) -> PathBuf {
    let resolved = std::path::absolute(socket).unwrap_or_else(|_| socket.to_path_buf());
    let digest = Sha256::digest(resolved.to_string_lossy().as_bytes());
    let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
    registry(config).join(format!("{pid}.{hex}.key"))
}

/// The two lines a delivery writes: auth (when a token is known), then the message.
pub fn frames(token: Option<&str>, text: &str, uuid: &str, from: &str) -> String {
    let mut out = String::new();
    if let Some(token) = token {
        out.push_str(&serde_json::json!({"type": "auth", "token": token}).to_string());
        out.push('\n');
    }
    let msg = serde_json::json!({
        "type": "user",
        "uuid": uuid,
        "from": from,
        "message": {"role": "user", "content": text},
    });
    out.push_str(&msg.to_string());
    out.push('\n');
    out
}

/// A `from` address Claude Code accepts: its address characters only, at most 300.
pub fn from_address(sender: &str) -> String {
    let clean: String = sender
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || ":_/.-".contains(c) { c } else { '-' })
        .take(280)
        .collect();
    format!("acpmux:{clean}")
}

/// Delivers `text` into `peer`'s inbox as message `uuid`: connecting and writing take at most
/// [`IO_TIMEOUT`] together.
#[cfg(unix)]
pub async fn deliver(
    config: &Path,
    peer: &Peer,
    text: &str,
    uuid: &str,
    from: &str,
) -> Result<(), String> {
    use tokio::io::AsyncWriteExt;
    let socket = peer.socket.as_deref().ok_or("the session has no messaging socket")?;
    let key = key_file(config, peer.pid, socket);
    let send = async {
        // Claude Code drops what comes without its token: with no readable key, nothing is sent.
        // Only a small regular file is read (never a FIFO), within the same deadline.
        let small_file =
            tokio::fs::metadata(&key).await.is_ok_and(|m| m.is_file() && m.len() <= MAX_FILE);
        let bytes = if small_file { tokio::fs::read(&key).await.ok() } else { None };
        let token = bytes
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
            .and_then(|v| v.get("peerToken").and_then(Value::as_str).map(str::to_owned))
            .ok_or_else(|| {
                format!("the session's inbox key {} is missing or unreadable", key.display())
            })?;
        let frames = frames(Some(&token), text, uuid, from);
        let mut stream = tokio::net::UnixStream::connect(socket).await.map_err(|e| {
            format!("could not reach the session's inbox {}: {e}", socket.display())
        })?;
        stream
            .write_all(frames.as_bytes())
            .await
            .map_err(|e| format!("could not write to the session's inbox: {e}"))?;
        let _ = stream.shutdown().await;
        Ok(())
    };
    tokio::time::timeout(IO_TIMEOUT, send).await.unwrap_or_else(|_| {
        Err(format!("the session's inbox {} did not answer in time", socket.display()))
    })
}

#[cfg(not(unix))]
pub async fn deliver(_: &Path, _: &Peer, _: &str, _: &str, _: &str) -> Result<(), String> {
    Err("delivering to a Claude Code session is Unix-only".into())
}

#[cfg(test)]
#[path = "claude_peers_tests.rs"]
mod tests;
