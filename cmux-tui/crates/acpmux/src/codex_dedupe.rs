//! Harness magic `dedupe` for Codex (RFD 0147): a read-only shell command Codex already ran in
//! this turn, with nothing it reads changed since, is refused with the one-line stub Claude's
//! callback gives (`claude_stdio/dedupe.rs`), so its output does not enter the context twice.
//!
//! Codex has no hook callback into a long-lived process: each hook is a command it runs per
//! call. So a `codex app-server` acpmux starts with the feature on gets four session-flag hooks
//! (cmux-tui-hooks `codex_session_flag_hooks_settings`, trusted by hash, beside the user's own),
//! each this binary's [`HOOK_ARG`] with the event, and the session's table is a small file the
//! hooks share under a lock, one per Codex session:
//! - `PreToolUse`: a `Bash` call from the read-only list (`dedupe_shell.rs`) whose folder and
//!   command match a run recorded in this turn, whose fingerprint is unchanged and whose result
//!   has not answered a stub yet, is refused: the stub on stderr and exit 2, which Codex shows the
//!   model as "Command blocked by PreToolUse hook: <stub>" (Codex 0.172.0, 2026-11-27). Any other
//!   call is fingerprinted and passes.
//! - `PostToolUse`: the call's result is recorded when its inputs still stamp as they did before
//!   it ran (a tree that moved mid-call is never recorded).
//! - `PostCompact`: the table is dropped; the earlier output may no longer be in context.
//! - `SessionEnd`: the file is removed.
//!
//! As on Claude, a stub is only ever given within the turn that ran the command, each earlier run
//! answers one stub (asking again runs it), and a table idle 5 minutes is empty. Codex's
//! `tool_response` is the command's text with no exit status, so a failing read is recorded too:
//! its inputs unchanged, it fails the same way.
//!
//! Off by default, behind the same switch as Claude's (`agents.harnessMagic.dedupe.enabled`,
//! `ACPMUX_HM_DEDUPE`), read when the launch is built. Fails open: an unreadable payload, a
//! file it cannot lock, a fingerprint it cannot take or a crash lets the call run (only exit 2
//! refuses, and only [`decide`] returns it).

use serde_json::Value;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use crate::claude_stdio::DedupeCodexShell as Shell;

/// The hidden word that runs the hook (`cli/entry.rs`, before any runtime starts).
pub const HOOK_ARG: &str = "__codex-dedupe";

/// Codex's wait for the hook. It answers in milliseconds; Codex lets the call run past this.
pub const HOOK_TIMEOUT_SECS: u64 = 10;
/// Codex clamps a SessionEnd hook's timeout to 3 s (`codex_trust::codex_normalized_timeout`).
const SESSION_END_TIMEOUT_SECS: u64 = 3;

const IDLE_RESET: Duration = Duration::from_secs(300);
const MAX_PENDING: usize = 64;
const MAX_RECORDS: usize = 256;
/// The largest payload it reads; a bigger one (a huge PostToolUse output) is not recorded.
const MAX_PAYLOAD: u64 = 4 << 20;

/// The hook events and the word each passes the hook.
const EVENTS: &[(&str, &str)] = &[
    ("PreToolUse", "pre"),
    ("PostToolUse", "post"),
    ("PostCompact", "compact"),
    ("SessionEnd", "end"),
];

/// The session's table, as its file holds it.
#[derive(Debug, Default, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub(crate) struct Table {
    /// Fingerprints taken at PreToolUse, by `tool_use_id`, waiting for the result.
    #[serde(default)]
    pending: Vec<(String, String, String)>,
    /// Results in context: (turn, key, fingerprint, calls seen when it ran, answered a stub).
    #[serde(default)]
    seen: Vec<Seen>,
    /// Tool calls this table has seen, the clock `ago` counts in.
    #[serde(default)]
    calls: u64,
    /// Calls stubbed, over the table's life (its counter).
    #[serde(default)]
    stubbed: u64,
}

#[derive(Debug, Default, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
struct Seen {
    turn: String,
    key: String,
    fingerprint: String,
    at: u64,
    used: bool,
}

/// What the hook answers for `event` on `input`, editing `table`: `Some(stub)` refuses the call.
pub(crate) fn decide(event: &str, input: &Value, table: &mut Table) -> Option<String> {
    let turn = input.get("turn_id").and_then(Value::as_str).unwrap_or_default();
    let id = input.get("tool_use_id").and_then(Value::as_str).unwrap_or_default();
    match event {
        "pre" => {
            table.calls += 1;
            let shell = Shell::of(input)?;
            let fingerprint = shell.fingerprint()?;
            let key = shell.key();
            if !turn.is_empty()
                && let Some(seen) = table.seen.iter_mut().rev().find(|s| {
                    !s.used && s.turn == turn && s.key == key && s.fingerprint == fingerprint
                })
            {
                seen.used = true;
                table.stubbed += 1;
                return Some(shell.stub(table.calls.saturating_sub(seen.at).max(1)));
            }
            if !id.is_empty() {
                table.pending.retain(|(i, _, _)| i != id);
                table.pending.push((id.to_owned(), key, fingerprint));
                let over = table.pending.len().saturating_sub(MAX_PENDING);
                table.pending.drain(..over);
            }
            None
        }
        "post" => {
            let at = table.pending.iter().position(|(i, _, _)| !id.is_empty() && i == id)?;
            let (_, key, before) = table.pending.remove(at);
            let shell = Shell::of(input)?;
            if turn.is_empty() || shell.key() != key || shell.fingerprint()? != before {
                return None;
            }
            input.get("tool_response")?;
            // A newer run of the same call replaces the older: its result is the one in view.
            table.seen.retain(|s| !(s.turn == turn && s.key == key));
            table.seen.push(Seen {
                turn: turn.to_owned(),
                key,
                fingerprint: before,
                at: table.calls,
                used: false,
            });
            let over = table.seen.len().saturating_sub(MAX_RECORDS);
            table.seen.drain(..over);
            None
        }
        "compact" => {
            *table = Table { calls: table.calls, stubbed: table.stubbed, ..Table::default() };
            None
        }
        _ => None,
    }
}

/// The hook: `event` (one of [`EVENTS`]' words), Codex's payload on stdin, the tables under
/// `dir`. Exits 2 with the stub on stderr to refuse; anything else exits 0.
pub fn main(event: Option<&str>, dir: Option<&Path>) -> anyhow::Result<()> {
    let (Some(event), Some(dir)) = (event, dir) else { return Ok(()) };
    let mut text = String::new();
    let _ = std::io::Read::read_to_string(
        &mut std::io::Read::take(std::io::stdin(), MAX_PAYLOAD),
        &mut text,
    );
    let Ok(input) = serde_json::from_str::<Value>(&text) else { return Ok(()) };
    let Some(path) = table_path(dir, &input) else { return Ok(()) };
    if event == "end" {
        let _ = std::fs::remove_file(&path);
        return Ok(());
    }
    if let Ok(Some(stub)) = with_table(&path, |table| decide(event, &input, table)) {
        eprintln!("{stub}");
        // crash-allow: Codex reads exit 2 as "refuse this call, show stderr to the model"
        std::process::exit(2);
    }
    Ok(())
}

/// The session's table file: one per Codex `session_id`, its name a hash of it.
pub(crate) fn table_path(dir: &Path, input: &Value) -> Option<PathBuf> {
    use sha2::Digest as _;
    let session = input.get("session_id")?.as_str().filter(|s| !s.is_empty())?;
    let name = format!("{:x}", sha2::Sha256::digest(session.as_bytes()));
    // A SHA-256 hex digest is 64 ASCII characters, so the first 32 always exist.
    Some(dir.join(format!("{}.json", name.get(..32)?)))
}

/// Runs `edit` on the table at `path` under an exclusive lock (parallel calls never lose an
/// entry) and writes it back. A table idle past [`IDLE_RESET`] or unreadable starts empty.
#[cfg(unix)]
pub(crate) fn with_table<R>(path: &Path, edit: impl FnOnce(&mut Table) -> R) -> std::io::Result<R> {
    use std::io::{Read, Seek, Write};
    use std::os::unix::fs::OpenOptionsExt;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    // Drop unlocks, then closes: the hook starts no child while it holds it.
    let mut held = cmux_file_lock::FileLock::take(file, cmux_file_lock::Kind::Exclusive)?;
    let file = held.file_mut();
    let idle = file
        .metadata()?
        .modified()
        .ok()
        .and_then(|m| SystemTime::now().duration_since(m).ok())
        .is_some_and(|d| d > IDLE_RESET);
    let mut text = String::new();
    file.read_to_string(&mut text)?;
    let mut table: Table =
        if idle { Table::default() } else { serde_json::from_str(&text).unwrap_or_default() };
    let answer = edit(&mut table);
    file.set_len(0)?;
    file.rewind()?;
    file.write_all(&serde_json::to_vec(&table).map_err(std::io::Error::other)?)?;
    Ok(answer)
}

#[cfg(not(unix))]
pub(crate) fn with_table<R>(
    _path: &Path,
    _edit: impl FnOnce(&mut Table) -> R,
) -> std::io::Result<R> {
    Err(std::io::Error::other("no dedupe table off unix"))
}

/// Where a launch's tables live: under the daemon's home, removed per session by `SessionEnd`.
pub fn tables_dir() -> PathBuf {
    crate::config::home().join("codex-dedupe")
}

/// The hooks a `codex app-server` launch gets for the dedupe: (event, command, timeout), run by
/// `exe prefix...`.
pub fn hooks(exe: &str, prefix: &[String], dir: &Path) -> Vec<(String, String, u64)> {
    EVENTS
        .iter()
        .map(|(event, word)| {
            let mut words = vec![exe.to_owned()];
            words.extend(prefix.iter().cloned());
            words.extend([HOOK_ARG.to_owned(), (*word).to_owned(), dir.display().to_string()]);
            let quoted: Vec<String> =
                words.iter().map(|w| format!("'{}'", w.replace('\'', "'\\''"))).collect();
            let timeout =
                if *event == "SessionEnd" { SESSION_END_TIMEOUT_SECS } else { HOOK_TIMEOUT_SECS };
            ((*event).to_owned(), quoted.join(" "), timeout)
        })
        .collect()
}

/// Whether a local `codex app-server` launch of `program args` in `cwd` gets the dedupe hooks:
/// the feature on, on unix, a command line that leaves Codex's hooks alone, and a Codex that
/// runs session-flag hooks (`codex_repo_gate::MIN_VERSION`).
pub fn wanted(
    program: &str,
    args: &[String],
    cwd: &Path,
    probe_env: &[(String, Option<String>)],
) -> bool {
    cfg!(unix)
        && crate::claude_stdio::dedupe_enabled_now()
        && crate::codex_app_server::is_launch(program, args)
        && !args.iter().any(|a| a.contains("hooks"))
        && crate::codex_repo_gate::supported(program, cwd, probe_env)
}

#[cfg(all(test, unix))]
#[path = "codex_dedupe_tests.rs"]
mod tests;
