//! The Chief's automations in the brain (automations.rs, issue 25573): the
//! `automation` tool, the owner's list/pause/resume/delete from Home
//! (`chief.automation.list` / `chief.automation.update`), and the fires.
//!
//! A schedule is due on the brain's own timer (`next_automation_due`), as a
//! `sleep` wake is; nothing polls for it. An `agent_done` automation fires
//! from `sub_done` when a subagent's report reaches the Chief. Each fire
//! queues the automation's note
//! (`Automation::note`), which starts a normal turn that posts its result
//! in the Chief conversation.

use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::{Brain, Source, now_ms};
use crate::automations::{AUTOMATIONS_MAX, Automation, AutomationCall, Cron, Event, Trigger};

/// What the owner asks of the automations from Home.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AutomationsRequest {
    List,
    /// `pause`, `resume`, `delete` or `run` automation `id`.
    Update {
        id: String,
        action: String,
    },
}

/// The longest the brain waits before it reads the wall clock again while a
/// schedule is active.
const SCHEDULE_RECHECK: Duration = Duration::from_secs(60);

/// The owner's update actions.
pub const UPDATE_ACTIONS: [&str; 4] = ["pause", "resume", "delete", "run"];

impl Brain {
    /// The automations, oldest first.
    pub fn automations(&self) -> &[Automation] {
        &self.state.automations
    }

    /// The `automation` tool.
    pub(super) fn automation(&mut self, call: AutomationCall) -> Result<String, String> {
        match call.action.as_str() {
            "add" => self.add_automation(&call),
            "list" => {
                if self.state.automations.is_empty() {
                    return Ok("outcome: done. no automations".to_owned());
                }
                let lines: Vec<String> = self
                    .state
                    .automations
                    .iter()
                    .map(Automation::line)
                    .collect();
                Ok(format!("outcome: done.\n{}", lines.join("\n")))
            }
            action => {
                let id = call.id.as_deref().unwrap_or_default();
                self.update_automation(id, action)
                    .map(|(kind, text)| format!("outcome: {kind}. {text}"))
            }
        }
    }

    fn add_automation(&mut self, call: &AutomationCall) -> Result<String, String> {
        let trigger = call.trigger()?;
        let (name, prompt) = call.texts()?;
        if self.state.automations.len() >= AUTOMATIONS_MAX {
            return Err(format!(
                "automation add: {AUTOMATIONS_MAX} automations exist already; delete one first"
            ));
        }
        // The same job asked twice (a retried turn) is one automation.
        if let Some(same) = self
            .state
            .automations
            .iter()
            .find(|a| a.trigger == trigger && a.prompt == prompt)
        {
            return Ok(format!("outcome: noop. it exists already: {}", same.line()));
        }
        let now = (self.clock)();
        self.state.next_automation += 1;
        let mut automation = Automation {
            id: format!("au{}", self.state.next_automation),
            name,
            prompt,
            trigger,
            paused: false,
            created_ms: now,
            next_ms: None,
            last_fired_ms: None,
            runs: 0,
            fired: Vec::new(),
        };
        schedule(&mut automation, now);
        if let Trigger::Schedule { cron } = &automation.trigger
            && automation.next_ms.is_none()
        {
            return Err(format!(
                "automation add: the cron `{cron}` never comes again"
            ));
        }
        let line = automation.line();
        (self.log)(&format!(
            "automation {} made: {}",
            automation.id,
            automation.trigger.describe()
        ));
        self.trace.emit(
            "automation.add",
            json!({"id": automation.id, "trigger": automation.trigger.kind()}),
        );
        self.state.automations.push(automation);
        self.save();
        Ok(format!(
            "outcome: done. {line}. Each fire starts a turn of yours with its prompt; post the result in this chat. The person sees, pauses and deletes it in Chief settings."
        ))
    }

    /// pause, resume, delete or run `id`: `(outcome, text)`.
    fn update_automation(
        &mut self,
        id: &str,
        action: &str,
    ) -> Result<(&'static str, String), String> {
        let Some(index) = self.state.automations.iter().position(|a| a.id == id) else {
            return Err(format!("automation {action}: no automation {id}"));
        };
        let now = (self.clock)();
        let answer = match action {
            "pause" | "resume" => {
                let pause = action == "pause";
                let automation = &mut self.state.automations[index];
                if automation.paused == pause {
                    return Ok(("noop", format!("{id} is {action}d already")));
                }
                automation.paused = pause;
                schedule(automation, now);
                ("done", automation.line())
            }
            "delete" => {
                let gone = self.state.automations.remove(index);
                ("done", format!("deleted {} \"{}\"", gone.id, gone.name))
            }
            "run" => {
                self.fire(index, now, None, "now, because it was asked to run now");
                ("done", format!("{id} runs now"))
            }
            other => return Err(format!("automation: no action {other}")),
        };
        (self.log)(&format!("automation {id}: {action}"));
        self.trace
            .emit("automation.update", json!({"id": id, "action": action}));
        self.save();
        Ok(answer)
    }

    /// chief.automation.list / chief.automation.update from Home: the brain's
    /// JSON answer, `{"automations": [...]}` (after the change) or an error.
    pub fn automations_control(&mut self, request: AutomationsRequest) -> Value {
        let result = match request {
            AutomationsRequest::List => Ok(None),
            AutomationsRequest::Update { id, action } => {
                if !UPDATE_ACTIONS.contains(&action.as_str()) {
                    return json!({"error": {"code": "bad_request", "message": format!("action is one of {}", UPDATE_ACTIONS.join(", "))}});
                }
                self.update_automation(&id, &action)
                    .map(|(kind, _)| Some(kind))
            }
        };
        match result {
            Ok(outcome) => {
                let mut answer = json!({
                    "automations": self.state.automations.iter().map(Automation::to_json).collect::<Vec<_>>(),
                });
                if let Some(outcome) = outcome {
                    answer["outcome"] = json!(outcome);
                }
                answer
            }
            Err(message) => json!({"error": {"code": "not_found", "message": message}}),
        }
    }

    /// When the brain must look at its automations next: the soonest
    /// schedule.
    pub(super) fn next_automation_due(&self) -> Option<Instant> {
        let now = now_ms();
        let at = |ms: u64| Instant::now() + Duration::from_millis(ms.saturating_sub(now));
        self.state
            .automations
            .iter()
            .filter(|a| !a.paused)
            .filter_map(|a| a.next_ms)
            .min()
            .map(at)
            // An Instant stands still while the Mac sleeps: look at the wall
            // clock again at least once a minute, so a 9:00 fire after a
            // night's sleep comes at wake, not hours later.
            .map(|due| due.min(Instant::now() + SCHEDULE_RECHECK))
    }

    /// Fires every schedule due at `now_ms` (wall clock). A schedule missed
    /// while the host was down or the Mac slept fires once and goes on from
    /// now.
    pub fn fire_automations_at(&mut self, now_ms: u64) {
        let due: Vec<usize> = self
            .state
            .automations
            .iter()
            .enumerate()
            .filter(|(_, a)| !a.paused && a.next_ms.is_some_and(|at| at <= now_ms))
            .map(|(i, _)| i)
            .collect();
        let mut fired = false;
        for index in due {
            let at = self.state.automations[index].next_ms.unwrap_or(now_ms);
            let late = now_ms.saturating_sub(at) / 1000;
            let why = if late > 60 {
                format!(
                    "at {}, {} min late: this Mac's Chief was not running then",
                    crate::automations::local_time(at),
                    late / 60
                )
            } else {
                format!("at {}", crate::automations::local_time(at))
            };
            self.fire(index, now_ms, None, &why);
            schedule(&mut self.state.automations[index], now_ms);
            fired = true;
        }
        if fired {
            self.save();
        }
    }

    /// Something happened: every automation that waits for it fires, once.
    pub fn automation_event(&mut self, event: Event) {
        let now = (self.clock)();
        let firing: Vec<usize> = self
            .state
            .automations
            .iter()
            .enumerate()
            .filter(|(_, a)| event.fires(a))
            .map(|(i, _)| i)
            .collect();
        if firing.is_empty() {
            return;
        }
        let key = event.key();
        let why = event.why();
        for index in firing {
            self.fire(index, now, Some(&key), &why);
        }
        self.save();
    }

    /// Records a fire of automation `index` and queues its note.
    fn fire(&mut self, index: usize, now: u64, key: Option<&str>, why: &str) {
        let automation = &mut self.state.automations[index];
        automation.record_fire(now, key);
        let note = automation.note(why);
        let id = automation.id.clone();
        (self.log)(&format!("automation {id} fires {why}"));
        self.trace
            .emit("automation.fire", json!({"id": id, "key": key}));
        self.queue(note, Source::Note);
    }
}

/// Sets `automation`'s next fire after `now` (none while paused or for an
/// event trigger).
fn schedule(automation: &mut Automation, now: u64) {
    automation.next_ms = match (&automation.trigger, automation.paused) {
        (Trigger::Schedule { cron }, false) => {
            Cron::parse(cron).ok().and_then(|c| c.next_local_ms(now))
        }
        _ => None,
    };
}

/// Whether a queued item is an automation's note (the brain's own, never a
/// person's message that only looks like one).
pub(super) fn is_automation_note(item: &super::Queued) -> bool {
    item.source == Source::Note && item.text.starts_with("[automation au")
}
