//! Harness magic `pathRules` (RFD 0158 §12): a repo's rule file loads the first time a session
//! touches a path it covers, as the PostToolUse hook's `additionalContext`, and not in every
//! session's system prompt.
//!
//! Why: a rule the system prompt carries is paid for on every request of every session, also by
//! the sessions that never touch the area it is about. A rule appended after the tool result that
//! needed it costs its tokens once, where it steers, and keeps the cache: nothing before it moves.
//! OpenHands skills carry the same `paths` triggers.
//!
//! A rule is a Markdown file in a repo's `.agents/rules/` with a front matter naming its paths,
//! globs from the repo's root (`*` stays within one folder, `**` crosses folders):
//!
//! ```text
//! ---
//! paths: ["cmux-tui/crates/acpmux/**", "docs/acpmux/*.md"]
//! ---
//! The rule's text.
//! ```
//!
//! `paths` may also be one glob, a comma-separated line, or a YAML block list (`- glob` lines). A
//! file with no `paths` is not a path rule and is skipped: a rule for every session belongs in
//! AGENTS.md. The repo is found from the touched file, so a session in one folder that edits a file
//! of another repo gets that repo's rules. `.agents/rules/` and not `.claude/rules/`, which Claude
//! Code loads by itself, so a rule is never said twice.
//!
//! The hook fires after a successful `Read`, `Edit`, `Write`, `MultiEdit` or `NotebookEdit`
//! ([`PATH_RULES_MATCHER`]). Each rule is said once per context: once in the main thread and once
//! in each subagent, whose context is its own, and again after a compaction or `/clear`, which drop
//! what was said. At most [`MAX_SAY`] characters go into one tool result; the rest wait for the next
//! touch.
//!
//! On by default (RFD 0158's determination: §12 in the first group); it does nothing in a repo with
//! no `.agents/rules/`. Off: `agents.harnessMagic.pathRules.enabled: false`, kill switch
//! `ACPMUX_HM_PATHRULES=0`. Fails open: an unreadable or malformed file is skipped, and the call's
//! result is left as it was. Counted per turn on the prompt result's
//! `_meta.harnessMagic.pathRules`, which the hub puts on `turn_result`: `fired` (rules said),
//! `saidChars` (their characters, the tokens they cost) and `deferred` (rules over the cap, said
//! at a later touch). A firing is logged with its rule id, never its text.

use super::*;
use std::collections::HashSet;
use std::path::{Path, PathBuf};

/// The callback's id.
pub(super) const PATH_RULES_CALLBACK: &str = "acpmux-path-rules";
/// The tools it fires after: the ones that name one file.
pub(super) const PATH_RULES_MATCHER: &str = "Read|Edit|Write|MultiEdit|NotebookEdit";
/// Claude Code's wait for the answer, in seconds; the answer is a few file reads.
pub(super) const PATH_RULES_TIMEOUT_S: u64 = 10;
/// The feature's name in `agents.harnessMagic` and on `turn_result`.
pub(crate) const FEATURE: &str = "pathRules";
/// Where a repo keeps its path rules, from its root.
pub(super) const RULES_DIR: &str = ".agents/rules";
/// The most rule files read from one repo.
const MAX_RULES: usize = 200;
/// The largest rule file read; a bigger one is skipped.
const MAX_RULE_BYTES: u64 = 16 * 1024;
/// The most characters said into one tool result.
pub(super) const MAX_SAY: usize = 12_000;
/// The most folders walked up from a touched file to find a repo's rules.
const MAX_DEPTH: usize = 64;

/// One rule file.
#[derive(Debug, Clone)]
pub(super) struct Rule {
    /// The file's name without `.md`.
    pub id: String,
    pub paths: Vec<glob::Pattern>,
    pub body: String,
}

/// Parses a rule file's text; `None` when it has no front matter, no `paths`, or no body.
pub(super) fn parse(id: &str, text: &str) -> Option<Rule> {
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let rest = text.strip_prefix("---\n").or_else(|| text.strip_prefix("---\r\n"))?;
    let mut front = Vec::new();
    let mut body_at = None;
    let mut offset: usize = 0;
    for line in rest.split_inclusive('\n') {
        offset = offset.saturating_add(line.len());
        if line.trim_end() == "---" {
            body_at = Some(offset);
            break;
        }
        front.push(line.trim_end_matches(['\n', '\r']));
    }
    let body = rest.get(body_at?..)?.trim();
    if body.is_empty() {
        return None;
    }
    let globs = front_paths(&front);
    let paths: Vec<glob::Pattern> =
        globs.iter().filter_map(|g| glob::Pattern::new(g.trim_start_matches("./")).ok()).collect();
    if paths.is_empty() {
        return None;
    }
    Some(Rule { id: id.to_owned(), paths, body: body.to_owned() })
}

/// The `paths` of a front matter's lines: an inline list, one glob or a comma-separated line, or
/// the `- glob` lines that follow an empty `paths:`.
fn front_paths(front: &[&str]) -> Vec<String> {
    let unquote = |s: &str| s.trim().trim_matches(|c| c == '"' || c == '\'').trim().to_owned();
    let mut lines = front.iter();
    while let Some(line) = lines.next() {
        let Some(value) = line.strip_prefix("paths:") else { continue };
        let value = value.trim();
        if value.is_empty() {
            return lines
                .map(|l| l.trim())
                .take_while(|l| l.starts_with('-') || l.is_empty())
                .filter_map(|l| l.strip_prefix('-'))
                .map(unquote)
                .filter(|g| !g.is_empty())
                .collect();
        }
        let value = value.strip_prefix('[').and_then(|v| v.strip_suffix(']')).unwrap_or(value);
        return value.split(',').map(unquote).filter(|g| !g.is_empty()).collect();
    }
    Vec::new()
}

/// Whether `rule` covers `rel`, a path from the repo's root with `/` separators.
pub(super) fn covers(rule: &Rule, rel: &str) -> bool {
    let options = glob::MatchOptions {
        case_sensitive: true,
        require_literal_separator: true,
        require_literal_leading_dot: false,
    };
    rule.paths.iter().any(|p| p.matches_with(rel, options))
}

/// The nearest folder above `file` holding [`RULES_DIR`], and `file` from it; the walk stops at
/// a repo's root (a `.git`) or after [`MAX_DEPTH`] folders.
pub(super) fn find_root(file: &Path) -> Option<(PathBuf, String)> {
    let mut dir = file.parent();
    for _ in 0..MAX_DEPTH {
        let d = dir?;
        if d.join(RULES_DIR).is_dir() {
            let rel = file.strip_prefix(d).ok()?;
            let rel: Vec<&str> = rel.iter().filter_map(|c| c.to_str()).collect();
            return Some((d.to_path_buf(), rel.join("/")));
        }
        if d.join(".git").exists() {
            return None;
        }
        dir = d.parent();
    }
    None
}

/// The path rules of the repo at `root`, in file-name order.
pub(super) fn load(root: &Path) -> Vec<Rule> {
    let Ok(entries) = std::fs::read_dir(root.join(RULES_DIR)) else { return Vec::new() };
    let mut files: Vec<PathBuf> = entries
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == "md"))
        .collect();
    files.sort();
    files.truncate(MAX_RULES);
    files
        .iter()
        .filter(|p| std::fs::metadata(p).is_ok_and(|m| m.is_file() && m.len() <= MAX_RULE_BYTES))
        .filter_map(|p| {
            let id = p.file_stem()?.to_str()?;
            parse(id, &std::fs::read_to_string(p).ok()?)
        })
        .collect()
}

/// A turn's counts.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub(super) struct Counters {
    pub fired: u64,
    pub said_chars: u64,
    pub deferred: u64,
}

impl Counters {
    pub(super) fn to_json(self) -> Value {
        json!({"fired": self.fired, "saidChars": self.said_chars, "deferred": self.deferred})
    }
}

#[derive(Default)]
struct State {
    /// (context: "" for the main thread, else the subagent's id; repo root; rule id).
    said: HashSet<(String, PathBuf, String)>,
    counters: Counters,
}

/// The rules said in this process's contexts, and the turn's counts.
#[derive(Default)]
pub(super) struct PathRules {
    state: std::sync::Mutex<State>,
}

impl PathRules {
    /// The `additionalContext` for a PostToolUse hook's `input`, marking what it says as said;
    /// `None` when no rule is due.
    pub(super) fn context_for(&self, input: &Value) -> Option<String> {
        let tool = &input["tool_input"];
        let raw = tool["file_path"].as_str().or_else(|| tool["notebook_path"].as_str())?;
        let mut file = PathBuf::from(raw);
        if file.is_relative() {
            file = Path::new(input["cwd"].as_str()?).join(file);
        }
        let (root, rel) = find_root(&file)?;
        let rules = load(&root);
        let context = input["agent_id"].as_str().unwrap_or("").to_owned();
        let mut state = self.state.lock().ok()?;
        let mut parts = Vec::new();
        let mut used: usize = 0;
        for rule in rules.iter().filter(|r| covers(r, &rel)) {
            let key = (context.clone(), root.clone(), rule.id.clone());
            if state.said.contains(&key) {
                continue;
            }
            let part = format!(
                "Repo rule `{RULES_DIR}/{}.md`, loaded because this session touched `{rel}` (said once):\n{}",
                rule.id, rule.body
            );
            if used.saturating_add(part.len()) > MAX_SAY && !parts.is_empty() {
                state.counters.deferred = state.counters.deferred.saturating_add(1);
                continue;
            }
            used = used.saturating_add(part.len());
            tracing::info!(rule = %rule.id, root = %root.display(), "pathRules: said");
            state.said.insert(key);
            state.counters.fired = state.counters.fired.saturating_add(1);
            let said = u64::try_from(part.chars().count()).unwrap_or(u64::MAX);
            state.counters.said_chars = state.counters.said_chars.saturating_add(said);
            parts.push(part);
        }
        (!parts.is_empty()).then(|| parts.join("\n\n"))
    }

    /// The turn's counts, reset for the next turn.
    pub(super) fn turn_ended(&self) -> Counters {
        self.state.lock().map(|mut s| std::mem::take(&mut s.counters)).unwrap_or_default()
    }

    /// A compaction or `/clear` dropped what was said: every rule is due again.
    pub(super) fn reset(&self) {
        if let Ok(mut s) = self.state.lock() {
            s.said.clear();
        }
    }
}

/// Whether the feature is on now (`agents.harnessMagic.pathRules.enabled`, `ACPMUX_HM_PATHRULES`).
pub(crate) fn enabled() -> bool {
    crate::hub::harness_magic::enabled(FEATURE)
}

/// The hook's answer: the rules due as `additionalContext`, or nothing.
pub(super) fn output(rules: &PathRules, input: &Value) -> Value {
    if input["hook_event_name"] != "PostToolUse" {
        return json!({});
    }
    match rules.context_for(input) {
        Some(text) => json!({"hookSpecificOutput": {
            "hookEventName": "PostToolUse", "additionalContext": text}}),
        None => json!({}),
    }
}

impl Translator {
    pub(super) async fn path_rules_hook(&self, rid: &str, req: &Value) {
        let output = if enabled() {
            let rules = self.path_rules.clone();
            let input = req.get("input").cloned().unwrap_or(Value::Null);
            tokio::task::spawn_blocking(move || output(&rules, &input))
                .await
                .unwrap_or_else(|_| json!({}))
        } else {
            json!({})
        };
        self.stdin_replies.lock().await.push(policy_gate::hook_reply(rid, output));
    }
}
