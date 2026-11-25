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
use super::media::{self, MediaRef};
use crate::tools::SendCall;

impl Brain {
    /// The `send` tool.
    pub(super) fn send(&mut self, call: SendCall) -> Result<String, String> {
        // The length gate: the first long send of a turn comes back for
        // Chief to cut; the next one posts (chief_kernel::replies). A send
        // marked `long` (a list the person asked for) posts the first time.
        if let Some(refusal) = chief_kernel::replies::length_check(
            call.text.as_deref().unwrap_or(""),
            self.chief.reply_max_words,
            self.length_refused || call.long,
        ) {
            self.length_refused = true;
            self.trace.emit(
                "chief.reply_too_long",
                serde_json::json!({"words": chief_kernel::replies::reply_words(call.text.as_deref().unwrap_or(""))}),
            );
            return Err(refusal);
        }
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
            if call.delay_seconds.is_some() {
                return Err(
                    "send: a message sent later carries text and URLs; send files now".into(),
                );
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
            if files.iter().any(|f| f.path == path) {
                continue;
            }
            let mime_type = media::attachment_type(&path);
            files.push(MediaRef {
                path,
                mime_type: mime_type.into(),
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
        if let Some(seconds) = call.delay_seconds {
            fingerprint.push_str(&format!("\u{0}delay={seconds}"));
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
        // The text as a reply's (subagent links), then a URL line each.
        // The file manifest stays separate: attachment count must not
        // consume the message's text allowance.
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
        if let Some(seconds) = call.delay_seconds {
            return self.send_later(entry, key, seconds);
        }
        self.sent_keys.insert(key.clone());
        // The wake run's `result`: the posted text, or the files it sent.
        let posted = if text.is_empty() {
            let names: Vec<String> = files
                .iter()
                .filter_map(|f| f.path.file_name().map(|n| n.to_string_lossy().into_owned()))
                .collect();
            format!("[{} file(s): {}]", names.len(), names.join(", "))
        } else {
            text.clone()
        };
        let entry = self.reply_with_media(entry, files.clone());
        self.state.outbox.push(entry);
        self.save();
        self.flush_outbox();
        // What the owner did with it: "sent" only when it took the message.
        // A refusal is the Chief's to know (2026-11-20: 25 messages the
        // owner refused with agent_budget were answered "sent").
        // The key it went under: a merge into an earlier waiting message
        // (pacing::coalesce) shares that message's fate; a refused link
        // card retries as `{key}:text`, a refused thread as `{key}:top`.
        let mut under = key.clone();
        while let Some(into) = self.merged_sends.remove(&under) {
            under = into;
        }
        let ours = |k: &str| {
            k == under
                || k.strip_prefix(under.as_str())
                    .is_some_and(|r| r.starts_with(':'))
        };
        let refused_at = self.refused.iter().position(|r| ours(&r.key));
        if let Some(refused) = refused_at.map(|at| self.refused.remove(at)) {
            self.sent_keys.remove(&key);
            let mut error = format!(
                "send: refused by the conversation, nothing was posted ({}): {}",
                refused.reason,
                refusal_meaning(&refused.reason)
            );
            error.push_str(&self.untold_refusals());
            return Err(error);
        }
        self.wake_run_posted(&posted);
        let what = match (files.len(), urls.len()) {
            (0, 0) => String::new(),
            (f, u) => format!(" with {} attachment(s)", f + u),
        };
        let queued = self.state.outbox.iter().any(|e| ours(&e.idempotency_key));
        let mut answer = match (queued, placed, call.reply_to) {
            (true, placed, _) => format!(
                "outcome: queued. not posted yet{what}: it waits its turn in the outbox (the gap after the last message, an upload or link previews){}; a refusal is told on your next send",
                placed.map(|p| format!("; {p}")).unwrap_or_default()
            ),
            (false, Some(placed), _) => format!("outcome: done. {placed}{what}"),
            (false, None, Some(id)) => {
                format!("outcome: done. sent{what} in the thread of message {id}")
            }
            (false, None, None) => format!("outcome: done. sent{what}"),
        };
        answer.push_str(&self.untold_refusals());
        Ok(answer)
    }

    /// `send` with `delay_seconds`: the conversation owner holds the message
    /// and posts it as the Chief then (`conversation-scheduled-v1`), whether
    /// or not the Chief runs; the user sees it waiting and can change it.
    fn send_later(
        &mut self,
        entry: crate::state::OutboxEntry,
        key: String,
        seconds: u64,
    ) -> Result<String, String> {
        let send_at_ms = super::now_ms().saturating_add(seconds.saturating_mul(1_000));
        let daemon = self
            .daemon
            .as_mut()
            .ok_or("send: the conversation is not connected yet; try again")?;
        let id = match daemon.schedule(&entry.conversation, &entry.op, send_at_ms) {
            Ok(id) => id,
            // The same message under its key is already queued (a replay
            // returns it) or already sent: never queue it a second time.
            Err(crate::daemon::OpError::Rejected(reason))
                if reason.contains("idempotency_conflict") =>
            {
                self.sent_keys.insert(key);
                return Ok("outcome: noop. this message is already scheduled or sent".to_owned());
            }
            Err(error) => return Err(format!("send: not scheduled: {error}")),
        };
        self.sent_keys.insert(key);
        Ok(format!(
            "outcome: done. scheduled {id} to send in {seconds} s"
        ))
    }
}

impl Brain {
    /// The refusals the Chief has not been told yet (messages queued earlier
    /// that the owner refused later), as lines to append to an answer.
    fn untold_refusals(&mut self) -> String {
        self.take_all_refused()
            .into_iter()
            .map(|r| {
                let text: String = r.text.chars().take(80).collect();
                let more = if r.text.chars().count() > 80 {
                    "…"
                } else {
                    ""
                };
                format!(
                    "\nearlier message not posted ({}): {text:?}{more}: {}",
                    r.reason,
                    refusal_meaning(&r.reason)
                )
            })
            .collect()
    }
}

/// What an owner's reject code means for the Chief.
fn refusal_meaning(reason: &str) -> &'static str {
    if reason.contains("agent_budget") {
        "the loop guard between agents takes no more agent messages in this thread until a person writes in it (6 agent messages follow their last one, and another agent shares the conversation). Sending again posts nothing: end the turn (stop). The host keeps what is owed (untold outcomes, unannounced starts) and puts it in your turn for the person's next message"
    } else if reason.contains("idempotency_conflict") {
        "this message's key was already used for other text (a host bug)"
    } else {
        "the conversation refused the message"
    }
}
