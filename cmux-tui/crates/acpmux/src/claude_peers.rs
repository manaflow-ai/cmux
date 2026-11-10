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
//! Off unless `agents.desktopBridge.enabled` is true in the settings file, or the session itself
//! asked for a name with `acpmux register NAME` (`hub/register.rs`): that one session is then
//! bridged whatever the setting says.
//!
//! Which token a delivery opens with. Claude Code documents the inbox for "a script or hook to
//! post into a session" (code.claude.com/docs/en/cross-session-messaging, "The session's inbox
//! socket"): it exports the socket's path and a per-session token to the session's hooks and
//! Bash commands as `CLAUDE_CODE_MESSAGING_SOCKET` and `CLAUDE_CODE_MESSAGING_TOKEN`, and a
//! connection that opens with `{"type":"auth","token":<that token>}` is the session's own child,
//! delivered under its inbound rules (held only by an explicit `crossSessionInbound`). `acpmux
//! register`, run in the session's shell, hands that token to the daemon ([`save_token`]), and
//! each later delivery opens with it while the same process runs. The message line is the
//! `{"type":"user","message":{"role":"user","content":...}}` line Claude Code's own `--debug` log
//! prints for injecting into the inbox, the shape of its documented stream-json input. Without a
//! registered token (the bridge setting's listing) the delivery opens with the peer key Claude
//! Code publishes beside the registry entry, as before: that file is not documented, so a chat
//! only the setting bridged says so in `acpmux ls` (`bridge.token=peer-key`).

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
// timeout: connecting and writing to a local Claude Code session's inbox socket; a session that does not answer gets an error the sender sees, nothing is dropped silently
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

/// The token `acpmux register` handed over for one chat: the session's documented
/// `CLAUDE_CODE_MESSAGING_TOKEN`, good only while the process `pid` that exported it runs with the
/// inbox at `socket`.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct ChildToken {
    pub pid: u32,
    pub socket: PathBuf,
    pub token: String,
    /// The process's `startedAt`: a later process under a reused pid is not the one that
    /// handed the token over.
    #[serde(default)]
    pub started: Option<u64>,
}

/// Where the daemon keeps the token registered for chat `chat_id` (0600, in a 0700 folder).
pub fn token_file(home: &Path, chat_id: &str) -> PathBuf {
    let safe: String =
        chat_id.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_').collect();
    home.join("bridge-tokens").join(format!("{safe}.json"))
}

/// Keeps `token` for chat `chat_id`, replacing an older one.
pub fn save_token(home: &Path, chat_id: &str, token: &ChildToken) -> anyhow::Result<()> {
    let bytes = serde_json::to_vec(token)?;
    crate::agent_tools::write_private(&token_file(home, chat_id), &bytes)
}

/// The token kept for chat `chat_id`, if it is still the live `peer`'s: a session that restarted
/// (another pid, or another inbox) has a new one, which only another `acpmux register` hands over.
/// `started` is the live process's `startedAt` ([`started_at`]); a token kept for an earlier
/// process under the same pid is not its.
pub fn token_for(home: &Path, chat_id: &str, peer: &Peer, started: Option<u64>) -> Option<String> {
    let kept = kept_token(home, chat_id)?;
    (kept.pid == peer.pid
        && peer.socket.as_deref() == Some(kept.socket.as_path())
        && started.is_some()
        && kept.started == started)
        .then_some(kept.token)
}

/// The registration kept for chat `chat_id`: the process, inbox, start and token it recorded.
pub fn kept_token(home: &Path, chat_id: &str) -> Option<ChildToken> {
    let path = token_file(home, chat_id);
    if std::fs::metadata(&path).ok()?.len() > MAX_FILE {
        return None;
    }
    serde_json::from_slice(&std::fs::read(path).ok()?).ok()
}

/// The arguments the kernel recorded when process `pid` started (macOS `KERN_PROCARGS2`): what
/// launched it, which no file can rewrite. None when they cannot be read.
#[cfg(target_os = "macos")]
pub fn launch_args(pid: u32) -> Option<Vec<String>> {
    let id = libc::c_int::try_from(pid).ok()?;
    let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, id];
    let mut size: libc::size_t = 0;
    // SAFETY: a size query: no buffer, `size` receives the length.
    let asked = unsafe {
        libc::sysctl(mib.as_mut_ptr(), 3, std::ptr::null_mut(), &mut size, std::ptr::null_mut(), 0)
    };
    if asked != 0 || size == 0 || size > (1 << 20) {
        return None;
    }
    let mut buf = vec![0u8; size];
    // SAFETY: `buf` holds `size` bytes, which the kernel fills at most.
    let read = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            3,
            buf.as_mut_ptr().cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if read != 0 {
        return None;
    }
    buf.truncate(size);
    procargs(&buf)
}

/// No launch arguments read off macOS.
#[cfg(not(target_os = "macos"))]
pub fn launch_args(_pid: u32) -> Option<Vec<String>> {
    None
}

/// `KERN_PROCARGS2`'s layout: argc (4 bytes), the executable path, NUL padding to the next
/// 8-byte boundary (1 to 8 bytes), then argc arguments, each NUL-terminated, then the environment.
/// Read exactly, failing closed: the padding must be exactly that long (so an empty first argument
/// is never taken for padding), argv[0] must name the executable, and exactly argc arguments are
/// taken, empty ones included, so no environment entry is ever read as one.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn procargs(buf: &[u8]) -> Option<Vec<String>> {
    let (count, rest) = buf.split_first_chunk::<4>()?;
    let argc = usize::try_from(i32::from_ne_bytes(*count)).ok()?;
    let path_len = rest.iter().position(|b| *b == 0)?;
    let (path, after_path) = rest.split_at(path_len);
    let pad = 8usize.checked_sub(path_len.checked_rem(8)?)?;
    let (padding, mut args_buf) = after_path.split_at_checked(pad)?;
    if padding.iter().any(|b| *b != 0) {
        return None;
    }
    let mut args = Vec::with_capacity(argc.min(4096));
    for _ in 0..argc {
        let end = args_buf.iter().position(|b| *b == 0)?;
        let (arg, tail) = args_buf.split_at(end);
        args.push(String::from_utf8_lossy(arg).into_owned());
        let (_, next) = tail.split_first()?;
        args_buf = next;
    }
    let base = |s: &[u8]| s.rsplit(|b| *b == b'/').next().map(<[u8]>::to_vec);
    let first = args.first()?;
    if first.is_empty() || base(first.as_bytes()) != base(path) {
        return None;
    }
    Some(args)
}

/// Claude Code's options that never take the next argument as their value: its boolean flags
/// and those whose value is optional (which never take a dash-led one). Any other option before
/// a session flag may be taking it as its value, so that launch names no session.
const NO_OPERAND: &[&str] = &[
    "--allow-dangerously-skip-permissions",
    "--ax-screen-reader",
    "--bg",
    "--background",
    "--bare",
    "--brief",
    "--chrome",
    "--no-chrome",
    "-c",
    "--continue",
    "--dangerously-skip-permissions",
    "--desktop",
    "--disable-slash-commands",
    "--exclude-dynamic-system-prompt-sections",
    "--forward-subagent-text",
    "-h",
    "--help",
    "--ide",
    "--include-hook-events",
    "--include-partial-messages",
    "--no-session-persistence",
    "-p",
    "--print",
    "--replay-user-messages",
    "--restricted",
    "--safe-mode",
    "--strict-mcp-config",
    "--tmux",
    "--verbose",
    "-v",
    "--version",
    // Optional values.
    "--cloud",
    "-d",
    "--debug",
    "--from-pr",
    "--prompt-suggestions",
    "--remote-control",
    "--teleport",
    "-w",
    "--worktree",
];

/// The conversation `args` start Claude Code on (`--resume ID`, `--resume=ID`, `-r ID`,
/// `--session-id ID`), read conservatively since it decides who may take over a registered chat:
/// nothing after `--` (positional text), no flag that could be the operand of the option before
/// it (one with no inline `=value` and not in [`NO_OPERAND`]), and None when more than one argument names a session. A
/// launch this misreads as naming none only means it cannot take a chat over. A forked launch
/// (`--fork-session`, in any position or spelling) starts a new conversation, so it names none.
pub fn resumed_session(args: &[String]) -> Option<String> {
    if args.iter().skip(1).any(|a| a.starts_with("--fork")) {
        return None;
    }
    let mut found: Vec<String> = Vec::new();
    let mut prev: Option<&str> = None;
    let mut it = args.iter().skip(1).peekable();
    while let Some(arg) = it.next() {
        if arg == "--" {
            break;
        }
        // An option with no inline value before this argument may take it as its value.
        let operand = prev
            .is_some_and(|p| p.starts_with('-') && !p.contains('=') && !NO_OPERAND.contains(&p));
        let named = ["--resume", "--session-id"]
            .iter()
            .find_map(|flag| arg.strip_prefix(flag).and_then(|r| r.strip_prefix('=')))
            .map(str::to_owned);
        if let Some(id) = named {
            if operand {
                return None;
            }
            found.push(id);
        } else if ["--resume", "-r", "--session-id"].contains(&arg.as_str()) {
            if operand {
                return None;
            }
            let id = it.next_if(|id| !id.starts_with('-'))?;
            found.push(id.clone());
            prev = Some(id.as_str());
            continue;
        }
        prev = Some(arg.as_str());
    }
    match found.as_slice() {
        [one] if !one.is_empty() => Some(one.clone()),
        _ => None,
    }
}

/// The `startedAt` of the live registry entry for `pid` (checked against the kernel's start of
/// `pid`, as [`live`] checks it).
pub fn started_at(config: &Path, pid: u32) -> Option<u64> {
    let path = registry(config).join(format!("{pid}.json"));
    read_entry(&path)?;
    let record: Value = serde_json::from_slice(&std::fs::read(&path).ok()?).ok()?;
    record.get("startedAt").and_then(Value::as_u64)
}

/// Whether `peer` is the only live registry entry that claims its conversation: a second
/// claimant (an entry anyone may write, naming the same session id) proves neither.
pub fn sole_claimant(peer: &Peer, live: &[Peer]) -> bool {
    !live.iter().any(|p| p.pid != peer.pid && p.session_id == peer.session_id)
}

/// The code-signing requirement Claude Code's own binary meets (the CLI and the desktop app's).
#[cfg(target_os = "macos")]
const CLAUDE_CODE_REQUIREMENT: &str = "=anchor apple generic and certificate leaf[subject.OU] = \"Q6L2SF6YDW\" and identifier \"com.anthropic.claude-code\"";

/// Whether the running process `pid` is Claude Code, as the kernel's code signing says
/// (`codesign --verify` of the live process against Anthropic's signature), never by its name
/// or path. Blocking: a second at most.
#[cfg(target_os = "macos")]
pub fn is_claude_code(pid: u32) -> bool {
    std::process::Command::new("/usr/bin/codesign")
        .args(["--verify", "-R", CLAUDE_CODE_REQUIREMENT, &pid.to_string()])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// No code signature to check off macOS: no process is proven to be Claude Code.
#[cfg(not(target_os = "macos"))]
pub fn is_claude_code(_pid: u32) -> bool {
    false
}

/// Whether the process listening on `socket` is `pid`, run by this daemon's user (the kernel's
/// peer credentials of a connection to it). A symlink is never followed.
#[cfg(unix)]
pub async fn inbox_is(socket: &Path, pid: u32) -> bool {
    if !std::fs::symlink_metadata(socket).is_ok_and(|m| !m.file_type().is_symlink()) {
        return false;
    }
    let Ok(Ok(stream)) =
        tokio::time::timeout(IO_TIMEOUT, tokio::net::UnixStream::connect(socket)).await
    else {
        return false;
    };
    let Ok(cred) = stream.peer_cred() else { return false };
    // SAFETY: getuid has no preconditions.
    let own = unsafe { libc::getuid() };
    cred.uid() == own && cred.pid().and_then(|p| u32::try_from(p).ok()) == Some(pid)
}

/// No unix sockets here: no inbox is proven.
#[cfg(not(unix))]
pub async fn inbox_is(_socket: &Path, _pid: u32) -> bool {
    false
}

/// Removes the token kept for chat `chat_id`, when it has one.
pub fn forget_token(home: &Path, chat_id: &str) {
    let _ = std::fs::remove_file(token_file(home, chat_id));
}

/// Delivers `text` into `peer`'s inbox as message `uuid`: connecting and writing take at most
/// [`IO_TIMEOUT`] together. `child_token` is the session's own registered token ([`token_for`]);
/// without one, the peer key file is read.
#[cfg(unix)]
pub async fn deliver(
    config: &Path,
    peer: &Peer,
    text: &str,
    uuid: &str,
    from: &str,
    child_token: Option<&str>,
) -> Result<(), String> {
    use tokio::io::AsyncWriteExt;
    let socket = peer.socket.as_deref().ok_or("the session has no messaging socket")?;
    let key = key_file(config, peer.pid, socket);
    let send = async {
        let token = match child_token {
            Some(token) => token.to_owned(),
            None => {
                // Claude Code drops what comes without its token: with no readable key, nothing
                // is sent. Only a small regular file is read (never a FIFO), within the deadline.
                let small_file = tokio::fs::metadata(&key)
                    .await
                    .is_ok_and(|m| m.is_file() && m.len() <= MAX_FILE);
                let bytes = if small_file { tokio::fs::read(&key).await.ok() } else { None };
                bytes
                    .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
                    .and_then(|v| v.get("peerToken").and_then(Value::as_str).map(str::to_owned))
                    .ok_or_else(|| {
                        format!(
                            "the session's inbox key {} is missing or unreadable",
                            key.display()
                        )
                    })?
            }
        };
        // Claude Code refuses to write through a symlink at a peer's socket path; neither does
        // acpmux.
        if std::fs::symlink_metadata(socket).is_ok_and(|m| m.file_type().is_symlink()) {
            return Err(format!("the session's inbox {} is a symlink", socket.display()));
        }
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
pub async fn deliver(
    _: &Path,
    _: &Peer,
    _: &str,
    _: &str,
    _: &str,
    _: Option<&str>,
) -> Result<(), String> {
    Err("delivering to a Claude Code session is Unix-only".into())
}

#[cfg(test)]
#[path = "claude_peers_tests.rs"]
mod tests;
