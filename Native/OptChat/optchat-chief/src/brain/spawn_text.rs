//! A turn that starts subagents says so in words (user 2026-11-05, msg
//! 22013: "llm behavior needs to respond with text alongside those chips").
//! Home draws each subagent as a pill beside the Chief's words of the turn
//! that started it; a turn that started some and posted no text (no reply, no
//! `send`, no `reply`) left the person with chips alone. Its end has the host
//! post `[a1] started: TITLE` itself (Lucas's latency plan, item 3: no Chief
//! turn spent on the relay). Only when that post cannot go out (no
//! conversation, or the owner refused it) does one `[no text]` note queue a
//! next turn that writes the words; that turn is not nudged again, so a
//! silent Chief never loops.

use super::Brain;

/// The first word of the note a silent spawn turn leaves.
pub const NO_TEXT_TAG: &str = "[no text]";

impl Brain {
    /// The running turn started subagents `ids`.
    pub(super) fn spawned_in_turn(&mut self, ids: &[String]) {
        if self.state.turn.is_some() {
            self.turn_spawned.extend(ids.iter().cloned());
        }
    }

    /// The running turn posted words of its own (`send`, `reply`).
    pub(super) fn said_in_turn(&mut self) {
        self.turn_said = true;
    }

    /// Turn `key` ended; `said` is whether its final text posts and `quiet`
    /// whether it was stopped or never started (it posts nothing by design).
    /// A turn that started subagents and said nothing queues the note.
    pub(super) fn check_spawn_words(&mut self, key: &str, said: bool, quiet: bool) {
        let spawned = std::mem::take(&mut self.turn_spawned);
        let said = std::mem::take(&mut self.turn_said) || said;
        let nudged = std::mem::take(&mut self.spawn_text_nudged);
        if spawned.is_empty() || said || quiet || nudged {
            return;
        }
        // The loop guard refuses every send: a note turn could post nothing.
        // The ids wait for the person's next turn (budget_hold.rs).
        if self.budget_held() {
            (self.log)(&format!(
                "turn {key} started {} and posted no text under the loop guard; held for the person's next message",
                spawned.join(", ")
            ));
            self.hold_spawns(spawned);
            return;
        }
        self.spawn_text_nudged = true;
        let lines = spawned
            .iter()
            .map(|id| {
                let title = self
                    .state
                    .sub(id)
                    .map(|(_, s)| s.title.trim().to_owned())
                    .filter(|title| !title.is_empty())
                    .unwrap_or_else(|| "the requested task".to_owned());
                format!("[{id}] started: {title}")
            })
            .collect::<Vec<_>>()
            .join("\n");
        let key_of = format!(
            "{}{}",
            super::outcome_ledger::HOST_SPAWN_KEY,
            spawned.join(",")
        );
        if self.host_post(key_of, lines, None) {
            (self.log)(&format!(
                "turn {key} started {} and posted no text; host-posting the start",
                spawned.join(", ")
            ));
        } else {
            (self.log)(&format!(
                "turn {key} started {} and posted no text; queuing a {NO_TEXT_TAG} note",
                spawned.join(", ")
            ));
            self.queue(no_text_note(&spawned), super::Source::Note);
        }
    }
}

/// The note's words before and after its ids ([`no_text_note`],
/// [`no_text_ids`] read the same layout).
const NO_TEXT_HEAD: &str = " Your last turn started ";
const NO_TEXT_AFTER_IDS: &str = " and posted no text: the person sees only their chips. \
Post one short message now (send, or your reply) that says in a line each what you started and why. \
Do not start them again.";

/// The note: who was started, and what the next turn must post.
pub fn no_text_note(ids: &[String]) -> String {
    format!(
        "{NO_TEXT_TAG}{NO_TEXT_HEAD}{}{NO_TEXT_AFTER_IDS}",
        ids.join(", ")
    )
}

/// The ids a [`no_text_note`] names; None for any other text.
pub(super) fn no_text_ids(note: &str) -> Option<Vec<String>> {
    let ids = note
        .strip_prefix(NO_TEXT_TAG)?
        .strip_prefix(NO_TEXT_HEAD)?
        .strip_suffix(NO_TEXT_AFTER_IDS)?;
    Some(ids.split(", ").map(str::to_owned).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_note_gives_back_its_ids() {
        let ids = vec!["a1".to_owned(), "a12".to_owned()];
        assert_eq!(no_text_ids(&no_text_note(&ids)), Some(ids));
        assert_eq!(no_text_ids("[untold] a1"), None);
        assert_eq!(no_text_ids("[no text] something else"), None);
    }
}
