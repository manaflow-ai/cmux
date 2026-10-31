//! Share Screen with Chief (`screen_share.rs`): at each turn start the
//! screen inbox becomes one quiet note, so the turn's delta carries what the
//! person's screen showed since the last turn. Never a wake by itself.

use super::Brain;

impl Brain {
    /// Logs the screen inbox as one note (keyed by its entry names, so a
    /// retried append logs it once) and empties the inbox. A failed append
    /// leaves the entries for the next turn.
    pub(super) fn ingest_screen_share(&mut self) {
        let Some(screen) = self.settings.screen_share.clone() else {
            return;
        };
        let Some(taken) = crate::screen_share::take(&screen) else {
            return;
        };
        if !taken.note.is_empty() {
            let entry = optchat_host::NewMessage {
                key: Some(taken.key.clone()),
                ..optchat_host::NewMessage::new(optchat_core::Kind::Note, &taken.note)
            };
            if let Err(e) = self.chat.append_with(&[entry], |_| Vec::new()) {
                (self.log)(&format!("logging the screen share note failed: {e}"));
                return;
            }
        }
        crate::screen_share::consume(&taken);
    }
}
