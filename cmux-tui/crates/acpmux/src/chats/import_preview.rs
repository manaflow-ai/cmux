//! The preview of an optional history import (`_acpmux/chat_import_preview`): before a person
//! brings a recent project's chats into cmux, what each one is, where it comes from and what
//! importing it would and would not carry.
//!
//! Nothing here imports or writes. Each row reuses the chat index's entry and `plan_open`, the
//! same plan `_acpmux/chat_open` answers, so Import runs each selected chat through the one open
//! path the app already has (`session/new` with `_meta.acpmux.adopt`, a terminal resume, or the
//! read-only transcript). Importing a chat twice opens the session that already adopted it
//! (`hub/adoption.rs`), and the row says so up front (`alreadyImported`). The source store is
//! only read, so cancelling (or never pressing Import) leaves every chat where it was.
//!
//! A row that cannot import cleanly is not dropped: it stays in the preview with its
//! `omissions` (the folder is gone, the file is unreadable or empty, only the newest part of a
//! large transcript is shown), so a partial import explains itself and the client can retry
//! the rows that failed.

use std::path::Path;

use cmux_chat_index::IndexedChat;
use serde_json::{Value, json};

use super::open::{StoreProfile, plan_open, store_dirs};
use cmux_json::JsonSet as _;

/// Chats one preview lists when the request names no limit.
pub const DEFAULT_CHATS: usize = 50;
/// The most chats one preview lists.
pub const MAX_CHATS: usize = 200;

/// What a preview row needs beyond the chat itself.
pub struct PreviewContext<'a> {
    pub profiles: &'a [StoreProfile],
    /// The person's home folder (`plan_open` never falls back to it).
    pub home: &'a Path,
    /// This machine's name: the chats a preview lists are all on it.
    pub host: &'a str,
    /// The acpmux session that already adopted `(family, agent session id)`, if any.
    pub adopted: &'a dyn Fn(&str, &str) -> Option<String>,
}

/// How a chat continues once imported.
fn resume_kind(plan_kind: &str) -> &'static str {
    match plan_kind {
        // The agent reloads its own session: history, tool state and attachments stay its own.
        "adopt" => "native",
        // The agent's own CLI resumes it in a terminal tab.
        "terminal" => "terminal",
        // No resume path: the transcript is shown, nothing continues it.
        _ => "readOnly",
    }
}

/// One chat's preview row.
pub fn row(chat: &IndexedChat, cx: &PreviewContext<'_>) -> Value {
    let entry = &chat.entry;
    let key = super::key_text(&entry.key());
    let mut omissions: Vec<Value> = Vec::new();
    let plan = match plan_open(chat, cx.profiles, None, cx.home) {
        Ok(plan) => plan,
        Err(reason) => {
            omissions.push(json!({"code": "plan", "detail": reason}));
            json!({"kind": "readOnly"})
        }
    };
    let kind = plan.get("kind").and_then(Value::as_str).unwrap_or("readOnly");
    let resume = resume_kind(kind);
    if let Some(reason) =
        plan.get("needsFolder").and_then(|n| n.get("reason")).and_then(Value::as_str)
    {
        omissions.push(json!({"code": "folder", "detail": reason}));
    }
    let mut readable = true;
    match std::fs::metadata(&entry.source_path) {
        Err(e) => {
            readable = false;
            omissions.push(json!({"code": "unreadable", "detail": e.to_string()}));
        }
        Ok(meta) if meta.is_file() && meta.len() == 0 => {
            readable = false;
            omissions.push(json!({"code": "empty", "detail": "the transcript file is empty"}));
        }
        Ok(meta) if meta.is_file() && meta.len() > crate::adopt_replay::MAX_BYTES => {
            omissions.push(json!({
                "code": "olderHistory",
                "detail": format!(
                    "cmux shows the newest {} MiB of this {} MiB transcript; the agent keeps all of it",
                    crate::adopt_replay::MAX_BYTES >> 20,
                    meta.len() >> 20
                ),
                "bytes": meta.len(),
            }));
        }
        Ok(_) => {}
    }
    if entry.archived {
        omissions.push(json!({"code": "archived", "detail": "archived in its agent"}));
    }
    let family = plan.get("family").and_then(Value::as_str);
    let adopted = match family {
        Some(family) if kind == "adopt" => (cx.adopted)(family, &entry.session_id),
        _ => None,
    };
    // What the import carries: a native resume keeps the agent's own state; the others carry
    // the transcript text only.
    let native = resume == "native" || resume == "terminal";
    let carries =
        json!({"text": readable, "tools": native && readable, "attachments": native && readable});
    let profile = plan.get("adopt").and_then(|a| a.get("harness")).cloned().unwrap_or(Value::Null);
    let blocked = !readable || (resume == "native" && plan.get("sessionNew").is_none());
    let state = if adopted.is_some() {
        "alreadyImported"
    } else if blocked {
        "needsAttention"
    } else {
        "ready"
    };
    let store = store_dirs(chat).into_iter().next();
    let mut value = json!({
        "key": key,
        "title": entry.title,
        "updatedMs": entry.updated_ms,
        "messageCount": entry.message_count,
        "source": {
            "harness": entry.harness.id(),
            "brand": super::brand::harness_brand(entry.harness),
            "path": entry.source_path,
            "store": store,
            "originator": entry.originator,
        },
        "project": entry.cwd,
        "host": cx.host,
        "account": {"profile": profile, "labels": chat.accounts},
        "resume": resume,
        "carries": carries,
        "omissions": omissions,
        "state": state,
        "importedSession": adopted,
    });
    value.set("open", plan);
    value
}

/// The preview of `chats` (newest first): a row each and the counts a summary line needs.
pub fn preview(project: Option<&str>, chats: &[IndexedChat], cx: &PreviewContext<'_>) -> Value {
    let rows: Vec<Value> = chats.iter().map(|chat| row(chat, cx)).collect();
    let count = |field: &str, value: &str| {
        rows.iter().filter(|row| row.get(field).and_then(Value::as_str) == Some(value)).count()
    };
    let with_omissions = rows
        .iter()
        .filter(|row| row.get("omissions").and_then(Value::as_array).is_some_and(|o| !o.is_empty()))
        .count();
    json!({
        "project": project,
        "host": cx.host,
        "summary": {
            "chats": rows.len(),
            "ready": count("state", "ready"),
            "alreadyImported": count("state", "alreadyImported"),
            "needsAttention": count("state", "needsAttention"),
            "native": count("resume", "native"),
            "terminal": count("resume", "terminal"),
            "readOnly": count("resume", "readOnly"),
            "withOmissions": with_omissions,
        },
        "rows": rows,
    })
}

#[cfg(test)]
#[path = "import_preview_tests.rs"]
mod tests;
