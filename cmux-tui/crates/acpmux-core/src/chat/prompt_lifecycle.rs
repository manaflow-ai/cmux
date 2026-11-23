//! A person's prompt, from the composer to its turn's end: the stages it passes through, and the
//! actions its bubble may offer in each (hq docs/design/user-message-lifecycle.md).
//!
//! Leo, 2026-11-22: "ok, so is this supposed to be cancellable or what? why am i seeing the edit
//! option available after you've already read it? well, the cross vs edit vs anything, we
//! need to be able to map out the lifecycle and what should reasonably be possible, when."
//!
//! The rule: an action shows only where it is possible and does what its name says. Cancel (the ✕)
//! only while nothing has read the prompt. Edit in place only while it waits in the queue. Once the
//! agent has read it, nothing edits it while its turn runs; after the turn ends, Edit is "edit and
//! resend from here": a fork through the turn before, kept as a new version beside the original
//! (the ChatGPT and claude.ai model). acpmux keeps the states (its queue, steers, holds and turn
//! results); `prompt_lifecycle.json` beside this crate is this table as data, and the agent pane's
//! test (webviews `conversation/promptLifecycle.test.tsx`) draws a prompt in every stage and checks
//! that its bubble offers exactly what the table says.
#![deny(clippy::indexing_slicing, clippy::expect_used)]

use serde::Serialize;

/// Where a person's prompt is.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Stage {
    /// In the composer: not sent. The composer, not a bubble, owns it.
    Composing,
    /// Sent, and acpmux has not taken it yet (the footer's "Sending").
    Sending,
    /// acpmux holds it until the agent's host can take it: the host is offline or a Cloud machine
    /// wakes ("Sending when ready").
    WaitingForHost,
    /// acpmux holds it in the chat's queue until the running turn ends (the composer's queue).
    Queued,
    /// Sent into the running turn; the agent reads it when its current step ends.
    SteerWaiting,
    /// Held in the inbox: a guest's prompt waiting for approval, or another agent's message held
    /// while its pair is paused or after a Stop.
    HeldInInbox,
    /// Did not get there (refused on the way, or the agent could not start).
    Failed,
    /// The agent has read it and its turn is still running (the turn's own prompt, or a steer that
    /// landed).
    Read,
    /// Its turn ended: answered.
    Answered,
}

/// What a control does.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Action {
    /// Copy the prompt's text.
    Copy,
    /// The ✕: take the prompt back before anything read it; its text returns to the composer, to
    /// change or send again. Its name says so ("Edit message"): the composer is where it is edited.
    Cancel,
    /// Change the prompt where it waits; it is sent as changed.
    EditInPlace,
    /// Edit and resend from here: a fork through the turn before the prompt, which gets the edited
    /// text. The original chat stays as it was; both are versions (< n/m >).
    EditAndResend,
    /// Send a waiting prompt into the running turn now.
    SendNow,
    /// Send a prompt that did not get there again, as it was.
    Retry,
    /// Delete a waiting prompt (the queue's trash can), remove one that did not get there, or
    /// decline a held one: its text is gone, not back in the composer.
    Remove,
    /// Approve a held prompt: it goes to the agent.
    Approve,
    /// Fork the chat through this prompt's own ended turn into a new chat.
    Fork,
    /// Bookmark the prompt.
    Bookmark,
}

/// What an action does to the agent's conversation.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Effect {
    /// Nothing the agent sees.
    None,
    /// Withdraws a prompt the agent never read.
    Withdraws,
    /// Changes a prompt the agent has not read yet.
    Changes,
    /// Sends (or sends again) to the agent.
    Sends,
    /// Forks: a new chat (or version) from an ended turn; this chat stays as it was.
    Forks,
}

impl Action {
    /// What the action does to the agent.
    pub const fn effect(self) -> Effect {
        match self {
            Self::Copy | Self::Bookmark => Effect::None,
            Self::Cancel | Self::Remove => Effect::Withdraws,
            Self::EditInPlace => Effect::Changes,
            Self::SendNow | Self::Retry | Self::Approve => Effect::Sends,
            Self::EditAndResend | Self::Fork => Effect::Forks,
        }
    }
}

/// What the stage alone does not say.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize)]
pub struct Facts {
    /// acpmux forks this chat through an ended turn (`forksAnyTurn`: Claude and Codex).
    pub forks: bool,
    /// A logged turn ended before this prompt: an edit has a turn to fork through. A chat's first
    /// prompt has none.
    pub turn_before: bool,
    /// It was sent into a running turn (a steer). Its turn opened with another prompt, which a
    /// fork through the turn before would drop, so it never edits and resends.
    pub steer: bool,
}

/// The actions a prompt in `stage` offers, in the order its row draws them.
pub fn actions(stage: Stage, facts: Facts) -> Vec<Action> {
    use Action::*;
    match stage {
        Stage::Composing => vec![],
        Stage::Sending | Stage::WaitingForHost => vec![Copy],
        Stage::Queued => vec![SendNow, Cancel, Remove, EditInPlace],
        Stage::SteerWaiting => vec![Copy, Cancel, SendNow],
        Stage::HeldInInbox => vec![Approve, Remove],
        Stage::Failed => vec![Retry, EditInPlace, Remove],
        Stage::Read => vec![Copy, Bookmark],
        Stage::Answered => {
            let mut shown = vec![Copy];
            if facts.forks && facts.turn_before && !facts.steer {
                shown.push(EditAndResend);
            }
            if facts.forks {
                shown.push(Fork);
            }
            shown.push(Bookmark);
            shown
        }
    }
}

/// Every stage, in lifecycle order.
pub const STAGES: [Stage; 9] = [
    Stage::Composing,
    Stage::Sending,
    Stage::WaitingForHost,
    Stage::Queued,
    Stage::SteerWaiting,
    Stage::HeldInInbox,
    Stage::Failed,
    Stage::Read,
    Stage::Answered,
];

/// Where a stage may go next (a transition moves nothing on screen: hq
/// docs/design/transcript-animation-rules.md; the bubble keeps its place and its footer's height).
pub fn next(stage: Stage) -> &'static [Stage] {
    match stage {
        Stage::Composing => &[Stage::Sending, Stage::Queued, Stage::SteerWaiting],
        Stage::Sending => {
            &[Stage::WaitingForHost, Stage::Queued, Stage::SteerWaiting, Stage::Read, Stage::Failed]
        }
        Stage::WaitingForHost => &[Stage::Read, Stage::Queued, Stage::Failed, Stage::Composing],
        Stage::Queued => &[Stage::SteerWaiting, Stage::Read, Stage::Composing],
        Stage::SteerWaiting => &[Stage::Read, Stage::Composing],
        Stage::HeldInInbox => &[Stage::Read, Stage::Queued],
        Stage::Failed => &[Stage::Sending, Stage::Composing],
        Stage::Read => &[Stage::Answered, Stage::Failed],
        Stage::Answered => &[],
    }
}

/// The table as data: each stage with its actions for every combination of facts, each action's
/// effect, and where each stage may go. `prompt_lifecycle.json` is this, pretty-printed.
pub fn table() -> serde_json::Value {
    let mut stages = Vec::new();
    for stage in STAGES {
        let mut cases = Vec::new();
        for bits in 0u8..8 {
            let facts =
                Facts { forks: bits & 1 != 0, turn_before: bits & 2 != 0, steer: bits & 4 != 0 };
            cases.push(serde_json::json!({ "facts": facts, "actions": actions(stage, facts) }));
        }
        stages.push(serde_json::json!({ "stage": stage, "next": next(stage), "cases": cases }));
    }
    let effects: serde_json::Map<String, serde_json::Value> = [
        Action::Copy,
        Action::Cancel,
        Action::EditInPlace,
        Action::EditAndResend,
        Action::SendNow,
        Action::Retry,
        Action::Remove,
        Action::Approve,
        Action::Fork,
        Action::Bookmark,
    ]
    .into_iter()
    .map(|action| {
        (
            serde_json::to_value(action)
                .ok()
                .and_then(|v| v.as_str().map(str::to_owned))
                .unwrap_or_default(),
            serde_json::to_value(action.effect()).unwrap_or_default(),
        )
    })
    .collect();
    serde_json::json!({
        "generated": "acpmux-core src/chat/prompt_lifecycle.rs; rerun with BLESS=1 cargo test -p acpmux-core prompt_lifecycle",
        "stages": stages,
        "effects": effects,
    })
}

#[cfg(test)]
#[path = "prompt_lifecycle_tests.rs"]
mod tests;
