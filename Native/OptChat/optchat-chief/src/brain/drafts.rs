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
}
