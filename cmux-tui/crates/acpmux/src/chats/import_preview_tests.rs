//! The import preview says, per chat, how it resumes, what it carries and what it leaves out,
//! and never drops a chat that cannot import cleanly.

use std::path::{Path, PathBuf};

use cmux_chat_index::{AdapterKind, ChatEntry, IndexedChat, Resume};
use serde_json::Value;

use super::*;

fn chat(
    harness: AdapterKind,
    id: &str,
    source: &Path,
    cwd: Option<&Path>,
    resume: Resume,
) -> IndexedChat {
    IndexedChat {
        entry: ChatEntry {
            harness,
            session_id: id.to_owned(),
            title: Some(format!("chat {id}")),
            title_source: None,
            cwd: cwd.map(|p| p.to_string_lossy().into_owned()),
            created_ms: None,
            updated_ms: 1,
            message_count: Some(4),
            source_path: source.to_path_buf(),
            originator: None,
            archived: false,
            resume,
        },
        accounts: vec!["work".to_owned()],
        roots: Vec::new(),
    }
}

fn claude_profile(home: &Path) -> StoreProfile {
    StoreProfile {
        name: "claude".to_owned(),
        family: "claude".to_owned(),
        claude: Some(home.join(".claude")),
        codex: None,
    }
}

fn write(path: &Path, text: &str) -> PathBuf {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
    path.to_path_buf()
}

fn codes(row: &Value) -> Vec<String> {
    row["omissions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|o| o["code"].as_str().unwrap().to_owned())
        .collect()
}

fn nothing_adopted(_: &str, _: &str) -> Option<String> {
    None
}

#[test]
fn a_claude_chat_with_a_profile_resumes_natively_and_carries_everything() {
    let tmp = tempfile::tempdir().unwrap();
    let project = tmp.path().join("project");
    std::fs::create_dir_all(&project).unwrap();
    let source = write(&tmp.path().join(".claude/projects/p/abc.jsonl"), "{}\n");
    let profiles = [claude_profile(tmp.path())];
    let cx = PreviewContext {
        profiles: &profiles,
        home: tmp.path(),
        host: "mac-1",
        adopted: &nothing_adopted,
    };
    let row =
        row(&chat(AdapterKind::ClaudeCode, "abc", &source, Some(&project), Resume::Adopt), &cx);
    assert_eq!(row["resume"], "native");
    assert_eq!(row["state"], "ready");
    assert_eq!(row["host"], "mac-1");
    assert_eq!(row["account"]["profile"], "claude");
    assert_eq!(row["account"]["labels"][0], "work");
    assert_eq!(row["source"]["harness"], "claude-code");
    assert_eq!(row["carries"]["tools"], true);
    assert!(codes(&row).is_empty(), "{row}");
    // Import goes through the same open plan `_acpmux/chat_open` answers.
    assert_eq!(row["open"]["kind"], "adopt");
    assert!(row["open"]["sessionNew"].is_object());
}

#[test]
fn a_chat_an_acpmux_session_already_adopted_is_already_imported() {
    let tmp = tempfile::tempdir().unwrap();
    let project = tmp.path().join("project");
    std::fs::create_dir_all(&project).unwrap();
    let source = write(&tmp.path().join(".claude/projects/p/abc.jsonl"), "{}\n");
    let profiles = [claude_profile(tmp.path())];
    let adopted =
        |family: &str, id: &str| (family == "claude" && id == "abc").then(|| "s-1".to_owned());
    let cx = PreviewContext { profiles: &profiles, home: tmp.path(), host: "h", adopted: &adopted };
    let row =
        row(&chat(AdapterKind::ClaudeCode, "abc", &source, Some(&project), Resume::Adopt), &cx);
    assert_eq!(row["state"], "alreadyImported");
    assert_eq!(row["importedSession"], "s-1");
}

#[test]
fn an_unreadable_empty_or_folderless_chat_stays_with_its_reason() {
    let tmp = tempfile::tempdir().unwrap();
    let profiles = [claude_profile(tmp.path())];
    let cx = PreviewContext {
        profiles: &profiles,
        home: tmp.path(),
        host: "h",
        adopted: &nothing_adopted,
    };
    let gone = tmp.path().join(".claude/projects/p/gone.jsonl");
    let empty = write(&tmp.path().join(".claude/projects/p/empty.jsonl"), "");
    let ok = write(&tmp.path().join(".claude/projects/p/ok.jsonl"), "{}\n");
    let moved = tmp.path().join("moved-away");
    let chats = [
        chat(AdapterKind::ClaudeCode, "gone", &gone, None, Resume::Adopt),
        chat(AdapterKind::ClaudeCode, "empty", &empty, None, Resume::Adopt),
        chat(AdapterKind::ClaudeCode, "ok", &ok, Some(&moved), Resume::Adopt),
    ];
    let preview = preview(Some("/p"), &chats, &cx);
    let rows = preview["rows"].as_array().unwrap();
    assert_eq!(rows.len(), 3, "no chat is dropped");
    assert!(codes(&rows[0]).contains(&"unreadable".to_owned()));
    assert_eq!(rows[0]["state"], "needsAttention");
    assert_eq!(rows[0]["carries"]["text"], false);
    assert!(codes(&rows[1]).contains(&"empty".to_owned()));
    assert!(codes(&rows[2]).contains(&"folder".to_owned()));
    assert_eq!(rows[2]["state"], "needsAttention");
    assert_eq!(preview["summary"]["needsAttention"], 3);
    assert_eq!(preview["summary"]["withOmissions"], 3);
}

#[test]
fn a_chat_with_no_resume_path_is_read_only_and_carries_text_only() {
    let tmp = tempfile::tempdir().unwrap();
    let project = tmp.path().join("project");
    std::fs::create_dir_all(&project).unwrap();
    let source = write(&tmp.path().join("cursor/chat.json"), "{}");
    let cx =
        PreviewContext { profiles: &[], home: tmp.path(), host: "h", adopted: &nothing_adopted };
    let row =
        row(&chat(AdapterKind::CursorAgent, "c1", &source, Some(&project), Resume::ReadOnly), &cx);
    assert_eq!(row["resume"], "readOnly");
    assert_eq!(row["state"], "ready");
    assert_eq!(row["carries"]["text"], true);
    assert_eq!(row["carries"]["tools"], false);
    assert_eq!(row["carries"]["attachments"], false);
}

#[test]
fn the_summary_counts_resumability() {
    let tmp = tempfile::tempdir().unwrap();
    let project = tmp.path().join("project");
    std::fs::create_dir_all(&project).unwrap();
    let a = write(&tmp.path().join(".claude/projects/p/a.jsonl"), "{}\n");
    let b = write(&tmp.path().join("cursor/b.json"), "{}");
    let profiles = [claude_profile(tmp.path())];
    let cx = PreviewContext {
        profiles: &profiles,
        home: tmp.path(),
        host: "h",
        adopted: &nothing_adopted,
    };
    let chats = [
        chat(AdapterKind::ClaudeCode, "a", &a, Some(&project), Resume::Adopt),
        chat(AdapterKind::CursorAgent, "b", &b, Some(&project), Resume::ReadOnly),
    ];
    let preview = preview(Some(project.to_str().unwrap()), &chats, &cx);
    assert_eq!(preview["summary"]["chats"], 2);
    assert_eq!(preview["summary"]["native"], 1);
    assert_eq!(preview["summary"]["readOnly"], 1);
    assert_eq!(preview["summary"]["ready"], 2);
}
