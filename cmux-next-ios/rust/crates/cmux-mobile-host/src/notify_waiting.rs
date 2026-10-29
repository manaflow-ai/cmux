//! Reconcile the sidebar's input indicator with actionable push requests.
//!
//! A watch snapshot can arrive after the permission event was emitted. Read
//! pending requests once per input transition, then use the live-event classifier
//! so recovery preserves actions and shares its permission-ID deduplication.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use cmux_mobile_link::api::NotifyEvent;
use serde_json::{Value, json};

use crate::notify::Classifier;

/// A read that never answers reconnects the existing watch; no polling task.
const INFO_TIMEOUT: Duration = Duration::from_secs(10);
const SESSION_LIMIT: usize = 4096;

#[derive(Default)]
pub(crate) struct Waiting {
    next_id: u64,
    sessions: HashMap<String, (InputState, u64)>,
    requests: HashMap<u64, Pending>,
}

#[derive(Clone, PartialEq, Eq)]
struct InputState {
    since: Option<u64>,
    kind: Option<String>,
    count: u64,
}

struct Pending {
    session: String,
    state: InputState,
    deadline: Instant,
}

impl Waiting {
    pub(crate) fn next_deadline(&self) -> Option<Instant> {
        self.requests.values().map(|request| request.deadline).min()
    }

    /// Outgoing acpmux queries and push requests for one watch frame.
    pub(crate) fn receive(
        &mut self,
        message: &Value,
        classifier: &mut Classifier,
    ) -> Result<(Vec<Value>, Vec<NotifyEvent>), String> {
        if message.get("id").and_then(Value::as_u64) == Some(2) {
            let mut queries = Vec::new();
            if let Some(result) = message.get("result") {
                classifier.load(result);
                for session in result.get("sessions").and_then(Value::as_array).into_iter().flatten() {
                    self.observe(session, &mut queries)?;
                }
            }
            return Ok((queries, vec![]));
        }
        if let Some(id) = message.get("id").and_then(Value::as_u64)
            && let Some(request) = self.requests.remove(&id)
        {
            if message.get("error").is_some() {
                // The next watch snapshot retries a still-pending state.
                return Err("pending-input lookup failed".into());
            }
            if self.sessions.get(&request.session) != Some(&(request.state, id)) {
                return Ok((vec![], vec![]));
            }
            let mut pushes = Vec::new();
            for pending in message.pointer("/result/pending").and_then(Value::as_array).into_iter().flatten()
            {
                let Some(mut params) = pending.as_object().cloned() else { continue };
                params.insert("sessionId".into(), Value::String(request.session.clone()));
                let event = json!({"method":"_acpmux/permission_pending","params":params});
                if let Some(push) = classifier.handle(&event) {
                    pushes.push(push);
                }
            }
            return Ok((vec![], pushes));
        }
        let mut queries = Vec::new();
        if message.get("method").and_then(Value::as_str) == Some("_acpmux/session_changed")
            && let Some(session) = message.pointer("/params/session")
        {
            self.observe(session, &mut queries)?;
        }
        Ok((queries, classifier.handle(message).into_iter().collect()))
    }

    fn observe(&mut self, session: &Value, queries: &mut Vec<Value>) -> Result<(), String> {
        let Some(session_id) = session.get("sessionId").and_then(Value::as_str) else { return Ok(()) };
        // Same source as AgentTurnState.of(summary:) on the Mac. Older peers
        // without indicator still expose waiting/pendingPermissions.
        let input = match session.get("indicator") {
            Some(indicator) => indicator.as_str() == Some("input"),
            None => {
                session.get("status").and_then(Value::as_str) == Some("waiting")
                    || session.get("pendingPermissions").and_then(Value::as_u64).unwrap_or(0) > 0
            }
        };
        if !input {
            self.sessions.remove(session_id);
            return Ok(());
        }
        let state = InputState {
            since: session
                .get("inputSince")
                .and_then(Value::as_u64)
                .or_else(|| session.pointer("/lane/since").and_then(Value::as_u64)),
            kind: session.get("waitingOn").and_then(Value::as_str).map(str::to_owned),
            count: session.get("pendingPermissions").and_then(Value::as_u64).unwrap_or(0),
        };
        if self.sessions.get(session_id).is_some_and(|(current, _)| current == &state) {
            return Ok(());
        }
        if (!self.sessions.contains_key(session_id) && self.sessions.len() >= SESSION_LIMIT)
            || self.requests.len() >= SESSION_LIMIT
        {
            return Err("pending-input watch exceeded session capacity".into());
        }
        self.next_id = self.next_id.checked_add(1).ok_or("pending-input request IDs exhausted")?.max(10);
        let id = self.next_id;
        self.sessions.insert(session_id.to_owned(), (state.clone(), id));
        self.requests.insert(
            id,
            Pending { session: session_id.to_owned(), state, deadline: Instant::now() + INFO_TIMEOUT },
        );
        queries
            .push(json!({"jsonrpc":"2.0","id":id,"method":"_acpmux/info","params":{"sessionId":session_id}}));
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn receive(
        waiting: &mut Waiting,
        message: &Value,
        classifier: &mut Classifier,
    ) -> (Vec<Value>, Vec<NotifyEvent>) {
        waiting.receive(message, classifier).unwrap()
    }

    fn session(status: &str, since: u64) -> Value {
        json!({"sessionId":"s1","harness":"claude-code","status":status,
            "indicator":if status == "waiting" {"input"} else {"working"},
            "waitingOn":if status == "waiting" {Some("permission")} else {None},"inputSince":since,"pendingPermissions":if status == "waiting" {1} else {0}})
    }

    fn changed(session: Value) -> Value {
        json!({"method":"_acpmux/session_changed","params":{"recordKind":"permission_request","session":session}})
    }

    fn pending(id: &str) -> Value {
        json!({"permissionId":id,"request":{"toolCall":{"title":"Write the file"},
            "options":[{"optionId":"yes","name":"Allow once","kind":"allow_once"},
                {"optionId":"no","name":"Deny","kind":"reject_once"}]}})
    }

    fn reply(request: &Value, pending: Value) -> Value {
        let mut result = session("waiting", 10);
        result["pending"] = json!([pending]);
        json!({"id":request["id"],"result":result})
    }

    #[test]
    fn entering_needs_permission_produces_exactly_one_push_request() {
        let mut waiting = Waiting::default();
        let mut classifier = Classifier::default();
        let change = changed(session("waiting", 10));
        let (queries, pushes) = receive(&mut waiting, &change, &mut classifier);
        assert!(pushes.is_empty(), "fetch the real options before offering actions");
        assert_eq!(queries.len(), 1);
        assert_eq!(queries[0]["method"], "_acpmux/info");
        assert_eq!(queries[0]["params"]["sessionId"], "s1");
        for _ in 0..3 {
            let (queries, pushes) = receive(&mut waiting, &change, &mut classifier);
            assert!(queries.is_empty());
            assert!(pushes.is_empty());
        }
        let response = reply(&queries[0], pending("p1"));
        let (_, pushes) = receive(&mut waiting, &response, &mut classifier);
        assert_eq!(pushes.len(), 1);
        assert_eq!(pushes[0].kind, "permission");
        assert_eq!(pushes[0].permission_id.as_deref(), Some("p1"));
        assert_eq!(pushes[0].options.iter().map(|o| o.id.as_str()).collect::<Vec<_>>(), ["yes", "no"]);
        assert!(receive(&mut waiting, &response, &mut classifier).1.is_empty());
        let mut direct = pending("p1");
        direct["sessionId"] = json!("s1");
        assert!(
            receive(
                &mut waiting,
                &json!({"method":"_acpmux/permission_pending","params":direct}),
                &mut classifier
            )
            .1
            .is_empty()
        );
    }

    #[test]
    fn reconnect_recovers_a_question_without_repeating_its_push() {
        let mut classifier = Classifier::default();
        let mut snapshot_session = session("waiting", 10);
        snapshot_session["stateSeq"] = json!(1);
        let snapshot = json!({"id":2,"result":{"sessions":[snapshot_session]}});
        for attempt in 0..2 {
            let mut waiting = Waiting::default();
            let (queries, _) = receive(&mut waiting, &snapshot, &mut classifier);
            assert_eq!(queries.len(), 1);
            let question = json!({"permissionId":"q1","request":{"toolCall":{
                "_meta":{"claude":{"tool":"AskUserQuestion"}},"rawInput":{"questions":[
                    {"question":"Which branch?","options":[{"label":"main"},{"label":"preview"}]}]}}}});
            let (_, pushes) = receive(&mut waiting, &reply(&queries[0], question), &mut classifier);
            assert_eq!(pushes.len(), usize::from(attempt == 0));
            if let Some(push) = pushes.first() {
                assert_eq!(push.kind, "question");
                assert_eq!(push.questions[0].question, "Which branch?");
                assert_eq!(push.questions[0].options.len(), 2);
            }
        }
    }
    #[test]
    fn unrelated_state_changes_do_not_refetch_and_a_new_wait_does() {
        let mut waiting = Waiting::default();
        let mut classifier = Classifier::default();
        let (queries, _) = receive(&mut waiting, &changed(session("waiting", 10)), &mut classifier);
        let (_, pushes) = receive(&mut waiting, &reply(&queries[0], pending("p1")), &mut classifier);
        assert_eq!(pushes.len(), 1);
        assert!(waiting.next_deadline().is_none());
        let mut same = session("waiting", 10);
        same["stateSeq"] = json!(999);
        same["preview"] = json!("another update");
        assert!(receive(&mut waiting, &changed(same), &mut classifier).0.is_empty());
        receive(&mut waiting, &changed(session("running", 11)), &mut classifier);
        let (queries, _) = receive(&mut waiting, &changed(session("waiting", 12)), &mut classifier);
        assert_eq!(queries.len(), 1);
        assert_eq!(receive(&mut waiting, &reply(&queries[0], pending("p2")), &mut classifier).1.len(), 1);
    }

    #[test]
    fn a_resolved_or_superseded_wait_discards_its_late_reply() {
        let mut waiting = Waiting::default();
        let mut classifier = Classifier::default();
        let (old, _) = receive(&mut waiting, &changed(session("waiting", 10)), &mut classifier);
        assert!(waiting.next_deadline().is_some());
        receive(&mut waiting, &changed(session("running", 11)), &mut classifier);
        // Older peers may reuse the same summary key on the next wait.
        let (new, _) = receive(&mut waiting, &changed(session("waiting", 10)), &mut classifier);
        assert!(receive(&mut waiting, &reply(&old[0], pending("old")), &mut classifier).1.is_empty());
        assert_eq!(receive(&mut waiting, &reply(&new[0], pending("new")), &mut classifier).1.len(), 1);
        assert!(waiting.next_deadline().is_none());
    }

    #[test]
    fn live_permission_first_and_recovery_still_send_only_once() {
        let mut waiting = Waiting::default();
        let mut classifier = Classifier::default();
        let (queries, _) = receive(&mut waiting, &changed(session("waiting", 10)), &mut classifier);
        let mut direct = pending("p1");
        direct["sessionId"] = json!("s1");
        let live = json!({"method":"_acpmux/permission_pending","params":direct});
        assert_eq!(receive(&mut waiting, &live, &mut classifier).1.len(), 1);
        assert!(receive(&mut waiting, &reply(&queries[0], pending("p1")), &mut classifier).1.is_empty());
    }

    #[test]
    fn existing_turn_pushes_still_pass_through_and_errors_reconnect() {
        let mut waiting = Waiting::default();
        let mut classifier = Classifier::default();
        let done = json!({"method":"_acpmux/session_changed","params":{"recordKind":"turn_result",
            "session":{"sessionId":"s1","indicator":"done","lastTurn":{"turnId":"t1","status":"completed"}}}});
        let (_, pushes) = receive(&mut waiting, &done, &mut classifier);
        assert_eq!(pushes.len(), 1);
        assert_eq!(pushes[0].kind, "completed");
        let (queries, _) = receive(&mut waiting, &changed(session("waiting", 10)), &mut classifier);
        let error = json!({"id":queries[0]["id"],"error":{"code":-32000,"message":"gone"}});
        assert!(waiting.receive(&error, &mut classifier).is_err());
    }
}
