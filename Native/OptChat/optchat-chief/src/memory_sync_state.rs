//! What the import UI needs around `memory import-from`: finding what a Mac
//! already holds (`detect`), a log of each write, and taking the last write back
//! (`undo`). The log holds keys and counts only, never text.

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use crate::paths::Paths;

/// One memory source found on this Mac.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
pub struct Detected {
    /// The `import-from` source name: `claude-code`, `claude-memory`, `codex`, `zip:/path`.
    pub source: String,
    /// `claude-code`, `claude-memory`, `codex`, `chatgpt-export`, `claude-ai-export`, `export`.
    pub kind: String,
    /// Conversations (claude-code), notes (memory kinds) or 1 (a zip).
    pub count: usize,
    pub bytes: u64,
    /// The folder or file it was found in.
    pub path: String,
}

/// Finds what this Mac holds, fast (no transcript is converted): Claude Code
/// transcripts and memory notes, Codex memory notes, and export zips of
/// claude.ai or ChatGPT in `~/Downloads` and `~/Desktop`.
pub fn detect(_user_home: &Path, _claude_config_dir: Option<String>) -> Vec<Detected> {
    unimplemented!()
}

/// One write, as the log keeps it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Run {
    pub batch: String,
    /// `local` or `cloud`.
    pub to: String,
    pub source: String,
    pub written: usize,
    /// Local: messages before the write and the backup file. Cloud: the Chief.
    pub messages_before: u64,
    pub backup: Option<PathBuf>,
    pub chief: Option<String>,
    pub keys: Vec<String>,
}

pub fn log_file(_paths: &Paths) -> PathBuf {
    unimplemented!()
}

pub fn record(_paths: &Paths, _run: &Run) -> Result<(), String> {
    unimplemented!()
}

/// The runs that were not undone, oldest first.
pub fn runs(_paths: &Paths) -> Vec<Run> {
    unimplemented!()
}

/// Restores a local write: the memory returns to its backup when nothing came
/// after the write (host stopped); the write's keys leave `import-keys.txt`.
/// Returns what it did.
pub fn undo_local(_paths: &Paths, _batch: Option<&str>) -> Result<String, String> {
    unimplemented!()
}

pub fn detect_json(found: &[Detected]) -> Value {
    json!({"sources": found})
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::browse::Imported;
    use crate::memory_sync::*;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("a665-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn write(path: &Path, text: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }

    fn zip_of(stage: &Path, out: &Path, files: &[&str]) {
        std::fs::create_dir_all(out.parent().unwrap()).unwrap();
        let ok = std::process::Command::new("zip")
            .current_dir(stage)
            .arg("-q")
            .arg(out)
            .args(files)
            .status()
            .unwrap();
        assert!(ok.success());
    }

    #[test]
    fn detect_finds_claude_code_notes_codex_and_export_zips() {
        let home = temp("detect");
        write(
            &home.join(".claude/projects/-Users-me-app/s1.jsonl"),
            "{\"type\":\"user\"}\n",
        );
        write(
            &home.join(".claude/projects/-Users-me-app/s2.jsonl"),
            "{\"type\":\"user\"}\n",
        );
        write(
            &home.join(".claude/projects/-Users-me-app/memory/prefs.md"),
            "I like Rust",
        );
        write(&home.join(".codex/memories/a.md"), "codex note");
        let stage = temp("stage");
        write(&stage.join("conversations.json"), "[]");
        write(&stage.join("chat.html"), "<html>");
        write(&stage.join("a.txt"), "x");
        // A ChatGPT export: conversations.json next to chat.html.
        zip_of(
            &stage,
            &home.join("Downloads/data-2026.zip"),
            &["conversations.json", "chat.html"],
        );
        // A zip with no conversations.json is not an export.
        zip_of(&stage, &home.join("Downloads/photos.zip"), &["a.txt"]);
        let found = detect(&home, None);
        let kinds: Vec<&str> = found.iter().map(|d| d.kind.as_str()).collect();
        assert!(kinds.contains(&"claude-code"), "{kinds:?}");
        assert!(kinds.contains(&"claude-memory"), "{kinds:?}");
        assert!(kinds.contains(&"codex"), "{kinds:?}");
        assert!(kinds.contains(&"chatgpt-export"), "{kinds:?}");
        assert_eq!(found.len(), 4, "photos.zip is not an export: {found:?}");
        let code = found.iter().find(|d| d.kind == "claude-code").unwrap();
        assert_eq!(code.count, 2);
        assert!(
            found
                .iter()
                .any(|d| d.source.starts_with("zip:") && d.source.ends_with("data-2026.zip"))
        );
    }

    #[test]
    fn detect_on_an_empty_mac_finds_nothing() {
        assert!(detect(&temp("none"), None).is_empty());
    }

    #[test]
    fn undo_local_restores_the_backup_and_forgets_the_keys() {
        let dir = temp("undo");
        let paths = Paths::new(&dir);
        crate::browse::import(
            &paths.chat,
            &paths.memory_db,
            &[Imported {
                kind: optchat_core::Kind::Note,
                text: "mine".into(),
                date: Some("2026-10-01T00:00:00Z".into()),
            }],
        )
        .unwrap();
        let before =
            crate::claude_import::existing_messages(&paths.chat, &paths.memory_db).unwrap();
        let list = vec![item(
            "note",
            "from claude",
            "2026-10-02T00:00:00.000Z",
            "claude-code",
        )];
        let (plan, fresh) = make_plan("claude-code", list, &local_known(&paths).unwrap());
        assert_eq!(plan.new, 1);
        let (n, backup) = write_local(&paths, &fresh).unwrap();
        record(
            &paths,
            &Run {
                batch: "b1".into(),
                to: "local".into(),
                source: "claude-code".into(),
                written: n,
                messages_before: before,
                backup,
                chief: None,
                keys: fresh.iter().map(|i| i.key.clone()).collect(),
            },
        )
        .unwrap();
        assert_eq!(runs(&paths).len(), 1);
        let msg = undo_local(&paths, None).unwrap();
        assert!(msg.contains('1'), "{msg}");
        let after = crate::claude_import::existing_messages(&paths.chat, &paths.memory_db).unwrap();
        assert_eq!(after, before, "the memory is what it was");
        assert!(runs(&paths).is_empty());
        // The same item is new again: its key left import-keys.txt and the memory.
        let again = make_plan(
            "claude-code",
            vec![item(
                "note",
                "from claude",
                "2026-10-02T00:00:00.000Z",
                "claude-code",
            )],
            &local_known(&paths).unwrap(),
        );
        assert_eq!(again.0.new, 1);
    }

    #[test]
    fn undo_local_refuses_when_messages_came_after_the_write() {
        let dir = temp("undo-late");
        let paths = Paths::new(&dir);
        let list = vec![item("note", "x", "2026-10-02T00:00:00.000Z", "codex")];
        let (_, fresh) = make_plan("codex", list, &Default::default());
        let (n, backup) = write_local(&paths, &fresh).unwrap();
        record(
            &paths,
            &Run {
                batch: "b1".into(),
                to: "local".into(),
                source: "codex".into(),
                written: n,
                messages_before: 0,
                backup,
                chief: None,
                keys: vec![fresh[0].key.clone()],
            },
        )
        .unwrap();
        crate::browse::import(
            &paths.chat,
            &paths.memory_db,
            &[Imported {
                kind: optchat_core::Kind::Note,
                text: "later".into(),
                date: None,
            }],
        )
        .unwrap();
        let err = undo_local(&paths, None).unwrap_err();
        assert!(err.contains("after"), "{err}");
        assert_eq!(
            crate::claude_import::existing_messages(&paths.chat, &paths.memory_db).unwrap(),
            2
        );
    }

    #[test]
    fn the_log_holds_keys_and_counts_never_text() {
        let dir = temp("log");
        let paths = Paths::new(&dir);
        record(
            &paths,
            &Run {
                batch: "b".into(),
                to: "cloud".into(),
                source: "codex".into(),
                written: 3,
                messages_before: 0,
                backup: None,
                chief: Some("agent_1".into()),
                keys: vec!["k1".into()],
            },
        )
        .unwrap();
        let raw = std::fs::read_to_string(log_file(&paths)).unwrap();
        assert!(raw.contains("k1") && raw.contains("agent_1"));
        assert_eq!(runs(&paths)[0].chief.as_deref(), Some("agent_1"));
    }
}
