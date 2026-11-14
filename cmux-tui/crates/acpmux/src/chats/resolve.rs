//! `/resume <ref>` (`_acpmux/chat_resolve`): the one chat a pasted reference names.
//!
//! The person pastes what they have (Lawrence 2026-11-07: "i paste in
//! 920ab030-… and i want it to just work"): a session id, the start of one,
//! the transcript's path, an index key (`claude-code:<id>`), or the command
//! that resumes it (`claude --resume <id>`, `codex resume <id>`). The index
//! already holds every chat's id and transcript path, so resolving reads no
//! transcript: a 110 MB session resolves as fast as a small one.

use std::path::{Path, PathBuf};

use cmux_chat_index::{AdapterKind, ChatEntry, ChatKey};

/// The shortest id start that may name a chat: shorter ones match too many.
pub const MIN_PREFIX: usize = 4;

/// What a reference names in the index.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Resolved {
    /// Exactly one chat.
    Found(ChatKey),
    /// Several chats start with the reference: their keys, newest first (at most 5).
    Ambiguous(Vec<ChatKey>),
    /// A transcript file the index does not hold yet: record its root, then resolve again.
    Unindexed(PathBuf),
    /// No chat.
    NotFound,
    /// Too short, or empty.
    TooShort,
}

/// The reference as typed, without quotes, a `file://` scheme or a resume command around it;
/// `~/` is the home folder.
pub fn normalize(text: &str, home: &Path) -> String {
    let mut text = text.trim();
    // A pasted command: the reference is its last word (`claude --resume <id>`, `codex resume <id>`).
    if let Some(last) = text.split_whitespace().last()
        && text.split_whitespace().count() > 1
        && !Path::new(text).exists()
    {
        text = last;
    }
    let text = text.trim_matches(|c| matches!(c, '"' | '\'' | '`' | '<' | '>'));
    let text = text.strip_prefix("file://").unwrap_or(text);
    match text.strip_prefix("~/") {
        Some(rest) => home.join(rest).to_string_lossy().into_owned(),
        None => text.to_owned(),
    }
}

/// The session id a transcript file name holds: Claude Code's `<id>.jsonl`, Codex's
/// `rollout-<time>-<id>.jsonl` (its last 36 characters when they form a UUID).
fn id_of_path(path: &Path) -> Option<String> {
    let stem = path.file_stem()?.to_str()?;
    let stem = stem.strip_suffix(".jsonl").unwrap_or(stem);
    let tail =
        stem.len().checked_sub(36).filter(|start| *start > 0).and_then(|start| stem.get(start..));
    if let Some(tail) = tail
        && is_uuid(tail)
    {
        return Some(tail.to_owned());
    }
    Some(stem.to_owned())
}

fn is_uuid(text: &str) -> bool {
    text.len() == 36
        && text.char_indices().all(|(i, c)| {
            if matches!(i, 8 | 13 | 18 | 23) { c == '-' } else { c.is_ascii_hexdigit() }
        })
}

fn looks_like_path(text: &str) -> bool {
    text.starts_with('/') || text.ends_with(".jsonl") || text.ends_with(".jsonl.zst")
}

/// The chat `text` names among `chats` (newest first). `exists` says whether a path is a file,
/// so a transcript the index does not hold yet can be recorded.
pub fn resolve<'a>(
    text: &str,
    chats: impl IntoIterator<Item = &'a ChatEntry>,
    exists: impl Fn(&Path) -> bool,
) -> Resolved {
    let chats: Vec<&ChatEntry> = chats.into_iter().collect();
    if let Some(key) = super::parse_key(text)
        && !looks_like_path(text)
    {
        return match chats.iter().find(|chat| chat.key() == key) {
            Some(_) => Resolved::Found(key),
            None => resolve_id(&key.session_id, &chats),
        };
    }
    if looks_like_path(text) {
        let path = Path::new(text);
        if let Some(chat) = chats.iter().find(|chat| same_file(&chat.source_path, path)) {
            return Resolved::Found(chat.key());
        }
        let found = id_of_path(path).map(|id| resolve_id(&id, &chats));
        return match found {
            Some(Resolved::Found(key)) => Resolved::Found(key),
            _ if exists(path) => Resolved::Unindexed(path.to_path_buf()),
            Some(other) => other,
            None => Resolved::NotFound,
        };
    }
    resolve_id(text, &chats)
}

fn same_file(a: &Path, b: &Path) -> bool {
    a == b || matches!((a.canonicalize(), b.canonicalize()), (Ok(a), Ok(b)) if a == b)
}

/// An id or the start of one, in any case: an exact id wins over the chats it starts.
fn resolve_id(id: &str, chats: &[&ChatEntry]) -> Resolved {
    let id = id.trim().to_ascii_lowercase();
    if id.chars().count() < MIN_PREFIX {
        return Resolved::TooShort;
    }
    if let Some(chat) = chats.iter().find(|chat| chat.session_id.to_ascii_lowercase() == id) {
        return Resolved::Found(chat.key());
    }
    let mut matches: Vec<ChatKey> = Vec::new();
    for chat in chats {
        if chat.session_id.to_ascii_lowercase().starts_with(&id) && !matches.contains(&chat.key()) {
            matches.push(chat.key());
        }
    }
    match matches.len() {
        0 => Resolved::NotFound,
        1 => Resolved::Found(matches.remove(0)),
        _ => {
            matches.truncate(5);
            Resolved::Ambiguous(matches)
        }
    }
}

/// The transcript of session `id` (a full UUID) on disk, for a chat the index does not hold yet
/// (a store made after the daemon started, like a first `claude` run on a new Mac): Claude Code's
/// `<projects>/<any folder>/<id>.jsonl` under each of `claude_projects`, then Codex's
/// `<sessions>/YYYY/MM/DD/rollout-*-<id>.jsonl` under each of `codex_sessions`. Reads directory
/// names only, never a transcript.
pub fn find_on_disk(
    id: &str,
    claude_projects: &[PathBuf],
    codex_sessions: &[PathBuf],
) -> Option<(AdapterKind, PathBuf)> {
    if !is_uuid(id) {
        return None;
    }
    let id = id.to_ascii_lowercase();
    let dirs = |path: &Path| -> Vec<PathBuf> {
        std::fs::read_dir(path)
            .map(|entries| {
                entries
                    .flatten()
                    .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_dir()))
                    .map(|entry| entry.path())
                    .collect()
            })
            .unwrap_or_default()
    };
    for projects in claude_projects {
        for folder in dirs(projects) {
            let transcript = folder.join(format!("{id}.jsonl"));
            if transcript.is_file() {
                return Some((AdapterKind::ClaudeCode, transcript));
            }
        }
    }
    let suffix = format!("-{id}.jsonl");
    for sessions in codex_sessions {
        // Newest day first: a session pasted to resume is most often a recent one.
        let mut days: Vec<PathBuf> =
            dirs(sessions).iter().flat_map(|y| dirs(y)).flat_map(|m| dirs(&m)).collect();
        days.sort_unstable_by(|a, b| b.cmp(a));
        for day in days {
            let Ok(entries) = std::fs::read_dir(&day) else { continue };
            let found = entries.flatten().map(|entry| entry.path()).find(|path| {
                path.file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name.starts_with("rollout-") && name.ends_with(&suffix))
            });
            if let Some(path) = found {
                return Some((AdapterKind::Codex, path));
            }
        }
    }
    None
}

#[cfg(test)]
mod tests;
