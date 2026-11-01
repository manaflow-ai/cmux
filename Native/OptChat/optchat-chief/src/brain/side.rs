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

use cmux_chief::rules::{PAGE, message_text};
use cmux_conversation::{Change, Message, Part, Summary};

use super::{Brain, Source, now_ms};
use crate::daemon::{MuxWake, OpError};
use crate::wake::chief_wakes;

impl Brain {
    /// A change of another local conversation (`membership`, local source
    /// only): a person's message in one the Chief takes part in is a wake
    /// of that conversation at its seq, read and answered as a cloud wake
    /// is. The local owner has no wake queue: the saved floor is the record.
    pub(super) fn on_local_side_change(&mut self, conversation: String, change: Change) {
        match change {
            Change::Conversation {
                conversation: summary,
            } => self.note_side_members(&summary),
            Change::Message { message } => {
                if message.author == self.settings.membership.participant {
                    self.mux_messages.insert(message.id.clone());
                    return;
                }
                // Not read: a conversation the Chief is not in, and a
                // message whose author is known to wake no Chief (an agent
                // that is not a Chief). An unknown author is read: the read
                // refreshes the participants.
                match self.side_member.get(&conversation) {
                    Some(None) => return,
                    Some(Some(people)) if people.get(&message.author) == Some(&false) => return,
                    _ => {}
                }
                self.on_mux_wake(vec![MuxWake {
                    conversation,
                    seq: message.seq,
                    reason: "local".into(),
                }]);
            }
            Change::MessageUpdated { .. } | Change::ReadCursor { .. } => {}
        }
    }

    /// Caches whether the Chief takes part in `summary`'s conversation, and
    /// which of its participants can wake it (people and Chiefs).
    fn note_side_members(&mut self, summary: &Summary) {
        let participant = &self.settings.membership.participant;
        let member = summary.participants.iter().any(|p| &p.id == participant);
        let people = member.then(|| {
            summary
                .participants
                .iter()
                .map(|p| {
                    let wakes = p.kind == cmux_conversation::ParticipantKind::Human
                        || cmux_chief::rules::is_chief(summary, &p.id);
                    (p.id.clone(), wakes)
                })
                .collect()
        });
        self.side_member.insert(summary.id.clone(), people);
    }

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
            Ok((summary, read)) => {
                let participant = self.settings.membership.participant.clone();
                self.note_side_members(&summary);
                for m in &read {
                    if m.author == participant {
                        self.mux_messages.insert(m.id.clone());
                    }
                }
                let pending: Vec<Message> = read.iter().filter(|m| m.seq > from).cloned().collect();
                for message in pending {
                    self.side_message(conversation, &summary, &read, message);
                }
            }
            Err(OpError::Rejected(why)) => {
                // Closed, or the chief left it: nothing to answer there.
                (self.log)(&format!(
                    "side conversation {conversation} is not readable ({why}); dropping its floor"
                ));
                self.state.side.remove(conversation);
                self.side_handled.remove(conversation);
                // Not read again for each of its messages.
                self.side_member.insert(conversation.to_owned(), None);
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

    /// What was read of `conversation`, oldest first: the snapshot's tail
    /// and older pages back to `from`, with its summary (the wake rule needs
    /// the participants, the Chief streak the threads' tails).
    fn read_side(
        &mut self,
        conversation: &str,
        from: u64,
    ) -> Result<(Summary, Vec<Message>), OpError> {
        let Some(daemon) = self.daemon.as_mut() else {
            return Err(OpError::Transport("no connection".into()));
        };
        let (summary, mut read) = daemon.snapshot(conversation, PAGE)?;
        while let Some(first) = read.first().map(|m| m.seq)
            && first > from + 1
        {
            let older = daemon.history(conversation, first, PAGE)?;
            if older.is_empty() {
                break;
            }
            let mut merged = older;
            merged.append(&mut read);
            read = merged;
        }
        Ok((summary, read))
    }

    /// One message of a woken side conversation: the main conversation's
    /// wake rule; a waking message is queued for a turn in `conversation`,
    /// anything else moves its floor once nothing of it is queued.
    fn side_message(
        &mut self,
        conversation: &str,
        summary: &Summary,
        read: &[Message],
        message: Message,
    ) {
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
        let has_files = message.parts.iter().any(super::files::is_file_part);
        if (!text.trim().is_empty() || has_images || has_files)
            && chief_wakes(
                &self.settings.membership.rule(true),
                summary,
                &message,
                |id| self.mux_messages.contains(id),
            )
            && self.under_chief_budget(conversation, summary, read, &message)
        {
            let labelled = if self.settings.membership.local_side {
                labelled_from(
                    summary,
                    &message.author,
                    &text,
                    &self.settings.membership.owner,
                )
            } else {
                labelled(summary, &text)
            };
            let remote = message
                .origin
                .as_ref()
                .map(|cmux_conversation::Origin::Remote { install }| install.clone());
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
            let sender = self.settings.membership.agent_sender(summary, &message);
            let logged = super::files::logged_text(
                &super::images::logged_text(
                    &super::inbox::agent_framed(sender.as_ref(), &labelled),
                    &images,
                ),
                &files,
            );
            if let Some(target) = crate::membership::thread_target(summary, &message) {
                self.reply_threads.insert(message.id.clone(), target);
            }
            self.queue_in(
                Some(conversation.to_owned()),
                logged,
                images,
                Source::Message {
                    seq: message.seq,
                    id: message.id.clone(),
                    remote,
                    agent: sender.as_ref().map(|s| s.name.clone()),
                    requires_approval: !self
                        .settings
                        .membership
                        .is_owner_message(summary, &message),
                },
            );
            return;
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

    /// The loop guard, the owner's own rule (`cmux_conversation`
    /// `thread_agent_streak`, `MAX_AGENT_TURNS`): a message by another Chief
    /// wakes this one only while the thread its reply goes into
    /// (`membership::thread_target`, else the top level) holds fewer agent
    /// texts since a person's text there
    /// than the budget. Past it the owner refuses the reply (`agent_budget`),
    /// so the Chief stays quiet instead of running that turn. A person's
    /// message always passes (it resets its thread).
    fn under_chief_budget(
        &self,
        conversation: &str,
        summary: &Summary,
        read: &[Message],
        message: &Message,
    ) -> bool {
        use cmux_chief::rules::is_chief;
        use cmux_conversation::{MAX_AGENT_TURNS, thread_agent_streak};
        if !is_chief(summary, &message.author) {
            return true;
        }
        // Where the reply goes (`membership::thread_target`): the message's
        // thread in a group conversation, else the top level.
        let target = crate::membership::thread_target(summary, message).map(|(root, _)| root);
        let newest_first: Vec<Message> = read.iter().rev().cloned().collect();
        let streak = thread_agent_streak(&summary.participants, &newest_first, target.as_deref());
        if streak >= MAX_AGENT_TURNS {
            let place = target.as_deref().unwrap_or("top level");
            (self.log)(&format!(
                "{conversation}: Chiefs paused ({streak} agent messages in thread {place} since a person wrote there); {} stays quiet",
                message.id
            ));
            return false;
        }
        true
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

/// [`labelled`] with the author's kind and name (local side conversations,
/// where people and other Chiefs write):
/// `[in conv <id> "<title>" from your owner|person|Chief|agent "<name>"]`. The name is
/// cleaned as the title is; the kind comes from the participant record, so a
/// Chief named like a person still reads as a Chief.
/// The owner's own messages (its local identity or a paired device of it)
/// say `from your owner "<name>"`: in a shared conversation the Chief must tell
/// its owner from everyone else (CHIEF-DONE B3: the owner's requests run,
/// anyone else's keep the approval rule).
fn labelled_from(summary: &Summary, author: &str, text: &str, owner: &str) -> String {
    let participant = summary.participants.iter().find(|p| p.id == author);
    let name = clean_label(participant.map_or(author, |p| p.display_name.as_str()));
    let human = participant.is_some_and(|p| p.kind == cmux_conversation::ParticipantKind::Human);
    let kind = if cmux_chief::rules::is_chief(summary, author) {
        "Chief"
    } else if human
        && participant.is_some_and(|p| p.id == owner || p.person.as_deref() == Some(owner))
    {
        "your owner"
    } else if human {
        "person"
    } else {
        "agent"
    };
    let base = labelled(summary, "");
    let head = base.trim_end().trim_end_matches(']');
    format!("{head} from {kind} \"{name}\"] {text}")
}

/// Longest title (characters) in a side message's label.
const LABEL_TITLE_CHARS: usize = 80;

/// A side message's text as the turn and the log see it: a fixed label with
/// the conversation id and its title in quotes, then the person's words.
/// The title is users' text that the model reads, so it loses newlines and
/// other control characters, brackets and quotes, and is cut to
/// `LABEL_TITLE_CHARS`: it cannot end the label or fake a line.
fn labelled(summary: &Summary, text: &str) -> String {
    let title = clean_label(&summary.title);
    format!("[in conv {} \"{title}\"] {text}", summary.id)
}

/// Users' text in a label: no newlines or other control characters, no
/// brackets or quotes, at most `LABEL_TITLE_CHARS`.
fn clean_label(text: &str) -> String {
    let cleaned: String = text
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .filter(|c| !matches!(c, '[' | ']' | '"'))
        .collect();
    cleaned
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(LABEL_TITLE_CHARS)
        .collect()
}

#[cfg(test)]
mod owner_label_tests {
    use super::labelled_from;
    use cmux_conversation::Summary;
    use serde_json::json;

    fn summary() -> Summary {
        serde_json::from_value(json!({
            "id": "conv_launch", "owner": "local", "title": "Launch", "rev": 1, "last_seq": 0, "read_cursors": {},
            "created_at": "2026-10-26T00:00:00Z", "updated_at": "2026-10-26T00:00:00Z",
            "participants": [
                {"id": "user_local", "kind": "human", "display_name": "Lawrence"},
                {"id": "remote_ins1", "kind": "human", "display_name": "Lawrence iPhone", "person": "user_local"},
                {"id": "user_leo", "kind": "human", "display_name": "Leo"},
                {"id": "agent_leo", "kind": "agent", "agent_class": "mux", "display_name": "Leo's Chief"}
            ]
        }))
        .unwrap()
    }

    #[test]
    fn the_owner_and_its_devices_read_as_your_owner_and_nobody_else_does() {
        let s = summary();
        assert_eq!(
            labelled_from(&s, "user_local", "ship it", "user_local"),
            "[in conv conv_launch \"Launch\" from your owner \"Lawrence\"] ship it"
        );
        assert!(
            labelled_from(&s, "remote_ins1", "ship it", "user_local")
                .contains("from your owner \"Lawrence iPhone\"")
        );
        assert!(
            labelled_from(&s, "user_leo", "ship it", "user_local").contains("from person \"Leo\"")
        );
        assert!(
            labelled_from(&s, "agent_leo", "done", "user_local")
                .contains("from Chief \"Leo's Chief\"")
        );
    }
}
