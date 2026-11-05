//! Share Screen with Chief (`screen_share.rs`): at each turn start the
//! screen inbox becomes quiet notes (one per `PER_NOTE` frames, in one
//! append), so the turn's delta carries what the person's screen showed since
//! the last turn. Never a wake by itself.

use super::Brain;

impl Brain {
    /// Logs the screen inbox as notes (each keyed by its entry names, so a
    /// retried append logs it once) and empties the inbox. A failed append
    /// leaves the entries for the next turn.
    pub(super) fn ingest_screen_share(&mut self) {
        let Some(screen) = self.settings.screen_share.clone() else {
            return;
        };
        let Some(taken) = crate::screen_share::take(&screen) else {
            return;
        };
        let entries: Vec<optchat_host::NewMessage> = taken
            .notes
            .iter()
            .map(|note| optchat_host::NewMessage {
                key: Some(note.key.clone()),
                ..optchat_host::NewMessage::new(optchat_core::Kind::Note, &note.text)
            })
            .collect();
        if !entries.is_empty()
            && let Err(e) = self.chat.append_with(&entries, |_| Vec::new())
        {
            (self.log)(&format!("logging the screen share notes failed: {e}"));
            return;
        }
        crate::screen_share::consume(&taken);
    }
}
