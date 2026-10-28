//! The Chief's `send` tool (plans/cmux-next/chief-tools-DESIGN.md): one
//! message posted now, with text, attached files and URLs, at the top level
//! or in the thread of a user message. It goes through the outbox like a
//! turn reply (retries, rate limits, idempotency), with the same subagent
//! links, link cards and uploads (previews.rs, media.rs).
//!
//! An attachment is an explicit act: the Chief's Markdown links to local
//! files stay links (it links reports and files all the time), and only the
//! paths in `attachments` are uploaded, of any type.

use std::path::PathBuf;

use cmux_conversation::{Op, PartRef};

use super::Brain;
use super::media::{self, MAX_MEDIA_BYTES, MediaRef};
use crate::tools::SendCall;

impl Brain {
    /// The `send` tool.
    pub(super) fn send(&mut self, call: SendCall) -> Result<String, String> {
        let home = std::env::var_os("HOME").map(PathBuf::from);
        // Every attachment is checked before anything is posted, so a bad
        // call can be fixed and sent again whole.
        let mut files: Vec<MediaRef> = Vec::new();
        let mut urls: Vec<String> = Vec::new();
        for item in &call.attachments {
            if item.starts_with("https://") || item.starts_with("http://") {
                urls.push(item.clone());
                continue;
            }
            let path = media::local_path(item, home.as_deref()).ok_or_else(|| {
                format!("send: attachment {item:?} is not an absolute path, ~/path, file:// or http(s) URL")
            })?;
            let meta = std::fs::metadata(&path)
                .map_err(|e| format!("send: attachment {}: {e}", path.display()))?;
            if !meta.is_file() {
                return Err(format!("send: attachment {} is not a file", path.display()));
            }
            if meta.len() == 0 {
                return Err(format!("send: attachment {} is empty", path.display()));
            }
            if meta.len() > MAX_MEDIA_BYTES {
                return Err(format!(
                    "send: attachment {} is {} MB; the limit is {} MB",
                    path.display(),
                    meta.len() / 1_000_000,
                    MAX_MEDIA_BYTES / 1_000_000
                ));
            }
            if files.iter().any(|f| f.path == path) {
                continue;
            }
            let mime_type = media::attachment_type(&path);
            files.push(MediaRef {
                path,
                mime_type,
                image_syntax: None,
            });
        }
        // A `reply_to` line that is no conversation message (a subagent's
        // report): the thread of the person's message behind it, else the top
        // level, said in the outcome.
        let mut placed = None;
        let thread = match call.reply_to {
            Some(view_id) if self.chat.logged_key(view_id).is_some() => {
                let message = self.message_of_line("send", view_id)?;
                let root = message
                    .thread_root
                    .clone()
                    .unwrap_or_else(|| message.id.clone());
                Some((message.conversation.clone(), message.id.clone(), root))
            }
            Some(view_id) => {
                let thread = self.thread_behind_line(view_id);
                placed = Some(match thread {
                    Some(_) => format!(
                        "line {view_id} is a report, not a message: sent in the thread of the message it answers"
                    ),
                    None => format!(
                        "line {view_id} is not a message and no message is behind it: sent at the top level"
                    ),
                });
                thread
            }
            None => None,
        };
        let conversation = match &thread {
            Some((c, _, _)) => c.clone(),
            None => self
                .state
                .conversation
                .clone()
                .ok_or("send: the conversation is not connected yet; try again")?,
        };
        let turn = self
            .state
            .turn
            .as_ref()
            .map_or_else(|| "idle".to_owned(), |t| t.key.clone());
        let mut fingerprint = call.text.clone().unwrap_or_default();
        for item in &call.attachments {
            fingerprint.push('\u{0}');
            fingerprint.push_str(item);
        }
        if let Some(id) = call.reply_to {
            fingerprint.push_str(&format!("\u{0}reply_to={id}"));
        }
        let key = format!(
            "send-{conversation}-{turn}-{:016x}",
            super::replies::fnv(fingerprint.as_bytes())
        );
        if self.sent_keys.contains(&key)
            || self.state.outbox.iter().any(|e| e.idempotency_key == key)
        {
            return Ok("outcome: noop. this message is already sent".to_owned());
        }
        // The text as a reply's (subagent links), then a URL line each, then
        // one `![name](<path>)` line per file: it leaves the text once the
        // file is uploaded, and stays as its fallback when the upload fails.
        let mut text = call
            .text
            .as_deref()
            .map(|t| self.link_subagents(t.trim()))
            .unwrap_or_default();
        for url in &urls {
            if !text.is_empty() {
                text.push('\n');
            }
            text.push_str(url);
        }
        for file in &mut files {
            let name = file
                .path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("file")
                .replace([']', '[', '\n'], " ");
            if !text.is_empty() {
                text.push('\n');
            }
            let start = text.len();
            text.push_str(&format!("![{name}](<{}>)", file.path.display()));
            file.image_syntax = Some(start..text.len());
        }
        if text.len() > super::REPLY_BYTES {
            return Err(format!(
                "send: the message is {} bytes; the limit is {}: split it into several sends",
                text.len(),
                super::REPLY_BYTES
            ));
        }
        let mut entry = super::reply_entry(conversation, &key, &text);
        if let (
            Some((_, parent, root)),
            Op::MessageSend {
                reply_to,
                thread_root,
                ..
            },
        ) = (&thread, &mut entry.op)
        {
            *reply_to = Some(PartRef {
                message_id: parent.clone(),
                part_index: 0,
            });
            *thread_root = Some(root.clone());
        }
        self.sent_keys.insert(key);
        let entry = self.reply_with_media(entry, files.clone());
        self.state.outbox.push(entry);
        self.save();
        self.flush_outbox();
        let what = match (files.len(), urls.len()) {
            (0, 0) => String::new(),
            (f, u) => format!(" with {} attachment(s)", f + u),
        };
        Ok(match (placed, call.reply_to) {
            (Some(placed), _) => format!("outcome: done. {placed}{what}"),
            (None, Some(id)) => format!("outcome: done. sent{what} in the thread of message {id}"),
            (None, None) => format!("outcome: done. sent{what}"),
        })
    }
}
