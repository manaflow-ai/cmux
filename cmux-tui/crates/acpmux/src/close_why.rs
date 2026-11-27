//! Who closed a session, why, and whether its work was finished: the record every close keeps.
//!
//! Leo, 2026-11-24: "also try to fix up whateve occured that closed the lanes when they weren't
//! finished? we need to be more persistent somehow when agents die but they have important work".
//! Ten CI v2 lanes closed with no trace of what closed them: acpmux logged hibernate, wake and
//! restart, never a close's actor. Now every close (`Hub::kill_held`, the one place a chat turns
//! `closed`) writes one `mux/closed` record to the chat's log, keeps the same record on its meta
//! (`SessionMeta::close`, so a closed row carries it as `close`), and logs one INFO line naming the
//! chat, the actor and the reason. Nothing is refused: a close with no outcome on a lane with work
//! (a `lane.reportsTo` or `goal` tag, or a goal not done) is recorded `unfinished`, never stopped.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::store::SessionMeta;

/// What closed a session.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CloseActor {
    /// `cli` (the local socket: `acpmux session stop|close`), `mcp` (an agent's stop through its
    /// helper token), `ttl` (an idle or expiry pass), `daemon` (the daemon's own close: a move, an
    /// import, a start it undid), `harness_exit`, `peer` (another machine's daemon or a remote
    /// client), `agent_self` (a session closing itself), `app` (the app's own pane).
    pub kind: String,
    /// The session that asked, when known (an agent's caller token).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    /// The machine that asked, when known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
    /// The asking process, when known (the unix socket peer's pid).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pid: Option<u32>,
}

impl CloseActor {
    pub fn new(kind: &str) -> Self {
        Self { kind: kind.to_owned(), ..Self::default() }
    }

    pub fn session(mut self, session: Option<&str>) -> Self {
        self.session = session.map(str::to_owned);
        self
    }

    pub fn host(mut self, host: Option<&str>) -> Self {
        self.host = host.map(str::to_owned);
        self
    }

    pub fn pid(mut self, pid: Option<u32>) -> Self {
        self.pid = pid;
        self
    }
}

/// What a closer says about its close: who, and optionally why and how the work ended.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CloseWhy {
    pub actor: CloseActor,
    pub reason: Option<String>,
    /// `done`, `dropped` (or a daemon's own, such as `moved`); None lets the record decide.
    pub outcome: Option<String>,
}

impl CloseWhy {
    pub fn by(kind: &str, reason: &str) -> Self {
        Self { actor: CloseActor::new(kind), reason: Some(reason.to_owned()), outcome: None }
    }

    pub fn actor(actor: CloseActor) -> Self {
        Self { actor, reason: None, outcome: None }
    }

    pub fn outcome(mut self, outcome: &str) -> Self {
        self.outcome = Some(outcome.to_owned());
        self
    }

    /// The `reason` and `outcome` a request carries (`_acpmux/kill`, `session/close`), on top of
    /// `actor`. Blank ones count as left out.
    pub fn from_params(actor: CloseActor, params: &Value) -> Self {
        let text = |key: &str| {
            params
                .get(key)
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
        };
        Self { actor, reason: text("reason"), outcome: text("outcome") }
    }
}

/// The durable record of one close: the `mux/closed` log record and `SessionMeta::close`.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CloseRecord {
    /// Unix ms.
    pub closed_at: u64,
    pub actor: CloseActor,
    /// The closer's words, or what the daemon knows of the path (`unrecorded` when neither).
    pub reason: String,
    /// `done`, `dropped`, `unfinished` (a lane with work closed with no outcome), or a daemon's own.
    pub outcome: String,
}

/// Whether the chat holds work someone expects finished: a lane reporting to a session, a goal
/// tag, or a goal its harness has not marked done.
pub fn holds_work(meta: &SessionMeta) -> bool {
    meta.tags.contains_key("lane.reportsTo")
        || meta.tags.contains_key("goal")
        || meta.goal.as_ref().is_some_and(|g| g.status != crate::goal::GoalStatus::Done)
}

impl CloseRecord {
    pub fn new(why: CloseWhy, meta: &SessionMeta, closed_at: u64) -> Self {
        let outcome = why.outcome.unwrap_or_else(|| {
            if holds_work(meta) { "unfinished".to_owned() } else { "dropped".to_owned() }
        });
        Self {
            closed_at,
            actor: why.actor,
            reason: why.reason.unwrap_or_else(|| "unrecorded".to_owned()),
            outcome,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn meta(tags: Value) -> SessionMeta {
        let mut m: SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "s1", "name": "lane", "harness": "claude",
            "cwd": "/tmp", "createdAt": 1, "updatedAt": 1, "status": "idle",
        }))
        .unwrap();
        m.tags = serde_json::from_value(tags).unwrap();
        m
    }

    #[test]
    fn a_lane_closed_with_no_outcome_is_unfinished() {
        let lane = meta(json!({"lane.reportsTo": {"value": "coord"}}));
        let r = CloseRecord::new(CloseWhy::by("cli", "stop"), &lane, 5);
        assert_eq!(r.outcome, "unfinished");
        let r = CloseRecord::new(CloseWhy::by("cli", "stop").outcome("done"), &lane, 5);
        assert_eq!(r.outcome, "done");
        let goal = meta(json!({"goal": {"value": "ship it"}}));
        assert_eq!(CloseRecord::new(CloseWhy::by("ttl", "x"), &goal, 5).outcome, "unfinished");
        let plain = meta(json!({}));
        assert_eq!(CloseRecord::new(CloseWhy::by("cli", "x"), &plain, 5).outcome, "dropped");
    }

    #[test]
    fn the_record_reads_back_as_its_json() {
        let actor = CloseActor::new("mcp").session(Some("parent")).pid(Some(42));
        let why = CloseWhy::from_params(actor, &json!({"reason": " merged ", "outcome": ""}));
        let r = CloseRecord::new(why, &meta(json!({})), 7);
        let v = serde_json::to_value(&r).unwrap();
        assert_eq!(
            v,
            json!({"closedAt": 7, "actor": {"kind": "mcp", "session": "parent", "pid": 42},
                   "reason": "merged", "outcome": "dropped"})
        );
        assert_eq!(serde_json::from_value::<CloseRecord>(v).unwrap(), r);
    }
}
