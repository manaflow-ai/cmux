//! One composer prompt's way to acpmux and the agent, as an explicit state machine (RFD 0026,
//! machine 2): an enum of states that carry their own data, and one pure [`step`] from
//! `(Machine, Event)` to the next machine and the effects to run, or a named [`Refusal`]. Every
//! (state, event) pair is written out: no arm falls through to a default.
//!
//! One machine is one `promptId`. Every `session/prompt` it writes ([`Effect::SendPrompt`]) goes
//! under a fresh [`Generation`]; the answer to that write (a refusal, no answer in time, acpmux
//! away) and the timers armed for it come back as events carrying it. acpmux's own word that it
//! took or the agent read the prompt ([`Event::Accepted`], [`Event::Read`]) names the `promptId`,
//! not one write: acpmux runs a `promptId` once, so any write's copy is the same prompt.
//!
//! The webviews replay the exported table (`schemas/composer-delivery/table.json`, [`table`]) in
//! `webviews/src/agent-session/acpmux/delivery/step.ts`; they hold no transition logic of their own.
//!
//! What the proof (tests) checks over every event sequence up to length 6: the machine awaits at
//! most one `session/prompt` at any time, writes none once the agent read the prompt, writes none
//! after acpmux took it unless acpmux then refused it, and each accepted Submit, Retry or held
//! release writes exactly one.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// The write a `session/prompt` went under, which its answer and timers carry back.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Generation(pub u64);

/// The hop a send stopped at: the pane could not reach acpmux, acpmux refused it or never
/// answered, or the agent's turn for it failed.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Hop {
    Connection,
    Acpmux,
    Agent,
}

impl Hop {
    pub fn as_str(self) -> &'static str {
        match self {
            Hop::Connection => "connection",
            Hop::Acpmux => "acpmux",
            Hop::Agent => "agent",
        }
    }
}

/// Whether a failure was an answer (a refusal) or the lack of one (a deadline, a dropped
/// connection). Only an unanswered failure gives way to acpmux's late word that it has the prompt.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FailCause {
    Refused,
    Unanswered,
}

/// Why the pane holds a prompt instead of sending it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "reason", rename_all = "snake_case", rename_all_fields = "camelCase")]
pub enum Hold {
    /// The folder's trust question is open (trustHeld.ts). Never written yet.
    Trust,
    /// The chat's Cloud machine is waking (cloudWake.ts). Never written yet.
    MachineWaking,
    /// acpmux is starting or reconnecting (sendWhenReady.ts): `attempt` came back with acpmux away.
    /// `resent`: the same frame went again under `attempt` and awaits its answer.
    /// `behind_turn`: the prompt was sent behind the running turn (a steer).
    HostStarting { attempt: Generation, resent: bool, behind_turn: bool },
}

/// A prompt's delivery state and the data only that state has.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case", rename_all_fields = "camelCase")]
pub enum Delivery {
    /// In the composer: nothing written.
    Draft,
    /// `session/prompt` went under `attempt`; no answer yet. `slow`: none for a while.
    Sending { attempt: Generation, slow: bool },
    /// As [`Delivery::Sending`], sent behind the running turn (a steer): it says it is queued
    /// behind that turn while on its way, never "Not sent".
    QueuedBehindTurn { attempt: Generation, slow: bool },
    /// The pane holds it.
    Held { hold: Hold },
    /// acpmux recorded it; `attempt` is the write whose late refusal (refused at its turn) still
    /// counts.
    Delivered { attempt: Generation },
    /// The agent started on it.
    Read { attempt: Generation },
    /// It did not get there: the hop it stopped at and the refuser's code.
    Failed { attempt: Generation, hop: Hop, code: String, cause: FailCause },
}

/// The codes that mean no answer came (not a refusal): a failure with one gives way to a late
/// acceptance. The webviews read this list from the table to name an `unanswered` event.
pub const UNANSWERED_CODES: [&str; 2] = ["timeout", "native.timed_out"];

/// The code a send's own deadline fails with.
pub const TIMEOUT_CODE: &str = "timeout";

impl Delivery {
    /// Every table key, in the table's order. A key is a state plus the data that changes its
    /// transitions or what the row says.
    pub const KEYS: [&'static str; 15] = [
        "draft",
        "sending",
        "sending_slow",
        "queued_behind_turn",
        "queued_behind_turn_slow",
        "held_trust",
        "held_machine_waking",
        "held_host_starting",
        "held_host_starting_behind_turn",
        "held_host_starting_resent",
        "held_host_starting_resent_behind_turn",
        "delivered",
        "read",
        "failed",
        "failed_unanswered",
    ];

    pub fn kind(&self) -> &'static str {
        match self {
            Delivery::Draft => "draft",
            Delivery::Sending { .. } => "sending",
            Delivery::QueuedBehindTurn { .. } => "queued_behind_turn",
            Delivery::Held { .. } => "held",
            Delivery::Delivered { .. } => "delivered",
            Delivery::Read { .. } => "read",
            Delivery::Failed { .. } => "failed",
        }
    }

    pub fn key(&self) -> &'static str {
        match self {
            Delivery::Draft => "draft",
            Delivery::Sending { slow: false, .. } => "sending",
            Delivery::Sending { slow: true, .. } => "sending_slow",
            Delivery::QueuedBehindTurn { slow: false, .. } => "queued_behind_turn",
            Delivery::QueuedBehindTurn { slow: true, .. } => "queued_behind_turn_slow",
            Delivery::Held { hold } => match hold {
                Hold::Trust => "held_trust",
                Hold::MachineWaking => "held_machine_waking",
                Hold::HostStarting { resent: false, behind_turn: false, .. } => {
                    "held_host_starting"
                }
                Hold::HostStarting { resent: false, behind_turn: true, .. } => {
                    "held_host_starting_behind_turn"
                }
                Hold::HostStarting { resent: true, behind_turn: false, .. } => {
                    "held_host_starting_resent"
                }
                Hold::HostStarting { resent: true, behind_turn: true, .. } => {
                    "held_host_starting_resent_behind_turn"
                }
            },
            Delivery::Delivered { .. } => "delivered",
            Delivery::Read { .. } => "read",
            Delivery::Failed { cause: FailCause::Refused, .. } => "failed",
            Delivery::Failed { cause: FailCause::Unanswered, .. } => "failed_unanswered",
        }
    }

    /// The pane's one word for it (`PromptDelivery.state`): a held-for-host prompt is still on its
    /// way. Draft and a trust or wake hold have no delivery row.
    pub fn word(&self) -> Option<&'static str> {
        match self {
            Delivery::Draft
            | Delivery::Held { hold: Hold::Trust }
            | Delivery::Held { hold: Hold::MachineWaking } => None,
            Delivery::Sending { .. }
            | Delivery::QueuedBehindTurn { .. }
            | Delivery::Held { hold: Hold::HostStarting { .. } } => Some("sending"),
            Delivery::Delivered { .. } => Some("delivered"),
            Delivery::Read { .. } => Some("read"),
            Delivery::Failed { .. } => Some("failed"),
        }
    }

    /// The write whose answer this state waits for: any other generation is stale.
    pub fn awaits(&self) -> Option<Generation> {
        match self {
            Delivery::Sending { attempt, .. }
            | Delivery::QueuedBehindTurn { attempt, .. }
            | Delivery::Held { hold: Hold::HostStarting { attempt, resent: true, .. } }
            | Delivery::Delivered { attempt }
            | Delivery::Failed { attempt, cause: FailCause::Unanswered, .. } => Some(*attempt),
            Delivery::Draft
            | Delivery::Held { hold: Hold::Trust }
            | Delivery::Held { hold: Hold::MachineWaking }
            | Delivery::Held { hold: Hold::HostStarting { resent: false, .. } }
            | Delivery::Read { .. }
            | Delivery::Failed { cause: FailCause::Refused, .. } => None,
        }
    }

    /// A `session/prompt` is out and unanswered: nothing may write another.
    pub fn in_flight(&self) -> bool {
        match self {
            Delivery::Sending { .. }
            | Delivery::QueuedBehindTurn { .. }
            | Delivery::Held { hold: Hold::HostStarting { resent: true, .. } } => true,
            Delivery::Draft
            | Delivery::Held { hold: Hold::Trust }
            | Delivery::Held { hold: Hold::MachineWaking }
            | Delivery::Held { hold: Hold::HostStarting { resent: false, .. } }
            | Delivery::Delivered { .. }
            | Delivery::Read { .. }
            | Delivery::Failed { .. } => false,
        }
    }

    /// The row says "Sending when ready" (held for acpmux).
    pub fn held_for_host(&self) -> bool {
        matches!(self, Delivery::Held { hold: Hold::HostStarting { .. } })
    }

    /// Sent behind the running turn: its row keeps its time while on its way.
    pub fn behind_turn(&self) -> bool {
        match self {
            Delivery::QueuedBehindTurn { .. } => true,
            Delivery::Held { hold: Hold::HostStarting { behind_turn, .. } } => *behind_turn,
            Delivery::Draft
            | Delivery::Sending { .. }
            | Delivery::Held { hold: Hold::Trust }
            | Delivery::Held { hold: Hold::MachineWaking }
            | Delivery::Delivered { .. }
            | Delivery::Read { .. }
            | Delivery::Failed { .. } => false,
        }
    }

    /// No answer for a while (stallLog.ts checks whether the pane missed the chat's events).
    pub fn slow(&self) -> bool {
        matches!(
            self,
            Delivery::Sending { slow: true, .. } | Delivery::QueuedBehindTurn { slow: true, .. }
        )
    }

    /// The hold's reason, for a held prompt.
    pub fn hold_reason(&self) -> Option<&'static str> {
        match self {
            Delivery::Held { hold: Hold::Trust } => Some("trust"),
            Delivery::Held { hold: Hold::MachineWaking } => Some("machine_waking"),
            Delivery::Held { hold: Hold::HostStarting { .. } } => Some("host_starting"),
            Delivery::Draft
            | Delivery::Sending { .. }
            | Delivery::QueuedBehindTurn { .. }
            | Delivery::Delivered { .. }
            | Delivery::Read { .. }
            | Delivery::Failed { .. } => None,
        }
    }
}

/// One prompt: its delivery and the last generation it wrote under.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Machine {
    pub delivery: Delivery,
    pub issued: Generation,
}

impl Machine {
    /// A prompt in the composer: nothing written.
    pub fn draft() -> Machine {
        Machine { delivery: Delivery::Draft, issued: Generation(0) }
    }
}

/// An intent, acpmux's word about the prompt, or an answer or timer under the write it was issued
/// with.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case", rename_all_fields = "camelCase")]
pub enum Event {
    /// Send (or Retry a failed one).
    Submit,
    /// Send behind the running turn (a steer), or Retry one.
    SubmitBehindTurn,
    /// The folder's trust question holds it before it goes.
    HoldTrust,
    /// The chat's Cloud machine is waking: held before it goes.
    HoldMachineWaking,
    /// The hold ended: a trust or wake hold goes back to the composer's send; a host hold writes
    /// the same frame again.
    Release,
    /// acpmux recorded the prompt (its acceptance, its echo or its `queued` record).
    Accepted,
    /// The agent started on it.
    Read,
    /// The write under `generation` was refused.
    Refused { generation: Generation, hop: Hop, code: String },
    /// The write under `generation` got no answer (a dropped connection, a lost prompt).
    Unanswered { generation: Generation, hop: Hop, code: String },
    /// The write under `generation` found acpmux away (starting or reconnecting).
    HostAway { generation: Generation },
    /// The slow timer armed for `generation` fired.
    SlowTimer { generation: Generation },
    /// The no-answer deadline armed for `generation` fired.
    FailTimer { generation: Generation },
    /// The person took it back (Edit, Remove) or its sender keeps it in the composer.
    HandBack,
}

impl Event {
    /// Every event's name, in the table's order.
    pub const KINDS: [&'static str; 13] = [
        "submit",
        "submit_behind_turn",
        "hold_trust",
        "hold_machine_waking",
        "release",
        "accepted",
        "read",
        "refused",
        "unanswered",
        "host_away",
        "slow_timer",
        "fail_timer",
        "hand_back",
    ];

    pub fn kind(&self) -> &'static str {
        match self {
            Event::Submit => "submit",
            Event::SubmitBehindTurn => "submit_behind_turn",
            Event::HoldTrust => "hold_trust",
            Event::HoldMachineWaking => "hold_machine_waking",
            Event::Release => "release",
            Event::Accepted => "accepted",
            Event::Read => "read",
            Event::Refused { .. } => "refused",
            Event::Unanswered { .. } => "unanswered",
            Event::HostAway { .. } => "host_away",
            Event::SlowTimer { .. } => "slow_timer",
            Event::FailTimer { .. } => "fail_timer",
            Event::HandBack => "hand_back",
        }
    }

    /// The generation an answer or timer carries; None for an intent or acpmux's word.
    pub fn generation(&self) -> Option<Generation> {
        match self {
            Event::Submit
            | Event::SubmitBehindTurn
            | Event::HoldTrust
            | Event::HoldMachineWaking
            | Event::Release
            | Event::Accepted
            | Event::Read
            | Event::HandBack => None,
            Event::Refused { generation, .. }
            | Event::Unanswered { generation, .. }
            | Event::HostAway { generation }
            | Event::SlowTimer { generation }
            | Event::FailTimer { generation } => Some(*generation),
        }
    }
}

/// What the caller runs after a transition, in order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "effect", rename_all = "snake_case", rename_all_fields = "camelCase")]
pub enum Effect {
    /// Write `session/prompt` for this prompt id under `generation`.
    SendPrompt { generation: Generation },
    /// Arm the slow timer and the no-answer deadline for `generation`.
    ArmTimers { generation: Generation },
    /// Clear the prompt's timers: acpmux has it.
    ClearTimers,
}

impl Effect {
    pub fn kind(&self) -> &'static str {
        match self {
            Effect::SendPrompt { .. } => "send_prompt",
            Effect::ArmTimers { .. } => "arm_timers",
            Effect::ClearTimers => "clear_timers",
        }
    }
}

/// Why an event was refused. The machine is unchanged.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Refusal {
    /// A `session/prompt` for it is out and unanswered: never a second one.
    InFlight,
    /// Nothing was written yet, so acpmux cannot have it.
    NotSent,
    /// The pane holds it; only Release (or the person's Edit) moves it.
    Held,
    /// Release with no hold.
    NotHeld,
    /// A hold applies only to a prompt still in the composer.
    NotDraft,
    /// acpmux already has it: never written again.
    AlreadyTaken,
    /// The agent already started on it.
    AlreadyRead,
    /// acpmux refused it: only Retry, Edit or Remove move it.
    AlreadyRefused,
    /// The slow timer already fired.
    AlreadySlow,
    /// An answer or timer the state does not wait for.
    NotAwaited,
    /// An answer or timer under another generation than the one the state waits for.
    StaleGeneration,
}

impl Refusal {
    pub const ALL: [Refusal; 11] = [
        Refusal::InFlight,
        Refusal::NotSent,
        Refusal::Held,
        Refusal::NotHeld,
        Refusal::NotDraft,
        Refusal::AlreadyTaken,
        Refusal::AlreadyRead,
        Refusal::AlreadyRefused,
        Refusal::AlreadySlow,
        Refusal::NotAwaited,
        Refusal::StaleGeneration,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Refusal::InFlight => "in_flight",
            Refusal::NotSent => "not_sent",
            Refusal::Held => "held",
            Refusal::NotHeld => "not_held",
            Refusal::NotDraft => "not_draft",
            Refusal::AlreadyTaken => "already_taken",
            Refusal::AlreadyRead => "already_read",
            Refusal::AlreadyRefused => "already_refused",
            Refusal::AlreadySlow => "already_slow",
            Refusal::NotAwaited => "not_awaited",
            Refusal::StaleGeneration => "stale_generation",
        }
    }
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

impl std::error::Error for Refusal {}

pub type Step = Result<(Machine, Vec<Effect>), Refusal>;

/// The machine after `event`, and the effects to run; or why `event` is refused.
pub fn step(machine: &Machine, event: &Event) -> Step {
    let issued = machine.issued;
    let next = Generation(issued.0 + 1);
    // A transition that writes `session/prompt` writes it under a new generation.
    let write = |delivery: Delivery| -> Step {
        Ok((
            Machine { delivery, issued: next },
            vec![Effect::SendPrompt { generation: next }, Effect::ArmTimers { generation: next }],
        ))
    };
    let settle = |delivery: Delivery, effects: Vec<Effect>| -> Step {
        Ok((Machine { delivery, issued }, effects))
    };
    let taken = |delivery: Delivery| settle(delivery, vec![Effect::ClearTimers]);
    let failed = |attempt: Generation, hop: Hop, code: &str, cause: FailCause| Delivery::Failed {
        attempt,
        hop,
        code: code.to_owned(),
        cause,
    };
    match (&machine.delivery, event) {
        // Draft: only Submit writes; a hold keeps it; acpmux cannot know it.
        (Delivery::Draft, Event::Submit) => write(Delivery::Sending { attempt: next, slow: false }),
        (Delivery::Draft, Event::SubmitBehindTurn) => {
            write(Delivery::QueuedBehindTurn { attempt: next, slow: false })
        }
        (Delivery::Draft, Event::HoldTrust) => settle(Delivery::Held { hold: Hold::Trust }, vec![]),
        (Delivery::Draft, Event::HoldMachineWaking) => {
            settle(Delivery::Held { hold: Hold::MachineWaking }, vec![])
        }
        (Delivery::Draft, Event::Release) => Err(Refusal::NotHeld),
        (Delivery::Draft, Event::Accepted | Event::Read | Event::HandBack) => Err(Refusal::NotSent),
        (
            Delivery::Draft,
            Event::Refused { .. }
            | Event::Unanswered { .. }
            | Event::HostAway { .. }
            | Event::SlowTimer { .. }
            | Event::FailTimer { .. },
        ) => Err(Refusal::NotAwaited),

        // On its way: never a second write; its answer, acpmux's word or its timers move it.
        (
            Delivery::Sending { attempt, slow } | Delivery::QueuedBehindTurn { attempt, slow },
            event,
        ) => {
            let behind_turn = matches!(machine.delivery, Delivery::QueuedBehindTurn { .. });
            let (attempt, slow) = (*attempt, *slow);
            match event {
                Event::Submit
                | Event::SubmitBehindTurn
                | Event::HoldTrust
                | Event::HoldMachineWaking
                | Event::HandBack => Err(Refusal::InFlight),
                Event::Release => Err(Refusal::NotHeld),
                Event::Accepted => taken(Delivery::Delivered { attempt }),
                Event::Read => taken(Delivery::Read { attempt }),
                Event::Refused { generation, hop, code } => {
                    current(attempt, *generation)?;
                    taken(failed(attempt, *hop, code, FailCause::Refused))
                }
                Event::Unanswered { generation, hop, code } => {
                    current(attempt, *generation)?;
                    taken(failed(attempt, *hop, code, FailCause::Unanswered))
                }
                Event::HostAway { generation } => {
                    current(attempt, *generation)?;
                    let hold = Hold::HostStarting { attempt, resent: false, behind_turn };
                    settle(Delivery::Held { hold }, vec![])
                }
                Event::SlowTimer { generation } => {
                    if slow {
                        return Err(Refusal::AlreadySlow);
                    }
                    current(attempt, *generation)?;
                    let delivery = if behind_turn {
                        Delivery::QueuedBehindTurn { attempt, slow: true }
                    } else {
                        Delivery::Sending { attempt, slow: true }
                    };
                    settle(delivery, vec![])
                }
                Event::FailTimer { generation } => {
                    current(attempt, *generation)?;
                    settle(
                        failed(attempt, Hop::Acpmux, TIMEOUT_CODE, FailCause::Unanswered),
                        vec![],
                    )
                }
            }
        }

        // Held before it went (trust, a waking machine): Release hands it back to the composer's
        // send, which writes it as a Submit; Edit or Remove takes it back.
        (Delivery::Held { hold: Hold::Trust | Hold::MachineWaking }, event) => match event {
            Event::Submit
            | Event::SubmitBehindTurn
            | Event::HoldTrust
            | Event::HoldMachineWaking => Err(Refusal::Held),
            Event::Release | Event::HandBack => settle(Delivery::Draft, vec![]),
            Event::Accepted | Event::Read => Err(Refusal::NotSent),
            Event::Refused { .. }
            | Event::Unanswered { .. }
            | Event::HostAway { .. }
            | Event::SlowTimer { .. }
            | Event::FailTimer { .. } => Err(Refusal::NotAwaited),
        },

        // Held for acpmux: Release writes the same frame again; acpmux's late word still lands.
        (Delivery::Held { hold: Hold::HostStarting { attempt, resent, behind_turn } }, event) => {
            let (attempt, resent, behind_turn) = (*attempt, *resent, *behind_turn);
            match event {
                Event::Submit
                | Event::SubmitBehindTurn
                | Event::HoldTrust
                | Event::HoldMachineWaking
                | Event::HandBack => Err(Refusal::InFlight),
                Event::Release if resent => Err(Refusal::InFlight),
                Event::Release => Ok((
                    Machine {
                        delivery: Delivery::Held {
                            hold: Hold::HostStarting { attempt: next, resent: true, behind_turn },
                        },
                        issued: next,
                    },
                    vec![
                        Effect::SendPrompt { generation: next },
                        Effect::ArmTimers { generation: next },
                    ],
                )),
                Event::Accepted => taken(Delivery::Delivered { attempt }),
                Event::Read => taken(Delivery::Read { attempt }),
                // The resent frame's answer, or the wait for acpmux given up (its deadline, the
                // pane's connection closed): the send ends failed, with Retry.
                Event::Refused { generation, hop, code } => {
                    current(attempt, *generation)?;
                    taken(failed(attempt, *hop, code, FailCause::Refused))
                }
                Event::Unanswered { generation, hop, code } => {
                    current(attempt, *generation)?;
                    taken(failed(attempt, *hop, code, FailCause::Unanswered))
                }
                Event::HostAway { generation } if resent => {
                    current(attempt, *generation)?;
                    let hold = Hold::HostStarting { attempt, resent: false, behind_turn };
                    settle(Delivery::Held { hold }, vec![])
                }
                Event::HostAway { .. } => Err(Refusal::NotAwaited),
                // The resent frame's deadline runs from the release (sendWhenReady.ts).
                Event::FailTimer { generation } if resent => {
                    current(attempt, *generation)?;
                    settle(
                        failed(attempt, Hop::Acpmux, TIMEOUT_CODE, FailCause::Unanswered),
                        vec![],
                    )
                }
                // No request of it counts down while it waits: its deadline starts again after.
                // acpmux is away, so a quiet chat is no sign of missed events: never slow.
                Event::SlowTimer { .. } | Event::FailTimer { .. } => Err(Refusal::Held),
            }
        }

        // acpmux has it: never written again. Only a refusal at its turn (it never ran) fails it.
        (Delivery::Delivered { attempt }, event) => match event {
            Event::Submit
            | Event::SubmitBehindTurn
            | Event::HoldTrust
            | Event::HoldMachineWaking
            | Event::Accepted
            | Event::Unanswered { .. }
            | Event::HostAway { .. }
            | Event::HandBack => Err(Refusal::AlreadyTaken),
            Event::Release => Err(Refusal::NotHeld),
            Event::Read => settle(Delivery::Read { attempt: *attempt }, vec![]),
            Event::Refused { generation, code, .. } => {
                current(*attempt, *generation)?;
                settle(failed(*attempt, Hop::Agent, code, FailCause::Refused), vec![])
            }
            Event::SlowTimer { .. } | Event::FailTimer { .. } => Err(Refusal::NotAwaited),
        },

        // The agent read it: nothing writes it again; what ends its turn is the transcript's.
        (Delivery::Read { .. }, event) => match event {
            Event::Submit
            | Event::SubmitBehindTurn
            | Event::HoldTrust
            | Event::HoldMachineWaking
            | Event::Read
            | Event::HandBack => Err(Refusal::AlreadyRead),
            Event::Accepted => Err(Refusal::AlreadyTaken),
            Event::Release => Err(Refusal::NotHeld),
            Event::Refused { .. }
            | Event::Unanswered { .. }
            | Event::HostAway { .. }
            | Event::SlowTimer { .. }
            | Event::FailTimer { .. } => Err(Refusal::NotAwaited),
        },

        // Not sent: Retry writes it again under the same prompt id; an unanswered failure gives
        // way to acpmux's late word.
        (Delivery::Failed { attempt, cause, .. }, event) => {
            let (attempt, unanswered) = (*attempt, *cause == FailCause::Unanswered);
            match event {
                Event::Submit => write(Delivery::Sending { attempt: next, slow: false }),
                Event::SubmitBehindTurn => {
                    write(Delivery::QueuedBehindTurn { attempt: next, slow: false })
                }
                Event::HoldTrust | Event::HoldMachineWaking => Err(Refusal::NotDraft),
                Event::Release => Err(Refusal::NotHeld),
                Event::HandBack => settle(Delivery::Draft, vec![]),
                Event::Accepted if unanswered => taken(Delivery::Delivered { attempt }),
                Event::Read if unanswered => taken(Delivery::Read { attempt }),
                Event::Accepted | Event::Read => Err(Refusal::AlreadyRefused),
                Event::Refused { generation, hop, code } if unanswered => {
                    current(attempt, *generation)?;
                    settle(failed(attempt, *hop, code, FailCause::Refused), vec![])
                }
                Event::Unanswered { generation, hop, code } if unanswered => {
                    current(attempt, *generation)?;
                    settle(failed(attempt, *hop, code, FailCause::Unanswered), vec![])
                }
                Event::Refused { .. } | Event::Unanswered { .. } => Err(Refusal::AlreadyRefused),
                Event::HostAway { .. } | Event::SlowTimer { .. } | Event::FailTimer { .. } => {
                    Err(Refusal::NotAwaited)
                }
            }
        }
    }
}

/// An answer is for the write the state waits on, or it is stale.
fn current(awaited: Generation, got: Generation) -> Result<(), Refusal> {
    if awaited == got { Ok(()) } else { Err(Refusal::StaleGeneration) }
}

/// The generation the table's sample states wrote under and its sample answers carry.
pub const SAMPLE: Generation = Generation(7);
/// The hop and code the table's sample refusals carry.
pub const SAMPLE_HOP: Hop = Hop::Acpmux;
pub const SAMPLE_CODE: &str = "sample.code";

/// One machine per key, in [`Delivery::KEYS`] order, written under [`SAMPLE`] where it was.
pub fn sample_states() -> Vec<Machine> {
    let a = SAMPLE;
    let host = |resent, behind_turn| Delivery::Held {
        hold: Hold::HostStarting { attempt: a, resent, behind_turn },
    };
    let failed = |cause| Delivery::Failed {
        attempt: a,
        hop: SAMPLE_HOP,
        code: SAMPLE_CODE.to_owned(),
        cause,
    };
    [
        Delivery::Draft,
        Delivery::Sending { attempt: a, slow: false },
        Delivery::Sending { attempt: a, slow: true },
        Delivery::QueuedBehindTurn { attempt: a, slow: false },
        Delivery::QueuedBehindTurn { attempt: a, slow: true },
        Delivery::Held { hold: Hold::Trust },
        Delivery::Held { hold: Hold::MachineWaking },
        host(false, false),
        host(false, true),
        host(true, false),
        host(true, true),
        Delivery::Delivered { attempt: a },
        Delivery::Read { attempt: a },
        failed(FailCause::Refused),
        failed(FailCause::Unanswered),
    ]
    .into_iter()
    .map(|delivery| {
        let issued = if delivery == Delivery::Draft { Generation(0) } else { a };
        Machine { delivery, issued }
    })
    .collect()
}

/// One event per kind, in [`Event::KINDS`] order; answers and timers carry `generation`.
pub fn sample_events(generation: Generation) -> [Event; 13] {
    let code = || SAMPLE_CODE.to_owned();
    [
        Event::Submit,
        Event::SubmitBehindTurn,
        Event::HoldTrust,
        Event::HoldMachineWaking,
        Event::Release,
        Event::Accepted,
        Event::Read,
        Event::Refused { generation, hop: SAMPLE_HOP, code: code() },
        Event::Unanswered { generation, hop: SAMPLE_HOP, code: code() },
        Event::HostAway { generation },
        Event::SlowTimer { generation },
        Event::FailTimer { generation },
        Event::HandBack,
    ]
}

/// The data a transition's next state takes, for a replayer: `attempt` (and `issued`) is a new
/// generation when the row writes `session/prompt`, else the old state's; a failure's hop and code
/// are the event's, or the row's `set` when the event carries none.
fn row_set(after: &Machine, event: &Event) -> Option<Value> {
    match (&after.delivery, event) {
        (Delivery::Failed { hop, code, .. }, Event::FailTimer { .. }) => {
            Some(json!({ "hop": hop.as_str(), "code": code }))
        }
        (Delivery::Failed { hop, .. }, Event::Refused { hop: from, .. }) if hop != from => {
            Some(json!({ "hop": hop.as_str() }))
        }
        _ => None,
    }
}

/// The whole transition table as data: every key against every event, each a transition (the key
/// it moves to and its effects' kinds) or a named refusal. Answers in the rows carry the
/// generation the state awaits; any other is refused as the `stale` rule says.
pub fn table() -> Value {
    let mut rows = Vec::new();
    for machine in sample_states() {
        for event in sample_events(SAMPLE) {
            let row = match step(&machine, &event) {
                Ok((after, effects)) => {
                    let mut row = json!({
                        "from": machine.delivery.key(),
                        "event": event.kind(),
                        "to": after.delivery.key(),
                        "effects": effects.iter().map(Effect::kind).collect::<Vec<_>>(),
                    });
                    if let (Some(set), Some(fields)) =
                        (row_set(&after, &event), row.as_object_mut())
                    {
                        fields.insert("set".to_owned(), set);
                    }
                    row
                }
                Err(refusal) => json!({
                    "from": machine.delivery.key(),
                    "event": event.kind(),
                    "refusal": refusal.as_str(),
                }),
            };
            rows.push(row);
        }
    }
    let states: Vec<Value> = sample_states()
        .iter()
        .map(|m| {
            let d = &m.delivery;
            json!({
                "key": d.key(),
                "state": d.kind(),
                "word": d.word(),
                "hold": d.hold_reason(),
                "awaits": d.awaits().is_some(),
                "inFlight": d.in_flight(),
                "heldForHost": d.held_for_host(),
                "behindTurn": d.behind_turn(),
                "slow": d.slow(),
            })
        })
        .collect();
    json!({
        "version": 1,
        "source": "cmux-tui/crates/acpmux-client/src/delivery.rs",
        "stale": "An answer or timer (refused, unanswered, host_away, slow_timer, fail_timer) under another generation than the state's attempt is refused stale_generation where its row is a transition, and with the row's own refusal where its row is one. A refusal leaves the machine unchanged.",
        "generations": "A row whose effects include send_prompt writes under a new generation (issued + 1), which becomes the state's attempt and issued; every other row keeps both. A state's attempt is the generation it awaits.",
        "data": "A failed state's hop and code are the event's (refused, unanswered), overridden by the row's set; fail_timer's come from set.",
        "unansweredCodes": UNANSWERED_CODES,
        "states": states,
        "events": Event::KINDS,
        "refusals": Refusal::ALL.map(Refusal::as_str),
        "transitions": rows,
    })
}

/// Seeded walks of [`step`] from a draft, every step's machine before and after (or its refusal),
/// committed as `schemas/composer-delivery/vectors.json` for other languages' replays to match
/// exactly, data and all.
pub fn vectors() -> Value {
    let mut seed: u64 = 0x0026_c0de;
    let mut next = move || {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        seed
    };
    let hops = [Hop::Connection, Hop::Acpmux, Hop::Agent];
    let codes = ["timeout", "native.timed_out", "trust.pending", "transport.closed"];
    let mut walks = Vec::new();
    for _ in 0..24 {
        let mut machine = Machine::draft();
        let mut steps = Vec::new();
        for _ in 0..14 {
            // Answers mostly under the awaited generation, sometimes a stale one.
            let generation = match next() % 4 {
                0 => Generation(machine.issued.0.saturating_sub(1)),
                _ => machine.issued,
            };
            let hop = hops.get((next() % 3) as usize).copied().unwrap_or(Hop::Connection);
            let code = codes.get((next() % 4) as usize).copied().unwrap_or("timeout").to_owned();
            let events = [
                Event::Submit,
                Event::SubmitBehindTurn,
                Event::HoldTrust,
                Event::HoldMachineWaking,
                Event::Release,
                Event::Accepted,
                Event::Read,
                Event::Refused { generation, hop, code: code.clone() },
                Event::Unanswered { generation, hop, code },
                Event::HostAway { generation },
                Event::SlowTimer { generation },
                Event::FailTimer { generation },
                Event::HandBack,
            ];
            let event = events
                .get((next() % events.len() as u64) as usize)
                .cloned()
                .unwrap_or(Event::HandBack);
            let row = match step(&machine, &event) {
                Ok((after, effects)) => {
                    let row = json!({ "before": machine, "event": event, "after": after, "effects": effects });
                    machine = after;
                    row
                }
                Err(refusal) => json!({ "before": machine, "event": event, "refusal": refusal }),
            };
            steps.push(row);
        }
        walks.push(Value::from(steps));
    }
    json!({
        "version": 1,
        "source": "cmux-tui/crates/acpmux-client/src/delivery.rs",
        "walks": walks,
    })
}

#[cfg(test)]
mod tests;
