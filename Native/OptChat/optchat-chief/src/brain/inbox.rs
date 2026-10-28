//! The inbox (mux/host rules): the Chief conversation's messages in seq
//! order, the wake rule, catch-up from the `agent_mux` read cursor after a
//! (re)connect, and the cursor itself, which moves only past messages that
//! are in the OptChat log, so a restart never loses or repeats one.
//!
//! Other conversations (G9): the main conversation's stream is the only one
//! the brain follows. Another conversation is read only when the chief's
//! wake queue names it (`side.rs`), or, on the local owner with
//! `OPTCHAT_GROUP_WAKE` set (`membership`), when a person writes in one the
//! Chief takes part in; it is answered there.

use cmux_chief::rules::{PAGE, message_text};

use crate::wake::chief_wakes;
use cmux_conversation::{Change, Message, Op, Part};

use super::{Brain, Source};
use crate::daemon::{DaemonEvent, OpError};

impl Brain {
    pub(super) fn on_daemon(&mut self, event: DaemonEvent) {
        match event {
            DaemonEvent::Up {
                port,
                conversation,
                reconnect,
            } => {
                self.daemon = Some(port);
                self.reconnect = Some(reconnect);
                if self.state.conversation.as_deref() != Some(conversation.id.as_str()) {
                    if let Some(old) = self.state.conversation.take() {
                        // A new conversation (the owner's store was made
                        // again): its seqs start over, so the old counters
                        // would skip its first messages. Start from its own
                        // agent_mux cursor; ops for the old one cannot land.
                        let cursor = conversation
                            .read_cursors
                            .get(&self.settings.membership.participant)
                            .copied()
                            .unwrap_or(0);
                        (self.log)(&format!(
                            "the Chief conversation changed from {old} to {}; reading it from seq {cursor}",
                            conversation.id
                        ));
                        self.handled = cursor;
                        self.state.logged_seq = cursor;
                        // Side conversations' replies stay.
                        self.state.outbox.retain(|e| e.conversation != old);
                        self.state.awaiting.clear();
                    }
                    self.state.conversation = Some(conversation.id.clone());
                    self.save();
                }
                self.summary = Some(conversation);
                self.prune_floors();
                self.post_notices();
                self.flush_outbox();
                // Typing is the daemon's ephemeral state: a daemon that
                // restarted while a main turn runs has forgotten it, and a
                // client that watches for the turn would never see it (E21).
                if self.state.turn.is_some() && self.turn_side().is_none() {
                    self.set_typing(true);
                }
                self.catch_up();
                self.describe_pending();
                // After the catch-up: a waiting message has started its turn.
                self.prewarm_next_turn();
            }
            DaemonEvent::Changed {
                conversation,
                change,
            } => {
                if self.state.conversation.as_deref() != Some(conversation.as_str()) {
                    if self.settings.membership.local_side {
                        self.on_local_side_change(conversation, change);
                    }
                    return;
                }
                match change {
                    Change::Conversation { conversation } => self.summary = Some(*conversation),
                    Change::ReadCursor { participant, seq } => {
                        if let Some(summary) = self.summary.as_mut() {
                            let cursor = summary.read_cursors.entry(participant).or_insert(0);
                            *cursor = (*cursor).max(seq);
                        }
                    }
                    Change::Message { message } => self.on_message(message),
                    Change::MessageUpdated { message } => self.on_message_updated(&message),
                }
            }
            DaemonEvent::Down => {
                self.daemon = None;
                self.reconnect = None;
            }
            DaemonEvent::Fatal(why) => {
                (self.log)(&why);
                self.fatal = Some(why);
            }
            DaemonEvent::MuxWake(wakes) => self.on_mux_wake(wakes),
        }
    }

    /// Drops the connection after a transport failure or a lost binding; the
    /// link connects and binds again, and the catch-up replays what was missed.
    pub(super) fn drop_daemon(&mut self) {
        self.daemon = None;
        if let Some(reconnect) = self.reconnect.take() {
            reconnect();
        }
    }

    /// Spec 5a.2: an edit or a retraction of a message the log holds is
    /// logged as a note that names its line (`edit of <id>: <text>`,
    /// `retracted <id>`), so the next turn's delta carries it and the next
    /// re-render folds it in. A reaction on the Chief's own messages goes to
    /// `on_chief_reactions` (reaction_wake.rs); another update logs nothing. A message still queued
    /// takes the edited text, or leaves the queue when retracted. The note's key
    /// names the change, so a replayed update is logged once.
    fn on_message_updated(&mut self, message: &Message) {
        let Some(main) = self.state.conversation.clone() else {
            return;
        };
        if message.author == self.settings.membership.participant {
            self.on_chief_reactions(&main, message);
            return;
        }
        let key = format!("{main}#{}", message.seq);
        let Some(target) = self.chat.logged_id(&key) else {
            self.update_queued(message);
            return;
        };
        let (text, change) = match (&message.retracted_at, &message.edited_at) {
            (Some(_), _) => {
                self.reply_not_needed(std::slice::from_ref(&message.id));
                (optchat_core::retracted(target), "retracted".to_owned())
            }
            (None, Some(at)) => (
                optchat_core::edit_of(target, &message_text(message)),
                format!("edited@{at}"),
            ),
            (None, None) => return,
        };
        let entry = optchat_host::NewMessage {
            key: Some(format!("{key}:{change}")),
            ..optchat_host::NewMessage::new(optchat_core::Kind::Note, &text)
        };
        if let Err(e) = self.chat.append_with(&[entry], |_| Vec::new()) {
            (self.log)(&format!(
                "logging the change of message {target} failed: {e}"
            ));
        }
    }

    /// A tapback or emoji someone else put on one of the Chief's own messages
    /// (a416: the user's reactions reach the Chief), when reactions cannot
    /// wake it (reaction_wake.rs), is logged as a quiet note, `reaction
    /// <glyph> [<tapback>] from <name> on your message: <its first line>`,
    /// which the next turn's delta carries. The note's key names the message,
    /// author, part and reaction, so a replayed update logs it once. The
    /// Chief's own reactions and removed ones log nothing.
    pub(super) fn note_reactions(&mut self, main: &str, message: &Message) {
        if message.retracted_at.is_some() {
            return;
        }
        let me = self.settings.membership.participant.clone();
        // (key, text): a note borrows its text, so the texts outlive the entries.
        let notes: Vec<(String, String)> = message
            .reactions
            .iter()
            .filter(|r| r.author != me)
            .map(|r| self.reaction_line(main, message, r))
            .collect();
        let entries: Vec<optchat_host::NewMessage> = notes
            .iter()
            .map(|(key, text)| optchat_host::NewMessage {
                key: Some(key.clone()),
                ..optchat_host::NewMessage::new(optchat_core::Kind::Note, text)
            })
            .collect();
        if entries.is_empty() {
            return;
        }
        if let Err(e) = self.chat.append_with(&entries, |_| Vec::new()) {
            (self.log)(&format!(
                "logging the reactions on message {} failed: {e}",
                message.seq
            ));
        }
    }

    /// The queued item of main-conversation message `message` (not logged
    /// yet) takes its edit, or leaves the queue when it was retracted.
    fn update_queued(&mut self, message: &Message) {
        let is_it = |q: &super::Queued| {
            q.conversation.is_none()
                && !q.logged
                && matches!(q.source, Source::Message { seq, .. } if seq == message.seq)
        };
        if message.retracted_at.is_some() {
            self.queue.retain(|q| !is_it(q));
            self.reply_not_needed(std::slice::from_ref(&message.id));
            if !self.queued_messages_of(None) {
                self.state.logged_seq = self.handled;
                self.save();
                self.set_cursor(self.handled);
                self.settle_acks();
            }
        } else if message.edited_at.is_some() {
            let text = message_text(message);
            for q in self.queue.iter_mut().filter(|q| is_it(q)) {
                q.text = super::images::logged_text(&text, &q.images);
            }
        }
    }

    fn on_message(&mut self, message: Message) {
        if message.author == self.settings.membership.participant {
            self.mux_messages.insert(message.id.clone());
        }
        if self.daemon.is_none() || message.seq <= self.handled {
            return;
        }
        if message.seq > self.handled + 1 {
            // A gap: something was missed; fetch it in order.
            self.catch_up();
            return;
        }
        self.handle(message);
    }

    /// Every message after what was handled (or the agent read cursor, if later).
    fn catch_up(&mut self) {
        let Some(conversation) = self.state.conversation.clone() else {
            return;
        };
        let Some(daemon) = self.daemon.as_mut() else {
            return;
        };
        let fetched = (|| {
            let (summary, messages) = daemon.snapshot(&conversation, PAGE)?;
            let cursor = summary
                .read_cursors
                .get(&self.settings.membership.participant)
                .copied()
                .unwrap_or(0);
            let from = self.handled.max(cursor);
            let mut pending: Vec<Message> =
                messages.iter().filter(|m| m.seq > from).cloned().collect();
            // Page back until the first missing message is in hand.
            while let Some(first) = pending.first().map(|m| m.seq)
                && first > from + 1
            {
                let older = daemon.history(&conversation, first, PAGE)?;
                if older.is_empty() {
                    break;
                }
                let mut merged: Vec<Message> = older.into_iter().filter(|m| m.seq > from).collect();
                merged.append(&mut pending);
                pending = merged;
            }
            Ok::<_, OpError>((summary, messages, pending, from))
        })();
        match fetched {
            Ok((summary, messages, pending, from)) => {
                for m in messages.iter().chain(pending.iter()) {
                    if m.author == self.settings.membership.participant {
                        self.mux_messages.insert(m.id.clone());
                    }
                }
                self.summary = Some(summary);
                self.handled = from;
                for message in pending {
                    self.handle(message);
                }
            }
            Err(e) => {
                (self.log)(&format!("catch-up failed: {e}"));
                self.drop_daemon();
            }
        }
    }

    /// Queues a waking message; moves the cursor past a message that needs no
    /// log once nothing before it is still queued.
    fn handle(&mut self, message: Message) {
        if message.seq <= self.handled {
            return;
        }
        self.handled = message.seq;
        self.note_main_message(&message);
        // A reply's parent first, so the log holds what the reply points at.
        self.note_reply_parent(&message);
        if message.author == self.settings.membership.participant {
            // a455: the Chief learns of a bubble posted in its name that it did not write.
            self.note_host_post(&message);
        }
        let Some(summary) = self.summary.as_ref() else {
            return;
        };
        let text = message_text(&message);
        let has_images = message.parts.iter().any(|part| {
            matches!(part, Part::Attachment { mime_type, .. } if mime_type.starts_with("image/"))
        });
        let has_files = message.parts.iter().any(super::files::is_file_part);
        if (!text.trim().is_empty() || has_images || has_files)
            && chief_wakes(
                &self.settings.membership.rule(false),
                summary,
                &message,
                |id| self.mux_messages.contains(id),
            )
        {
            let remote = message
                .origin
                .as_ref()
                .map(|cmux_conversation::Origin::Remote { install }| install.clone());
            // The turn sees the images; the log keeps their references.
            let images = match self.daemon.as_mut() {
                Some(daemon) if has_images => super::images::read_images(daemon.as_mut(), &message),
                _ => Vec::new(),
            };
            // The turn opens other files from this Mac; the line names where.
            let files = match self.daemon.as_mut() {
                Some(daemon) if has_files => {
                    let root = self.file.attachments_dir();
                    super::files::read_files(daemon.as_mut(), &message, &root)
                }
                _ => Vec::new(),
            };
            let logged =
                super::files::logged_text(&super::images::logged_text(&text, &images), &files);
            self.queue_with_images(
                logged,
                images,
                Source::Message {
                    seq: message.seq,
                    id: message.id.clone(),
                    remote,
                    requires_approval: !self
                        .settings
                        .membership
                        .is_owner_message(summary, &message),
                },
            );
            // A waking message of the Chief conversation is a person's
            // (other Chiefs wake it only in side conversations): it waits
            // for a reply (reply_ledger.rs).
            self.await_reply(&message, &text);
            return;
        }
        if !self.queued_messages_of(None) {
            self.state.logged_seq = self.handled;
            self.save();
            self.set_cursor(self.handled);
            self.settle_acks();
        }
    }

    pub(super) fn set_cursor(&mut self, seq: u64) {
        let Some(conversation) = self.state.conversation.clone() else {
            return;
        };
        let current = self
            .summary
            .as_ref()
            .and_then(|s| {
                s.read_cursors
                    .get(&self.settings.membership.participant)
                    .copied()
            })
            .unwrap_or(0);
        if seq <= current {
            return;
        }
        let Some(daemon) = self.daemon.as_mut() else {
            return;
        };
        let participant = self.settings.membership.participant.clone();
        let key = format!("cursor:{participant}:{seq}");
        match daemon.op(&conversation, &key, &Op::ReadCursorSet { seq }) {
            Ok(_) => {
                if let Some(summary) = self.summary.as_mut() {
                    summary.read_cursors.insert(participant, seq);
                }
            }
            Err(OpError::Rejected(reason)) if reason.contains("cursor_regression") => {}
            Err(OpError::Rejected(reason)) if reason.contains("actor_mismatch") => {
                // The app replaced the token: bind again now, not at the next reply.
                (self.log)(&format!("read cursor {seq}: binding lost; reconnecting"));
                self.drop_daemon();
            }
            Err(OpError::Rejected(reason)) => {
                (self.log)(&format!("read cursor {seq} refused: {reason}"))
            }
            Err(OpError::Transport(e)) => {
                (self.log)(&format!("read cursor {seq}: {e}"));
                self.drop_daemon();
            }
        }
    }

    pub(super) fn set_typing(&mut self, on: bool) {
        let Some(conversation) = self.state.conversation.clone() else {
            return;
        };
        let Some(daemon) = self.daemon.as_mut() else {
            return;
        };
        match daemon.typing(&conversation, on) {
            Ok(()) => {}
            Err(OpError::Rejected(reason)) if reason.contains("actor_mismatch") => {
                (self.log)(&format!("typing {on}: binding lost; reconnecting"));
                self.drop_daemon();
            }
            Err(OpError::Rejected(reason)) if reason == "typing_unsupported" => {
                if !self.typing_unsupported {
                    self.typing_unsupported = true;
                    (self.log)("this conversation owner takes no typing indicator");
                }
            }
            Err(OpError::Rejected(reason)) => (self.log)(&format!("typing {on} refused: {reason}")),
            Err(OpError::Transport(e)) => {
                (self.log)(&format!("typing {on}: {e}"));
                self.drop_daemon();
            }
        }
    }
}
