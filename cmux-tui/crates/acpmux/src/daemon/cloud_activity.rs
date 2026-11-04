//! On a cmux Cloud machine, this daemon's chats at work count as the machine's activity, so the
//! Cloud never pauses a machine for idleness while one of its chats runs a turn.
//!
//! The machine's Cloud agent (cmux-host `cloud/session.rs`) sends the machine's activity report
//! (`cloud.vm.status.report`), and the Cloud pauses a machine whose report shows no open session
//! and no recent input or agent action. The terminal daemon's count (`subscribe-activity`) sees
//! attached terminals and hook-reported agents, never an ACP chat's turn, so a Cloud chat mid-turn
//! with no app attached looked idle.
//!
//! So this daemon tells the agent, as one `{"acp_activity": {"turns": n,
//! "last_agent_action_at": ms}}` line per connection on its socket, how many of its own sessions
//! are at work ([`crate::hub::Hub::sessions_at_work`]: a turn running, queued, awaiting a
//! permission or question, a continuation pending, a background task, subagent or sub-session at
//! work) and when its agents last acted (a turn's start or end, a tool call, a permission
//! request). A line goes when the count changes, when an agent acted with none at work (a turn's
//! `turn_result` read after its end already counted 0), and every [`RENEW`] in any case. The
//! agent forgets the count 90 s after the last line, so a daemon that died mid-turn does not keep
//! the machine awake forever, and it advertises `activity-turns` (the Cloud's go-ahead for a
//! short idle pause) only while these lines arrive, so an agent that restarted never reports 0
//! sessions as known before acpmux told it. A tool call between lines reaches the agent with the
//! next line; while a session is at work the machine is not idle anyway.
//!
//! Three rules keep a turn from looking idle (cmux#33328, #33329, #33330):
//! - Until this daemon's startup settles ([`crate::hub::Hub::startup_settled`]: the store and
//!   chat logs loaded, adoption done), it reports at least one session at work: a turn in an
//!   agent host that outlived the last daemon, or a cut turn about to resume, is not counted yet.
//! - The line that first says 0 at work after a count above 0 (or after startup) carries the
//!   time it was observed as the last action, so a quiet turn that just ended never reports an
//!   old tool call's time before its `turn_result` is read.
//! - Each line names its daemon (`"daemon"`: its socket path), so the agent keeps one count per
//!   daemon on the machine and adds them instead of letting an idle daemon's renewal replace a
//!   busy one's.
//!
//! Each line also carries `last_person_prompt_at` (Unix ms) once a person prompted one of this
//! daemon's chats ([`crate::hub::Hub::last_person_prompt_at`]: never an agent's message, a
//! trigger's delivery or a send from inside a session). The Cloud keeps the machine running for a
//! while after a person's chat (cmux-platform `IdlePolicy.ts`, the post-chat warm window; off with
//! `CLOUD_POST_CHAT_WARM_SECONDS=0`), and a chat's prompt is the only input of the person's a
//! Cloud chat makes. A new prompt time goes at once. It never moves backwards, and like the rest
//! of this report it lives in memory only.
//!
//! Each line also says what every session at work waits on (`"phases"`, capability
//! `activity-phases`), so the Cloud can tell a turn that only waits on the model from one that
//! runs a tool in the guest (cmux#34298):
//! `{"relayed": false, "turns": [{"phase", "since", "processes", "attached"}]}`, one entry per
//! session at work, in the order of their ids.
//! - `phase`: `tool` while one of its ACP tool calls is open (`tool_call` / `tool_call_update`
//!   at `in_progress`, until `completed` or `failed`); else `tool-starting` while a call is named
//!   but its input still streams (`crate::hub::tool_start`: Claude's block started, so a tool
//!   will run within seconds: the early wake; the Cloud reads any phase but `model-wait` as
//!   awake, so a sleep never starts under it and a resume can start before the call lands);
//!   else `pinned` while processes the agent left running (a
//!   background shell or task) or a background subagent or sub-session work, or while it is at
//!   work with no turn; else `person` while a permission or question waits; else `model-wait`.
//! - `since`: when this daemon first saw it in that phase (Unix ms).
//! - `processes`: how many processes it left running; `attached`: an attached client shows it.
//! - `relayed`: whether every turn's model stream ends outside this machine. No relay exists
//!   yet, so it is false and the Cloud never sleeps a machine inside a turn on it.
//!
//! A tool call a lagged event stream missed is forgotten at the turn's end or when the session
//! stops being at work, so a missed `completed` never holds `tool` past its turn. A missed start
//! is worse (a tool would run under `model-wait`), so after a lag every session then at work
//! reports `unknown` (which the Cloud reads as awake) until its turn ends or it is no longer at
//! work.
//!
//! A machine without the agent's socket (every machine that is not a Cloud machine) sends nothing.

use crate::hub::{Hub, SessionAtWork};
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::AsyncWriteExt;

/// How often a line goes in any case. The agent keeps a count for 90 s
/// (cmux-host `cloud/wire.rs` `ACP_ACTIVITY_TTL_MS`), so two lines can be lost before it forgets.
pub(super) const RENEW: Duration = Duration::from_secs(20);
/// A line must not hold this loop on a dead socket.
const SEND_TIMEOUT: Duration = Duration::from_secs(2);

/// What was sent and what is known, sans I/O.
#[derive(Debug, Default)]
pub(super) struct Tracker {
    /// This daemon's name on the machine (its socket path); empty names none.
    daemon: String,
    /// The count and the action time the agent last got, if a line went.
    sent: Option<(u64, Option<u64>)>,
    /// The count last observed, sent or not.
    observed: Option<u64>,
    /// When this daemon's agents last acted (Unix ms).
    last_action: Option<u64>,
    /// When a person last prompted one of this daemon's chats (Unix ms).
    person_prompt: Option<u64>,
    /// The person's prompt time the agent last got.
    sent_person_prompt: Option<u64>,
    /// Each session's open tool calls (`in_progress`, not yet `completed` or `failed`).
    open_tools: BTreeMap<String, BTreeSet<String>>,
    /// Each session's calls named before they run ([`crate::hub::tool_start`]).
    starting: BTreeMap<String, BTreeSet<String>>,
    /// The event stream lagged: tool events may be missing. Sessions at work at the next read
    /// are `unknown` until their turn ends ([`Self::uncertain`]).
    lagged: bool,
    /// Sessions whose tool events may be missing since a lag.
    uncertain: BTreeSet<String>,
    /// Each session at work's phase and since when, once [`Self::observe`] ran.
    phases: Option<BTreeMap<String, TurnPhase>>,
    /// The phases the agent last got, by session: (phase, since).
    sent_phases: Option<Vec<(String, &'static str, u64)>>,
}

/// What one session at work waits on (the module doc's `phases`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct TurnPhase {
    pub phase: &'static str,
    pub since: u64,
    pub processes: usize,
    pub attached: bool,
}

impl Tracker {
    pub(super) fn new(daemon: String) -> Tracker {
        Tracker { daemon, ..Tracker::default() }
    }

    /// An agent acted at `at_ms` (a record's own time).
    pub(super) fn acted(&mut self, at_ms: u64) {
        if at_ms > 0 {
            self.last_action = Some(self.last_action.map_or(at_ms, |t| t.max(at_ms)));
        }
    }

    /// A person prompted one of this daemon's chats at `at_ms`; an older time changes nothing.
    pub(super) fn person_prompted(&mut self, at_ms: u64) {
        if at_ms > 0 {
            self.person_prompt = Some(self.person_prompt.map_or(at_ms, |t| t.max(at_ms)));
        }
    }

    /// Whether the record `dir`/`kind` is an agent action: a turn's start or end, a permission
    /// request, a tool call starting or changing.
    pub(super) fn is_action(dir: &str, kind: &str) -> bool {
        match dir {
            "mux" => matches!(kind, "turn_started" | "turn_result" | "permission_request"),
            "in" => matches!(kind, "tool_call" | "tool_call_update"),
            _ => false,
        }
    }

    /// An ACP record `kind` of session `sid` (`tool_call` or `tool_call_update`, `msg` its raw
    /// JSON-RPC message): opens or closes a tool call. True when the session's phase may have
    /// changed (its first call opened or its last closed).
    pub(super) fn tool_event(&mut self, sid: &str, kind: &str, msg: &Value) -> bool {
        if !matches!(kind, "tool_call" | "tool_call_update") {
            return false;
        }
        let update = msg.pointer("/params/update").unwrap_or(msg);
        let Some(id) = update.get("toolCallId").and_then(Value::as_str) else { return false };
        let status = update.get("status").and_then(Value::as_str);
        let before = (self.open_tools.contains_key(sid), self.starting.contains_key(sid));
        match status {
            // Named, its input still streaming (an update keeps whatever state it had).
            None | Some("pending") if kind == "tool_call" => {
                insert(&mut self.starting, sid, id);
            }
            Some("in_progress") => {
                remove(&mut self.starting, sid, id);
                insert(&mut self.open_tools, sid, id);
            }
            Some("completed" | "failed") => {
                remove(&mut self.starting, sid, id);
                remove(&mut self.open_tools, sid, id);
            }
            _ => return false,
        }
        before != (self.open_tools.contains_key(sid), self.starting.contains_key(sid))
    }

    /// Session `sid`'s turn ended: whatever call it left open (cancelled, or a `completed` the
    /// event stream dropped) is closed. True when one was open.
    pub(super) fn turn_ended(&mut self, sid: &str) -> bool {
        let uncertain = self.uncertain.remove(sid);
        let starting = self.starting.remove(sid).is_some();
        self.open_tools.remove(sid).is_some() || starting || uncertain
    }

    /// The event stream dropped events: what a session at work waits on is not known until its
    /// turn ends.
    pub(super) fn lagged(&mut self) {
        self.lagged = true;
    }

    /// The sessions at work as read at `now_ms`: each one's phase, its since kept while the
    /// phase holds. A session no longer at work forgets its open calls.
    pub(super) fn observe(&mut self, at_work: &[SessionAtWork], now_ms: u64) {
        let ids: BTreeSet<&str> = at_work.iter().map(|s| s.id.as_str()).collect();
        self.open_tools.retain(|sid, _| ids.contains(sid.as_str()));
        self.starting.retain(|sid, _| ids.contains(sid.as_str()));
        self.uncertain.retain(|sid| ids.contains(sid.as_str()));
        if std::mem::take(&mut self.lagged) {
            self.uncertain.extend(ids.iter().map(|id| (*id).to_owned()));
        }
        let before = self.phases.take().unwrap_or_default();
        let mut phases = BTreeMap::new();
        for s in at_work {
            let phase = if self.uncertain.contains(&s.id) {
                "unknown"
            } else if self.open_tools.contains_key(&s.id) {
                "tool"
            } else if self.starting.contains_key(&s.id) {
                "tool-starting"
            } else if s.processes > 0 || s.below || !s.turn {
                "pinned"
            } else if s.person {
                "person"
            } else {
                "model-wait"
            };
            let since = before.get(&s.id).filter(|p| p.phase == phase).map_or(now_ms, |p| p.since);
            let entry = TurnPhase { phase, since, processes: s.processes, attached: s.shown };
            phases.insert(s.id.clone(), entry);
        }
        self.phases = Some(phases);
    }

    /// The phases as the agent gets them: by session id, phase and since.
    fn phase_key(&self) -> Option<Vec<(String, &'static str, u64)>> {
        let phases = self.phases.as_ref()?;
        Some(phases.iter().map(|(id, p)| (id.clone(), p.phase, p.since)).collect())
    }

    /// The line to send with `turns` sessions at work observed at `now_ms`, or None: on a
    /// renewal (`renew`), when the count changed, and with none at work when an agent acted since
    /// the last line. The first 0 after a count above 0 (or after none) counts as an action at
    /// `now_ms`: the work ended no earlier than it was seen to.
    pub(super) fn line(&mut self, turns: u64, renew: bool, now_ms: u64) -> Option<Value> {
        if turns == 0 && self.observed != Some(0) {
            self.acted(now_ms);
        }
        self.observed = Some(turns);
        let changed = match self.sent {
            None => true,
            Some((sent, _)) if sent != turns => true,
            Some((_, at)) => turns == 0 && at != self.last_action,
        };
        // Every phase change goes at once (the Cloud reads the last report on a timer).
        let phases = self.phase_key();
        let phases_changed = phases.is_some() && phases != self.sent_phases;
        // A person's prompt goes at once: it opens the Cloud's post-chat warm window.
        let prompted = self.person_prompt != self.sent_person_prompt;
        if !(changed || phases_changed || prompted || renew) {
            return None;
        }
        self.sent = Some((turns, self.last_action));
        self.sent_phases = phases;
        self.sent_person_prompt = self.person_prompt;
        let mut activity = json!({"turns": turns});
        if let Some(at) = self.last_action {
            activity.set("last_agent_action_at", json!(at));
        }
        if let Some(at) = self.person_prompt {
            activity.set("last_person_prompt_at", json!(at));
        }
        if !self.daemon.is_empty() {
            activity.set("daemon", json!(self.daemon));
        }
        if let Some(phases) = &self.phases {
            let turns: Vec<Value> = phases
                .values()
                .map(|p| {
                    json!({"phase": p.phase, "since": p.since, "processes": p.processes,
                        "attached": p.attached})
                })
                .collect();
            activity.set("phases", json!({"relayed": false, "turns": turns}));
        }
        Some(json!({"acp_activity": activity}))
    }

    /// The agent did not take the last line: send the count again with the next chance.
    pub(super) fn unsent(&mut self) {
        self.sent = None;
        self.sent_phases = None;
        self.sent_person_prompt = None;
    }
}

/// Adds call `id` to session `sid`'s set.
fn insert(sets: &mut BTreeMap<String, BTreeSet<String>>, sid: &str, id: &str) {
    sets.entry(sid.to_owned()).or_default().insert(id.to_owned());
}

/// Removes call `id` from session `sid`'s set, and the set once it is empty.
fn remove(sets: &mut BTreeMap<String, BTreeSet<String>>, sid: &str, id: &str) {
    if let Some(set) = sets.get_mut(sid) {
        set.remove(id);
        if set.is_empty() {
            sets.remove(sid);
        }
    }
}

/// Resolves once `path` exists: at once on a Cloud machine. Elsewhere it waits for a file event in
/// the nearest folder of the path that exists (`/run/cmux-vm-agent`, else `/run`), with no timer,
/// and looks again on each. A watch that cannot start resolves at once (the loop then runs as
/// before: it reports nothing while the socket is absent).
async fn agent_socket_appears(path: &Path) {
    use notify::Watcher as _;
    if path.exists() {
        return;
    }
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    let Ok(mut watcher) =
        notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
            if !matches!(&event, Ok(e) if e.kind.is_access()) {
                let _ = tx.send(());
            }
        })
    else {
        return;
    };
    let mut watched: Option<std::path::PathBuf> = None;
    loop {
        // Watch before checking, so a socket made in between is seen by the check or wakes the wait.
        let Some(dir) = path.ancestors().skip(1).find(|d| d.is_dir()).map(Path::to_path_buf) else {
            return;
        };
        if watched.as_ref() != Some(&dir) {
            if let Some(old) = watched.take() {
                let _ = watcher.unwatch(&old);
            }
            if watcher.watch(&dir, notify::RecursiveMode::NonRecursive).is_err() {
                return;
            }
            watched = Some(dir);
        }
        if path.exists() || rx.recv().await.is_none() {
            return;
        }
    }
}

/// Follows this daemon's own sessions and reports how many are at work while the Cloud agent's
/// socket is there.
pub(super) async fn activity_loop(hub: Arc<Hub>) {
    let path = super::cloud_handoff::agent_socket();
    // Off a Cloud machine nothing reads the report: no renew tick and no resume subscription (it
    // keeps the hub's resume tick running) until the agent's socket appears (cmux-ad m9).
    agent_socket_appears(&path).await;
    let mut events = hub.subscribe();
    let mut resumes = hub.subscribe_resumes();
    let mut person_prompts = hub.subscribe_person_prompts();
    let mut tracker = Tracker::new(crate::config::socket_path().to_string_lossy().into_owned());
    let mut tick = tokio::time::interval(RENEW);
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        let renew = tokio::select! {
            ev = events.recv() => match ev {
                // Missed events: the count is read again now, and what each session at work
                // waits on is unknown until its turn ends.
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                    tracker.lagged();
                    true
                }
                Err(_) => break,
                Ok(ev) => {
                    if ev.remote.is_some() {
                        continue;
                    }
                    let (dir, kind) = (ev.record.dir.as_str(), ev.record.kind.as_str());
                    if Tracker::is_action(dir, kind) {
                        tracker.acted(ev.record.at);
                    }
                    if dir == "mux" && kind == "turn_result" {
                        tracker.turn_ended(&ev.session_id);
                    }
                    // Only acpmux's own records change what is at work, and a tool call's start
                    // or end what a session waits on; an agent's stream (every token) never does.
                    let phase =
                        dir == "in" && tracker.tool_event(&ev.session_id, kind, &ev.record.msg);
                    if dir != "mux" && !phase {
                        continue;
                    }
                    false
                }
            },
            _ = tick.tick() => true,
            // After a pause the agent's count may have run out: a line goes at once.
            Ok(()) = resumes.changed() => true,
            // A person's prompt: its time goes at once (the line sees it changed).
            Ok(()) = person_prompts.changed() => false,
        };
        if !path.exists() {
            continue;
        }
        let detail = {
            let hub = hub.clone();
            tokio::task::spawn_blocking(move || hub.sessions_at_work_detail()).await.ok()
        };
        let now = crate::store::now_ms();
        let at_work = match &detail {
            Some(detail) => {
                tracker.observe(detail, now);
                detail.len()
            }
            // A count that cannot be read is not a known 0.
            None => 1,
        };
        let at_work = reported_at_work(at_work, hub.startup_settled());
        if let Some(at) = hub.last_person_prompt_at() {
            tracker.person_prompted(at);
        }
        let Some(line) = tracker.line(at_work as u64, renew, now) else { continue };
        if !send(&path, &line).await {
            tracker.unsent();
        }
    }
}

/// The count to report: while startup has not settled, never below 1 (what it has not
/// rebuilt yet may be a running turn). The next tick after it settles sends the real count.
pub(super) fn reported_at_work(at_work: usize, settled: bool) -> usize {
    if settled { at_work } else { at_work.max(1) }
}

/// One line on its own connection; false when the agent did not take it.
async fn send(path: &Path, line: &Value) -> bool {
    let write = async {
        let mut stream = tokio::net::UnixStream::connect(path).await?;
        stream.write_all(format!("{line}\n").as_bytes()).await?;
        stream.shutdown().await
    };
    matches!(tokio::time::timeout(SEND_TIMEOUT, write).await, Ok(Ok(())))
}

#[cfg(test)]
#[path = "cloud_activity_tests.rs"]
mod tests;
