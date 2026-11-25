//! The loop guard hold (Lawrence's Chief, 2026-11-21).
//!
//! When the conversation's loop guard refuses the Chief's messages
//! (`agent_budget`: six agent texts since the person last wrote, with another
//! agent in the conversation), nothing the Chief sends posts until the person
//! writes. The host's nags to tell the person (the `stop`/`sleep` refusal for
//! landed work, the `[untold]` retry turn, the `[no text]` note) then only
//! cost turns that post nothing: on Nov 21 every subagent report cost a
//! refused `send`, a refused `stop` and an `[untold]` turn whose sends were
//! refused again, dozens of times.
//!
//! So a refusal with `agent_budget` in the Chief's conversation sets
//! `HostState::budget_hold`. While it holds, `stop` and `sleep` go through,
//! the `[untold]` checks wait (kept, not dropped) and a silent spawn turn's
//! ids wait in `held_spawns` instead of a `[no text]` note (an `[untold]` or
//! `[no text]` note already queued when the hold starts is dropped the same way). The person's next
//! message ends the hold, and its turn carries a `<held-news>` block naming
//! what is owed, so that answer tells it. A Chief message the owner takes
//! ends the hold too (the guard let it through), and the nags come back.
//!
//! The hold also starts before any refusal (Nov 22: a host that started with
//! the guard already closed ran an `[untold]` turn per report until one of its
//! own sends was refused): the host keeps the newest top-level texts of the
//! Chief conversation it read (`guard_rows`) and counts them by the owner's
//! own rule (`cmux_conversation` budget: two or more agents, at most
//! `MAX_AGENT_TURNS` agent texts since a person's text). At the cap, the hold
//! starts.

use std::collections::BTreeMap;

use cmux_conversation::{MAX_AGENT_TURNS, Message, Part, ParticipantKind};

use super::{Brain, Queued, Source};

/// The newest top-level texts `guard_rows` keeps: the cap and a margin.
const GUARD_ROWS_KEPT: usize = 4 * MAX_AGENT_TURNS;

impl Brain {
    /// Whether the loop guard refuses the Chief's messages now.
    pub(super) fn budget_held(&self) -> bool {
        self.state.budget_hold
    }

    /// The owner refused a Chief message in `conversation` for `reason`.
    pub(super) fn note_budget_refusal(&mut self, conversation: &str, reason: &str) {
        if !reason.contains("agent_budget")
            || self.state.conversation.as_deref() != Some(conversation)
        {
            return;
        }
        self.start_budget_hold("the loop guard refuses the Chief's messages");
    }

    /// A message of the Chief conversation was read (live, in a catch-up,
    /// or the owner's answer to the Chief's own send): a top-level text
    /// joins the guard's count, and at the owner's cap the hold starts.
    /// Keyed by seq, so the order messages arrive in does not matter.
    pub(super) fn guard_row(&mut self, message: &Message) {
        if message.thread_root.is_some() || !message.parts.iter().any(Part::counts_as_turn) {
            return;
        }
        let Some(summary) = self.summary.as_ref() else {
            return;
        };
        let kind = summary
            .participants
            .iter()
            .find(|p| p.id == message.author)
            .map(|p| p.kind);
        let agents = summary
            .participants
            .iter()
            .filter(|p| p.kind == ParticipantKind::Agent)
            .count();
        // Only a person's or an agent's text counts (as the owner's rule).
        let Some(kind @ (ParticipantKind::Human | ParticipantKind::Agent)) = kind else {
            return;
        };
        let person = kind == ParticipantKind::Human;
        self.guard_rows.insert(message.seq, person);
        while self.guard_rows.len() > GUARD_ROWS_KEPT {
            self.guard_rows.pop_first();
        }
        // The owner's cap applies only where two or more agents could loop.
        let streak = guard_streak(&self.guard_rows);
        if agents >= 2 && streak >= MAX_AGENT_TURNS {
            self.start_budget_hold(&format!(
                "the loop guard is at its cap ({streak} agent messages since the person wrote)"
            ));
        }
    }

    /// Starts the hold (a noop while it holds), for `why`.
    fn start_budget_hold(&mut self, why: &str) {
        if self.state.budget_hold {
            return;
        }
        self.state.budget_hold = true;
        // An `[untold]` retry turn still queued could post nothing either:
        // its subagents stay in `untold`, for the person's next turn.
        self.queue.retain(|q| {
            !(matches!(q.source, Source::Note) && q.text.starts_with(super::UNTOLD_TAG))
        });
        // A `[no text]` note still queued (the turn's send waited in the
        // outbox and was refused after it ended): its ids wait the same way.
        let mut held = Vec::new();
        self.queue.retain(|q| {
            let ids = matches!(q.source, Source::Note)
                .then(|| super::spawn_text::no_text_ids(&q.text))
                .flatten();
            let keep = ids.is_none();
            held.extend(ids.into_iter().flatten());
            keep
        });
        for id in held {
            if !self.state.held_spawns.contains(&id) {
                self.state.held_spawns.push(id);
            }
        }
        self.save();
        (self.log)(&format!(
            "{why}: untold and no-text notes wait for the person's next message"
        ));
    }

    /// The owner took a Chief message in `conversation`: the guard lets
    /// messages through again.
    pub(super) fn note_budget_open(&mut self, conversation: &str) {
        if !self.state.budget_hold || self.state.conversation.as_deref() != Some(conversation) {
            return;
        }
        self.state.budget_hold = false;
        self.save();
        (self.log)("the loop guard took a Chief message again: the hold ended");
    }

    /// A silent spawn turn under the hold: its ids wait for the person.
    pub(super) fn hold_spawns(&mut self, ids: Vec<String>) {
        for id in ids {
            if !self.state.held_spawns.contains(&id) {
                self.state.held_spawns.push(id);
            }
        }
        self.save();
    }

    /// A turn starts on `items` of conversation `side` (None: the Chief's
    /// own). When the person wrote there, the hold ends, and what it kept
    /// from being told comes back as the turn's `<held-news>` block.
    pub(super) fn end_budget_hold(
        &mut self,
        side: Option<&str>,
        items: &[Queued],
    ) -> Option<String> {
        let person = side.is_none()
            && items
                .iter()
                .any(|q| matches!(q.source, Source::Message { .. }));
        if !person || (!self.state.budget_hold && self.state.held_spawns.is_empty()) {
            return None;
        }
        let was_held = std::mem::take(&mut self.state.budget_hold);
        let spawns = std::mem::take(&mut self.state.held_spawns);
        self.save();
        let untold: Vec<String> = if was_held {
            self.state.untold.iter().map(|u| u.id.clone()).collect()
        } else {
            Vec::new()
        };
        held_news(&untold, &spawns)
    }
}

/// The `<held-news>` block, or None when nothing is owed.
pub fn held_news(untold: &[String], spawns: &[String]) -> Option<String> {
    if untold.is_empty() && spawns.is_empty() {
        return None;
    }
    let mut lines = vec![
        "<held-news>".to_owned(),
        "The loop guard refused your messages until the person wrote this one, so they saw nothing you sent since. Put what is owed in this answer, one line each, naming each id:".to_owned(),
    ];
    if !untold.is_empty() {
        lines.push(format!(
            "- finished, outcome not told yet: {} (what changed and its link, what is still open)",
            untold.join(", ")
        ));
    }
    if !spawns.is_empty() {
        lines.push(format!(
            "- started with no words to the person: {} (what each works on)",
            spawns.join(", ")
        ));
    }
    lines.push("</held-news>".to_owned());
    Some(lines.join("\n"))
}

/// Agent texts after the newest person's text in `rows` (seq to whether a
/// person wrote it): the owner's `thread_agent_streak` over what was read.
fn guard_streak(rows: &BTreeMap<u64, bool>) -> usize {
    rows.values().rev().take_while(|person| !**person).count()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_streak_counts_agent_texts_after_the_newest_person_text() {
        let rows: BTreeMap<u64, bool> = [(1, false), (2, true), (3, false), (5, false)]
            .into_iter()
            .collect();
        assert_eq!(guard_streak(&rows), 2);
        assert_eq!(guard_streak(&BTreeMap::new()), 0);
    }
}
