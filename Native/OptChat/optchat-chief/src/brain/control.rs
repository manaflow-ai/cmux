//! `control(action, ...)`: the Chief's control over its subagents
//! (DESIGN 2026-10-19, Lawrence: "fix such that you can interrupt sessions
//! better"). Every answer starts with `outcome: done|queued|noop|refused`,
//! and every action checks state first, so a repeat is a `noop`, never a
//! second effect and never an unknown outcome.
//!
//! - `status [id]`: state, elapsed, last output, pending prompt, inbox.
//! - `interrupt id [message]`: `session/cancel` now; the cut run reports
//!   nothing when a message follows, the message is its next prompt.
//! - `answer id option|deny`: its pending permission prompt.
//! - `pause id` / `resume id [message]`: held (no auto-resume, inbox kept).
//! - `cancel id`: over for good (its transcript stays for `zoom`).
//! - `restart id [message]`: stop the turn, continue in the same session.
//! - `priority id`: a queued one starts next. `cap n`: the live cap.
//!
//! Pushed to the Chief, never polled: reports (spawns.rs), prompts
//! (`permission_note`), stuck runs (`sub_tick`) and delivered inboxes.

use std::time::Duration;

use cmux_chief::acp::SessionSummary;
use serde_json::{Value, json};

use super::{Brain, Source};
use crate::state::{SubRecord, SubStatus};
use crate::tools::ControlCall;

/// A running subagent whose session did not change for this long gets one
/// stuck note per run.
pub(super) const STUCK_AFTER: Duration = Duration::from_secs(15 * 60);
/// How often the brain checks for stuck subagents.
pub(super) const TICK: Duration = Duration::from_secs(60);
/// The prompt `restart` sends when it is given none.
pub(super) const RESTART_PROMPT: &str = "Continue from where you stopped.";
/// The prompt `resume` sends when it is given none.
pub(super) const RESUME_PROMPT: &str = "Continue.";
/// Most subagents `status` lists.
const STATUS_MAX: usize = 40;
/// Characters kept of a last output line.
const LINE_CHARS: usize = 200;

fn now_ms() -> u64 {
    super::now_ms()
}

fn outcome(kind: &str, text: impl AsRef<str>) -> Result<String, String> {
    Ok(format!("outcome: {kind}. {}", text.as_ref()))
}

/// The state `status` names for one subagent.
pub(super) fn state_name(sub: &SubRecord, now: u64) -> &'static str {
    if sub.cancelled {
        return "cancelled";
    }
    if sub.paused {
        return "paused";
    }
    match sub.status {
        SubStatus::Queued => "queued",
        SubStatus::Starting => "starting",
        SubStatus::Running if sub.permission.is_some() => "waiting-on-permission",
        SubStatus::Running if stuck(sub, now) => "stuck",
        SubStatus::Running => "running",
        SubStatus::Done | SubStatus::Reported => {
            let report = sub.report.as_deref().unwrap_or("");
            if report.starts_with("(failed") || report.starts_with("(did not start") {
                "failed"
            } else if sub.stopped {
                "stopped"
            } else {
                "idle"
            }
        }
    }
}

fn stuck(sub: &SubRecord, now: u64) -> bool {
    let since = sub.active_ms.max(sub.run_ms);
    since > 0 && now.saturating_sub(since) >= STUCK_AFTER.as_millis() as u64
}

fn minutes(ms: u64) -> String {
    let s = ms / 1000;
    if s < 60 {
        format!("{s}s")
    } else if s < 3600 {
        format!("{}m", s / 60)
    } else {
        format!("{}h{:02}m", s / 3600, (s % 3600) / 60)
    }
}

fn clip(text: &str) -> String {
    let line = text
        .lines()
        .rev()
        .find(|l| !l.trim().is_empty())
        .unwrap_or("")
        .trim();
    if line.chars().count() <= LINE_CHARS {
        line.to_owned()
    } else {
        let mut cut: String = line.chars().take(LINE_CHARS).collect();
        cut.push('…');
        cut
    }
}

/// A permission prompt's title and option ids, as the request has them.
pub(super) fn prompt_parts(request: &Value) -> (String, Vec<(String, String)>) {
    let call = request.get("toolCall").unwrap_or(request);
    let title = call
        .get("title")
        .and_then(Value::as_str)
        .or_else(|| request.get("title").and_then(Value::as_str))
        .unwrap_or("a permission")
        .to_owned();
    let options = request
        .get("options")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|o| {
            let id = o.get("optionId").and_then(Value::as_str)?;
            let name = o
                .get("name")
                .and_then(Value::as_str)
                .or_else(|| o.get("kind").and_then(Value::as_str))
                .unwrap_or(id);
            Some((id.to_owned(), name.to_owned()))
        })
        .collect();
    (title, options)
}

/// A subagent's permission prompt as the Chief's note: the prompt, its
/// options, and how to answer, steer or ask the user.
pub(super) fn permission_note(id: &str, request: &Value) -> String {
    let (title, options) = prompt_parts(request);
    let input = request
        .get("toolCall")
        .and_then(|c| c.get("rawInput"))
        .map(|v| {
            let text = v.to_string();
            let text: String = text.chars().take(600).collect();
            format!("\nInput: {text}")
        })
        .unwrap_or_default();
    let options = if options.is_empty() {
        "(none listed)".to_owned()
    } else {
        options
            .iter()
            .map(|(id, name)| format!("{id} ({name})"))
            .collect::<Vec<_>>()
            .join(", ")
    };
    format!(
        "[{id}] waits on a prompt: {title}{input}\nOptions: {options}\nAnswer: control(action: \"answer\", id: \"{id}\", option: OPTION_ID or \"deny\"). Or steer it: control(action: \"interrupt\", id: \"{id}\", message: \"do this instead\"). Approve only safe steps (reads, edits and tests in its worktree); ask the user for money, legal, destructive or credential steps."
    )
}

impl Brain {
    /// Serves one `control` call.
    pub(super) fn control(&mut self, call: &ControlCall) -> Result<String, String> {
        if call.action == "cap" {
            return self.control_cap(call.n.unwrap_or(0) as usize);
        }
        if call.action == "status" && call.id.is_none() {
            return Ok(self.status_all());
        }
        let id = call.id.as_deref().unwrap_or_default();
        let Some((_, sub)) = self.state.sub(id) else {
            return Err(format!("no subagent {id}"));
        };
        let sub = sub.clone();
        self.trace
            .emit("control", json!({"action": call.action, "id": id}));
        let message = call.message.as_deref();
        match call.action.as_str() {
            "status" => Ok(self.status_line(&sub, true)),
            "interrupt" => self.control_interrupt(&sub, message),
            "answer" => self.control_answer(&sub, call.option.as_deref().unwrap_or("deny")),
            "pause" => self.control_pause(&sub),
            "resume" => self.control_resume(&sub, message),
            "cancel" => self.control_cancel(&sub),
            "restart" => self.control_restart(&sub, message),
            "priority" => self.control_priority(&sub),
            other => Err(format!("control: no action {other}")),
        }
    }

    fn status_all(&self) -> String {
        let now = now_ms();
        let mut subs: Vec<&SubRecord> = self
            .state
            .spawns
            .values()
            .flat_map(|r| r.subs.iter())
            .filter(|s| {
                s.status != SubStatus::Reported || now.saturating_sub(s.run_ms) < 2 * 3600 * 1000
            })
            .collect();
        subs.sort_by_key(|s| {
            std::cmp::Reverse(s.id.trim_start_matches('a').parse::<u64>().unwrap_or(0))
        });
        let total = subs.len();
        let mut lines: Vec<String> = subs
            .into_iter()
            .take(STATUS_MAX)
            .map(|s| self.status_line(s, false))
            .collect();
        if total > STATUS_MAX {
            lines.push(format!("(and {} older)", total - STATUS_MAX));
        }
        let cap = match self.live_cap() {
            Some(n) => format!("cap {n}"),
            None => "no cap".to_owned(),
        };
        let head = format!(
            "outcome: done. {} at work ({cap}); subagents of the last 2 h, newest first:",
            self.live_subs()
        );
        if lines.is_empty() {
            return "outcome: done. No subagents in the last 2 h.".to_owned();
        }
        format!("{head}\n{}", lines.join("\n"))
    }

    /// One subagent's status; `full` adds its last output and prompt.
    fn status_line(&self, sub: &SubRecord, full: bool) -> String {
        let now = now_ms();
        let state = state_name(sub, now);
        let mut line = format!(
            "- {} [{state}] {} for {}",
            sub.id,
            sub.title,
            minutes(now.saturating_sub(sub.run_ms))
        );
        if !sub.inbox.is_empty() {
            line.push_str(&format!("; {} message(s) waiting", sub.inbox.len()));
        }
        if let Some(p) = &sub.permission {
            let (title, options) = prompt_parts(&p.request);
            let ids: Vec<&str> = options.iter().map(|(id, _)| id.as_str()).collect();
            line.push_str(&format!("; prompt: {title} [{}]", ids.join(", ")));
        }
        if sub.priority != 0 {
            line.push_str(&format!("; priority {}", sub.priority));
        }
        if !full {
            return line;
        }
        let summary: Option<SessionSummary> = sub
            .session_id
            .as_deref()
            .and_then(|s| self.agents.session(s).ok().flatten());
        let mut out = format!("outcome: done. {line}");
        if let Some(s) = &summary {
            out.push_str(&format!("\nsession: {} ({:?})", s.session_id, s.status));
            if let Some(m) = &s.last_message {
                out.push_str(&format!("\nlast {}: {}", m.role, clip(&m.text)));
            } else if let Some(p) = &s.preview {
                out.push_str(&format!("\nlast: {}", clip(p)));
            }
            if let Some(p) = &s.last_prompt {
                out.push_str(&format!("\nlast prompt: {}", clip(p)));
            }
        } else if sub.session_id.is_none() {
            out.push_str("\nno session yet");
        }
        if let Some(r) = sub.report.as_deref().filter(|_| state != "running") {
            out.push_str(&format!("\nlast report: {}", clip(r)));
        }
        if let Some(p) = &sub.permission {
            out.push('\n');
            out.push_str(&permission_note(&sub.id, &p.request));
        }
        out
    }

    fn running(sub: &SubRecord) -> bool {
        sub.status == SubStatus::Running && sub.session_id.is_some()
    }

    fn control_interrupt(
        &mut self,
        sub: &SubRecord,
        message: Option<&str>,
    ) -> Result<String, String> {
        let id = sub.id.as_str();
        if !Self::running(sub) {
            return match (message, sub.session_id.is_some()) {
                (Some(m), _) => self
                    .tell_keyed(id, m, None)
                    .map(|a| a.replacen("outcome: done.", "outcome: done. It was not running;", 1)),
                (None, _) => outcome(
                    "noop",
                    format!("{id} is not running a turn ({})", state_name(sub, now_ms())),
                ),
            };
        }
        let session = sub.session_id.clone().unwrap_or_default();
        if let Some(sub) = self.state.sub_mut(id) {
            sub.after_stop = message.map(str::to_owned);
        }
        self.save();
        if let Err(e) = self.agents.cancel(&session) {
            if let Some(sub) = self.state.sub_mut(id) {
                sub.after_stop = None;
            }
            self.save();
            return outcome("refused", format!("{id} could not be interrupted: {e}"));
        }
        self.trace.emit(
            "control.interrupt",
            json!({"id": id, "follow": message.is_some()}),
        );
        match message {
            Some(_) => outcome(
                "done",
                format!(
                    "{id} is interrupted; its turn stops now and your message is its next prompt"
                ),
            ),
            None => outcome(
                "done",
                format!("{id} is interrupted; it keeps its context; tell it what to do next"),
            ),
        }
    }

    fn control_answer(&mut self, sub: &SubRecord, option: &str) -> Result<String, String> {
        let id = sub.id.as_str();
        let (Some(p), Some(session)) = (sub.permission.clone(), sub.session_id.clone()) else {
            return outcome("noop", format!("{id} has no pending prompt"));
        };
        let (_, options) = prompt_parts(&p.request);
        let deny = option.eq_ignore_ascii_case("deny");
        // Spawned under the ask floor (a remote-origin turn): a person
        // answers its prompts, never the Chief.
        if !deny && sub.policy.as_deref() == Some(crate::approval::ASK) {
            return outcome(
                "refused",
                format!(
                    "{id} runs under the ask floor: a person answers its prompts in the Chief chat; you may deny or steer it"
                ),
            );
        }
        if !deny && !options.is_empty() && !options.iter().any(|(o, _)| o == option) {
            let ids: Vec<&str> = options.iter().map(|(o, _)| o.as_str()).collect();
            return outcome(
                "refused",
                format!(
                    "{id}'s prompt has no option {option}; its options: {}, or deny",
                    ids.join(", ")
                ),
            );
        }
        let answer = if deny { None } else { Some(option) };
        match self.agents.respond_permission(&session, &p.id, answer) {
            Ok(()) => {
                if let Some(sub) = self.state.sub_mut(id) {
                    sub.permission = None;
                }
                self.save();
                self.trace
                    .emit("control.answer", json!({"id": id, "option": option}));
                outcome("done", format!("{id}'s prompt is answered: {option}"))
            }
            Err(e) => outcome(
                "refused",
                format!(
                    "{id}'s prompt was not answered ({e}). acpmux takes an allow only from the person's app; deny works, or steer it: control(action: \"interrupt\", id: \"{id}\", message: \"...\"), or ask the user to answer in its workspace"
                ),
            ),
        }
    }

    fn control_pause(&mut self, sub: &SubRecord) -> Result<String, String> {
        let id = sub.id.as_str();
        if sub.paused {
            return outcome("noop", format!("{id} is paused already"));
        }
        if sub.cancelled {
            return outcome("noop", format!("{id} was cancelled"));
        }
        let running = Self::running(sub);
        if let Some(sub) = self.state.sub_mut(id) {
            sub.paused = true;
        }
        self.save();
        if running
            && let Err(e) = self
                .agents
                .cancel(sub.session_id.as_deref().unwrap_or_default())
        {
            return outcome(
                "refused",
                format!("{id} is marked paused, but its turn did not stop: {e}"),
            );
        }
        outcome(
            "done",
            format!("{id} is paused; messages wait in its inbox until control resume"),
        )
    }

    fn control_resume(&mut self, sub: &SubRecord, message: Option<&str>) -> Result<String, String> {
        let id = sub.id.as_str();
        if sub.cancelled {
            return outcome(
                "refused",
                format!(
                    "{id} was cancelled; control(action: \"restart\", id: \"{id}\") brings it back"
                ),
            );
        }
        let was_paused = sub.paused;
        if let Some(s) = self.state.sub_mut(id) {
            s.paused = false;
        }
        self.save();
        match sub.status {
            SubStatus::Queued => {
                if let Some(m) = message {
                    let _ = self.tell_keyed(id, m, None);
                }
                self.start_queued();
                return outcome(
                    "done",
                    format!("{id} is queued again; it starts when there is room"),
                );
            }
            SubStatus::Starting => {
                if let Some(m) = message {
                    let _ = self.tell_keyed(id, m, None);
                }
                return outcome(
                    "queued",
                    format!("{id} is starting; it gets its messages then"),
                );
            }
            SubStatus::Running if !was_paused => {
                return match message {
                    Some(m) => self.tell_keyed(id, m, None),
                    None => outcome("noop", format!("{id} is running")),
                };
            }
            _ => {}
        }
        if sub.session_id.is_none() {
            return outcome(
                "refused",
                format!("{id} never started; spawn its task again"),
            );
        }
        let text = message.unwrap_or(RESUME_PROMPT);
        if let Some(s) = self.state.sub_mut(id) {
            s.inbox.insert(
                0,
                crate::state::InboxMessage {
                    text: text.to_owned(),
                    at_ms: now_ms(),
                },
            );
        }
        let waiting = self.state.sub(id).map_or(0, |(_, s)| s.inbox.len());
        self.flush_inbox(id);
        let left = self.state.sub(id).map_or(0, |(_, s)| s.inbox.len());
        if left == waiting {
            return outcome(
                "refused",
                format!("{id} could not be resumed; see its status"),
            );
        }
        outcome("done", format!("{id} resumed with {waiting} message(s)"))
    }

    fn control_cancel(&mut self, sub: &SubRecord) -> Result<String, String> {
        let id = sub.id.as_str();
        if sub.cancelled {
            return outcome("noop", format!("{id} was cancelled already"));
        }
        if let Some(s) = self.state.sub_mut(id) {
            s.cancelled = true;
            s.inbox.clear();
            s.after_stop = None;
        }
        self.save();
        match sub.status {
            SubStatus::Queued => {
                self.stop_subagent(id);
                outcome("done", format!("{id} is cancelled; it never started"))
            }
            SubStatus::Starting | SubStatus::Running => match sub.session_id.as_deref() {
                Some(session) => match self.agents.cancel(session) {
                    Ok(()) => outcome(
                        "done",
                        format!(
                            "{id} is cancelled; its turn stops now; its chat stays for zoom(\"{id}\")"
                        ),
                    ),
                    Err(e) => outcome(
                        "refused",
                        format!("{id} is marked cancelled, but its turn did not stop: {e}"),
                    ),
                },
                None => outcome(
                    "done",
                    format!("{id} is cancelled; it is still starting and gets nothing more"),
                ),
            },
            SubStatus::Done | SubStatus::Reported => {
                outcome("done", format!("{id} was idle; it is cancelled now"))
            }
        }
    }

    fn control_restart(
        &mut self,
        sub: &SubRecord,
        message: Option<&str>,
    ) -> Result<String, String> {
        let id = sub.id.as_str();
        let text = message.unwrap_or(RESTART_PROMPT).to_owned();
        if let Some(s) = self.state.sub_mut(id) {
            s.cancelled = false;
            s.paused = false;
            s.resume_attempts = 0;
        }
        self.save();
        if Self::running(sub) {
            return self
                .control_interrupt(sub, Some(&text))
                .map(|a| a.replacen("is interrupted", "restarts: its turn is interrupted", 1));
        }
        match (sub.status, sub.session_id.is_some()) {
            (SubStatus::Queued, _) => {
                let _ = self.tell_keyed(id, &text, None);
                self.control_priority(sub)
            }
            (SubStatus::Starting, _) => self.tell_keyed(id, &text, None),
            (_, true) => self.tell_keyed(id, &text, None).map(|a| {
                a.replacen(
                    "outcome: done.",
                    "outcome: done. Restarted in the same session;",
                    1,
                )
            }),
            (_, false) => outcome(
                "refused",
                format!("{id} never started; spawn its task again"),
            ),
        }
    }

    fn control_priority(&mut self, sub: &SubRecord) -> Result<String, String> {
        let id = sub.id.as_str();
        if sub.status != SubStatus::Queued {
            return outcome(
                "noop",
                format!("{id} is not queued ({})", state_name(sub, now_ms())),
            );
        }
        let top = self
            .state
            .spawns
            .values()
            .flat_map(|r| r.subs.iter())
            .filter(|s| s.status == SubStatus::Queued)
            .map(|s| s.priority)
            .max()
            .unwrap_or(0);
        if sub.priority == top && top > 0 {
            return outcome("noop", format!("{id} starts next already"));
        }
        if let Some(s) = self.state.sub_mut(id) {
            s.priority = top + 1;
        }
        self.save();
        self.start_queued();
        outcome("done", format!("{id} starts next"))
    }

    fn control_cap(&mut self, n: usize) -> Result<String, String> {
        let before = self.live_cap();
        self.state.live_cap = Some(n);
        self.save();
        self.start_queued();
        let now = match self.live_cap() {
            Some(n) => format!("at most {n} at once"),
            None => "no cap".to_owned(),
        };
        if before == self.live_cap() {
            return outcome("noop", format!("the cap is {now} already"));
        }
        outcome(
            "done",
            format!("subagents: {now}; queued ones start as there is room"),
        )
    }

    /// Once a minute: a running subagent whose session did not change for
    /// [`STUCK_AFTER`] gets one note per run.
    pub(super) fn sub_tick(&mut self) {
        let now = now_ms();
        let stuck_ids: Vec<(String, u64)> = self
            .state
            .spawns
            .values()
            .flat_map(|r| r.subs.iter())
            .filter(|s| {
                Self::running(s)
                    && !s.stuck_noted
                    && !s.paused
                    && s.permission.is_none()
                    && stuck(s, now)
            })
            .map(|s| (s.id.clone(), now.saturating_sub(s.active_ms.max(s.run_ms))))
            .collect();
        for (id, idle) in stuck_ids {
            if let Some(s) = self.state.sub_mut(&id) {
                s.stuck_noted = true;
            }
            self.save();
            self.trace
                .emit("subagent.stuck", json!({"id": id, "idle_ms": idle}));
            self.queue(
                format!(
                    "[{id}] looks stuck: no progress for {}. See control(action: \"status\", id: \"{id}\"); interrupt or restart it if needed.",
                    minutes(idle)
                ),
                Source::Note,
            );
        }
    }
}

/// Sends `SubTick` to the brain every [`TICK`] until the brain is gone.
pub(super) fn start_ticker(tx: std::sync::mpsc::Sender<super::Input>) {
    let _ = std::thread::Builder::new()
        .name("subagent-tick".into())
        .spawn(move || {
            loop {
                // A fixed, intended interval (stuck detection), not a poll
                // of a condition another signal could give.
                std::thread::sleep(TICK);
                if tx.send(super::Input::SubTick).is_err() {
                    return;
                }
            }
        });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_prompt_note_lists_its_options_and_the_policy() {
        let request = json!({
            "toolCall": {"title": "Bash: rm -rf build", "rawInput": {"command": "rm -rf build"}},
            "options": [{"optionId": "allow_once", "name": "Allow"}, {"optionId": "reject", "name": "Reject"}],
        });
        let note = permission_note("a3", &request);
        assert!(note.starts_with("[a3] waits on a prompt: Bash: rm -rf build"));
        assert!(note.contains("allow_once (Allow), reject (Reject)"));
        assert!(note.contains("ask the user for money, legal, destructive or credential steps"));
    }

    #[test]
    fn states_name_what_a_subagent_does() {
        let now = 10 * 3600 * 1000;
        let mut sub = SubRecord {
            id: "a1".into(),
            status: SubStatus::Running,
            session_id: Some("s".into()),
            run_ms: now - 1000,
            active_ms: now - 1000,
            ..SubRecord::default()
        };
        assert_eq!(state_name(&sub, now), "running");
        sub.active_ms = now - STUCK_AFTER.as_millis() as u64 - 1;
        sub.run_ms = sub.active_ms;
        assert_eq!(state_name(&sub, now), "stuck");
        sub.permission = Some(crate::state::PendingPermission::default());
        assert_eq!(state_name(&sub, now), "waiting-on-permission");
        sub.status = SubStatus::Done;
        sub.permission = None;
        sub.report = Some("(failed: boom)".into());
        assert_eq!(state_name(&sub, now), "failed");
        sub.paused = true;
        assert_eq!(state_name(&sub, now), "paused");
        sub.cancelled = true;
        assert_eq!(state_name(&sub, now), "cancelled");
    }
}
