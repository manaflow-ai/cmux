//! G9: the Chief answers in many conversations. The brain subscribes to the
//! main conversation's stream only. The daemon relays the chief's wake
//! queue (`cloud-mux-wake`, `cloud-mux-resynced`): wakes by ids only, never
//! text. A wake for a side conversation makes the brain read it through the
//! leased port (the chief's own authorized snapshot and history reads), from
//! its saved floor, and apply the same wake rule as the main conversation;
//! a waking message is queued in the one inbox with its conversation id.
//!
//! Trust: a side conversation is read only after the daemon woke it, only
//! through the connected (leased) port, and only the woken id. Nothing in a
//! message body names what the brain reads.

use cmux_chief::rules::{AGENT_MUX, PAGE, message_text};
use cmux_conversation::{Message, Part, Summary};

use super::{Brain, Source, now_ms};
use crate::daemon::{MuxWake, OpError};
use crate::wake::chief_wakes;

impl Brain {
    pub(super) fn on_mux_wake(&mut self, wakes: Vec<MuxWake>) {
        // Only through the leased port. A wake that comes while it is down
        // is delivered again (`cloud-mux-resynced`) after the reconnect.
        if self.daemon.is_none() {
            return;
        }
        // One read per conversation, from its lowest woken seq.
        let mut order: Vec<(String, u64)> = Vec::new();
        for wake in wakes {
            if wake.conversation.is_empty() || wake.seq == 0 {
                continue;
            }
            self.wake_pending(&wake.conversation, wake.seq);
            match order.iter_mut().find(|(c, _)| *c == wake.conversation) {
                Some(entry) => entry.1 = entry.1.min(wake.seq),
                None => order.push((wake.conversation, wake.seq)),
            }
        }
        for (conversation, seq) in order {
            if self.state.conversation.as_deref() == Some(conversation.as_str()) {
                // The main conversation's own stream reads it: no read here.
                continue;
            }
            self.side_wake(&conversation, seq);
            if self.daemon.is_none() {
                return;
            }
        }
        self.prune_floors();
        self.settle_acks();
    }

    /// A wake of side conversation `conversation` at `seq`.
    fn side_wake(&mut self, conversation: &str, seq: u64) {
        let saved = self.state.side.get(conversation).map(|f| f.seq);
        let known = self.side_handled.get(conversation).copied().max(saved);
        // A conversation without a floor starts at its first wake: what came
        // before it was never the chief's to answer.
        let from = known.unwrap_or(seq - 1);
        self.side_handled.insert(conversation.to_owned(), from);
        let floor = self.state.side.entry(conversation.to_owned()).or_default();
        floor.touched_ms = now_ms();
        if saved.is_none() {
            floor.seq = from;
        }
        self.save();
        if seq <= from {
            return;
        }
        match self.read_side(conversation, from) {
            Ok((summary, messages)) => {
                for m in &messages {
                    if m.author == AGENT_MUX {
                        self.mux_messages.insert(m.id.clone());
                    }
                }
                for message in messages {
                    self.side_message(conversation, &summary, message);
                }
            }
            Err(OpError::Rejected(why)) => {
                // Closed, or the chief left it: nothing to answer there.
                (self.log)(&format!(
                    "side conversation {conversation} is not readable ({why}); dropping its floor"
                ));
                self.state.side.remove(conversation);
                self.side_handled.remove(conversation);
                self.save();
                // Acked so the queue stops delivering it.
                let top = self.mux_pending.get(conversation).copied().unwrap_or(seq);
                self.ack(conversation, top);
            }
            Err(OpError::Transport(e)) => {
                (self.log)(&format!("reading side conversation {conversation}: {e}"));
                self.drop_daemon();
            }
        }
    }

    /// Every message of `conversation` after `from`, oldest first, with its
    /// summary (the wake rule needs the participants).
    fn read_side(
        &mut self,
        conversation: &str,
        from: u64,
    ) -> Result<(Summary, Vec<Message>), OpError> {
        let Some(daemon) = self.daemon.as_mut() else {
            return Err(OpError::Transport("no connection".into()));
        };
        let (summary, messages) = daemon.snapshot(conversation, PAGE)?;
        let mut pending: Vec<Message> = messages.into_iter().filter(|m| m.seq > from).collect();
        while let Some(first) = pending.first().map(|m| m.seq)
            && first > from + 1
        {
            let older = daemon.history(conversation, first, PAGE)?;
            if older.is_empty() {
                break;
            }
            let mut merged: Vec<Message> = older.into_iter().filter(|m| m.seq > from).collect();
            merged.append(&mut pending);
            pending = merged;
        }
        Ok((summary, pending))
    }

    /// One message of a woken side conversation: the main conversation's
    /// wake rule; a waking message is queued for a turn in `conversation`,
    /// anything else moves its floor once nothing of it is queued.
    fn side_message(&mut self, conversation: &str, summary: &Summary, message: Message) {
        let handled = self.side_handled.get(conversation).copied().unwrap_or(0);
        let repeat = self
            .state
            .side
            .get(conversation)
            .is_some_and(|f| f.ids.contains(&message.id));
        if message.seq <= handled || repeat {
            return;
        }
        self.side_handled
            .insert(conversation.to_owned(), message.seq);
        let text = message_text(&message);
        let has_images = message.parts.iter().any(|part| {
            matches!(part, Part::Attachment { mime_type, .. } if mime_type.starts_with("image/"))
        });
        if (!text.trim().is_empty() || has_images)
            && chief_wakes(summary, &message, |id| self.mux_messages.contains(id))
        {
            let labelled = labelled(summary, &text);
            match crate::approval::Answer::parse(&text) {
                // An answer to this conversation's pending approval.
                Some(answer) if self.has_approval(Some(conversation)) => {
                    self.answer_approval(answer, &message, Some(conversation));
                    if let Err(e) = self.chat.append(optchat_core::Kind::User, &labelled) {
                        (self.log)(&format!("logging an approval failed: {e}"));
                    }
                }
                _ => {
                    let remote = message
                        .origin
                        .as_ref()
                        .map(|cmux_conversation::Origin::Remote { install }| install.clone());
                    let images = match self.daemon.as_mut() {
                        Some(daemon) if has_images => {
                            super::images::read_images(daemon.as_mut(), &message)
                        }
                        _ => Vec::new(),
                    };
                    let logged = super::images::logged_text(&labelled, &images);
                    self.queue_in(
                        Some(conversation.to_owned()),
                        logged,
                        images,
                        Source::Message {
                            seq: message.seq,
                            id: message.id.clone(),
                            remote,
                        },
                    );
                    return;
                }
            }
        }
        if !self.queued_messages_of(Some(conversation)) {
            self.state
                .side
                .entry(conversation.to_owned())
                .or_default()
                .handled(message.seq, &message.id);
            self.save();
        }
    }

    /// The floor of `conversation` (None: main) whose handled seq is
    /// `handled`: one before its first message still queued, else `handled`.
    pub(super) fn floor_of(&self, conversation: Option<&str>, handled: u64) -> u64 {
        self.queue
            .iter()
            .filter(|q| q.conversation.as_deref() == conversation)
            .filter_map(|q| match q.source {
                Source::Message { seq, .. } => Some(seq),
                _ => None,
            })
            .min()
            .map_or(handled, |seq| handled.min(seq - 1))
    }
}

/// Longest title (characters) in a side message's label.
const LABEL_TITLE_CHARS: usize = 80;

/// A side message's text as the turn and the log see it: a fixed label with
/// the conversation id and its title in quotes, then the person's words.
/// The title is users' text that the model reads, so it loses newlines and
/// other control characters, brackets and quotes, and is cut to
/// `LABEL_TITLE_CHARS`: it cannot end the label or fake a line.
fn labelled(summary: &Summary, text: &str) -> String {
    let cleaned: String = summary
        .title
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .filter(|c| !matches!(c, '[' | ']' | '"'))
        .collect();
    let title: String = cleaned
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(LABEL_TITLE_CHARS)
        .collect();
    format!("[in conv {} \"{title}\"] {text}", summary.id)
}
