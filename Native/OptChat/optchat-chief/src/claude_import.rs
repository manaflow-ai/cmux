//! `optchat-chief import-claude-code`: Claude Code transcripts
//! (`~/.claude/projects/<project>/<session>.jsonl`) as import items
//! (section 10: "months of older agent sessions as plain text: the user's
//! messages and the agent's final replies, without repeated pastes and tool
//! noise").
//!
//! Per session, in file order: a `note` naming the session and its working
//! directory, then for each turn the user's message (`user`), one `tool`
//! line summarizing the turn's tool calls (names with counts and the files
//! they named; never inputs or outputs, which can hold secrets) and the
//! turn's final reply (`talk`). Every item keeps its transcript timestamp.
//! Dropped: thinking, intermediate replies, tool results, meta lines, slash
//! command lines, interruptions, subagent (sidechain) lines, lines a resumed
//! session copied from an earlier one (same uuid), and a long user message
//! seen before (a repeated paste). Sessions go in order of their first line.
//!
//! The conversion only reads; `browse::import` writes the items through the
//! chat.

use std::collections::HashSet;
use std::fmt;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use optchat_core::Kind;
use serde_json::Value;

use crate::browse::Imported;

/// A user message at least this long, seen before, is a repeated paste.
pub const PASTE_CHARS: usize = 500;
/// Most files a tool summary names.
const SUMMARY_FILES: usize = 8;

/// What a conversion found (the dry run prints it).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Stats {
    pub sessions: usize,
    pub user: usize,
    pub replies: usize,
    pub tool_summaries: usize,
    pub repeated_pastes: usize,
    /// Lines a resumed session copied from an earlier one.
    pub copied_lines: usize,
    /// Lines that are not a JSON object.
    pub bad_lines: usize,
    /// Earliest and latest imported item's date.
    pub first: Option<String>,
    pub last: Option<String>,
}

impl fmt::Display for Stats {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{} sessions: {} user messages, {} final replies, {} tool summaries; skipped {} repeated pastes, {} copied lines, {} unreadable lines; {} to {}",
            self.sessions,
            self.user,
            self.replies,
            self.tool_summaries,
            self.repeated_pastes,
            self.copied_lines,
            self.bad_lines,
            self.first.as_deref().unwrap_or("-"),
            self.last.as_deref().unwrap_or("-"),
        )
    }
}

/// `$CLAUDE_CONFIG_DIR/projects`, else `<home>/.claude/projects`.
pub fn default_projects_dir(home: &Path, config_dir: Option<String>) -> PathBuf {
    match config_dir.filter(|d| !d.trim().is_empty()) {
        Some(dir) => PathBuf::from(dir).join("projects"),
        None => home.join(".claude").join("projects"),
    }
}

/// Every session under `projects` (a missing directory has none).
pub fn convert_projects(projects: &Path) -> io::Result<(Vec<Imported>, Stats)> {
    let mut files: Vec<PathBuf> = Vec::new();
    let Ok(dirs) = fs::read_dir(projects) else {
        return Ok((Vec::new(), Stats::default()));
    };
    for dir in dirs.flatten() {
        let Ok(entries) = fs::read_dir(dir.path()) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().is_some_and(|e| e == "jsonl") {
                files.push(path);
            }
        }
    }
    // Parse every file, then order sessions by their first timestamp.
    let mut sessions: Vec<(String, String, Vec<Value>)> = Vec::new();
    let mut stats = Stats::default();
    for path in files {
        let text = fs::read_to_string(&path)?;
        let mut lines = Vec::new();
        for line in text.lines().filter(|l| !l.trim().is_empty()) {
            match serde_json::from_str::<Value>(line) {
                Ok(v) if v.is_object() => lines.push(v),
                _ => stats.bad_lines += 1,
            }
        }
        let first = lines
            .iter()
            .find_map(|l| l.get("timestamp").and_then(Value::as_str))
            .unwrap_or("")
            .to_owned();
        let name = path
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default();
        sessions.push((first, name, lines));
    }
    sessions.sort_by(|a, b| (&a.0, &a.1).cmp(&(&b.0, &b.1)));
    let mut seen_uuids: HashSet<String> = HashSet::new();
    let mut seen_pastes: HashSet<String> = HashSet::new();
    let mut items = Vec::new();
    for (_, name, lines) in sessions {
        let session = convert_session(&name, &lines, &mut seen_uuids, &mut seen_pastes, &mut stats);
        if !session.is_empty() {
            stats.sessions += 1;
            items.extend(session);
        }
    }
    for item in &items {
        if let Some(date) = &item.date {
            if stats.first.as_ref().is_none_or(|f| date < f) {
                stats.first = Some(date.clone());
            }
            if stats.last.as_ref().is_none_or(|l| date > l) {
                stats.last = Some(date.clone());
            }
        }
    }
    Ok((items, stats))
}

/// One turn being read: its tool calls and its latest reply.
#[derive(Default)]
struct Turn {
    tools: Vec<(String, usize)>,
    files: Vec<String>,
    tool_date: Option<String>,
    reply: Option<(String, Option<String>)>,
}

impl Turn {
    fn flush(&mut self, out: &mut Vec<Imported>, stats: &mut Stats) {
        let turn = std::mem::take(self);
        if !turn.tools.is_empty() {
            let names: Vec<String> = turn
                .tools
                .iter()
                .map(|(name, n)| format!("{name} ×{n}"))
                .collect();
            let mut text = format!("Claude Code tools: {}", names.join(", "));
            if !turn.files.is_empty() {
                text.push_str(&format!(" (files: {})", turn.files.join(", ")));
            }
            out.push(Imported {
                kind: Kind::Tool,
                text,
                date: turn.tool_date,
            });
            stats.tool_summaries += 1;
        }
        if let Some((text, date)) = turn.reply {
            out.push(Imported {
                kind: Kind::Talk,
                text,
                date,
            });
            stats.replies += 1;
        }
    }
}

fn convert_session(
    name: &str,
    lines: &[Value],
    seen_uuids: &mut HashSet<String>,
    seen_pastes: &mut HashSet<String>,
    stats: &mut Stats,
) -> Vec<Imported> {
    let mut out = Vec::new();
    let mut turn = Turn::default();
    let mut header: Option<(String, Option<String>)> = None;
    for line in lines {
        if let Some(uuid) = line.get("uuid").and_then(Value::as_str)
            && !seen_uuids.insert(uuid.to_owned())
        {
            stats.copied_lines += 1;
            continue;
        }
        let date = line
            .get("timestamp")
            .and_then(Value::as_str)
            .filter(|d| chrono::DateTime::parse_from_rfc3339(d).is_ok())
            .map(str::to_owned);
        if header.is_none() && date.is_some() {
            let cwd = line.get("cwd").and_then(Value::as_str).unwrap_or("?");
            header = Some((format!("Claude Code session {name} in {cwd}"), date.clone()));
        }
        if line.get("isSidechain").and_then(Value::as_bool) == Some(true)
            || line.get("isMeta").and_then(Value::as_bool) == Some(true)
        {
            continue;
        }
        let content = line.pointer("/message/content");
        match line.get("type").and_then(Value::as_str) {
            Some("user") => {
                let Some(text) = content.and_then(user_text) else {
                    continue;
                };
                if text.chars().count() >= PASTE_CHARS && !seen_pastes.insert(text.clone()) {
                    stats.repeated_pastes += 1;
                    continue;
                }
                turn.flush(&mut out, stats);
                out.push(Imported {
                    kind: Kind::User,
                    text,
                    date,
                });
                stats.user += 1;
            }
            Some("assistant") => {
                for block in content.and_then(Value::as_array).into_iter().flatten() {
                    match block.get("type").and_then(Value::as_str) {
                        Some("text") => {
                            let text = block.get("text").and_then(Value::as_str).unwrap_or("");
                            if !text.trim().is_empty() {
                                turn.reply = Some((text.trim().to_owned(), date.clone()));
                            }
                        }
                        Some("tool_use") => {
                            let name = block.get("name").and_then(Value::as_str).unwrap_or("tool");
                            match turn.tools.iter_mut().find(|(n, _)| n == name) {
                                Some((_, count)) => *count += 1,
                                None => turn.tools.push((name.to_owned(), 1)),
                            }
                            turn.tool_date = turn.tool_date.take().or(date.clone());
                            let file = block.get("input").and_then(|i| {
                                ["file_path", "notebook_path", "path"]
                                    .iter()
                                    .find_map(|k| i.get(*k).and_then(Value::as_str))
                            });
                            if let Some(file) = file
                                && turn.files.len() < SUMMARY_FILES
                                && !turn.files.iter().any(|f| f == file)
                            {
                                turn.files.push(file.to_owned());
                            }
                        }
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }
    turn.flush(&mut out, stats);
    if out.is_empty() {
        return out;
    }
    let (text, date) = header.unwrap_or_else(|| (format!("Claude Code session {name}"), None));
    out.insert(
        0,
        Imported {
            kind: Kind::Note,
            text,
            date,
        },
    );
    out
}

/// The user's own words in a user line: its text (a string, or its text
/// blocks), never tool results, slash commands or interruption marks.
fn user_text(content: &Value) -> Option<String> {
    let text = match content {
        Value::String(s) => s.clone(),
        Value::Array(blocks) => blocks
            .iter()
            .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
            .filter_map(|b| b.get("text").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join("\n"),
        _ => return None,
    };
    let trimmed = text.trim();
    let noise = trimmed.is_empty()
        || trimmed.starts_with("<command-name>")
        || trimmed.starts_with("<command-message>")
        || trimmed.starts_with("<local-command-stdout>")
        || trimmed.starts_with("<local-command-stderr>")
        || trimmed.starts_with("<system-reminder>")
        || trimmed.starts_with("[Request interrupted by user");
    (!noise).then(|| trimmed.to_owned())
}

/// How many messages the memory in `chat_dir` holds (no host may run). A
/// memory that does not exist yet holds none and is not created.
pub fn existing_messages(chat_dir: &Path, db: &Path) -> Result<u64, String> {
    if !chat_dir.exists() && !db.exists() {
        return Ok(0);
    }
    let chat = crate::browse::open_offline(chat_dir, db)?;
    let n = chat.status().messages;
    chat.shutdown();
    Ok(n)
}

/// What a dry run says when a write would put the history after `existing`
/// live messages (None when the memory is empty).
pub fn order_warning(existing: u64) -> Option<String> {
    (existing > 0).then(|| {
        format!(
            "the memory already holds {existing} messages: a write would put this older history after them (ids from {existing} on), out of time order; write refuses unless --append-after-live is given"
        )
    })
}

/// Writes `items` into the memory in `chat_dir` through the chat. Refused,
/// with nothing written, when the memory already has messages, unless
/// `append_after_live` accepts that the history goes after them.
pub fn import_history(
    chat_dir: &Path,
    db: &Path,
    items: &[Imported],
    append_after_live: bool,
) -> Result<usize, String> {
    let existing = existing_messages(chat_dir, db)?;
    if existing > 0 && !append_after_live {
        return Err(format!(
            "refused: the memory already holds {existing} messages, and this older history would appear after them, out of time order. Import into an empty memory, or pass --append-after-live to append it after the current messages anyway"
        ));
    }
    crate::browse::import(chat_dir, db, items)
}
