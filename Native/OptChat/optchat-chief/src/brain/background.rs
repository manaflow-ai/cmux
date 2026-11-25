//! A turn Claude Code runs on its own in a Chief turn session (acpmux
//! `background_turn`: a background task ended, most often a call the steer
//! deadline moved to the background so a person's message is read at once,
//! `steer.rs`). Its answer is the Chief's report of that work, and the person
//! waits for it: the brain folds the bracket when it ends and posts its
//! words in the conversation the turn answered, unless the Chief posted with
//! its own `send` there. Before, the answer stayed in the session and the
//! next Chief turn skipped it, so a promised report never came (review of the
//! background move, 2026-11-19).
//!
//! Sessions followed: the kept turn session, and a turn session that runs
//! moved work but is not kept (`Draining`): it is not ended until its
//! background turn ends, then it is.

use super::Brain;
use crate::fold::TurnFold;

/// A turn session that is not kept but still runs work its turn moved to
/// the background: followed until that work's background turn ends.
#[derive(Clone, Debug)]
pub(super) struct Draining {
    pub session: String,
    /// The last event its turn folded.
    pub after: u64,
    pub conversation: Option<String>,
}

impl Brain {
    /// acpmux says a turn Claude Code ran on its own in session `session`
    /// started or ended (`state`).
    pub(super) fn on_background_turn(&mut self, session: &str, state: &str) {
        if state != "ended" {
            return;
        }
        let kept = self
            .kept
            .as_ref()
            .filter(|k| k.kept.session == session)
            .map(|k| (k.kept.after, k.conversation.clone()));
        let draining = self.draining.iter().position(|d| d.session == session);
        let (after, conversation) = match (kept, draining) {
            (Some(k), _) => k,
            (None, Some(i)) => (
                self.draining[i].after,
                self.draining[i].conversation.clone(),
            ),
            (None, None) => return,
        };
        let events = match self.agents.events(session, after) {
            Ok(events) => events,
            Err(e) => {
                (self.log)(&format!("reading the turn session's background turn: {e}"));
                return;
            }
        };
        let mut fold = TurnFold::following(after);
        for event in &events {
            fold.apply(event);
            if fold.ended().is_some() {
                break;
            }
        }
        // Only a bracket that ended: one still open is the next event's.
        if fold.ended().is_none() {
            return;
        }
        let end = fold.seq();
        if let Some(k) = self.kept.as_mut().filter(|k| k.kept.session == session) {
            k.kept.after = end;
            k.moved = false;
        }
        if let Some(i) = draining {
            let d = self.draining.remove(i);
            if let Err(e) = self.agents.end_session(&d.session) {
                (self.log)(&format!("ending turn session {}: {e}", d.session));
            }
        }
        let text = fold.final_text().unwrap_or_default();
        let posted = fold.posted_itself();
        if self.trace.is_on() {
            self.trace.emit(
                "background.reply",
                serde_json::json!({"session": session, "after": after, "posted_itself": posted,
                                   "reply": self.trace.text(&text)}),
            );
        }
        if posted || text.trim().is_empty() || text.trim() == "NO_REPLY" {
            return;
        }
        let Some(conversation) = conversation.or_else(|| self.state.conversation.clone()) else {
            return;
        };
        (self.log)(&format!(
            "the turn session {session} answered a background task on its own; posting its reply"
        ));
        // A turn reply's key form (`turn:optchat:`): the transcript, the
        // reply ledger and the outbox know it as the Chief's own words.
        let key = format!("turn:optchat:background:{session}:{after}");
        self.state
            .outbox
            .push(super::reply_entry(conversation, &key, &text));
        self.save();
        self.flush_outbox();
    }

    /// acpmux is connected again: its new link has no event of the sessions
    /// the old one followed, so read each followed session once for a
    /// background turn that ended meanwhile.
    pub(super) fn catch_up_background(&mut self) {
        let mut sessions: Vec<String> = self.draining.iter().map(|d| d.session.clone()).collect();
        if let Some(k) = self.kept.as_ref() {
            sessions.push(k.kept.session.clone());
        }
        for session in sessions {
            self.on_background_turn(&session, "ended");
        }
    }
}
