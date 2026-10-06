//! The Claude Code transcript importer (section 10: "months of older agent
//! sessions as plain text: the user's messages and the agent's final
//! replies, without repeated pastes and tool noise"). Fixtures only: never
//! the user's real `~/.claude/projects`.

use std::fs;
use std::path::Path;

use optchat_chief::browse::import;
use optchat_chief::claude_import::{convert_projects, default_projects_dir};
use optchat_core::Kind;
use serde_json::{Value, json};

fn write_session(dir: &Path, project: &str, session: &str, lines: &[Value]) {
    let p = dir.join(project);
    fs::create_dir_all(&p).unwrap();
    let text: String = lines.iter().map(|l| format!("{l}\n")).collect();
    fs::write(p.join(format!("{session}.jsonl")), text).unwrap();
}

fn user(uuid: &str, at: &str, content: Value) -> Value {
    json!({"type": "user", "uuid": uuid, "timestamp": at, "sessionId": "s1", "cwd": "/w/app",
           "isSidechain": false, "message": {"role": "user", "content": content}})
}

fn assistant(uuid: &str, at: &str, id: &str, block: Value) -> Value {
    json!({"type": "assistant", "uuid": uuid, "timestamp": at, "sessionId": "s1", "cwd": "/w/app",
           "isSidechain": false, "message": {"role": "assistant", "id": id, "content": [block]}})
}

fn fixture(dir: &Path) {
    let paste = "x".repeat(800);
    write_session(
        dir,
        "-w-app",
        "s1",
        &[
            json!({"type": "summary", "summary": "fix the build"}),
            user(
                "u1",
                "2026-03-01T10:00:00.000Z",
                json!("fix the build, it fails on CI"),
            ),
            assistant(
                "a1",
                "2026-03-01T10:00:05.000Z",
                "m1",
                json!({"type": "thinking", "thinking": "secret plan"}),
            ),
            assistant(
                "a2",
                "2026-03-01T10:00:06.000Z",
                "m1",
                json!({"type": "text", "text": "Let me look."}),
            ),
            assistant(
                "a3",
                "2026-03-01T10:00:07.000Z",
                "m1",
                json!({"type": "tool_use", "id": "t1", "name": "Read", "input": {"file_path": "/w/app/build.rs"}}),
            ),
            user(
                "u2",
                "2026-03-01T10:00:08.000Z",
                json!([{"type": "tool_result", "tool_use_id": "t1", "content": "fn main() {}"}]),
            ),
            assistant(
                "a4",
                "2026-03-01T10:00:09.000Z",
                "m2",
                json!({"type": "tool_use", "id": "t2", "name": "Bash", "input": {"command": "TOKEN=abc cargo build"}}),
            ),
            user(
                "u3",
                "2026-03-01T10:00:10.000Z",
                json!([{"type": "tool_result", "tool_use_id": "t2", "content": "error: x"}]),
            ),
            assistant(
                "a5",
                "2026-03-01T10:00:11.000Z",
                "m3",
                json!({"type": "tool_use", "id": "t3", "name": "Read", "input": {"file_path": "/w/app/Cargo.toml"}}),
            ),
            assistant(
                "a6",
                "2026-03-01T10:00:20.000Z",
                "m4",
                json!({"type": "text", "text": "Fixed: build.rs used a removed API."}),
            ),
            // Noise: a meta line, a slash command, an interruption, a subagent.
            json!({"type": "user", "uuid": "u4", "timestamp": "2026-03-01T10:01:00.000Z", "isMeta": true,
                   "message": {"role": "user", "content": "Caveat: local commands"}}),
            user(
                "u5",
                "2026-03-01T10:01:01.000Z",
                json!("<command-name>/clear</command-name>"),
            ),
            user(
                "u6",
                "2026-03-01T10:01:02.000Z",
                json!([{"type": "text", "text": "[Request interrupted by user]"}]),
            ),
            json!({"type": "assistant", "uuid": "a7", "timestamp": "2026-03-01T10:01:03.000Z", "isSidechain": true,
                   "message": {"role": "assistant", "id": "m5", "content": [{"type": "text", "text": "subagent words"}]}}),
            user(
                "u7",
                "2026-03-01T10:02:00.000Z",
                json!([{"type": "text", "text": paste.clone()}]),
            ),
            assistant(
                "a8",
                "2026-03-01T10:02:05.000Z",
                "m6",
                json!({"type": "text", "text": "Got the log."}),
            ),
        ],
    );
    // A later session: the same long paste again (skipped), and a line the
    // resumed session copied from the first (same uuid, skipped).
    write_session(
        dir,
        "-w-app",
        "s2",
        &[
            user(
                "u1",
                "2026-03-01T10:00:00.000Z",
                json!("fix the build, it fails on CI"),
            ),
            user("v1", "2026-03-02T09:00:00.000Z", json!(paste)),
            user(
                "v2",
                "2026-03-02T09:00:01.000Z",
                json!("and again tomorrow"),
            ),
            assistant(
                "b1",
                "2026-03-02T09:00:04.000Z",
                "n1",
                json!({"type": "text", "text": "Will do."}),
            ),
            json!("not an object"),
            Value::String("{torn".into()),
        ],
    );
}

#[test]
fn sessions_become_user_messages_final_replies_and_tool_summaries_with_their_dates() {
    let dir = tempfile::tempdir().unwrap();
    fixture(dir.path());
    let (items, stats) = convert_projects(dir.path()).unwrap();
    let got: Vec<(Kind, &str, Option<&str>)> = items
        .iter()
        .map(|i| (i.kind, i.text.as_str(), i.date.as_deref()))
        .collect();
    let paste = "x".repeat(800);
    assert_eq!(
        got,
        vec![
            (
                Kind::Note,
                "Claude Code session s1 in /w/app",
                Some("2026-03-01T10:00:00.000Z")
            ),
            (
                Kind::User,
                "fix the build, it fails on CI",
                Some("2026-03-01T10:00:00.000Z")
            ),
            (
                Kind::Tool,
                "Claude Code tools: Read ×2, Bash ×1 (files: /w/app/build.rs, /w/app/Cargo.toml)",
                Some("2026-03-01T10:00:07.000Z")
            ),
            (
                Kind::Talk,
                "Fixed: build.rs used a removed API.",
                Some("2026-03-01T10:00:20.000Z")
            ),
            (Kind::User, paste.as_str(), Some("2026-03-01T10:02:00.000Z")),
            (Kind::Talk, "Got the log.", Some("2026-03-01T10:02:05.000Z")),
            (
                Kind::Note,
                "Claude Code session s2 in /w/app",
                Some("2026-03-02T09:00:00.000Z")
            ),
            (
                Kind::User,
                "and again tomorrow",
                Some("2026-03-02T09:00:01.000Z")
            ),
            (Kind::Talk, "Will do.", Some("2026-03-02T09:00:04.000Z")),
        ]
    );
    // Thinking, tool input values (the command), tool output, meta lines,
    // slash commands, interruptions and subagents never appear.
    let all: String = items.iter().map(|i| i.text.clone()).collect();
    for absent in [
        "secret plan",
        "TOKEN",
        "fn main",
        "Caveat",
        "/clear",
        "interrupted",
        "subagent",
        "Let me look.",
    ] {
        assert!(!all.contains(absent), "{absent}");
    }
    assert_eq!(stats.sessions, 2);
    assert_eq!(stats.user, 3);
    assert_eq!(stats.replies, 3);
    assert_eq!(stats.tool_summaries, 1);
    assert_eq!(stats.repeated_pastes, 1);
    assert_eq!(stats.copied_lines, 1);
    assert_eq!(stats.bad_lines, 2);
    assert_eq!(stats.first.as_deref(), Some("2026-03-01T10:00:00.000Z"));
    assert_eq!(stats.last.as_deref(), Some("2026-03-02T09:00:04.000Z"));
    assert!(stats.to_string().contains("2 sessions"), "{stats}");
}

/// The items go into the memory through the chat (the store seam), each
/// with its own date.
#[test]
fn an_import_writes_the_items_with_their_dates_through_the_chat() {
    let dir = tempfile::tempdir().unwrap();
    let projects = dir.path().join("projects");
    fixture(&projects);
    let (items, _) = convert_projects(&projects).unwrap();
    let chat_dir = dir.path().join("chat");
    let db = dir.path().join("memory.sqlite3");
    assert_eq!(import(&chat_dir, &db, &items).unwrap(), items.len());
    let chat = optchat_chief::browse::open_offline(&chat_dir, &db).unwrap();
    assert_eq!(
        chat.message(1),
        Some((Kind::User, "fix the build, it fails on CI".into()))
    );
    assert_eq!(chat.stamp(1).as_deref(), Some("2026-03-01T10:00:00.000Z"));
}

#[test]
fn the_default_projects_dir_follows_claude_config_dir() {
    let home = Path::new("/h");
    assert_eq!(
        default_projects_dir(home, None),
        Path::new("/h/.claude/projects")
    );
    assert_eq!(
        default_projects_dir(home, Some("/c".into())),
        Path::new("/c/projects")
    );
    // A missing directory converts to nothing.
    let (items, stats) = convert_projects(Path::new("/nonexistent-optchat-test")).unwrap();
    assert!(items.is_empty());
    assert_eq!(stats.sessions, 0);
}

/// Old history must not land after live messages: on a memory that already
/// has messages, a write is refused unless the caller accepts that order
/// (`--append-after-live`), and nothing is written; the dry run says so.
#[test]
fn a_write_after_live_messages_is_refused_unless_accepted() {
    use optchat_chief::claude_import::{existing_messages, import_history, order_warning};
    let dir = tempfile::tempdir().unwrap();
    let projects = dir.path().join("projects");
    fixture(&projects);
    let (items, _) = convert_projects(&projects).unwrap();
    // An empty memory takes the history.
    let empty = dir.path().join("empty");
    let empty_db = dir.path().join("empty.sqlite3");
    assert_eq!(existing_messages(&empty, &empty_db).unwrap(), 0);
    assert_eq!(order_warning(0), None);
    assert_eq!(
        import_history(&empty, &empty_db, &items, false).unwrap(),
        items.len()
    );
    // A memory with a live message refuses, and writes nothing.
    let live = dir.path().join("live");
    let live_db = dir.path().join("live.sqlite3");
    {
        let chat = optchat_chief::browse::open_offline(&live, &live_db).unwrap();
        chat.append(Kind::User, "a live message").unwrap();
        chat.shutdown();
    }
    assert_eq!(existing_messages(&live, &live_db).unwrap(), 1);
    let warning = order_warning(1).unwrap();
    assert!(warning.contains("after"), "{warning}");
    let refused = import_history(&live, &live_db, &items, false).unwrap_err();
    assert!(refused.contains("--append-after-live"), "{refused}");
    assert!(refused.contains("after"), "{refused}");
    assert_eq!(existing_messages(&live, &live_db).unwrap(), 1);
    // Accepted: appended after the live message.
    assert_eq!(
        import_history(&live, &live_db, &items, true).unwrap(),
        items.len()
    );
    let chat = optchat_chief::browse::open_offline(&live, &live_db).unwrap();
    assert_eq!(chat.message(0), Some((Kind::User, "a live message".into())));
    assert_eq!(chat.status().messages, 1 + items.len() as u64);
}
