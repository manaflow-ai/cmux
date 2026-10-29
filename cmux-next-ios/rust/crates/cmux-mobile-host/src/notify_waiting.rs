//! Reconcile the sidebar's waiting state with actionable push requests.

use std::collections::{HashMap, HashSet};

use cmux_mobile_link::api::NotifyEvent;
use serde_json::Value;

use crate::notify::Classifier;

#[derive(Default)]
pub(crate) struct Waiting {
    next_id: u64,
    requests: HashMap<u64, String>,
    seen: HashSet<(String, String)>,
}

impl Waiting {
    /// Outgoing acpmux queries and push requests for one watch frame.
    pub(crate) fn receive(
        &mut self,
        message: &Value,
        classifier: &mut Classifier,
    ) -> (Vec<Value>, Vec<NotifyEvent>) {
        if message.get("id").and_then(Value::as_u64) == Some(2) {
            if let Some(result) = message.get("result") {
                classifier.load(result);
                let mut queries = Vec::new();
                for session in result.get("sessions").and_then(Value::as_array).into_iter().flatten() {
                    self.query_if_waiting(session, &mut queries);
                }
                return (queries, vec![]);
            }
            return (vec![], vec![]);
        }
        if let Some(id) = message.get("id").and_then(Value::as_u64)
            && let Some(session_id) = self.requests.remove(&id)
        {
            let mut pushes = Vec::new();
            for pending in message.pointer("/result/pending").and_then(Value::as_array).into_iter().flatten()
            {
                let Some(permission_id) = pending.get("permissionId").and_then(Value::as_str) else {
                    continue;
                };
                let mut params = pending.clone();
                params["sessionId"] = Value::String(session_id.clone());
                params["permissionId"] = Value::String(permission_id.to_owned());
                let event = serde_json::json!({"method":"_acpmux/permission_pending","params":params});
                if let Some(push) = classifier.handle(&event) {
                    pushes.push(push);
                }
            }
            return (vec![], pushes);
        }
        if message.get("method").and_then(Value::as_str) == Some("_acpmux/session_changed")
            && let Some(session) = message.pointer("/params/session")
        {
            let mut queries = Vec::new();
            self.query_if_waiting(session, &mut queries);
            return (queries, classifier.handle(message).into_iter().collect());
        }
        (vec![], classifier.handle(message).into_iter().collect())
    }

    fn query_if_waiting(&mut self, session: &Value, queries: &mut Vec<Value>) {
        let Some(session_id) = session.get("sessionId").and_then(Value::as_str) else { return };
        let waiting = session.get("waitingOn").and_then(Value::as_str).is_some()
            || session.get("status").and_then(Value::as_str) == Some("waiting")
            || session.get("pendingPermissions").and_then(Value::as_u64).unwrap_or(0) > 0;
        if !waiting {
            return;
        }
        let state = session
            .get("stateSeq")
            .map(Value::to_string)
            .or_else(|| session.get("inputSince").map(Value::to_string))
            .unwrap_or_default();
        if !self.seen.insert((session_id.to_owned(), state)) {
            return;
        }
        self.next_id = self.next_id.saturating_add(1).max(10);
        let id = self.next_id;
        self.requests.insert(id, session_id.to_owned());
        queries.push(serde_json::json!({"jsonrpc":"2.0","id":id,"method":"_acpmux/info","params":{"sessionId":session_id}}));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn session(status: &str, since: u64) -> Value {
        json!({"sessionId":"s1","harness":"claude-code","status":status,
            "waitingOn":"permission","inputSince":since,"pendingPermissions":if status == "waiting" {1} else {0}})
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
        let (queries, pushes) = waiting.receive(&change, &mut classifier);
        assert!(pushes.is_empty(), "fetch the real options before offering actions");
        assert_eq!(queries.len(), 1);
        assert_eq!(queries[0]["method"], "_acpmux/info");
        assert_eq!(queries[0]["params"]["sessionId"], "s1");
        for _ in 0..3 {
            let (queries, pushes) = waiting.receive(&change, &mut classifier);
            assert!(queries.is_empty());
            assert!(pushes.is_empty());
        }
        let response = reply(&queries[0], pending("p1"));
        let (_, pushes) = waiting.receive(&response, &mut classifier);
        assert_eq!(pushes.len(), 1);
        assert_eq!(pushes[0].kind, "permission");
        assert_eq!(pushes[0].permission_id.as_deref(), Some("p1"));
        assert_eq!(pushes[0].options.iter().map(|o| o.id.as_str()).collect::<Vec<_>>(), ["yes", "no"]);
        assert!(waiting.receive(&response, &mut classifier).1.is_empty());
        let mut direct = pending("p1");
        direct["sessionId"] = json!("s1");
        assert!(
            waiting
                .receive(&json!({"method":"_acpmux/permission_pending","params":direct}), &mut classifier)
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
            let (queries, _) = waiting.receive(&snapshot, &mut classifier);
            assert_eq!(queries.len(), 1);
            let question = json!({"permissionId":"q1","request":{"toolCall":{
                "_meta":{"claude":{"tool":"AskUserQuestion"}},"rawInput":{"questions":[
                    {"question":"Which branch?","options":[{"label":"main"},{"label":"preview"}]}]}}}});
            let (_, pushes) = waiting.receive(&reply(&queries[0], question), &mut classifier);
            assert_eq!(pushes.len(), usize::from(attempt == 0));
            if let Some(push) = pushes.first() {
                assert_eq!(push.kind, "question");
                assert_eq!(push.questions[0].question, "Which branch?");
                assert_eq!(push.questions[0].options.len(), 2);
            }
        }
    }
}
