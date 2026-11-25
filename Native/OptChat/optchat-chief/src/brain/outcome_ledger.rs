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
//! runs, one retry turn starts on an `[untold]` note that names it. An
//! unambiguous result is posted by the host, while a report needing Chief
//! judgment keeps the `[untold]` model turn. A Chief that still says nothing
//! gets no loop. A
//! subagent Chief sends back to work (tell, restart, resume) leaves too: its
//! next report is the one to tell.

use std::time::{Duration, Instant};

use cmux_conversation::{Op, Part};
use optchat_core::Kind;

use super::{Brain, Phase, Source, now_ms};
use crate::state::{SubStatus, Untold};

/// The first word of an outcome retry turn's note.
pub const UNTOLD_TAG: &str = "[untold]";

/// Idempotency prefixes for host-authored chat messages. They are distinct
/// from Chief `send`/turn keys so a host post never answers a person's
/// pending message or counts as a model turn.
pub const HOST_OUTCOME_KEY: &str = "host-outcome:";
pub const HOST_SPAWN_KEY: &str = "host-spawn:";

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
    pub(super) fn note_finished(&mut self, id: &str, report: &str, policy: Option<&str>) {
        if self.state.untold.iter().any(|u| u.id == id) {
            return;
        }
        self.state.untold.push(Untold {
            id: id.to_owned(),
            since_ms: now_ms(),
            requires_chief: outcome_requires_chief(report, policy),
            ..Untold::default()
        });
        self.save();
    }

    /// Chief sent subagent `id` back to work (a tell, restart or resume): it
    /// runs again, and its next report is the one to tell, so this one asks
    /// for no post (persona replay, Oct 28: "this ping is noise").
    pub(super) fn outcome_resumed(&mut self, id: &str) {
        // Nor does the running turn owe it now (landed_told.rs).
        self.turn_landed.retain(|(i, _)| i != id);
        let was_told = self.state.sub(id).is_some_and(|(_, sub)| sub.told_ms != 0);
        if let Some(sub) = self.state.sub_mut(id) {
            sub.told_ms = 0;
        }
        let before = self.state.untold.len();
        self.state.untold.retain(|u| u.id != id);
        if was_told || self.state.untold.len() != before {
            self.save();
        }
    }

    /// The owner took Chief post `op`: every subagent it names is told.
    pub(super) fn outcome_posted(&mut self, op: &Op) {
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
        let host_outcome = self
            .state
            .untold
            .iter()
            .find(|u| u.posted_key.as_deref() == Some(client_key(op)))
            .map(|u| u.id.clone());
        let host_spawn = client_key(op).starts_with(HOST_SPAWN_KEY);
        // Every open subagent it names was told now (`<open-items>`).
        let now = self.now();
        let mut told = false;
        for sub in self
            .state
            .spawns
            .values_mut()
            .flat_map(|r| r.subs.iter_mut())
        {
            let open = sub.at_work()
                || sub.waiting()
                || matches!(sub.status, SubStatus::Done | SubStatus::Reported);
            if open && names(&text, &sub.id) {
                sub.told_ms = now;
                told = true;
            }
        }
        let host_spawn_note =
            host_spawn.then_some("host posted the subagent start; it is in the Chief log");
        if self.state.untold.is_empty() {
            if told {
                self.save();
            }
            if let Some(note) = host_spawn_note
                && let Err(e) = self.chat.append(Kind::Note, note)
            {
                (self.log)(&format!("logging host subagent start failed: {e}"));
            }
            return;
        }
        let before = self.state.untold.len();
        self.state
            .untold
            .retain(|u| host_outcome.as_deref() != Some(u.id.as_str()) && !names(&text, &u.id));
        if self.state.untold.len() != before {
            if let Some(id) = host_outcome {
                let note = format!("host posted subagent {id}'s result; it is in the Chief log");
                if let Err(e) = self.chat.append(Kind::Note, &note) {
                    (self.log)(&format!("logging host outcome {id} failed: {e}"));
                }
            }
            if let Some(note) = host_spawn_note
                && let Err(e) = self.chat.append(Kind::Note, note)
            {
                (self.log)(&format!("logging host subagent start failed: {e}"));
            }
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
        // Under the loop guard no check is due: the person's next turn
        // carries the outcomes (budget_hold.rs).
        if self.state.untold.is_empty() || self.budget_held() {
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
        // The loop guard refuses every send: a retry turn could post nothing.
        // The outcomes wait, kept and not retried, for the person's next
        // message, whose turn names them (budget_hold.rs).
        if self.budget_held() {
            for u in self.state.untold.iter_mut() {
                if u.due_ms.is_some_and(|d| d <= now) {
                    u.due_ms = None;
                }
            }
            self.save();
            (self.log)("outcome checks wait: the loop guard refuses the Chief's messages");
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
        let mut post: Vec<String> = Vec::new();
        let mut dropped: Vec<String> = Vec::new();
        for u in self.state.untold.iter_mut() {
            if u.due_ms.is_none_or(|d| d > now) {
                continue;
            }
            if u.posted_key.is_some() {
                continue;
            }
            if !u.requires_chief {
                u.due_ms = None;
                post.push(u.id.clone());
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
        for id in post {
            self.post_due_outcome(&id);
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

    /// Posts a host-authored message into the Chief conversation. The outbox
    /// is durable, and the key is saved on the matching outcome before the
    /// daemon is flushed, so a restart cannot lose or duplicate the post.
    /// False when it was not posted, or the owner already refused it.
    pub(super) fn host_post(
        &mut self,
        key: String,
        text: String,
        outcome_id: Option<&str>,
    ) -> bool {
        let Some(conversation) = self.state.conversation.clone() else {
            if let Some(id) = outcome_id
                && let Some(u) = self.state.untold.iter_mut().find(|u| u.id == id)
            {
                u.requires_chief = true;
                u.due_ms = Some(now_ms());
                self.save();
            }
            return false;
        };
        if let Some(id) = outcome_id {
            // The loop guard refuses the Chief's posts: a held outcome stays
            // untold for the person's next message (budget_hold.rs).
            if self.budget_held() {
                return false;
            }
            let Some(u) = self.state.untold.iter_mut().find(|u| u.id == id) else {
                return false;
            };
            if u.posted_key.is_some() {
                return false;
            }
            u.posted_key = Some(key.clone());
        }
        self.state.outbox.push(super::answer_entry(
            conversation,
            &key,
            &text,
            Vec::new(),
            Vec::new(),
        ));
        self.save();
        self.flush_outbox();
        // A refusal the flush already met (host_post_refused) cleared the
        // key: the outcome is the Chief's again, so the caller keeps its turn.
        outcome_id.is_none_or(|id| {
            self.state
                .untold
                .iter()
                .find(|u| u.id == id)
                .is_none_or(|u| u.posted_key.is_some())
        })
    }

    /// A host-authored post was refused. Keep the report and wake the Chief
    /// so it can decide how to recover, rather than silently dropping it.
    pub(super) fn host_post_refused(&mut self, key: &str) -> bool {
        let Some(id) = key.strip_prefix(HOST_OUTCOME_KEY) else {
            return false;
        };
        let Some(u) = self.state.untold.iter_mut().find(|u| u.id == id) else {
            return false;
        };
        u.posted_key = None;
        u.requires_chief = true;
        // Under the loop guard a retry turn could post nothing: the outcome
        // waits for the person's next message (budget_hold.rs).
        if self.state.budget_hold {
            u.due_ms = None;
            self.save();
            return true;
        }
        u.due_ms = Some(now_ms());
        self.save();
        self.queue(untold_note(&[id.to_owned()]), Source::Note);
        true
    }

    /// A no-text spawn post was refused. Reuse the old note as a recovery
    /// path, but only after the host message itself failed.
    pub(super) fn host_spawn_refused(&mut self, key: &str) -> bool {
        let Some(ids) = key.strip_prefix(HOST_SPAWN_KEY) else {
            return false;
        };
        let ids: Vec<String> = ids.split(',').map(str::to_owned).collect();
        if ids.is_empty() || ids.iter().any(String::is_empty) {
            return false;
        }
        if self.budget_held() {
            self.hold_spawns(ids);
        } else {
            self.queue(crate::brain::spawn_text::no_text_note(&ids), Source::Note);
        }
        true
    }

    /// Host-post an ordinary finished result once its batching window is due.
    pub(super) fn post_due_outcome(&mut self, id: &str) -> bool {
        let Some((report, ws_id)) = self
            .state
            .sub(id)
            .map(|(_, s)| (s.report.clone().unwrap_or_default(), s.ws_id.clone()))
        else {
            return false;
        };
        if self
            .state
            .untold
            .iter()
            .find(|u| u.id == id)
            .and_then(|u| u.posted_key.as_ref())
            .is_some()
        {
            return false;
        }
        let key = format!("{HOST_OUTCOME_KEY}{id}");
        let mut text = format!("[{id}] {report}\n{}", crate::agent_chat::footer(id));
        if self.chief.show_after_report
            && let Some(block) = crate::show::block_in(&report, ws_id.as_deref())
        {
            text.push('\n');
            text.push_str(&block);
        }
        self.host_post(key, text, Some(id))
    }
}

/// Reports that still need the Chief's judgment keep the model turn. The
/// host can relay a completed, non-error result, while ask-floor work, a
/// harness failure, an open question, or an explicit decision request stays
/// in the existing `[untold]` path.
pub fn outcome_requires_chief(report: &str, policy: Option<&str>) -> bool {
    policy == Some(crate::approval::ASK)
        || crate::auto_resume::error_line(report).is_some()
        // A host-written report ("(turn failed: ...)", "(did not start:
        // ...)", "(failed: ...)") is a failure, never a mechanical result.
        || report.trim_start().starts_with('(')
        || !crate::check_in::report_is_final(report)
        || report.to_ascii_lowercase().contains("approval")
        || report.to_ascii_lowercase().contains("decision")
}

fn client_key(op: &Op) -> &str {
    match op {
        Op::MessageSend { client_msg_id, .. } => client_msg_id,
        _ => "",
    }
}

/// Whether `text` names subagent `id` as a word (`a1` is not in `a12`).
pub(super) fn names(text: &str, id: &str) -> bool {
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

    #[test]
    fn final_report_can_use_a_host_post() {
        assert!(!outcome_requires_chief(
            "Implemented and verified in PR #42.",
            None
        ));
    }

    #[test]
    fn judgment_reports_keep_the_model_turn() {
        assert!(outcome_requires_chief(
            "The harness failed: API Error: timeout",
            None
        ));
        assert!(outcome_requires_chief("Should I restart the worker?", None));
        assert!(outcome_requires_chief(
            "(turn failed: You've hit your weekly limit)",
            None
        ));
        assert!(outcome_requires_chief(
            "The change is ready for approval.",
            None
        ));
        assert!(outcome_requires_chief(
            "Completed the requested work.",
            Some(crate::approval::ASK)
        ));
    }
}
