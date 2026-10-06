//! `optchat-chief browse` and `import` (section 10).
//!
//! Browse writes the whole memory as one HTML page: the current view, ROOT
//! (every message) and each level of the tree, each entry with its range,
//! time span and size. Import appends old history (JSON lines) as messages,
//! kind `note` unless a line says otherwise, each with its own date when the
//! line has one; the compactor then builds the tree over them like any other
//! messages.
//!
//! Both read the memory where it lives: through the running host (the only
//! process that may open the chat), or, with no host running, by opening
//! the chat directly. Import refuses while a host runs: a turn would
//! interleave with the notes, and notes keep their ids only in an empty chat.

use std::fmt::Write as _;
use std::path::Path;
use std::sync::Arc;

use optchat_core::{Kind, NodeId};
use optchat_host::{
    CompactModel, CompactRequest, Config, Followup, ModelError, OptChat, Reply, SystemClock,
};
use serde_json::Value;

fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            c => out.push(c),
        }
    }
    out
}

/// The page for `chat`.
pub fn html(chat: &OptChat) -> String {
    let status = chat.status();
    let t = status.messages;
    let date = |id: u64| chat.date(id).unwrap_or_default();
    let mut page = String::from(
        "<!doctype html><meta charset=utf-8><meta name=viewport content=\"width=device-width,initial-scale=1\"><title>Chief memory</title>\
<style>:root{color-scheme:light dark}body{font:14px/1.45 ui-monospace,Menlo,monospace;margin:16px;background:Canvas;color:CanvasText}\
pre{white-space:pre-wrap;word-break:break-word}details{margin:2px 0}summary{cursor:pointer}.m{opacity:.65}</style>",
    );
    let _ = write!(
        page,
        "<h1>Chief memory</h1><p class=m>{t} messages, {} view lines ({} bytes of {}), {} nodes built</p>",
        status.view_lines, status.view_size, status.budget, status.built
    );
    let _ = write!(
        page,
        "<h2>View</h2><pre>{}</pre>",
        escape(&chat.render_view().text)
    );
    let _ = write!(page, "<h2>ROOT</h2>");
    for id in 0..t {
        if let Some((kind, text)) = chat.message(id) {
            let _ = write!(
                page,
                "<details><summary>{id} {} <span class=m>{} · {} bytes</span></summary><pre>{}</pre></details>",
                kind.as_str(),
                escape(&date(id)),
                text.len(),
                escape(&text)
            );
        }
    }
    let mut l = 0u32;
    while t > 0 && (1u64 << l) <= t {
        let _ = write!(page, "<h2>Level {l} ({} messages per node)</h2>", 1u64 << l);
        for i in 0..(t >> l) {
            let node = NodeId::new(l, i);
            let span = format!("{} to {}", date(node.start()), date(node.end() - 1));
            match chat.node(node) {
                Some(text) => {
                    let _ = write!(
                        page,
                        "<details><summary>{} <span class=m>{} · {} bytes</span></summary><pre>{}</pre></details>",
                        node.name(),
                        escape(&span),
                        text.len(),
                        escape(&text)
                    );
                }
                None => {
                    let _ = write!(
                        page,
                        "<p class=m>{} not built yet ({})</p>",
                        node.name(),
                        escape(&span)
                    );
                }
            }
        }
        l += 1;
    }
    page
}

/// One imported message.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Imported {
    pub kind: Kind,
    pub text: String,
    /// When it was first written (RFC 3339); None: the import's own time.
    pub date: Option<String>,
}

/// Parses JSON lines `{"text": "...", "kind": "note", "date": "..."}` (kind
/// optional, default note; date optional, RFC 3339; blank lines skipped).
pub fn parse_import(input: &str) -> Result<Vec<Imported>, String> {
    let mut out = Vec::new();
    for (n, line) in input.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        let value: Value =
            serde_json::from_str(line).map_err(|e| format!("line {}: {e}", n + 1))?;
        let text = value
            .get("text")
            .and_then(Value::as_str)
            .ok_or_else(|| format!("line {}: no \"text\"", n + 1))?;
        let kind = match value.get("kind").and_then(Value::as_str) {
            None => Kind::Note,
            Some(k) => Kind::parse(k).ok_or_else(|| format!("line {}: unknown kind {k}", n + 1))?,
        };
        let date = match value.get("date") {
            None | Some(Value::Null) => None,
            Some(Value::String(d)) if chrono::DateTime::parse_from_rfc3339(d).is_ok() => {
                Some(d.clone())
            }
            Some(other) => {
                return Err(format!(
                    "line {}: \"date\" must be an RFC 3339 time, not {other}",
                    n + 1
                ));
            }
        };
        out.push(Imported {
            kind,
            text: text.to_owned(),
            date,
        });
    }
    Ok(out)
}

/// A compactor model for a chat opened only to read or import: the host
/// builds the tree when it next runs, so no call is made here.
struct Deferred;

impl CompactModel for Deferred {
    fn call(&self, _: &CompactRequest, _: &[Followup]) -> Result<Reply, ModelError> {
        Err(ModelError::new("built by the host"))
    }
}

/// Opens the chat directly (no host running).
pub fn open_offline(dir: &Path) -> Result<OptChat, String> {
    let config = Config {
        agent: crate::prompt::AGENT.to_owned(),
        reporter: Arc::new(|_| {}),
        ..Config::default()
    };
    OptChat::open_with(dir, config, Arc::new(Deferred), Arc::new(SystemClock)).map_err(|e| {
        format!(
            "opening {}: {e} (is the Chief host running?)",
            dir.display()
        )
    })
}

/// Appends `items` to the chat in `dir` (no host may run). Returns how many.
pub fn import(dir: &Path, items: &[Imported]) -> Result<usize, String> {
    let chat = open_offline(dir)?;
    let before = chat.status().messages;
    if before > 0 {
        crate::log::log(format!(
            "importing after {before} messages: the notes get ids from {before} on, not their own"
        ));
    }
    for item in items {
        match &item.date {
            Some(date) => chat.append_dated(item.kind, &item.text, date),
            None => chat.append(item.kind, &item.text),
        }
        .map_err(|e| format!("appending: {e}"))?;
    }
    chat.shutdown();
    Ok(items.len())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn import_lines_default_to_notes() {
        let items =
            parse_import("{\"text\": \"a\"}\n\n{\"text\": \"b\", \"kind\": \"user\"}\n").unwrap();
        assert_eq!(
            items,
            vec![
                Imported {
                    kind: Kind::Note,
                    text: "a".into(),
                    date: None,
                },
                Imported {
                    kind: Kind::User,
                    text: "b".into(),
                    date: None,
                },
            ]
        );
        assert!(parse_import("{\"kind\": \"note\"}").is_err());
        assert!(parse_import("{\"text\": \"a\", \"kind\": \"nope\"}").is_err());
    }

    /// Section 10: imported history keeps each message's own date (`date`,
    /// RFC 3339), so `date(id)` tells when it was written, not imported.
    #[test]
    fn an_import_keeps_each_messages_date() {
        let items = parse_import(
            "{\"text\": \"old\", \"date\": \"2026-03-01T09:30:00-08:00\"}\n{\"text\": \"undated\"}\n",
        )
        .unwrap();
        assert_eq!(items[0].date.as_deref(), Some("2026-03-01T09:30:00-08:00"));
        assert_eq!(items[1].date, None);
        assert!(parse_import("{\"text\": \"a\", \"date\": \"yesterday\"}").is_err());
        let dir = tempfile::tempdir().unwrap();
        let chat_dir = dir.path().join("chat");
        assert_eq!(import(&chat_dir, &items).unwrap(), 2);
        let chat = open_offline(&chat_dir).unwrap();
        assert_eq!(chat.stamp(0).as_deref(), Some("2026-03-01T09:30:00-08:00"));
        assert_ne!(chat.stamp(1).as_deref(), Some("2026-03-01T09:30:00-08:00"));
    }

    #[test]
    fn an_import_lands_in_the_log_and_the_page_shows_it() {
        let dir = tempfile::tempdir().unwrap();
        let chat_dir = dir.path().join("chat");
        let items =
            parse_import("{\"text\": \"<b>old</b> note\"}\n{\"text\": \"second\"}\n").unwrap();
        assert_eq!(import(&chat_dir, &items).unwrap(), 2);
        let chat = open_offline(&chat_dir).unwrap();
        assert_eq!(
            chat.message(0),
            Some((Kind::Note, "<b>old</b> note".into()))
        );
        let page = html(&chat);
        assert!(page.contains("&lt;b&gt;old&lt;/b&gt; note"), "{page}");
        assert!(page.contains("<h2>ROOT</h2>") && page.contains("<h2>Level 1"));
    }
}
