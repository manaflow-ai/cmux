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
//! - `show id` / `hide id`: open or close its sidebar workspace (#26386:
//!   subagents run hidden unless `subagents.showWorkspaces` is on).
//!
//! Pushed to the Chief, never polled: reports (spawns.rs), prompts
//! (`permission_note`), stuck runs (`sub_tick`) and delivered inboxes.
//!
//! Stuck runs (acp-chief-issues.md #4/#5, a204): `sub_tick` reads a quiet
//! subagent's events (sub_watch.rs). One alive in a wait or a tool (Claude
//! Code beats every 30 s) is left alone; one silent for
//! [`crate::sub_watch::STALL_AFTER`] is continued automatically (interrupt,
//! then a continue prompt that names its fleet runs), and the Chief hears of
//! it only when that did not help, or when one wait runs past its limit.

use std::time::Duration;

use cmux_chief::acp::SessionSummary;
use serde_json::{Value, json};

use std::sync::mpsc::Sender;

use super::{Brain, Input, Source};
use crate::state::{SubRecord, SubStatus, WorkspaceSlot};
use crate::tools::ControlCall;

/// A running subagent whose session did not change for this long has its
/// events read (`sub_tick`).
pub(super) const QUIET_AFTER: Duration = Duration::from_secs(5 * 60);
/// Automatic continues of one silent run before the Chief hears of it.
pub(super) const AUTO_CONTINUES: u32 = 2;
/// A session idle this long after its run began, with no turn end since its
/// last report, is done (#7); younger, its first prompt may not have started.
pub(super) const IDLE_GRACE: Duration = Duration::from_secs(2 * 60);
/// A tool heartbeat this recent means the tool is alive: a restart steers
/// instead of killing it (#16).
pub(super) const ALIVE_BEAT: Duration = Duration::from_secs(3 * 60);
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
        SubStatus::Running if quiet(sub, now) => "quiet",
        SubStatus::Running => "running",
        SubStatus::Done | SubStatus::Reported => {
            let report = sub.report.as_deref().unwrap_or("");
            if report.starts_with("(failed") || report.starts_with("(did not start") {
                "failed"
            } else if sub.stopped && report.starts_with("(stopped") {
                "stopped"
            } else {
                "done"
            }
        }
    }
}

/// Its session summary has not changed for [`QUIET_AFTER`]: its events
/// say whether it waits, works or stalled.
fn quiet(sub: &SubRecord, now: u64) -> bool {
    let since = sub.active_ms.max(sub.run_ms);
    since > 0 && now.saturating_sub(since) >= QUIET_AFTER.as_millis() as u64
}

fn minutes(ms: u64) -> String {
    crate::sub_watch::minutes(ms)
}

fn busy(status: cmux_chief::acp::SessionStatus) -> bool {
    use cmux_chief::acp::SessionStatus;
    matches!(status, SessionStatus::Running | SessionStatus::Waiting)
}

/// `text` on one line, at most `n` characters.
fn one_line(text: &str, n: usize) -> String {
    let line: String = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if line.chars().count() <= n {
        line
    } else {
        let mut cut: String = line.chars().take(n).collect();
        cut.push('…');
        cut
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

/// Gives `sub`'s next workspace a fresh key: the session daemon replays a
/// mutation id it has seen, so a closed workspace's key never opens again. A
/// record from before slots were kept gets one (its topic group, the home
/// folder for its terminal).
pub(super) fn retire_slot_key(sub: &mut SubRecord) {
    let slot = sub.workspace_slot.get_or_insert_with(|| WorkspaceSlot {
        key: String::new(),
        group: crate::workspaces::topic_group(&sub.task),
        cwd: std::env::var_os("HOME")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|| std::path::PathBuf::from("/")),
    });
    slot.key = crate::workspaces::new_key();
}

/// A subagent's permission prompt as the Chief's note: the prompt, its
/// options, and how to deny or steer it. Only the person's app can allow
/// (acpmux), so the note never asks the Chief to allow; `shown`: the app
/// shows the prompt with a working Allow button (`approval_shown`).
pub(super) fn permission_note(id: &str, request: &Value, shown: bool) -> String {
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
    let who = if shown {
        format!(
            "Only the user can allow it, with the Allow button in {id}'s workspace; tell them in one line if it matters."
        )
    } else {
        format!(
            "Nobody can allow it: the app shows no working Allow button for {id}. The host denies it after {} s; a hidden local subagent's Allow button shows once control(action: \"show\", id: \"{id}\") opens its workspace.",
            crate::approval::PERMISSION_WAIT.as_secs()
        )
    };
    format!(
        "[{id}] waits on a prompt: {title}{input}\nOptions: {options}\n{who} Deny it: control(action: \"answer\", id: \"{id}\", option: \"deny\"). Or steer it: control(action: \"interrupt\", id: \"{id}\", message: \"do this instead\")."
    )
}

impl Brain {
    /// Serves one `control` call.
    pub(super) fn control(&mut self, call: &ControlCall) -> Result<String, String> {
        if call.action == "cap" {
            return self.control_cap(call.n.unwrap_or(0) as usize);
        }
        if call.action == "cloud" {
            return self.control_cloud(call.peer.as_deref());
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
            "status" => {
                let watch = self.refresh_watch(id).cloned().unwrap_or_default();
                let sub = self.state.sub(id).map_or(sub, |(_, s)| s.clone());
                Ok(self.status_line(&sub, Some(&watch)))
            }
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

    /// Serves `control show|hide id`: opens or closes the subagent's sidebar
    /// workspace on a thread (the session daemon's I/O never runs on the
    /// brain's loop), which answers `reply` once it is done. The record
    /// changes first, so a second `show` while one opens is a noop.
    pub(super) fn control_workspace(
        &mut self,
        call: &ControlCall,
        reply: Sender<Result<String, String>>,
    ) {
        let id = call.id.clone().unwrap_or_default();
        let Some((_, sub)) = self.state.sub(&id) else {
            let _ = reply.send(Err(format!("no subagent {id}")));
            return;
        };
        let sub = sub.clone();
        self.trace
            .emit("control", json!({"action": call.action, "id": id}));
        let Some(workspaces) = self.workspaces.clone() else {
            let _ = reply.send(outcome(
                "refused",
                "this Chief host has no cmux session to make workspaces in",
            ));
            return;
        };
        let log = self.log.clone();
        if call.action == "hide" {
            let Some(key) = sub.workspace.clone() else {
                let _ = reply.send(outcome(
                    "noop",
                    format!("{id} has no workspace; it runs hidden"),
                ));
                return;
            };
            if let Some(s) = self.state.sub_mut(&id) {
                s.workspace = None;
                retire_slot_key(s);
            }
            self.save();
            self.rewatch_permission(&id);
            std::thread::spawn(move || {
                let mut text = format!(
                    "closed {id}'s workspace; it goes on hidden, its link still opens its chat, and control(action: \"show\", id: \"{id}\") opens a new one"
                );
                // A workspace the user closed already fails here; the record
                // stays hidden either way, so a later `show` opens a new one.
                if let Err(e) = workspaces.close(&key) {
                    log(&format!("subagent {id}: closing its workspace: {e}"));
                    text.push_str(&format!(
                        " (closing said: {e}; the user may have closed it already)"
                    ));
                }
                let _ = reply.send(outcome("done", text));
            });
            return;
        }
        if sub.workspace.is_some() {
            let _ = reply.send(outcome("noop", format!("{id} already has its workspace (closed by the user? hide, then show, opens a new one)")));
            return;
        }
        let Some(session) = sub.session_id.clone() else {
            let _ = reply.send(outcome(
                "refused",
                format!("{id} has not started yet; show it once it runs"),
            ));
            return;
        };
        // Its slot comes right after its start: a show before it would open
        // a second workspace beside the one the spawn may open.
        if sub.workspace_slot.is_none() && sub.status == SubStatus::Starting {
            let _ = reply.send(outcome(
                "refused",
                format!("{id} is still starting; show it once it runs"),
            ));
            return;
        }
        let mut record = sub.clone();
        if record.workspace_slot.is_none() {
            retire_slot_key(&mut record);
        }
        let slot = record.workspace_slot.take().unwrap_or_default();
        let name = if sub.title.is_empty() {
            crate::workspaces::title(&sub.task)
        } else {
            sub.title.clone()
        };
        if let Some(s) = self.state.sub_mut(&id) {
            s.workspace = Some(slot.key.clone());
            s.workspace_slot = Some(slot.clone());
        }
        self.save();
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            let answer = match workspaces.open(&slot.key, &session, &name, &slot.group, &slot.cwd) {
                Ok(key) => {
                    let mut note = format!(
                        "{id} has its workspace \"{name}\" in group \"{}\" in {}",
                        slot.group,
                        workspaces.place()
                    );
                    if let Some(r) = workspaces.locate(&key) {
                        note.push_str(&format!(" (id {})", r.id));
                    }
                    let _ = tx.send(Input::SubagentWorkspaceShown { id, key, name });
                    outcome("done", note)
                }
                Err(e) => {
                    log(&format!("subagent {id}: opening its workspace: {e}"));
                    let _ = tx.send(Input::SubagentWorkspaceFailed {
                        id: id.clone(),
                        key: slot.key,
                    });
                    outcome("refused", format!("opening {id}'s workspace: {e}"))
                }
            };
            let _ = reply.send(answer);
        });
    }

    fn status_all(&self) -> String {
        let now = self.now();
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
            .map(|s| self.status_line(s, None))
            .collect();
        if total > STATUS_MAX {
            lines.push(format!("(and {} older)", total - STATUS_MAX));
        }
        let cap = match self.live_cap() {
            Some(n) => format!("cap {n}"),
            None => "no cap".to_owned(),
        };
        // #19: how many of those at work only wait on the fleet (or another
        // run): with many waiting, a lower cap frees no Mac, more spawns
        // only lengthen the queue.
        let mut by_state: std::collections::BTreeMap<&str, usize> = Default::default();
        for sub in self
            .state
            .spawns
            .values()
            .flat_map(|r| r.subs.iter())
            .filter(|s| s.at_work())
        {
            *by_state.entry(self.state_of(sub, now)).or_default() += 1;
        }
        let states = by_state
            .iter()
            .map(|(k, n)| format!("{n} {k}"))
            .collect::<Vec<_>>()
            .join(", ");
        let head = format!(
            "outcome: done. {} at work ({cap}){}; subagents of the last 2 h, newest first:",
            self.live_subs(),
            if states.is_empty() {
                String::new()
            } else {
                format!(": {states}")
            }
        );
        if lines.is_empty() {
            return "outcome: done. No subagents in the last 2 h.".to_owned();
        }
        format!("{head}\n{}", lines.join("\n"))
    }

    /// The state a subagent is in: its watch's (thinking, running-tool,
    /// waiting, stalled, done) while it runs, else `state_name`.
    fn state_of(&self, sub: &SubRecord, now: u64) -> &'static str {
        let plain = state_name(sub, now);
        if !matches!(plain, "running" | "quiet") {
            return plain;
        }
        match self.watches.get(&sub.id) {
            Some(w) => w.doing(now).state(),
            None => plain,
        }
    }

    /// The current watch of running subagent `id`: its events since the
    /// last read are folded in (#6). None for one with no session.
    pub(super) fn refresh_watch(&mut self, id: &str) -> Option<&crate::sub_watch::Watch> {
        let (session, floor) = {
            let (_, sub) = self.state.sub(id)?;
            (sub.session_id.clone()?, sub.floor)
        };
        let watch = self
            .watches
            .entry(id.to_owned())
            .or_insert_with(|| crate::sub_watch::Watch::after(floor));
        if watch.seq() < floor {
            *watch = crate::sub_watch::Watch::after(floor);
        }
        match self.agents.events(&session, watch.seq()) {
            Ok(events) => {
                for e in &events {
                    watch.apply(e);
                }
            }
            Err(e) => (self.log)(&format!("subagent {id}: reading its events: {e}")),
        }
        self.watches.get(id)
    }

    /// One subagent's status. With `watch` (a full status): its task, what
    /// it does now, its last line, its pushes and its last report (#6).
    fn status_line(&self, sub: &SubRecord, watch: Option<&crate::sub_watch::Watch>) -> String {
        let now = self.now();
        let state = match watch {
            Some(w) if matches!(state_name(sub, now), "running" | "quiet") => w.doing(now).state(),
            _ => self.state_of(sub, now),
        };
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
        if sub.workspace.is_none() {
            line.push_str("; hidden (no workspace)");
        }
        if sub.auto_continues > 0 {
            line.push_str(&format!("; auto-continued {}x", sub.auto_continues));
        }
        let Some(watch) = watch else {
            return line;
        };
        let mut out = format!("outcome: done. {line}");
        if !sub.task.is_empty() {
            out.push_str(&format!("\ntask: {}", one_line(&sub.task, 240)));
        }
        let running = sub.status == SubStatus::Running;
        for l in watch.summary(now) {
            // A finished run's "doing" is its state; its report says more.
            if !running && l.starts_with("doing:") {
                continue;
            }
            out.push_str(&format!("\n{l}"));
        }
        let summary: Option<SessionSummary> = sub
            .session_id
            .as_deref()
            .and_then(|s| self.agents.session(s).ok().flatten());
        if let Some(s) = &summary {
            out.push_str(&format!("\nsession: {} ({:?})", s.session_id, s.status));
            // The first prompt is the Chief's view and the task (shown
            // above); a later one is a tell or the user's message.
            if let Some(p) = s.last_prompt.as_deref().filter(|p| !p.contains("</chat>")) {
                out.push_str(&format!("\nlast prompt: {}", clip(p)));
            }
        } else if sub.session_id.is_none() {
            out.push_str("\nno session yet");
        }
        if let Some(r) = sub.report.as_deref().filter(|_| !running) {
            out.push_str(&format!("\nlast report: {}", one_line(r, 400)));
        }
        if let Some(p) = &sub.permission {
            out.push('\n');
            out.push_str(&permission_note(
                &sub.id,
                &p.request,
                Self::approval_shown(sub),
            ));
        }
        out
    }

    fn running(sub: &SubRecord) -> bool {
        sub.status == SubStatus::Running && sub.session_id.is_some()
    }

    pub(super) fn control_interrupt(
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
        // #16: the follow-up says what the cut turn was in and which fleet
        // runs to wait on again, so nothing is lost or run twice.
        let now = self.now();
        let note = self.refresh_watch(id).map(|w| w.resume_note(now));
        let follow = message.map(|m| match &note {
            Some(note) => format!("{m}\n\n{note}"),
            None => m.to_owned(),
        });
        if let Some(sub) = self.state.sub_mut(id) {
            sub.after_stop = follow;
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
        // Spawned under the spawn floor (a turn another person started):
        // its local effects are refused, never allowed by the Chief.
        if !deny && sub.policy.as_deref() == Some(crate::approval::ASK) {
            return outcome(
                "refused",
                format!(
                    "{id} runs under the spawn floor of another person's turn: its local effects are refused; you may deny or steer it"
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
        // A deny answers with the prompt's reject option (a cancel when it
        // has none).
        // Never `reject_always`: a lasting rule would refuse a later allow
        // of the person's.
        let reject = p
            .request
            .get("options")
            .and_then(Value::as_array)
            .and_then(|o| {
                o.iter()
                    .find(|o| o.get("kind").and_then(Value::as_str) == Some("reject_once"))
            })
            .and_then(|o| o.get("optionId").and_then(Value::as_str))
            .map(str::to_owned);
        let answer = if deny {
            reject.as_deref()
        } else {
            Some(option)
        };
        match self.agents.respond_permission(&session, &p.id, answer) {
            Ok(()) => {
                if let Some(sub) = self.state.sub_mut(id) {
                    sub.permission = None;
                }
                self.forget_unanswered(&session, &p.id);
                self.save();
                self.trace
                    .emit("control.answer", json!({"id": id, "option": option}));
                outcome("done", format!("{id}'s prompt is answered: {option}"))
            }
            Err(e) if deny => outcome(
                "refused",
                format!("{id}'s prompt was not denied ({e}); it may be answered already"),
            ),
            Err(e) if !e.contains("approve this on the Mac app") => outcome(
                "refused",
                format!("{id}'s prompt was not answered ({e}); it may be answered already"),
            ),
            Err(e) => {
                // acpmux takes an allow only from the person's app (the
                // user's "allow" relayed by the Chief, too). Never leave
                // the prompt open silently: the person hears where to
                // allow it, or, with no working button for it, it is denied
                // so the subagent goes on.
                (self.log)(&format!("allowing {id}'s prompt {}: {e}", p.id));
                let shown = Self::approval_shown(sub);
                let what = crate::approval::describe(
                    &crate::approval::tool_name(&p.request),
                    p.request.pointer("/toolCall/rawInput"),
                );
                if shown {
                    self.tell_person_once(
                        &p.id,
                        &format!(
                            "{id} waits for your approval to {what}: use the Allow button in its workspace."
                        ),
                    );
                    return outcome(
                        "refused",
                        format!(
                            "{id}'s prompt was not allowed: only the user can allow, with the Allow button in {id}'s workspace, and they were just told so in the chat. Do not try to allow it again; you may deny it or steer it: control(action: \"interrupt\", id: \"{id}\", message: \"...\")"
                        ),
                    );
                }
                let denied = self
                    .agents
                    .respond_permission(&session, &p.id, reject.as_deref());
                if denied.is_ok() {
                    if let Some(sub) = self.state.sub_mut(id) {
                        sub.permission = None;
                    }
                    self.forget_unanswered(&session, &p.id);
                    self.save();
                } else {
                    self.watch_unanswered(
                        crate::approval::Pending {
                            session_id: session.clone(),
                            permission_id: p.id.clone(),
                            tool: crate::approval::tool_name(&p.request),
                            request: p.request.clone(),
                            child: Some(id.to_owned()),
                        },
                        super::approvals::NOT_DELIVERED,
                    );
                }
                if denied.is_ok() {
                    self.tell_person_once(
                        &p.id,
                        &format!(
                            "{id} asked to {what}; I denied it, because only the cmux app can approve and it has no Allow button for {id}."
                        ),
                    );
                }
                outcome(
                    "refused",
                    format!(
                        "{id}'s prompt cannot be allowed: only the user's app allows, and it shows no working Allow button for {id}. {} The user was told. Steer it: control(action: \"interrupt\", id: \"{id}\", message: \"...\")",
                        match denied {
                            Ok(()) => "It was denied.".to_owned(),
                            Err(e) => format!(
                                "Denying it failed too ({e}); the host denies it again later."
                            ),
                        }
                    ),
                )
            }
        }
    }

    /// Posts `text` to the person in the main conversation, in the front
    /// desk's voice, once per `permission` (a model that relays the same
    /// "allow" again posts nothing more).
    fn tell_person_once(&mut self, permission: &str, text: &str) {
        let Some(conversation) = self.state.conversation.clone() else {
            return;
        };
        if !self.approval_told.insert(permission.to_owned()) {
            return;
        }
        let key = crate::voice::key(crate::voice::DESK, &format!("approval:{permission}"));
        self.state
            .outbox
            .push(super::reply_entry(conversation, &key, text));
        self.save();
        self.flush_outbox();
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
        // No longer at work: its slot frees now, not when its turn ends.
        self.start_queued();
        match sub.status {
            SubStatus::Queued => {
                self.stop_subagent(id);
                outcome("done", format!("{id} is cancelled; it never started"))
            }
            SubStatus::Starting | SubStatus::Running => match sub.session_id.as_deref() {
                Some(session) => match self.agents.cancel(session) {
                    Ok(()) => {
                        self.end_background_processes(id, session);
                        outcome(
                            "done",
                            format!(
                                "{id} is cancelled; its turn stops now; its chat stays for zoom(\"{id}\")"
                            ),
                        )
                    }
                    Err(e) => outcome(
                        "refused",
                        format!("{id} is marked cancelled, but its turn did not stop: {e}"),
                    ),
                },
                None => outcome(
                    "done",
                    format!(
                        "{id} is cancelled; it is still starting, and its turn stops as soon as it starts"
                    ),
                ),
            },
            SubStatus::Done | SubStatus::Reported => {
                outcome("done", format!("{id} was idle; it is cancelled now"))
            }
        }
    }

    pub(super) fn control_restart(
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
            // #16: one alive in a wait or a tool (a recent heartbeat) keeps
            // it; the message is steered in and read when that call ends.
            // `interrupt` still cuts it.
            let now = self.now();
            let alive = self.refresh_watch(id).and_then(|w| {
                let doing = w.doing(now);
                let beat = match &doing {
                    crate::sub_watch::Doing::Waiting { beat_ago_ms, .. }
                    | crate::sub_watch::Doing::Tool { beat_ago_ms, .. } => *beat_ago_ms,
                    _ => None,
                };
                beat.filter(|ms| *ms < ALIVE_BEAT.as_millis() as u64)
                    .map(|_| doing.label())
            });
            if let Some(label) = alive {
                // `queue`: steered in when it can be, else after the call;
                // never an interrupt.
                return self.tell_with(id, &text, None, true).map(|_| {
                    format!(
                        "outcome: done. {id} is alive, {label}. A restart would kill that call and run it again, so your message is steered in instead; it reads it between its tool calls or when the call ends. To cut it now: control(action: \"interrupt\", id: \"{id}\", message: ...)."
                    )
                });
            }
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

    /// `control cloud [PEER|off]`: shows or sets the acpmux peer new
    /// subagents run on by default (plans/cmux-next/cloud-subagents-DESIGN.md).
    fn control_cloud(&mut self, peer: Option<&str>) -> Result<String, String> {
        let now = |p: Option<&str>| {
            match p {
            Some(crate::subagents::PER_AGENT) => "each new subagent runs in its own Freestyle VM (chief-sub-<id>), sized to its task; tasks that need the Mac stay here (spawn place \"local\" keeps one here, \"cloud:small|medium|large\" picks the size)".to_owned(),
            Some(p) => format!("new subagents run on the cloud peer {p} (spawn place \"local\" keeps one here)"),
            None => "new subagents run on this host (spawn place \"cloud\" needs a peer: control cloud PEER)".to_owned(),
        }
        };
        let current = self.state.cloud_peer.clone();
        // Nothing saved: cloud by default when a pool tool is set up (v2).
        let pool = self.cloud_vms.as_ref().is_some_and(|v| v.available());
        let effective = |saved: &Option<String>| match saved.as_deref() {
            Some("") => None,
            Some(p) => Some(p.to_owned()),
            None if pool => Some(crate::subagents::PER_AGENT.to_owned()),
            None => None,
        };
        let Some(peer) = peer.map(str::trim).filter(|p| !p.is_empty()) else {
            return outcome("noop", now(effective(&current).as_deref()));
        };
        let next = if peer == "off" {
            String::new()
        } else {
            peer.to_owned()
        };
        if current.as_deref() == Some(next.as_str()) {
            return outcome(
                "noop",
                format!("{} already", now(effective(&current).as_deref())),
            );
        }
        self.state.cloud_peer = Some(next);
        self.save();
        (self.log)(&format!("control cloud: {peer}"));
        outcome("done", now(effective(&self.state.cloud_peer).as_deref()))
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

    /// `escalate_auth` from subagent `agent`: the Chief reads it before
    /// anything else queued (`queue_urgent`). Only a known subagent of this
    /// Chief escalates.
    pub(super) fn escalate_auth(
        &mut self,
        agent: &str,
        request: &crate::tools::AuthEscalation,
    ) -> Result<String, String> {
        if self.state.sub(agent).is_none() {
            return Err(format!("escalate_auth: no subagent {agent} on this Chief"));
        }
        self.trace.emit(
            "subagent.escalate_auth",
            json!({"id": agent, "site": request.site, "kind": request.kind}),
        );
        self.queue_urgent(request.note(agent));
        Ok(format!(
            "outcome: done. Your Chief has it now, ahead of its other work: it opens {url} in Home's right pane, fills what it may, presses the passkey or security-key button so macOS shows Touch ID, and asks the user to touch the sensor. It tells you when {site} is signed in. Until then do the parts that need no sign-in; never read or type a password, and do not escalate {site} again.",
            url = request.url,
            site = request.site,
        ))
    }

    /// The clock the watch reads (ms since the epoch).
    pub(super) fn now(&self) -> u64 {
        (self.clock)()
    }

    /// Once a minute: each running subagent whose session summary has not
    /// changed for [`QUIET_AFTER`] has its events read (sub_watch.rs). A
    /// session acpmux no longer runs is settled (#7); one alive in a wait
    /// or a tool is left alone (#4); a silent one is continued
    /// automatically, and the Chief hears of it only when the continues did
    /// not help (#5); one wait or tool past its limit gets one note.
    pub(super) fn sub_tick(&mut self) {
        let now = self.now();
        let quiet_ids: Vec<String> = self
            .state
            .spawns
            .values()
            .flat_map(|r| r.subs.iter())
            .filter(|s| {
                Self::running(s)
                    && !s.stuck_noted
                    && !s.paused
                    && !s.cancelled
                    && s.permission.is_none()
                    && !s.awaiting_task
                    && quiet(s, now)
            })
            .map(|s| s.id.clone())
            .collect();
        for id in quiet_ids {
            self.watch_sub(&id, now);
        }
        let state = &self.state;
        self.watches.retain(|id, _| {
            state
                .sub(id)
                .is_some_and(|(_, s)| s.status == SubStatus::Running)
        });
    }

    fn watch_sub(&mut self, id: &str, now: u64) {
        let Some(session) = self.state.sub(id).and_then(|(_, s)| s.session_id.clone()) else {
            return;
        };
        // #7: acpmux no longer runs it; the host missed (or never got) its end.
        if let Ok(Some(summary)) = self.agents.session(&session)
            && !busy(summary.status)
        {
            // Its turn end is read as usual; idle with none (an interrupt of
            // a session that was idle already) is settled as done.
            self.sub_changed(&summary);
            self.settle_idle(id);
            return;
        }
        let Some(watch) = self.refresh_watch(id) else {
            return;
        };
        let alarm = watch.alarm(now);
        let last_event = watch.last_event_ms();
        let note = watch.resume_note(now);
        let lines = watch.summary(now);
        let Some((_, sub)) = self.state.sub(id) else {
            return;
        };
        let (continues, continued) = (sub.auto_continues, sub.continued_ms);
        match alarm {
            crate::sub_watch::Alarm::None => {}
            crate::sub_watch::Alarm::Stalled { silent_ms } => {
                let stall = crate::sub_watch::STALL_AFTER.as_millis() as u64;
                // A new stall: it did something after the last continue.
                let fresh = continued == 0 || last_event > continued;
                if fresh && continues < AUTO_CONTINUES && self.resume_policy.is_some() {
                    self.auto_continue(id, &session, silent_ms, &note, now);
                } else if now.saturating_sub(continued) >= stall || continued == 0 {
                    let tried = if continues > 0 {
                        format!(
                            ", and {} automatic continue(s) did not help (the last {} ago)",
                            continues,
                            minutes(now.saturating_sub(continued))
                        )
                    } else {
                        String::new()
                    };
                    self.stuck_note(
                        id,
                        format!(
                            "[{id}] is stuck: no event for {}{tried}.",
                            minutes(silent_ms)
                        ),
                        &lines,
                        json!({"id": id, "idle_ms": silent_ms, "after_continue": continues > 0}),
                    );
                }
            }
            crate::sub_watch::Alarm::Overdue { what, for_ms } => {
                self.stuck_note(
                    id,
                    format!(
                        "[{id}] has been {what} for {} (it is alive). The fleet queue: http://100.89.225.106:18765/status. Tell it to stop waiting, or leave it.",
                        minutes(for_ms)
                    ),
                    &lines,
                    json!({"id": id, "overdue_ms": for_ms, "what": what}),
                );
            }
        }
    }

    /// Interrupts silent subagent `id` and sends it a continue prompt that
    /// carries `note` (sub_watch `resume_note`); no note to the Chief.
    fn auto_continue(&mut self, id: &str, session: &str, silent_ms: u64, note: &str, now: u64) {
        let text = format!(
            "[auto-continue] Nothing came from you for {}: no tool ran and nothing streamed, so the host stopped that turn. Continue your task from where you stopped. {note}",
            minutes(silent_ms)
        );
        let attempt = if let Some(sub) = self.state.sub_mut(id) {
            sub.after_stop = Some(text);
            sub.auto_continues += 1;
            sub.continued_ms = now;
            sub.auto_continues
        } else {
            return;
        };
        self.save();
        if let Err(e) = self.agents.cancel(session) {
            (self.log)(&format!(
                "subagent {id}: its automatic continue failed: {e}"
            ));
            if let Some(sub) = self.state.sub_mut(id) {
                sub.after_stop = None;
            }
            self.save();
            return;
        }
        (self.log)(&format!("subagent {id}: silent, continued automatically"));
        self.trace.emit(
            "subagent.auto_continue",
            json!({"id": id, "silent_ms": silent_ms, "attempt": attempt}),
        );
    }

    /// One note to the Chief about subagent `id`, once per run, with what
    /// it does (`lines`) and how to act.
    fn stuck_note(&mut self, id: &str, head: String, lines: &[String], trace: Value) {
        if let Some(s) = self.state.sub_mut(id) {
            s.stuck_noted = true;
        }
        self.save();
        self.trace.emit("subagent.stuck", trace);
        let task = self
            .state
            .sub(id)
            .map(|(_, s)| one_line(&s.task, 160))
            .filter(|t| !t.is_empty())
            .map(|t| format!("\ntask: {t}"))
            .unwrap_or_default();
        self.queue(
            format!(
                "{head}{task}\n{}\nAct: control(action: \"restart\", id: \"{id}\", message: ...) or control(action: \"cancel\", id: \"{id}\").",
                lines.join("\n")
            ),
            Source::Note,
        );
    }

    /// Subagent `id`'s session is idle with no turn end since its last
    /// report (#7: a51, a60, a62 stayed "at work" for 15 h): it is done,
    /// quietly. A follow-up the Chief queued (`after_stop`) is sent when
    /// fresh and dropped when the run has been quiet for an hour.
    fn settle_idle(&mut self, id: &str) {
        let now = self.now();
        let Some((_, sub)) = self.state.sub(id) else {
            return;
        };
        if sub.status != SubStatus::Running
            || sub.awaiting_task
            || now.saturating_sub(sub.run_ms) < IDLE_GRACE.as_millis() as u64
        {
            return;
        }
        let stale = now.saturating_sub(sub.active_ms.max(sub.run_ms)) >= 3600 * 1000;
        if stale
            && let Some(s) = self.state.sub_mut(id)
            && let Some(dropped) = s.after_stop.take()
        {
            (self.log)(&format!(
                "subagent {id}: dropped a follow-up an hour old: {}",
                one_line(&dropped, 120)
            ));
        }
        self.trace.emit("subagent.settled_idle", json!({"id": id}));
        self.sub_done(
            id,
            "(idle: its session went idle with no new reply since its last report)".into(),
            true,
            None,
            None,
        );
    }
}

/// How often the host checks its cloud VMs for idle ones: a VM pauses at
/// most this long after `cloud.autoPauseIdleSeconds`.
pub(super) const CLOUD_TICK: Duration = Duration::from_secs(5);

/// Sends `CloudTick` to the brain every [`CLOUD_TICK`] until it is gone.
pub(super) fn start_cloud_ticker(tx: std::sync::mpsc::Sender<super::Input>) {
    let _ = std::thread::Builder::new()
        .name("cloud-tick".into())
        .spawn(move || {
            loop {
                // A fixed, intended interval (idle VM check), not a poll for
                // a result.
                std::thread::sleep(CLOUD_TICK);
                if tx.send(super::Input::CloudTick).is_err() {
                    return;
                }
            }
        });
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
        let note = permission_note("a3", &request, true);
        assert!(note.starts_with("[a3] waits on a prompt: Bash: rm -rf build"));
        assert!(note.contains("allow_once (Allow), reject (Reject)"));
        assert!(note.contains("Only the user can allow it"));
        assert!(permission_note("a3", &request, false).contains("Nobody can allow it"));
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
        // Quiet only: its events (sub_watch.rs) say whether it is stuck.
        sub.active_ms = now - QUIET_AFTER.as_millis() as u64 - 1;
        sub.run_ms = sub.active_ms;
        assert_eq!(state_name(&sub, now), "quiet");
        sub.permission = Some(crate::state::PendingPermission::default());
        assert_eq!(state_name(&sub, now), "waiting-on-permission");
        sub.status = SubStatus::Done;
        sub.permission = None;
        sub.report = Some("all landed".into());
        assert_eq!(state_name(&sub, now), "done");
        sub.report = Some("(failed: boom)".into());
        assert_eq!(state_name(&sub, now), "failed");
        sub.paused = true;
        assert_eq!(state_name(&sub, now), "paused");
        sub.cancelled = true;
        assert_eq!(state_name(&sub, now), "cancelled");
    }
}
