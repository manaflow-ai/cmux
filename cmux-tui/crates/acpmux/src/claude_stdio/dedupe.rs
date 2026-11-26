//! Harness magic `dedupe`: a call whose answer is already in the model's context is answered
//! with a one-line stub instead of running again.
//!
//! Measured on our own sessions (leo-workspace `tools/costs_sessions.py`, 2026-11-20): 6.7% of
//! tool calls were identical (tool and input) to an earlier call in the same session, and every
//! extra request reads the whole context again. Claude Code 2.1.331 carries its own "File
//! unchanged since last read" stub, but it did not fire in a `claude -p` stream-json session: two
//! Reads of one unchanged file, in separate steps, both returned the whole file (2026-11-24, haiku
//! and sonnet). So acpmux answers them itself, through a PreToolUse hook callback
//! ([`DEDUPE_CALLBACK`]) registered at `initialize` beside `cmux-repo-sync` and
//! `acpmux-policy-gate`. Claude Code runs every matching hook and takes the strictest answer, so
//! the gate still holds: this callback only ever answers nothing or `deny` with the stub.
//!
//! Two kinds of call are stubbed, each at most once per earlier result (the model that asks
//! again gets the call run, so a context that lost the earlier result costs one call, not a
//! loop):
//! - a `Read` of a file (same path, the same lines or fewer) whose content hash and stat are
//!   what they were when this session last read it;
//! - in the same turn, the same Bash command from a short read-only list whose every input
//!   (`dedupe_shell.rs`) stats the same.
//!
//! State resets on a compaction (`compact_boundary`), on `/clear`, after 5 minutes with no tool
//! call (Claude Code may clear old tool results once its prompt cache has lapsed), and with the
//! process (a resumed chat is a new process with a new translator). A subagent's calls are kept
//! apart from the main thread's: its context is its own.
//!
//! The output cap the feature also planned is Claude Code's already: a Bash result over 30,000
//! characters is saved to a file and the model gets a 2 KB preview and the path (38 KB and 59.5
//! KB results, measured the same day), so acpmux adds nothing there.
//!
//! Off by default (Leo, 2026-11-26: "identify all the weird opinionated fleet things we shipped
//! into the app and remove them"): it refuses a call the agent made, so only a person who asked
//! for it gets it. On: `agents.harnessMagic.dedupe.enabled: true`; `ACPMUX_HM_DEDUPE=0` turns it
//! off whatever the file says. Fails open: any
//! error, a fingerprint that takes over [`WORK_BOUND`], or a call it does not know passes through
//! with no decision. Counted per turn on the prompt result's `_meta.harnessMagic.dedupe`, which
//! the hub puts on `turn_result` (`readsStubbed`, `callsStubbed`, `estTokensSaved`).

use super::dedupe_shell::{self, Inputs};
use super::*;
use std::path::PathBuf;
use std::time::{Duration, Instant};

/// The callback's id.
pub(super) const DEDUPE_CALLBACK: &str = "acpmux-dedupe";
/// The tools it is fired for.
pub(super) const DEDUPE_MATCHER: &str = "Read|Bash";
/// Claude Code's wait for the answer, in seconds. The answer comes in milliseconds; a fingerprint
/// past [`WORK_BOUND`] answers nothing.
pub(super) const DEDUPE_TIMEOUT_S: u64 = 30;
/// The setting that turns it on (off unless `true`).
pub const SETTING_ENABLED: &str = "agents.harnessMagic.dedupe.enabled";
/// The daemon's switch, over the setting: `0` (or `false`, `off`, `no`) turns it off, `1` (or
/// `true`, `on`, `yes`) on.
pub const KILL_ENV: &str = "ACPMUX_HM_DEDUPE";

const IDLE_RESET: Duration = Duration::from_secs(300);
const WORK_BOUND: Duration = Duration::from_secs(3);
/// The largest file it hashes; a bigger one passes through.
const MAX_HASHED: u64 = 4 << 20;
/// Claude Code's Read with no `limit` shows this many lines.
const DEFAULT_READ_LINES: u64 = 2000;
const MAX_READS_PER_FILE: usize = 4;
const MAX_PENDING: usize = 512;
const MAX_RECORDS: usize = 4096;

#[cfg(test)]
thread_local! {
    /// Turns the feature on for this test thread, whatever the settings file says (it is off by
    /// default; a `#[tokio::test]` runs on one thread).
    pub(super) static ON_FOR_TEST: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// Whether the feature is on now (the setting is read at most every 5 s).
pub(super) fn enabled() -> bool {
    let env = std::env::var(KILL_ENV).ok();
    if env_off(env.as_deref()) {
        return false;
    }
    if env.as_deref().is_some_and(|v| {
        matches!(v.trim().to_ascii_lowercase().as_str(), "1" | "true" | "on" | "yes")
    }) {
        return true;
    }
    #[cfg(test)]
    if ON_FOR_TEST.with(std::cell::Cell::get) {
        return true;
    }
    static CACHE: std::sync::Mutex<Option<(Instant, bool)>> = std::sync::Mutex::new(None);
    let Ok(mut cache) = CACHE.lock() else { return false };
    if let Some((at, on)) = *cache
        && at.elapsed() < Duration::from_secs(5)
    {
        return on;
    }
    let on = match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => enabled_in(Some(&doc)),
        _ => false,
    };
    *cache = Some((Instant::now(), on));
    on
}

/// On unless the settings document turns it off.
pub(super) fn enabled_in(doc: Option<&Value>) -> bool {
    doc.and_then(|d| crate::user_settings::value(d, SETTING_ENABLED)).and_then(|v| v.as_bool())
        == Some(true)
}

pub(super) fn env_off(value: Option<&str>) -> bool {
    matches!(
        value.map(|v| v.trim().to_ascii_lowercase()).as_deref(),
        Some("0" | "false" | "off" | "no")
    )
}

/// A turn's counts.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub(super) struct Counters {
    pub reads_stubbed: u64,
    pub calls_stubbed: u64,
    pub est_tokens_saved: u64,
}

impl Counters {
    pub(super) fn to_json(self) -> Value {
        json!({
            "readsStubbed": self.reads_stubbed,
            "callsStubbed": self.calls_stubbed,
            "estTokensSaved": self.est_tokens_saved,
        })
    }
}

/// A call the callback knows.
#[derive(Debug, Clone, PartialEq)]
pub(super) enum Call {
    /// `lines`: the first line and one past the last.
    Read {
        path: PathBuf,
        lines: (u64, u64),
    },
    Shell {
        cwd: String,
        command: String,
        inputs: Inputs,
    },
}

impl Call {
    /// The call in a PreToolUse hook `input`, when it is one the callback may stub.
    pub(super) fn of(input: &Value) -> Option<Call> {
        let tool = input.get("tool_name")?.as_str()?;
        let args = input.get("tool_input")?.as_object()?;
        match tool {
            "Read" => {
                if args.keys().any(|k| !matches!(k.as_str(), "file_path" | "offset" | "limit")) {
                    return None;
                }
                let path = PathBuf::from(args.get("file_path")?.as_str()?);
                if !path.is_absolute() {
                    return None;
                }
                let number = |k: &str| match args.get(k) {
                    None | Some(Value::Null) => Some(None),
                    Some(v) => v.as_u64().map(Some),
                };
                let start = number("offset")?.unwrap_or(1).max(1);
                let count = number("limit")?.unwrap_or(DEFAULT_READ_LINES);
                Some(Call::Read { path, lines: (start, start.saturating_add(count)) })
            }
            "Bash" => {
                if args.keys().any(|k| !matches!(k.as_str(), "command" | "description" | "timeout"))
                {
                    return None;
                }
                let command = args.get("command")?.as_str()?.trim().to_owned();
                let cwd = input.get("cwd")?.as_str()?.to_owned();
                if !Path::new(&cwd).is_absolute() {
                    return None;
                }
                let inputs = dedupe_shell::inputs(&command, Path::new(&cwd))?;
                Some(Call::Shell { cwd, command, inputs })
            }
            _ => None,
        }
    }

    /// The fingerprint of what the call's answer depends on, or `None` when it cannot be taken.
    pub(super) fn fingerprint(&self) -> Option<String> {
        match self {
            Call::Read { path, .. } => file_fingerprint(path),
            Call::Shell { inputs, .. } => dedupe_shell::fingerprint(inputs),
        }
    }
}

/// A regular file's stat and content hash.
fn file_fingerprint(path: &Path) -> Option<String> {
    use sha2::Digest;
    let meta = std::fs::metadata(path).ok()?;
    if !meta.is_file() || meta.len() > MAX_HASHED {
        return None;
    }
    let before = dedupe_shell::stamp(path);
    let bytes = std::fs::read(path).ok()?;
    // Written while it was read: no fingerprint.
    if dedupe_shell::stamp(path) != before {
        return None;
    }
    let hash = sha2::Sha256::digest(&bytes);
    Some(format!("{before}\n{hash:x}"))
}

/// The fingerprint's stat part, to check a call's inputs did not move while it ran.
fn stamp_part(call: &Call, fingerprint: &str) -> Option<String> {
    match call {
        Call::Read { path, .. } => {
            let now = dedupe_shell::stamp(path);
            fingerprint.starts_with(&format!("{now}\n")).then_some(now)
        }
        Call::Shell { inputs, .. } => {
            (dedupe_shell::fingerprint(inputs).as_deref() == Some(fingerprint)).then(String::new)
        }
    }
}

struct Pending {
    agent: String,
    call: Call,
    fingerprint: String,
    at: u64,
    turn: u64,
    epoch: u64,
}

struct Seen {
    fingerprint: String,
    lines: (u64, u64),
    at: u64,
    turn: u64,
    chars: usize,
    stubbed: bool,
}

#[derive(Default)]
struct State {
    /// Tool calls the callback saw, numbered from 1.
    calls: u64,
    turn: u64,
    /// Bumped by each reset: a result of a call made before it records nothing.
    epoch: u64,
    last_call: Option<Instant>,
    pending: HashMap<String, Pending>,
    reads: HashMap<(String, PathBuf), Vec<Seen>>,
    shells: HashMap<(String, String, String), Seen>,
    counters: Counters,
}

impl State {
    fn forget(&mut self) {
        self.pending.clear();
        self.reads.clear();
        self.shells.clear();
        self.epoch += 1;
    }
}

/// One Claude Code process's dedupe state.
#[derive(Default)]
pub(super) struct Dedupe {
    state: std::sync::Mutex<State>,
}

impl Dedupe {
    /// The stub for tool call `use_id` by `agent` ("" for the main thread), or `None` to let it
    /// run (it is then remembered until its result comes).
    pub(super) fn decide(
        &self,
        use_id: &str,
        agent: &str,
        call: Call,
        fingerprint: String,
        now: Instant,
    ) -> Option<String> {
        let mut s = self.state.lock().ok()?;
        if s.last_call.is_some_and(|at| now.saturating_duration_since(at) > IDLE_RESET) {
            s.forget();
        }
        s.last_call = Some(now);
        s.calls += 1;
        let n = s.calls;
        let turn = s.turn;
        let found = match &call {
            Call::Read { path, lines } => s
                .reads
                .get_mut(&(agent.to_owned(), path.clone()))
                .and_then(|seen| {
                    seen.iter_mut().find(|r| {
                        !r.stubbed
                            && r.fingerprint == fingerprint
                            && r.lines.0 <= lines.0
                            && lines.1 <= r.lines.1
                    })
                })
                .map(|r| {
                    r.stubbed = true;
                    (n - r.at, r.chars)
                }),
            Call::Shell { cwd, command, .. } => s
                .shells
                .get_mut(&(agent.to_owned(), cwd.clone(), command.clone()))
                .filter(|r| !r.stubbed && r.turn == turn && r.fingerprint == fingerprint)
                .map(|r| {
                    r.stubbed = true;
                    (n - r.at, r.chars)
                }),
        };
        if let Some((ago, chars)) = found {
            let stub = stub(&call, ago);
            let saved = (chars.saturating_sub(stub.len()) / 4) as u64;
            match call {
                Call::Read { .. } => s.counters.reads_stubbed += 1,
                Call::Shell { .. } => s.counters.calls_stubbed += 1,
            }
            s.counters.est_tokens_saved += saved;
            return Some(stub);
        }
        if s.pending.len() >= MAX_PENDING {
            s.pending.clear();
        }
        let epoch = s.epoch;
        s.pending.insert(
            use_id.to_owned(),
            Pending { agent: agent.to_owned(), call, fingerprint, at: n, turn, epoch },
        );
        None
    }

    /// Tool call `use_id`'s result came: a clean one whose inputs did not move while it ran is
    /// what a later identical call is answered from.
    pub(super) fn result(&self, use_id: &str, is_error: bool, text: &str) {
        let Some(p) = self.state.lock().ok().and_then(|mut s| s.pending.remove(use_id)) else {
            return;
        };
        if is_error || text.is_empty() || !full_answer(text) {
            return;
        }
        if stamp_part(&p.call, &p.fingerprint).is_none() {
            return;
        }
        let Ok(mut s) = self.state.lock() else { return };
        if s.epoch != p.epoch {
            return;
        }
        let total: usize = s.reads.values().map(Vec::len).sum::<usize>() + s.shells.len();
        if total >= MAX_RECORDS {
            s.reads.clear();
            s.shells.clear();
        }
        let chars = text.chars().count();
        match p.call {
            Call::Read { path, lines } => {
                let seen = s.reads.entry((p.agent, path)).or_default();
                seen.retain(|r| r.fingerprint == p.fingerprint);
                if seen.len() >= MAX_READS_PER_FILE {
                    seen.remove(0);
                }
                seen.push(Seen {
                    fingerprint: p.fingerprint,
                    lines,
                    at: p.at,
                    turn: p.turn,
                    chars,
                    stubbed: false,
                });
            }
            Call::Shell { cwd, command, .. } => {
                s.shells.insert(
                    (p.agent, cwd, command),
                    Seen {
                        fingerprint: p.fingerprint,
                        lines: (0, 0),
                        at: p.at,
                        turn: p.turn,
                        chars,
                        stubbed: false,
                    },
                );
            }
        }
    }

    /// The context no longer holds what was read (a compaction, `/clear`).
    pub(super) fn reset(&self) {
        if let Ok(mut s) = self.state.lock() {
            s.forget();
        }
    }

    /// A turn ended: its counts (taken), and shell results stop counting.
    pub(super) fn turn_ended(&self) -> Counters {
        let Ok(mut s) = self.state.lock() else { return Counters::default() };
        s.turn += 1;
        s.shells.clear();
        std::mem::take(&mut s.counters)
    }
}

/// Whether a result's text is the call's whole answer: not Claude Code's own unchanged-file stub,
/// and not a view its token cap cut.
fn full_answer(text: &str) -> bool {
    const NOT: [&str; 4] = [
        "File unchanged since last read",
        "Wasted call",
        "<system-reminder>This file is already in your context",
        "[dedupe]",
    ];
    !NOT.iter().any(|p| text.starts_with(p)) && !text.contains("[Truncated: PARTIAL view")
}

/// What the model reads instead of the call's result.
pub(super) fn stub(call: &Call, ago: u64) -> String {
    let ago = match ago {
        1 => "1 call ago".to_owned(),
        n => format!("{n} calls ago"),
    };
    match call {
        Call::Read { .. } => format!(
            "[dedupe] unchanged since your Read {ago}; it is still in your context. (Not read \
             again. If that result is no longer in your context, Read again and it runs.)"
        ),
        Call::Shell { command, .. } => format!(
            "[dedupe] `{command}` ran {ago} with the same inputs (no file or ref it reads \
             changed), so its output is the same; it is still in your context. (Not run again. \
             Run it again and it runs.)"
        ),
    }
}

impl Translator {
    /// Claude Code fired the dedupe callback (`req`, its `hook_callback`).
    pub(super) async fn dedupe_hook(&self, rid: &str, req: &Value) {
        let output = self.dedupe_output(req).await;
        self.stdin_replies.lock().await.push(policy_gate::hook_reply(rid, output));
    }

    async fn dedupe_output(&self, req: &Value) -> Value {
        let pass = json!({});
        if !enabled() {
            return pass;
        }
        let input = req.get("input").cloned().unwrap_or(Value::Null);
        let Some(call) = Call::of(&input) else { return pass };
        let use_id = input
            .get("tool_use_id")
            .or_else(|| req.get("tool_use_id"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned();
        if use_id.is_empty() {
            return pass;
        }
        let agent = input.get("agent_id").and_then(Value::as_str).unwrap_or("").to_owned();
        let probe = call.clone();
        let work = tokio::task::spawn_blocking(move || probe.fingerprint());
        let Ok(Ok(Some(fingerprint))) = tokio::time::timeout(WORK_BOUND, work).await else {
            return pass;
        };
        match self.dedupe.decide(&use_id, &agent, call, fingerprint, Instant::now()) {
            Some(stub) => policy_gate::pre_tool("deny", &stub),
            None => pass,
        }
    }

    /// A tool result (`inbound.rs`): off the reading task, as its check stats files.
    pub(super) async fn dedupe_result(&self, use_id: &str, is_error: bool, text: &str) {
        if use_id.is_empty() || !self.dedupe.has_pending(use_id) {
            return;
        }
        let dedupe = self.dedupe.clone();
        let (use_id, text) = (use_id.to_owned(), text.to_owned());
        let work = tokio::task::spawn_blocking(move || dedupe.result(&use_id, is_error, &text));
        let _ = tokio::time::timeout(WORK_BOUND, work).await;
    }
}

impl Dedupe {
    pub(super) fn has_pending(&self, use_id: &str) -> bool {
        self.state.lock().is_ok_and(|s| s.pending.contains_key(use_id))
    }
}
