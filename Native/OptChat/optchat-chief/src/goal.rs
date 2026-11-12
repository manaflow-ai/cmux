//! A subagent works under Claude Code's `/goal` until its task is done
//! (user, 2026-11-10: "you should have opus 5.5 set goal/loop so it doesn't
//! stop until it's all done").
//!
//! `/goal <condition>` (Claude Code 2.1.322) adds a session Stop hook: after
//! each would-be stop a separate check reads the conversation and, while the
//! condition does not hold, makes Claude keep working in the same turn. The
//! command also starts a turn whose directive is the condition. So a
//! subagent's start is two prompts: its view and task with "reply `ready`",
//! then `/goal` naming that task as the thing to finish. The second is the
//! prompt the Chief follows; its end is the subagent's report.
//!
//! On by default for a Claude subagent on this Mac; cmux-next.json
//! `chief.subagentGoal: false` turns it off (a codex subagent or one on a
//! peer never gets it: neither runs this Claude Code command).

use serde_json::{Value, json};

/// The cmux-next.json key that turns the goal off (`false`); on when unset.
pub const SETTING: &str = "chief.subagentGoal";

/// The model a Claude subagent runs on when neither the spawn nor the
/// engine names one.
pub const MODEL: &str = "claude-opus-5-5";

/// Claude Code's cap on a goal condition (2.1.322 `Qon`).
pub const CONDITION_LIMIT: usize = 4000;

/// When the subagent may stop: the task is done and landed, or only the
/// user can unblock it, or the Chief told it to stop. The check reads the
/// conversation only, so each case names what the final reply must show.
pub const CONDITION: &str = "The Chief's task in this session's first message is finished. \
Finished means one of: (1) the work is done and landed where the task says \
(pushed to the branch it names, plainly, not on a scratch branch), and the \
final reply gives the landed commit range OLD..NEW and what was verified; \
(2) the task asks for no code change (a question, a review, a check) and \
the final reply answers it in full; (3) the final reply names a blocker \
that only the user can clear (money, legal, a destructive step, \
credentials, a physical action) after everything else was done; or (4) \
the Chief told this session to stop, wait or hand off. Waiting on a build, \
a test run, a fleet machine or CI is not finished: wait for it and go on.";

/// Whether the person left the goal on: `chief.subagentGoal` is not `false`.
pub fn on(user: Option<&Value>) -> bool {
    user.and_then(|d| crate::agent_memory::settings::value(d, SETTING))
        .and_then(|v| v.as_bool())
        .unwrap_or(true)
}

/// The prompt that sets the goal and starts the work.
pub fn command() -> String {
    format!("/goal {CONDITION}")
}

/// The block after the task in the first prompt: wait for the goal.
pub fn hold_block() -> Value {
    json!({
        "type": "text",
        "text": "Do not start yet: reply only `ready`. The next message sets your goal \
                 (/goal) and starts the work on this task.",
    })
}
