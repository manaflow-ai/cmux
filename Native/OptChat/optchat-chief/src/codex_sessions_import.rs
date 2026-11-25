//! Codex chat transcripts (`$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl`)
//! as `memory import-from codex-sessions` items, the Codex twin of
//! `claude_import` for Claude Code.
//!
//! Per session, in file order: a `note` naming the session and its working
//! directory, then each turn's user message (`user`) and the turn's final
//! reply (`ai`). Every item keeps its transcript timestamp, so its key (and a
//! re-run's dedupe) is stable. Dropped: developer and system messages, the
//! context Codex injects as user messages (`<environment_context>`, AGENTS.md
//! instructions), reasoning, tool calls and tool output (which can hold
//! secrets), intermediate replies, a long user message seen before (a
//! repeated paste), and non-interactive sessions (`codex exec`, which tools
//! and reviewers run, not the person).

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use serde_json::Value;

/// One message of a Codex transcript, ready to become an import item.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CodexItem {
    /// `note`, `user` or `ai`.
    pub kind: &'static str,
    pub text: String,
    pub date: String,
}

/// `$CODEX_HOME/sessions`, else `~/.codex/sessions`.
pub fn default_sessions_dir(user_home: &Path, codex_home: Option<String>) -> PathBuf {
    match codex_home.filter(|h| !h.trim().is_empty()) {
        Some(h) => PathBuf::from(h).join("sessions"),
        None => user_home.join(".codex").join("sessions"),
    }
}

/// Every `*.jsonl` under `dir` (any depth), sorted by path, which for Codex's
/// `YYYY/MM/DD/rollout-<time>-<id>.jsonl` layout is oldest first.
pub fn session_files(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&d) else {
            continue;
        };
        for e in entries.flatten() {
            let path = e.path();
            let Ok(ft) = e.file_type() else { continue };
            if ft.is_dir() {
                stack.push(path);
            } else if ft.is_file() && path.extension().is_some_and(|x| x == "jsonl") {
                out.push(path);
            }
        }
    }
    out.sort();
    out
}

/// Session files and their total bytes, for `detect` (nothing is parsed).
pub fn count_sessions(dir: &Path) -> (usize, u64) {
    session_files(dir)
        .iter()
        .filter_map(|p| std::fs::metadata(p).ok())
        .filter(|m| m.len() > 0)
        .fold((0, 0), |(n, b), m| (n + 1, b + m.len()))
}

/// A session the person drove: not `codex exec` (tools, reviewers) and not a
/// subagent another agent spawned.
fn interactive(meta: &Value) -> bool {
    let source = &meta["source"];
    !(source.as_str() == Some("exec")
        || meta["originator"].as_str() == Some("codex_exec")
        || source.get("subagent").is_some()
        || meta["thread_source"].as_str() == Some("subagent"))
}

/// User messages Codex writes itself (context, instructions), not the person's.
fn injected(text: &str) -> bool {
    let t = text.trim_start();
    [
        "<environment_context>",
        "<user_instructions>",
        "<permissions",
        "<turn_aborted>",
        // `!cmd`: the command and its output, which can hold secrets.
        "<user_shell_command>",
        "# AGENTS.md instructions",
    ]
    .iter()
    .any(|p| t.starts_with(p))
}

/// The text parts of a `message` payload (`input_text` / `output_text`).
fn message_text(content: &Value) -> String {
    match content {
        Value::String(s) => s.clone(),
        Value::Array(parts) => parts
            .iter()
            .filter(|p| {
                matches!(
                    p["type"].as_str(),
                    Some("input_text" | "output_text" | "text")
                )
            })
            .filter_map(|p| p["text"].as_str())
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

/// One transcript's items; empty for a non-interactive (`exec`) session.
/// `seen_pastes` carries long user messages across sessions.
pub fn convert_session(text: &str, seen_pastes: &mut HashSet<String>) -> Vec<CodexItem> {
    let mut out = Vec::new();
    let mut reply: Option<CodexItem> = None;
    let mut seen_header = false;
    for line in text.lines() {
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        let p = &v["payload"];
        let date = v["timestamp"]
            .as_str()
            .or(p["timestamp"].as_str())
            .unwrap_or("")
            .to_owned();
        match v["type"].as_str() {
            Some("session_meta") => {
                // A fork or resume repeats a header; the first one names the session.
                if seen_header {
                    continue;
                }
                seen_header = true;
                if !interactive(p) {
                    return Vec::new();
                }
                let cwd = p["cwd"].as_str().unwrap_or("");
                let id = p["id"].as_str().unwrap_or("");
                out.push(CodexItem {
                    kind: "note",
                    text: format!("Codex session {id} in {cwd}"),
                    date,
                });
            }
            Some("response_item") if p["type"] == "message" => {
                let body = message_text(&p["content"]);
                if body.trim().is_empty() {
                    continue;
                }
                match p["role"].as_str() {
                    Some("user") => {
                        if injected(&body) {
                            continue;
                        }
                        out.extend(reply.take());
                        if body.chars().count() >= crate::claude_import::PASTE_CHARS
                            && !seen_pastes.insert(body.clone())
                        {
                            continue;
                        }
                        out.push(CodexItem {
                            kind: "user",
                            text: body,
                            date,
                        });
                    }
                    // Commentary (progress notes between tool calls) is never the
                    // turn's reply; older transcripts carry no phase.
                    Some("assistant") if p["phase"].as_str() != Some("commentary") => {
                        reply = Some(CodexItem {
                            kind: "ai",
                            text: body,
                            date,
                        });
                    }
                    _ => {}
                }
            }
            _ => {}
        }
    }
    out.extend(reply);
    // A session with only its header says nothing.
    if out.iter().all(|i| i.kind == "note") {
        return Vec::new();
    }
    out
}

/// Every interactive session under `dir`, oldest first.
pub fn convert_sessions(dir: &Path) -> Vec<CodexItem> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for f in session_files(dir) {
        if let Ok(text) = std::fs::read_to_string(&f) {
            out.extend(convert_session(&text, &mut seen));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(v: serde_json::Value) -> String {
        format!("{v}\n")
    }

    fn meta(source: &str, originator: &str) -> String {
        line(
            serde_json::json!({"timestamp":"2026-11-01T10:00:00.000Z","type":"session_meta",
            "payload":{"id":"s1","cwd":"/w/proj","source":source,"originator":originator}}),
        )
    }

    fn msg(at: &str, role: &str, kind: &str, text: &str) -> String {
        line(serde_json::json!({"timestamp":at,"type":"response_item",
            "payload":{"type":"message","role":role,"content":[{"type":kind,"text":text}]}}))
    }

    fn interactive() -> String {
        [
            meta("cli", "codex_cli_rs"),
            msg("2026-11-01T10:00:01.000Z", "developer", "input_text", "sandbox rules"),
            msg("2026-11-01T10:00:02.000Z", "user", "input_text", "<environment_context>cwd</environment_context>"),
            msg("2026-11-01T10:00:03.000Z", "user", "input_text", "fix the tab bar"),
            line(serde_json::json!({"timestamp":"2026-11-01T10:00:04.000Z","type":"response_item",
                "payload":{"type":"function_call","name":"shell","arguments":"{\"cmd\":\"cat .env\"}"}})),
            msg("2026-11-01T10:00:05.000Z", "assistant", "output_text", "looking"),
            msg("2026-11-01T10:00:06.000Z", "assistant", "output_text", "fixed it"),
            msg("2026-11-01T10:01:00.000Z", "user", "input_text", "thanks"),
            msg("2026-11-01T10:01:01.000Z", "assistant", "output_text", "any time"),
        ]
        .concat()
    }

    #[test]
    fn keeps_user_messages_and_final_replies_only() {
        let items = convert_session(&interactive(), &mut HashSet::new());
        let got: Vec<(&str, &str)> = items.iter().map(|i| (i.kind, i.text.as_str())).collect();
        assert_eq!(
            got,
            vec![
                ("note", "Codex session s1 in /w/proj"),
                ("user", "fix the tab bar"),
                ("ai", "fixed it"),
                ("user", "thanks"),
                ("ai", "any time"),
            ]
        );
        assert_eq!(items[2].date, "2026-11-01T10:00:06.000Z");
    }

    #[test]
    fn commentary_is_never_the_final_reply() {
        let say = |at: &str, phase: &str, text: &str| {
            line(
                serde_json::json!({"timestamp":at,"type":"response_item","payload":{"type":"message",
                "role":"assistant","phase":phase,"content":[{"type":"output_text","text":text}]}}),
            )
        };
        let t = [
            meta("cli", "codex_cli_rs"),
            msg("2026-11-01T10:00:03.000Z", "user", "input_text", "go"),
            say("2026-11-01T10:00:04.000Z", "final_answer", "done"),
            say("2026-11-01T10:00:05.000Z", "commentary", "checking more"),
        ]
        .concat();
        let items = convert_session(&t, &mut HashSet::new());
        assert_eq!(items.last().unwrap().text, "done");
        // A turn still running: only commentary so far, so no reply yet.
        let running = [
            meta("cli", "codex_cli_rs"),
            msg("2026-11-01T10:00:03.000Z", "user", "input_text", "go"),
            say("2026-11-01T10:00:04.000Z", "commentary", "looking"),
        ]
        .concat();
        assert!(
            convert_session(&running, &mut HashSet::new())
                .iter()
                .all(|i| i.kind != "ai")
        );
    }

    #[test]
    fn subagent_sessions_are_skipped() {
        let t = [
            line(
                serde_json::json!({"timestamp":"2026-11-01T10:00:00.000Z","type":"session_meta",
                "payload":{"id":"s2","cwd":"/w","originator":"acpmux",
                    "source":{"subagent":{"thread_spawn":{"parent":"s1"}}}}}),
            ),
            msg(
                "2026-11-01T10:00:03.000Z",
                "user",
                "input_text",
                "parent's brief",
            ),
        ]
        .concat();
        assert!(convert_session(&t, &mut HashSet::new()).is_empty());
    }

    #[test]
    fn only_the_first_header_counts() {
        let t = [
            interactive(),
            meta("exec", "codex_exec"),
            msg("2026-11-01T10:02:00.000Z", "user", "input_text", "later"),
        ]
        .concat();
        let items = convert_session(&t, &mut HashSet::new());
        assert_eq!(items.iter().filter(|i| i.kind == "note").count(), 1);
        assert_eq!(items.last().unwrap().text, "later");
    }

    /// `!cmd` in Codex records the command and its output as a user message;
    /// that output (`cat .env`) must never reach memory.
    #[test]
    fn shell_command_records_are_dropped() {
        let t = [
            meta("cli", "codex_cli_rs"),
            msg(
                "2026-11-01T10:00:02.000Z",
                "user",
                "input_text",
                "<user_shell_command>\n<command>cat .env</command>\n<output>DB_PASSWORD=hunter2</output>\n</user_shell_command>",
            ),
            msg("2026-11-01T10:00:03.000Z", "user", "input_text", "what now"),
        ]
        .concat();
        let items = convert_session(&t, &mut HashSet::new());
        assert!(
            items.iter().all(|i| !i.text.contains("hunter2")),
            "{items:?}"
        );
        assert_eq!(items.last().unwrap().text, "what now");
    }

    #[test]
    fn exec_sessions_are_skipped() {
        let t = [
            meta("exec", "codex_exec"),
            msg(
                "2026-11-01T10:00:03.000Z",
                "user",
                "input_text",
                "review this",
            ),
        ]
        .concat();
        assert!(convert_session(&t, &mut HashSet::new()).is_empty());
    }

    #[test]
    fn repeated_long_paste_is_kept_once() {
        let paste = "x".repeat(crate::claude_import::PASTE_CHARS);
        let t = [
            meta("cli", "codex_cli_rs"),
            msg("2026-11-01T10:00:03.000Z", "user", "input_text", &paste),
        ]
        .concat();
        let mut seen = HashSet::new();
        assert_eq!(convert_session(&t, &mut seen).len(), 2);
        assert!(convert_session(&t, &mut seen).is_empty());
    }

    #[test]
    fn walks_dated_folders_oldest_first_and_counts() {
        let dir = std::env::temp_dir().join(format!("codex-sessions-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        for (d, text) in [("2026/11/02", "second"), ("2026/10/30", "first")] {
            let folder = dir.join(d);
            std::fs::create_dir_all(&folder).unwrap();
            let t = [
                meta("cli", "codex_cli_rs"),
                msg("2026-11-01T10:00:03.000Z", "user", "input_text", text),
            ]
            .concat();
            std::fs::write(folder.join("rollout-a.jsonl"), t).unwrap();
        }
        let users: Vec<String> = convert_sessions(&dir)
            .into_iter()
            .filter(|i| i.kind == "user")
            .map(|i| i.text)
            .collect();
        assert_eq!(users, vec!["first", "second"]);
        assert_eq!(count_sessions(&dir).0, 2);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn sessions_dir_honours_codex_home() {
        let home = Path::new("/h");
        assert_eq!(
            default_sessions_dir(home, None),
            PathBuf::from("/h/.codex/sessions")
        );
        assert_eq!(
            default_sessions_dir(home, Some("/c".into())),
            PathBuf::from("/c/sessions")
        );
    }
}
