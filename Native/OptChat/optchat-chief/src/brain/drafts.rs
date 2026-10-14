//! Drafts of the running turn's reply (parity item 4, `draft.rs`): the
//! turn runner makes them, the brain publishes them to the turn's
//! conversation, and the last one (`done`) after the reply is posted.

use super::Brain;

impl Brain {
    /// A draft of the running turn's reply goes to its conversation.
    pub(super) fn turn_draft(&mut self, draft: &crate::draft::Draft) {
        let Some(conversation) = self
            .state
            .turn
            .as_ref()
            .filter(|t| t.key == draft.turn)
            .and_then(|t| t.conversation.clone())
        else {
            return;
        };
        // A Chief that acts on its own may answer NO_REPLY in a channel:
        // no live text there, only the final draft that clears it.
        if self.settings.membership.acts_on_its_own()
            && !draft.done
            && self.state.conversation.as_deref() != Some(conversation.as_str())
        {
            return;
        }
        self.publish_draft(&conversation, draft);
    }

    /// Publishes a draft; a failure is logged once per process (drafts are
    /// display only, the posted reply is the record).
    pub(super) fn publish_draft(&mut self, conversation: &str, draft: &crate::draft::Draft) {
        let Some(daemon) = self.daemon.as_mut() else {
            return;
        };
        if let Err(e) = daemon.draft(conversation, draft)
            && !self.draft_failed
        {
            self.draft_failed = true;
            (self.log)(&format!(
                "publishing a reply draft failed: {e}; later failures are not logged"
            ));
        }
    }

    /// A change of the running turn's run record goes to its conversation
    /// (`conversation-run-append`). The brain adds what the turn runner does
    /// not know: the run's key as its reply's key, and the messages the reply
    /// answers. A failure is logged once per process (display only).
    pub(super) fn turn_run(&mut self, update: crate::run::RunUpdate) {
        let Some(turn) = self.state.turn.as_ref().filter(|t| t.key == update.turn) else {
            return;
        };
        let Some(conversation) = turn.conversation.clone() else {
            return;
        };
        let mut run = update.run;
        run.insert("id".into(), serde_json::json!(update.turn));
        run.insert("turn".into(), serde_json::json!(update.turn));
        if !turn.answers.is_empty() {
            let answers: Vec<&String> = turn.answers.iter().take(16).collect();
            run.insert("answers".into(), serde_json::json!(answers));
        }
        // A reply to a group message goes into that message's thread
        // (`reply_threads`): the run shows there while it works.
        if let Some((root, _)) = turn.answers.first().and_then(|id| self.reply_threads.get(id)) {
            run.insert("thread_root".into(), serde_json::json!(root));
        }
        let Some(daemon) = self.daemon.as_mut() else {
            return;
        };
        if let Err(e) = daemon.run_append(&conversation, serde_json::Value::Object(run), update.steps)
            && !self.run_failed
        {
            self.run_failed = true;
            (self.log)(&format!(
                "appending to the turn's run failed: {e}; later failures are not logged"
            ));
        }
    }
}
