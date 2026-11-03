//! The outcome ledger: every finished subagent's outcome reaches the person
//! (Lawrence 2026-10-28: "i'm still worried about chief's tenacity/persistence,
//! in acting on + following up with literally every single action i say").
//! Oct 20-27, 32% of the subagents of Lawrence's Chief finished with no Chief
//! post naming them in the hour after.
//!
//! A subagent joins `HostState::untold` when its final report is delivered
//! (not one the person stopped) and leaves when a Chief post names it (`a12`,
//! as a word; a subagent link carries the id too). A turn that saw the report
//! and ended without naming it leaves a check; when it is due and no turn
//! runs, one retry turn starts on an `[untold]` note that names it. After that
//! it is dropped and logged: the host never posts on the Chief's behalf ("no
//! fake messages"), and a Chief that still says nothing gets no loop. A
//! subagent Chief sends back to work (tell, restart, resume) leaves too: its
//! next report is the one to tell.

use std::time::{Duration, Instant};

use cmux_conversation::{Op, Part};

use super::{Brain, Phase, Source, now_ms};
use crate::state::Untold;

/// The first word of an outcome retry turn's note.
pub const UNTOLD_TAG: &str = "[untold]";

/// The wait after the turn that saw a report ended, before the check: a
/// batching window, so subagents that finish close together are told in one
/// digest turn, not one forced turn each (Leo, 2026-11-02: 22 `[untold]`
/// turns in four days, one per report). Each later turn end moves every
/// pending check to its own window, up to [`UNTOLD_MAX_HOLD`] after the
/// subagent finished.
pub const UNTOLD_WAIT: Duration = Duration::from_secs(120);

/// The longest an outcome waits for its batch, from when it finished.
pub const UNTOLD_MAX_HOLD: Duration = Duration::from_secs(600);

/// Retry turns per subagent before it is dropped.
pub const MAX_UNTOLD_TRIES: u32 = 1;

impl Brain {
    /// The finished subagents whose outcome no Chief post told yet.
    pub fn untold_outcomes(&self) -> Vec<String> {
        self.state.untold.iter().map(|u| u.id.clone()).collect()
    }

    /// Subagent `id`'s final report was delivered: its outcome waits to be told.
    pub(super) fn note_finished(&mut self, id: &str) {
        if self.state.untold.iter().any(|u| u.id == id) {
            return;
        }
        self.state.untold.push(Untold {
            id: id.to_owned(),
            since_ms: now_ms(),
            ..Untold::default()
        });
        self.save();
    }

    /// Chief sent subagent `id` back to work (a tell, restart or resume): it
    /// runs again, and its next report is the one to tell, so this one asks
    /// for no post (persona replay, Oct 28: "this ping is noise").
    pub(super) fn outcome_resumed(&mut self, id: &str) {
        let before = self.state.untold.len();
        self.state.untold.retain(|u| u.id != id);
        if self.state.untold.len() != before {
            self.save();
        }
    }

    /// The owner took Chief post `op`: every subagent it names is told.
    pub(super) fn outcome_posted(&mut self, op: &Op) {
        if self.state.untold.is_empty() {
            return;
        }
        let Op::MessageSend { parts, .. } = op else {
            return;
        };
        let text: String = parts
            .iter()
            .filter_map(|p| match p {
                Part::Text { text, .. } => Some(text.as_str()),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join("\n");
        let before = self.state.untold.len();
        self.state.untold.retain(|u| !names(&text, &u.id));
        if self.state.untold.len() != before {
            self.save();
        }
    }

    /// Whether subagent `id`'s report still waits in the queue, unseen.
    fn report_queued(&self, id: &str) -> bool {
        self.queue
            .iter()
            .any(|q| matches!(&q.source, Source::Spawn(r) if r.subs.iter().any(|(s, _)| s == id)))
    }

    /// A turn ended: each untold subagent whose report it saw gets a check,
    /// and every pending check moves to the same batching window.
    pub(super) fn schedule_outcome_checks(&mut self) {
        if self.state.untold.is_empty() {
            return;
        }
        let now = now_ms();
        let seen: Vec<bool> = self
            .state
            .untold
            .iter()
            .map(|u| !self.report_queued(&u.id))
            .collect();
        for (u, seen) in self.state.untold.iter_mut().zip(seen) {
            if seen || u.due_ms.is_some() {
                u.due_ms = Some(batched_due(u.since_ms, now));
            }
        }
        self.save();
    }

    /// When the next outcome check is due, on the brain's clock.
    pub(super) fn next_outcome_due(&self) -> Option<Instant> {
        let at = self.state.untold.iter().filter_map(|u| u.due_ms).min()?;
        Some(Instant::now() + Duration::from_millis(at.saturating_sub(now_ms())))
    }

    /// Runs every outcome check due at `now` (ms since the epoch): a running
    /// turn moves it later; else one retry turn names the due subagents, and
    /// those already retried are dropped.
    pub fn fire_outcome_checks_at(&mut self, now: u64) {
        if !self
            .state
            .untold
            .iter()
            .any(|u| u.due_ms.is_some_and(|d| d <= now))
        {
            return;
        }
        if self.phase != Phase::Idle || self.resume_at.is_some() {
            let later = now + UNTOLD_WAIT.as_millis() as u64;
            for u in self.state.untold.iter_mut() {
                if u.due_ms.is_some_and(|d| d <= now) {
                    u.due_ms = Some(later);
                }
            }
            self.save();
            return;
        }
        let mut retry: Vec<String> = Vec::new();
        let mut dropped: Vec<String> = Vec::new();
        for u in self.state.untold.iter_mut() {
            if u.due_ms.is_none_or(|d| d > now) {
                continue;
            }
            if u.tries >= MAX_UNTOLD_TRIES {
                dropped.push(u.id.clone());
                continue;
            }
            u.tries += 1;
            // Checked again once the retry turn ends.
            u.due_ms = None;
            retry.push(u.id.clone());
        }
        self.state.untold.retain(|u| !dropped.contains(&u.id));
        if !dropped.is_empty() {
            (self.log)(&format!(
                "outcome never told after a retry: {}",
                dropped.join(", ")
            ));
        }
        if !retry.is_empty() {
            (self.log)(&format!(
                "outcome not told yet: {}; starting a retry turn",
                retry.join(", ")
            ));
            self.queue
                .retain(|q| !(matches!(q.source, Source::Note) && q.text.starts_with(UNTOLD_TAG)));
            self.save();
            self.queue(untold_note(&retry), Source::Note);
        } else {
            self.save();
        }
    }
}

/// Whether `text` names subagent `id` as a word (`a1` is not in `a12`).
fn names(text: &str, id: &str) -> bool {
    let word = |c: Option<char>| c.is_some_and(|c| c.is_alphanumeric() || c == '_');
    text.match_indices(id).any(|(at, _)| {
        !word(text[..at].chars().next_back()) && !word(text[at + id.len()..].chars().next())
    })
}

/// When the check of an outcome that finished at `since_ms` is due, for a
/// turn that ended at `now`: one window later, but no later than
/// [`UNTOLD_MAX_HOLD`] after it finished (and never before `now`).
pub fn batched_due(since_ms: u64, now: u64) -> u64 {
    let window = now + UNTOLD_WAIT.as_millis() as u64;
    let cap = since_ms.saturating_add(UNTOLD_MAX_HOLD.as_millis() as u64);
    window.min(cap).max(now)
}

/// The retry turn's note.
fn untold_note(ids: &[String]) -> String {
    format!(
        "{UNTOLD_TAG} These subagents finished and the person has not been told their outcome: {}.\n\
         Tell the person now in one message, one line each, naming each id: what changed and its \
         link, what is still open, and what you do about it (follow up, restart, or done). If one \
         needs nothing from them, still say its result in that one line.",
        ids.join(", ")
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_check_waits_one_window_capped_by_the_max_hold() {
        let w = UNTOLD_WAIT.as_millis() as u64;
        let hold = UNTOLD_MAX_HOLD.as_millis() as u64;
        assert_eq!(batched_due(1_000, 1_000), 1_000 + w);
        // A later turn end moves it, but not past the hold.
        assert_eq!(batched_due(1_000, 1_000 + hold - 10), 1_000 + hold);
        // Past the hold already: due now.
        assert_eq!(batched_due(1_000, 1_000 + hold + 5), 1_000 + hold + 5);
    }
}
