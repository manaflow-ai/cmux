//! A turn Claude Code runs on its own in the Chief's kept turn session
//! (acpmux `background_turn`: a background task ended, most often a call the
//! steer deadline moved to the background so a person's message is read at
//! once, `steer.rs`). Its answer is the Chief's report of that work, and the
//! person waits for it: the brain folds the bracket when it ends and posts
//! its words, unless the Chief posted with its own `send` there. Before, the
//! answer stayed in the session and the next Chief turn skipped it, so a
//! promised report never came (review of the background move, 2026-11-19).

use super::Brain;
use crate::fold::TurnFold;

impl Brain {
    /// acpmux says a turn Claude Code ran on its own in session `session`
    /// started or ended (`state`).
    pub(super) fn on_background_turn(&mut self, session: &str, state: &str) {
        if state != "ended" {
            return;
        }
        // Only the Chief's own kept turn session: no Chief turn runs in it
        // (a turn takes the kept session when it starts).
        let Some(after) = self
            .kept
            .as_ref()
            .filter(|k| k.kept.session == session)
            .map(|k| k.kept.after)
        else {
            return;
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
        }
        // The next Chief turn in this session folds after it.
        if let Some(k) = self.kept.as_mut() {
            k.kept.after = fold.seq();
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
        (self.log)(&format!(
            "the turn session {session} answered a background task on its own; posting its reply"
        ));
        self.notices
            .push((format!("turn:background:{session}:{after}"), text));
        self.post_notices();
    }
}
