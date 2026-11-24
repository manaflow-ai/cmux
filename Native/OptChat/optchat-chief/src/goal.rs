//! A subagent works under a goal until its task is done (user, 2026-11-10:
//! "you should have opus 5.5 set goal/loop so it doesn't stop until it's
//! all done").
//!
//! The goal is the hook Claude Code's `/goal <condition>` adds (2.1.325): a
//! Stop hook of type `prompt`, which at each would-be stop asks a model
//! whether the condition holds and, while it does not, makes Claude go on
//! in the same turn. The Chief sets it with the session: acpmux's
//! `stopCondition` (`SessionSpec::stop_condition`) gives Claude Code that
//! hook at every start, a resume or respawn too. So a subagent's start is
//! one prompt, its view and task (with [`note_block`] naming the bar), and
//! its first turn is the work.
//!
//! Until 2026-11-18 the start was two prompts: the view and task with
//! an order to reply only `ready`, then `/goal` (a slash command
//! runs only as a whole message, its condition the rest of that message,
//! so the task could not ride along; sent back to back, acpmux ran the
//! short `/goal` first, a1141). The `ready` turn read the whole context for
//! nothing: 95 starts from Nov 12 to 18, median 65.6k input tokens and
//! 3.5 s each (user, 2026-11-18: "why wasn't it just one prompt?").
//!
//! A Codex subagent gets the same condition: acpmux sets it as Codex's own
//! goal (codex-acp `_session/goal`) beside its first prompt, and Codex starts
//! its next turns itself until it marks the goal complete. Its report waits
//! for a turn end with the goal no longer active
//! (`brain/children.rs` `goal_goes_on`).
//!
//! On by default for a Claude or Codex subagent on this Mac; cmux-next.json
//! `chief.subagentGoal: false` turns it off (one on a peer never gets it:
//! the peer's acpmux may not know `stopCondition`).

use serde_json::{Value, json};

/// The cmux-next.json key that turns the goal off (`false`); on when unset.
pub const SETTING: &str = "chief.subagentGoal";

/// The model a Claude subagent runs on when neither the spawn nor the
/// engine names one.
pub const MODEL: &str = "claude-opus-5-5";

/// Claude Code's cap on a goal condition (2.1.325 `mmn`; acpmux refuses a
/// longer `stopCondition`).
pub const CONDITION_LIMIT: usize = 4000;

/// When the subagent may stop: the task is done and landed, or only the
/// user can unblock it or decide, or the Chief told it to stop. The check
/// reads the conversation only, so each case names what the final reply
/// must show.
///
/// A wait on the user's decision (a look to OK before a push, a Chief order)
/// is a stop, and a repeat of that report is too: without both, a subagent
/// holding for "push it" was sent back by every check and posted one more
/// "still holding" each time (user, 2026-11-23: "it spams too much 'still
/// holding' even though the turn has ended"). acpmux also caps the checks at
/// one re-prompt with no tool call between (`hub/stop_condition.rs`).
pub const CONDITION: &str = "The Chief's task in this session's first message is finished. \
Finished means one of: (1) the work is done and landed where the task says \
(pushed to the branch it names, plainly, not on a scratch branch), and the \
final reply gives the landed commit range OLD..NEW and what was verified; \
(2) the task asks for no code change (a question, a review, a check) and \
the final reply answers it in full; (3) the final reply names a blocker \
that only the user can clear (money, legal, a destructive step, \
credentials, a physical action) after everything else was done; (4) \
the task or the Chief leaves a decision to the user (such as OK of a look \
before a push), everything else is done, and the final reply names that \
decision and the words that answer it; or (5) the Chief told this session \
to stop, wait or hand off. A final reply that repeats an earlier report of \
case 3, 4 or 5 with no tool call since is finished: never ask for it \
again. Waiting on a build, a test run, a fleet machine or CI is not \
finished: wait for it and go on.";

/// Whether the person left the goal on: `chief.subagentGoal` is not `false`.
pub fn on(user: Option<&Value>) -> bool {
    user.and_then(|d| crate::agent_memory::settings::value(d, SETTING))
        .and_then(|v| v.as_bool())
        .unwrap_or(true)
}

/// The marker in a hold prompt's id (`optchat-sub:<id>:task:<ms>`), which
/// a subagent started before the one-prompt start still has in its log.
const HOLD_MARK: &str = ":task:";

/// Whether `prompt_id` is the hold prompt of a subagent started before the
/// one-prompt start: its turn only answered `ready`, so it is never the
/// subagent's report (user 2026-11-12, msg 30563: that `ready` reached the
/// Chief as "[a1145] ready"). No new subagent has one.
pub fn is_hold_prompt(prompt_id: Option<&str>) -> bool {
    prompt_id.is_some_and(|p| {
        p.strip_prefix(crate::subagents::PROMPT_PREFIX)
            .and_then(|p| p.strip_prefix("sub:"))
            .is_some_and(|p| p.contains(HOLD_MARK))
    })
}

/// The block after the task in a goal subagent's one prompt: the bar its
/// session's Stop hook holds it to, so it works toward it from the start.
pub fn note_block() -> Value {
    json!({
        "type": "text",
        "text": format!(
            "You work under a goal: every would-be stop is checked, and you go back to work until this holds. {CONDITION}"
        ),
    })
}
