//! Harness magic `dirRules` (RFD 0158 §12, beside `pathRules`' `.agents/rules/*.md`): a directory's
//! `AGENTS.md` reaches the model the
//! first time the session touches a file under that directory, as the tool result's
//! `additionalContext`, instead of never.
//!
//! Measured on our own sessions (101 recent Claude Code transcripts on a lane VM, 2026-11-26):
//! Claude Code loads a nested `CLAUDE.md` when a call touches its directory, and in this repo
//! those files are one-line pointers ("Read and follow `AGENTS.md` in this directory before you
//! change ..."). 76 (session, directory) pointer loads, 0 followed by a Read of the `AGENTS.md`
//! they point to: the directory's rules never reached the model. This callback reads that
//! `AGENTS.md` and appends it to the result of the call that touched the directory, once per
//! context. Appended after the call, not put in the system prompt, so the prompt cache holds.
//!
//! Which files: walking up from the touched path to the repository root (the first directory
//! holding `.git`), every `AGENTS.md` whose directory's `CLAUDE.md` does not already bring it in
//! (a `CLAUDE.md` that is, or links to, that `AGENTS.md`, or imports it with `@AGENTS.md`, is
//! loaded by Claude Code itself; the repo root's is, through the system prompt). Outermost first.
//! Each at most [`MAX_FILE_BYTES`] (a longer one is cut, with its path to read the rest), at
//! most [`MAX_CALL_BYTES`] per call.
//!
//! State: the directories already shown, per context (the main thread, each subagent apart).
//! It resets on a compaction (`compact_boundary`), on `/clear`, and with the process.
//!
//! Off by default (Leo, 2026-11-26: "identify all the weird opinionated fleet things we shipped
//! into the app and remove them"): it adds text to the agent's context, so only a person who
//! asked for it gets it. On: `agents.harnessMagic.dirRules.enabled: true`; `ACPMUX_HM_DIRRULES=0`
//! turns it off whatever the file says. Fails open: any error, or a walk over [`WORK_BOUND`],
//! answers nothing. Counted per turn on the prompt result's `_meta.harnessMagic.dirRules`
//! (`filesInjected`, `bytesInjected`).

use super::*;
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// The callback's id.
pub(super) const DIR_RULES_CALLBACK: &str = "acpmux-dir-rules";
/// The tools it is fired for: the ones whose input names a path.
pub(super) const DIR_RULES_MATCHER: &str = "Read|Edit|Write|MultiEdit|NotebookEdit|Grep|Glob";
/// Claude Code's wait for the answer, in seconds.
pub(super) const DIR_RULES_TIMEOUT_S: u64 = 10;
/// The setting that turns it on (off unless `true`).
pub const SETTING_ENABLED: &str = "agents.harnessMagic.dirRules.enabled";
/// The daemon's switch, over the setting.
pub const KILL_ENV: &str = "ACPMUX_HM_DIRRULES";

const WORK_BOUND: Duration = Duration::from_secs(2);
/// The most of one `AGENTS.md` shown.
pub(super) const MAX_FILE_BYTES: usize = 12 * 1024;
/// The most shown after one call.
pub(super) const MAX_CALL_BYTES: usize = 24 * 1024;
/// How far up it looks for the repository root.
const MAX_DEPTH: usize = 24;
const MAX_SEEN: usize = 4096;

#[cfg(test)]
thread_local! {
    pub(super) static ON_FOR_TEST: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// Whether the feature is on now (the setting is read at most every 5 s).
pub(crate) fn enabled() -> bool {
    let env = std::env::var(KILL_ENV).ok();
    if super::dedupe::env_off(env.as_deref()) {
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

/// On only when the settings document says `true`.
pub(super) fn enabled_in(doc: Option<&Value>) -> bool {
    doc.and_then(|d| crate::user_settings::value(d, SETTING_ENABLED)).and_then(|v| v.as_bool())
        == Some(true)
}

/// A turn's counts.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub(super) struct Counters {
    pub files_injected: u64,
    pub bytes_injected: u64,
}

impl Counters {
    pub(super) fn to_json(self) -> Value {
        json!({"filesInjected": self.files_injected, "bytesInjected": self.bytes_injected})
    }
}

/// The directories each context has been shown, and the turn's counts.
#[derive(Default)]
pub(super) struct DirRules {
    inner: std::sync::Mutex<State>,
}

#[derive(Default)]
struct State {
    /// (agent id, `""` for the main thread; directory).
    seen: HashSet<(String, PathBuf)>,
    counters: Counters,
}

impl DirRules {
    /// Everything shown is gone from the context.
    pub(super) fn reset(&self) {
        if let Ok(mut s) = self.inner.lock() {
            s.seen.clear();
        }
    }

    pub(super) fn turn_ended(&self) -> Counters {
        self.inner.lock().map(|mut s| std::mem::take(&mut s.counters)).unwrap_or_default()
    }

    fn seen_for(&self, agent: &str) -> HashSet<PathBuf> {
        let Ok(s) = self.inner.lock() else { return HashSet::new() };
        s.seen.iter().filter(|(a, _)| a == agent).map(|(_, d)| d.clone()).collect()
    }

    /// Records what was shown and returns the rules no other call showed first.
    fn mark(&self, agent: &str, shown: &[Rule]) -> Vec<Rule> {
        let Ok(mut s) = self.inner.lock() else { return Vec::new() };
        if s.seen.len() > MAX_SEEN {
            s.seen.clear();
        }
        let fresh: Vec<Rule> = shown
            .iter()
            .filter(|r| s.seen.insert((agent.to_owned(), r.dir.clone())))
            .cloned()
            .collect();
        for r in &fresh {
            s.counters.files_injected += 1;
            s.counters.bytes_injected += r.text.len() as u64;
        }
        fresh
    }
}

/// One directory's rules, ready to show.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Rule {
    pub dir: PathBuf,
    pub file: PathBuf,
    pub text: String,
}

/// The path a call's input names, made absolute against `cwd`.
pub(super) fn touched_path(input: &Value) -> Option<PathBuf> {
    let tool_input = input.get("tool_input")?;
    let raw = ["file_path", "notebook_path", "path"]
        .iter()
        .find_map(|k| tool_input.get(*k).and_then(Value::as_str))
        .filter(|p| !p.is_empty())?;
    let path = PathBuf::from(raw);
    if path.is_absolute() {
        return Some(path);
    }
    let cwd = input.get("cwd").and_then(Value::as_str).filter(|c| !c.is_empty())?;
    Some(Path::new(cwd).join(path))
}

/// The `AGENTS.md` files covering `path` that Claude Code does not load itself and `seen` has
/// not had, outermost first, cut to the caps.
pub(super) fn rules_for(path: &Path, seen: &HashSet<PathBuf>) -> Vec<Rule> {
    let start = if path.is_dir() {
        path.to_path_buf()
    } else {
        match path.parent() {
            Some(p) => p.to_path_buf(),
            None => return Vec::new(),
        }
    };
    let mut dirs = Vec::new();
    let mut root = false;
    for dir in start.ancestors().take(MAX_DEPTH) {
        dirs.push(dir.to_path_buf());
        if dir.join(".git").exists() {
            root = true;
            break;
        }
    }
    // Outside a repository: nobody wrote rules for this path.
    if !root {
        return Vec::new();
    }
    let mut out = Vec::new();
    let mut total = 0;
    for dir in dirs.into_iter().rev() {
        if seen.contains(&dir) {
            continue;
        }
        let file = dir.join("AGENTS.md");
        let Ok(text) = std::fs::read_to_string(&file) else { continue };
        if text.trim().is_empty() || claude_loads_it(&dir, &file) {
            continue;
        }
        let text = cut(&text, &file);
        if total + text.len() > MAX_CALL_BYTES {
            break;
        }
        total += text.len();
        out.push(Rule { dir, file, text });
    }
    out
}

/// Whether the directory's `CLAUDE.md` already brings its `AGENTS.md` into the context.
fn claude_loads_it(dir: &Path, agents: &Path) -> bool {
    let claude = dir.join("CLAUDE.md");
    if let (Ok(a), Ok(b)) = (std::fs::canonicalize(&claude), std::fs::canonicalize(agents))
        && a == b
    {
        return true;
    }
    std::fs::read_to_string(&claude)
        .is_ok_and(|t| t.lines().any(|l| l.trim() == "@AGENTS.md" || l.trim() == "@./AGENTS.md"))
}

fn cut(text: &str, file: &Path) -> String {
    if text.len() <= MAX_FILE_BYTES {
        return text.to_owned();
    }
    let head = text.get(..text.floor_char_boundary(MAX_FILE_BYTES)).unwrap_or_default();
    format!("{head}\n[cut at {MAX_FILE_BYTES} bytes; the rest is in {}]", file.display())
}

/// The text added to the call's result.
pub(super) fn context_text(rules: &[Rule]) -> String {
    let mut s = String::new();
    for r in rules {
        s.push_str(&format!(
            "<directory-rules path=\"{}\">\nThe rules for files under {} (shown once; follow them for this work):\n{}\n</directory-rules>\n",
            r.file.display(),
            r.dir.display(),
            r.text.trim_end()
        ));
    }
    s
}

impl Translator {
    pub(super) async fn dir_rules_hook(&self, rid: &str, req: &Value) {
        let output = self.dir_rules_output(req).await;
        self.stdin_replies.lock().await.push(policy_gate::hook_reply(rid, output));
    }

    async fn dir_rules_output(&self, req: &Value) -> Value {
        let pass = json!({});
        let input = req.get("input").cloned().unwrap_or(Value::Null);
        if !enabled() || input.get("hook_event_name").and_then(Value::as_str) != Some("PostToolUse")
        {
            return pass;
        }
        let Some(path) = touched_path(&input) else { return pass };
        let agent = input.get("agent_id").and_then(Value::as_str).unwrap_or("").to_owned();
        let seen = self.dir_rules.seen_for(&agent);
        let work = tokio::task::spawn_blocking(move || rules_for(&path, &seen));
        let Ok(Ok(rules)) = tokio::time::timeout(WORK_BOUND, work).await else { return pass };
        let fresh = self.dir_rules.mark(&agent, &rules);
        if fresh.is_empty() {
            return pass;
        }
        json!({"hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": context_text(&fresh),
        }})
    }
}
