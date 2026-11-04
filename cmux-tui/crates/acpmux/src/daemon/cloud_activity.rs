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
//! A machine without the agent's socket (every machine that is not a Cloud machine) sends nothing.

use crate::hub::Hub;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
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

    /// Whether the record `dir`/`kind` is an agent action: a turn's start or end, a permission
    /// request, a tool call starting or changing.
    pub(super) fn is_action(dir: &str, kind: &str) -> bool {
        match dir {
            "mux" => matches!(kind, "turn_started" | "turn_result" | "permission_request"),
            "in" => matches!(kind, "tool_call" | "tool_call_update"),
            _ => false,
        }
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
        if !(changed || renew) {
            return None;
        }
        self.sent = Some((turns, self.last_action));
        let mut activity = json!({"turns": turns});
        if let Some(at) = self.last_action {
            activity.set("last_agent_action_at", json!(at));
        }
        if !self.daemon.is_empty() {
            activity.set("daemon", json!(self.daemon));
        }
        Some(json!({"acp_activity": activity}))
    }

    /// The agent did not take the last line: send the count again with the next chance.
    pub(super) fn unsent(&mut self) {
        self.sent = None;
    }
}

/// Follows this daemon's own sessions and reports how many are at work while the Cloud agent's
/// socket is there.
pub(super) async fn activity_loop(hub: Arc<Hub>) {
    let path = super::cloud_handoff::agent_socket();
    let mut events = hub.subscribe();
    let mut resumes = hub.subscribe_resumes();
    let mut tracker = Tracker::new(crate::config::socket_path().to_string_lossy().into_owned());
    let mut tick = tokio::time::interval(RENEW);
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        let renew = tokio::select! {
            ev = events.recv() => {
                let ev = match ev {
                    Ok(ev) => ev,
                    // Missed events only delay a change to the next tick.
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(_) => break,
                };
                if ev.remote.is_some() {
                    continue;
                }
                let (dir, kind) = (ev.record.dir.as_str(), ev.record.kind.as_str());
                if Tracker::is_action(dir, kind) {
                    tracker.acted(ev.record.at);
                }
                // Only acpmux's own records change what is at work; an agent's stream (every
                // token) never counts sessions.
                if dir != "mux" {
                    continue;
                }
                false
            }
            _ = tick.tick() => true,
            // After a pause the agent's count may have run out: a line goes at once.
            Ok(()) = resumes.changed() => true,
        };
        if !path.exists() {
            continue;
        }
        let at_work = {
            let hub = hub.clone();
            // A count that cannot be read is not a known 0.
            tokio::task::spawn_blocking(move || hub.sessions_at_work()).await.unwrap_or(1)
        };
        let at_work = reported_at_work(at_work, hub.startup_settled());
        let now = crate::store::now_ms();
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
