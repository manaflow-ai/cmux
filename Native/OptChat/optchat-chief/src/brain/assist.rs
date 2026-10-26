//! The brain's side of the Chief as a personal assistant (assistant.rs,
//! #25576): learned preferences in each turn's tail, a wake for a promise
//! made with none, and one `[decide]` note for a reply that ends by handing
//! a decision back.

use super::{Brain, Source, now_ms};
use crate::assistant;
use crate::state::Wake;

impl Brain {
    /// The tail line naming the preferences `remember` kept since the
    /// system text was made; None when there are none or no profile. One
    /// small file read per turn.
    pub(super) fn learned_line(&self) -> Option<String> {
        let path = self.settings.person.as_ref()?;
        let profile = std::fs::read_to_string(path).ok()?;
        assistant::learned_note(&assistant::learned_since(
            &profile,
            &self.settings.system_text,
        ))
    }

    /// The running turn posted `text` (send, reply).
    pub(super) fn note_said(&mut self, text: Option<&str>) {
        if let Some(text) = text.map(str::trim).filter(|t| !t.is_empty()) {
            self.turn_said.push(text.to_owned());
        }
    }

    /// A turn of the Chief conversation ended with final text `last` (empty:
    /// none posted). A promise to come back with no wake and no subagent at
    /// work gets a wake; a last post that ends with an offer gets a
    /// `[decide]` note, which starts the next turn. Neither for a turn that
    /// answers such a nudge, nor for one that carried another person's text.
    pub(super) fn follow_through(&mut self, last: &str) {
        let mut said = std::mem::take(&mut self.turn_said);
        if !last.trim().is_empty() {
            said.push(last.trim().to_owned());
        }
        let slept = std::mem::take(&mut self.turn_slept);
        let nudged = std::mem::take(&mut self.turn_nudged);
        if said.is_empty() || nudged || self.last_turn_ask {
            return;
        }
        if !slept
            && self.state.wakes.is_empty()
            && self.at_work_line().is_none()
            && let Some(promise) = said.iter().find_map(|t| assistant::promise(t))
        {
            let now = now_ms();
            self.state.wakes.push(Wake {
                at_ms: now + assistant::PROMISE_WAKE_SECS * 1000,
                asked_ms: now,
                note: assistant::promise_wake_note(&promise),
                until_event: false,
            });
            self.save();
            (self.log)(&format!(
                "the Chief promised \"{promise}\" with no wake: waking it in {} min",
                assistant::PROMISE_WAKE_SECS / 60
            ));
        }
        if let Some(offer) = said.last().and_then(|t| assistant::trailing_offer(t)) {
            (self.log)(&format!(
                "the Chief's reply ended with an offer (\"{offer}\"): a {} note follows",
                assistant::DECIDE_TAG
            ));
            self.queue(assistant::decide_note(&offer), Source::Note);
        }
    }
}
