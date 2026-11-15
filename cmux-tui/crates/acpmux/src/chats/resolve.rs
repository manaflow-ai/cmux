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
mod tests {
    use super::*;
    use cmux_chat_index::Resume;

    const ID: &str = "920ab030-d857-4a26-8afb-574eb70e8b2c";

    fn chat(harness: AdapterKind, id: &str, path: &str) -> ChatEntry {
        ChatEntry {
            harness,
            session_id: id.to_owned(),
            title: None,
            title_source: None,
            cwd: Some("/Users/me/fun/prime-interface".into()),
            created_ms: None,
            updated_ms: 0,
            message_count: None,
            source_path: PathBuf::from(path),
            originator: None,
            archived: false,
            resume: Resume::Adopt,
        }
    }

    fn index() -> Vec<ChatEntry> {
        vec![
            chat(
                AdapterKind::ClaudeCode,
                ID,
                &format!("/Users/me/.claude/projects/-Users-me-fun-prime-interface/{ID}.jsonl"),
            ),
            chat(
                AdapterKind::ClaudeCode,
                "920ab999-0000-4000-8000-000000000000",
                "/Users/me/.claude/projects/-Users-me/920ab999-0000-4000-8000-000000000000.jsonl",
            ),
            chat(
                AdapterKind::Codex,
                "019a1b2c-3d4e-7f00-8000-0000000000aa",
                "/Users/me/.codex/sessions/2026/11/07/rollout-2026-11-07T10-00-00-019a1b2c-3d4e-7f00-8000-0000000000aa.jsonl",
            ),
        ]
    }

    fn key(harness: AdapterKind, id: &str) -> ChatKey {
        ChatKey { harness, session_id: id.to_owned() }
    }

    fn run(text: &str) -> Resolved {
        let chats = index();
        resolve(&normalize(text, Path::new("/Users/me")), &chats, |_| false)
    }

    #[test]
    fn a_pasted_claude_session_id_finds_its_chat_in_any_project_folder() {
        assert_eq!(run(ID), Resolved::Found(key(AdapterKind::ClaudeCode, ID)));
        assert_eq!(
            run(&format!("  {} \n", ID.to_uppercase())),
            Resolved::Found(key(AdapterKind::ClaudeCode, ID))
        );
    }

    #[test]
    fn a_codex_session_id_finds_its_chat() {
        let id = "019a1b2c-3d4e-7f00-8000-0000000000aa";
        assert_eq!(run(id), Resolved::Found(key(AdapterKind::Codex, id)));
        assert_eq!(
            run(&format!("codex resume {id}")),
            Resolved::Found(key(AdapterKind::Codex, id))
        );
    }

    #[test]
    fn a_unique_id_start_finds_its_chat_and_a_shared_one_lists_them() {
        assert_eq!(run("920ab030"), Resolved::Found(key(AdapterKind::ClaudeCode, ID)));
        assert_eq!(
            run("019a"),
            Resolved::Found(key(AdapterKind::Codex, "019a1b2c-3d4e-7f00-8000-0000000000aa"))
        );
        assert_eq!(
            run("920ab"),
            Resolved::Ambiguous(vec![
                key(AdapterKind::ClaudeCode, ID),
                key(AdapterKind::ClaudeCode, "920ab999-0000-4000-8000-000000000000"),
            ])
        );
        assert_eq!(run("920"), Resolved::TooShort);
        assert_eq!(run("ffffffff"), Resolved::NotFound);
    }

    #[test]
    fn a_transcript_path_or_command_or_key_finds_its_chat() {
        let found = Resolved::Found(key(AdapterKind::ClaudeCode, ID));
        assert_eq!(
            run(&format!("/Users/me/.claude/projects/-Users-me-fun-prime-interface/{ID}.jsonl")),
            found
        );
        assert_eq!(
            run(&format!("~/.claude/projects/-Users-me-fun-prime-interface/{ID}.jsonl")),
            found
        );
        assert_eq!(run(&format!("file:///Users/me/.claude/projects/x/{ID}.jsonl")), found);
        assert_eq!(run(&format!("claude --resume {ID}")), found);
        assert_eq!(run(&format!("claude -r '{ID}'")), found);
        assert_eq!(run(&format!("claude-code:{ID}")), found);
        let codex = "/Users/me/.codex/sessions/2026/11/07/rollout-2026-11-07T10-00-00-019a1b2c-3d4e-7f00-8000-0000000000aa.jsonl";
        assert_eq!(
            run(codex),
            Resolved::Found(key(AdapterKind::Codex, "019a1b2c-3d4e-7f00-8000-0000000000aa"))
        );
    }

    #[test]
    fn a_transcript_file_the_index_lacks_is_recorded_not_refused() {
        let chats = index();
        let path =
            "/Users/me/elsewhere/.claude/projects/p/aaaabbbb-0000-4000-8000-000000000000.jsonl";
        assert_eq!(resolve(path, &chats, |_| true), Resolved::Unindexed(PathBuf::from(path)));
        assert_eq!(resolve(path, &chats, |_| false), Resolved::NotFound);
    }

    #[test]
    fn a_full_id_the_index_lacks_is_found_in_the_claude_or_codex_store_on_disk() {
        let home = tempfile::tempdir().expect("tempdir");
        let projects = home.path().join(".claude/projects");
        let sessions = home.path().join(".codex/sessions");
        std::fs::create_dir_all(projects.join("-Users-me-fun-prime-interface")).expect("mkdir");
        std::fs::create_dir_all(sessions.join("2026/11/07")).expect("mkdir");
        let claude = projects.join(format!("-Users-me-fun-prime-interface/{ID}.jsonl"));
        std::fs::write(&claude, "{}\n").expect("write");
        let codex_id = "019a1b2c-3d4e-7f00-8000-0000000000aa";
        let codex =
            sessions.join(format!("2026/11/07/rollout-2026-11-07T10-00-00-{codex_id}.jsonl"));
        std::fs::write(&codex, "{}\n").expect("write");
        let roots = (vec![projects], vec![sessions]);
        assert_eq!(
            find_on_disk(&ID.to_uppercase(), &roots.0, &roots.1),
            Some((AdapterKind::ClaudeCode, claude))
        );
        assert_eq!(find_on_disk(codex_id, &roots.0, &roots.1), Some((AdapterKind::Codex, codex)));
        assert_eq!(find_on_disk("aaaabbbb-0000-4000-8000-000000000000", &roots.0, &roots.1), None);
        assert_eq!(find_on_disk("920ab030", &roots.0, &roots.1), None);
    }
}
