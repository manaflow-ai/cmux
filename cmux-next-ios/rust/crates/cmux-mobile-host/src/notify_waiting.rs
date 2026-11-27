//! Reconcile the sidebar's input indicator with actionable push requests.
//!
//! A watch snapshot can arrive after the permission event was emitted. Read
//! pending requests once per input transition, then use the live-event classifier
//! so recovery preserves actions and shares its permission-ID deduplication.

use std::collections::{HashMap, HashSet, VecDeque};
use std::time::{Duration, Instant};

use cmux_mobile_link::api::NotifyEvent;
use serde_json::{Value, json};

use crate::notify::Classifier;

/// A read that never answers reconnects the existing watch; no polling task.
const INFO_TIMEOUT: Duration = Duration::from_secs(10);
/// A page of the watch list that never answers reconnects the watch too. A page is up
/// to acpmux's largest reply, and acpmux may hold it back while it paces list builds.
const PAGE_TIMEOUT: Duration = Duration::from_secs(60);
const SESSION_LIMIT: usize = 4096;

#[derive(Default)]
pub(crate) struct Waiting {
    next_id: u64,
    sessions: HashMap<String, (InputState, u64)>,
    requests: HashMap<u64, Pending>,
    queued: VecDeque<u64>,
    active: Option<u64>,
    /// The `_acpmux/sessions` reading the watch list's next page, and when it is due; none
    /// once the list is whole.
    page: Option<u64>,
    page_deadline: Option<Instant>,
    /// The page cursors this watch list gave: one given twice would page it forever.
    cursors: HashSet<String>,
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
    deadline: Option<Instant>,
}

impl Waiting {
    pub(crate) fn next_deadline(&self) -> Option<Instant> {
        let lookup = self.active.and_then(|id| self.requests.get(&id)?.deadline);
        lookup.into_iter().chain(self.page_deadline).min()
    }

    /// Outgoing acpmux queries and push requests for one watch frame.
    pub(crate) fn receive(
        &mut self,
        message: &Value,
        classifier: &mut Classifier,
    ) -> Result<(Vec<Value>, Vec<NotifyEvent>), String> {
        let id = message.get("id").and_then(Value::as_u64);
        if id == Some(2) || (id.is_some() && id == self.page) {
            let mut queries = Vec::new();
            if let Some(result) = message.get("result") {
                if id == Some(2) {
                    self.cursors.clear();
                } else if !result.get("sessions").is_some_and(Value::is_array) {
                    // A page that lists nothing would pass the rest of the list for read.
                    return Err("acpmux session page lists no sessions".into());
                }
                classifier.load(result);
                for session in result.get("sessions").and_then(Value::as_array).into_iter().flatten() {
                    self.observe(session)?;
                }
                queries.extend(self.next_page(result)?);
            } else if id != Some(2) {
                // The next watch reads the list again from its start.
                return Err("acpmux session page failed".into());
            }
            queries.extend(self.start_next());
            return Ok((queries, vec![]));
        }
        if let Some(id) = message.get("id").and_then(Value::as_u64)
            && self.active == Some(id)
            && let Some(request) = self.requests.remove(&id)
        {
            self.active = None;
            if self.sessions.get(&request.session) != Some(&(request.state, id)) {
                return Ok((self.start_next(), vec![]));
            }
            if message.get("error").is_some() {
                // The next watch snapshot retries a still-pending state.
                return Err("pending-input lookup failed".into());
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
            return Ok((self.start_next(), pushes));
        }
        if message.get("method").and_then(Value::as_str) == Some("_acpmux/session_changed")
            && let Some(session) = message.pointer("/params/session")
        {
            self.observe(session)?;
        }
        Ok((self.start_next(), classifier.handle(message).into_iter().collect()))
    }

    fn observe(&mut self, session: &Value) -> Result<(), String> {
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
            self.forget(session_id);
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
        self.forget(session_id);
        if (!self.sessions.contains_key(session_id) && self.sessions.len() >= SESSION_LIMIT)
            || self.requests.len() >= SESSION_LIMIT
        {
            return Err("pending-input watch exceeded session capacity".into());
        }
        self.next_id = self.next_id.checked_add(1).ok_or("pending-input request IDs exhausted")?.max(10);
        let id = self.next_id;
        self.sessions.insert(session_id.to_owned(), (state.clone(), id));
        self.requests.insert(id, Pending { session: session_id.to_owned(), state, deadline: None });
        self.queued.push_back(id);
        Ok(())
    }

    /// The `_acpmux/sessions` for the rest of a list too large for one reply: acpmux
    /// answers the watch with its first rows and a string `nextCursor`, the rest by that
    /// cursor until a page has none (acpmux `Client::whole_list`).
    fn next_page(&mut self, result: &Value) -> Result<Option<Value>, String> {
        self.page = None;
        self.page_deadline = None;
        let cursor = match result.get("nextCursor") {
            None | Some(Value::Null) => return Ok(None),
            Some(Value::String(cursor)) => cursor,
            Some(other) => return Err(format!("acpmux gave the page cursor {other}")),
        };
        if !self.cursors.insert(cursor.clone()) {
            return Err(format!("acpmux gave the page cursor {cursor:?} twice"));
        }
        self.next_id = self.next_id.checked_add(1).ok_or("pending-input request IDs exhausted")?.max(10);
        self.page = Some(self.next_id);
        self.page_deadline = Some(Instant::now() + PAGE_TIMEOUT);
        Ok(Some(json!({"jsonrpc":"2.0","id":self.next_id,"method":"_acpmux/sessions",
            "params":{"cursor":cursor}})))
    }

    /// This dedicated connection has only auth/watch (and its list's next page) plus one
    /// recovery lookup, staying below acpmux's per-connection request limit even for a large snapshot.
    fn start_next(&mut self) -> Vec<Value> {
        if self.active.is_some() {
            return vec![];
        }
        let Some(id) = self.queued.pop_front() else { return vec![] };
        let Some(request) = self.requests.get_mut(&id) else { return vec![] };
        request.deadline = Some(Instant::now() + INFO_TIMEOUT);
        self.active = Some(id);
        vec![json!({"jsonrpc":"2.0","id":id,"method":"_acpmux/info",
            "params":{"sessionId":request.session}})]
    }

    fn forget(&mut self, session: &str) {
        if let Some((_, id)) = self.sessions.remove(session)
            && self.active != Some(id)
        {
            self.requests.remove(&id);
            self.queued.retain(|queued| *queued != id);
        }
        // A request already sent still occupies the server's slot until its
        // response. Keep its deadline so a lost stale response cannot stall
        // later work; the state check above discards its eventual payload.
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
    fn a_watch_list_past_one_reply_reads_its_rest_from_the_cursor() {
        let mut waiting = Waiting::default();
        let mut classifier = Classifier::default();
        let first = json!({"id":2,"result":{"sessions":[],"nextCursor":"c1"}});
        let (queries, _) = receive(&mut waiting, &first, &mut classifier);
        assert_eq!(queries.len(), 1);
        assert_eq!(queries[0]["method"], "_acpmux/sessions");
        assert_eq!(queries[0]["params"], json!({"cursor":"c1"}));
        let rest = json!({"id":queries[0]["id"],"result":{"sessions":[session("waiting", 10)]}});
        let (queries, _) = receive(&mut waiting, &rest, &mut classifier);
        assert_eq!(queries.len(), 1);
        assert_eq!(queries[0]["method"], "_acpmux/info");
        assert_eq!(queries[0]["params"]["sessionId"], "s1");
    }

    #[test]
    fn a_watch_list_page_it_cannot_trust_fails_the_watch() {
        let mut classifier = Classifier::default();
        let first = json!({"id":2,"result":{"sessions":[],"nextCursor":"c1"}});
        let page = |waiting: &mut Waiting, classifier: &mut Classifier, result: Value| {
            let (queries, _) = receive(waiting, &first, classifier);
            let reply = json!({"id":queries[0]["id"],"result":result});
            waiting.receive(&reply, classifier).map(|(queries, _)| queries)
        };
        let mut waiting = Waiting::default();
        let twice = page(&mut waiting, &mut classifier, json!({"sessions":[],"nextCursor":"c1"}));
        assert!(twice.is_err_and(|why| why.contains("twice")));
        let mut waiting = Waiting::default();
        let number = page(&mut waiting, &mut classifier, json!({"sessions":[],"nextCursor":7}));
        assert!(number.is_err_and(|why| why.contains("page cursor 7")));
        let mut waiting = Waiting::default();
        let nothing = page(&mut waiting, &mut classifier, json!({"nextCursor":null}));
        assert!(nothing.is_err_and(|why| why.contains("lists no sessions")));
        let mut waiting = Waiting::default();
        let empty = page(&mut waiting, &mut classifier, json!({"sessions":[],"nextCursor":"c2"})).unwrap();
        assert_eq!(empty[0]["params"], json!({"cursor":"c2"}), "an empty page's cursor is followed");
        // The page asked for has a deadline (the watch reconnects past it); the whole list none.
        let due = waiting.next_deadline().expect("a page asked for is due");
        assert!(due > Instant::now() + PAGE_TIMEOUT - Duration::from_secs(5));
        let last = json!({"id":empty[0]["id"],"result":{"sessions":[]}});
        receive(&mut waiting, &last, &mut classifier);
        assert_eq!(waiting.next_deadline(), None);
        // A new watch reads the list again from its start, and may give the same cursors.
        assert_eq!(receive(&mut waiting, &first, &mut classifier).0[0]["params"], json!({"cursor":"c1"}));
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
        assert!(waiting.next_deadline().is_some(), "the server still holds the sent lookup's slot");
        // Older peers may reuse the same summary key on the next wait.
        assert!(receive(&mut waiting, &changed(session("waiting", 10)), &mut classifier).0.is_empty());
        let (new, pushes) = receive(&mut waiting, &reply(&old[0], pending("old")), &mut classifier);
        assert!(pushes.is_empty());
        assert_eq!(new.len(), 1);
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

    #[test]
    fn closed_and_unreachable_sessions_do_not_revive_pending_asks() {
        for status in ["closed", "unreachable", "disconnected"] {
            let mut waiting = Waiting::default();
            let mut classifier = Classifier::default();
            let mut summary = session("waiting", 10);
            summary["status"] = json!(status);
            summary["indicator"] = Value::Null;
            let (queries, pushes) = receive(&mut waiting, &changed(summary), &mut classifier);
            assert!(queries.is_empty(), "{status}");
            assert!(pushes.is_empty(), "{status}");
            assert!(waiting.next_deadline().is_none());
        }
    }

    #[test]
    fn large_snapshots_drain_one_lookup_at_a_time_and_drop_obsolete_queued_states() {
        let mut waiting = Waiting::default();
        let mut classifier = Classifier::default();
        let sessions: Vec<_> = (0..100)
            .map(|index| {
                let mut summary = session("waiting", 10);
                summary["sessionId"] = json!(format!("s{index}"));
                summary
            })
            .collect();
        let snapshot = json!({"id":2,"result":{"sessions":sessions}});
        let (mut queries, _) = receive(&mut waiting, &snapshot, &mut classifier);
        assert_eq!(queries.len(), 1, "never flood the server's 64 request slots");

        // A queued request that resolves must never be sent.
        let mut resolved = session("running", 11);
        resolved["sessionId"] = json!("s50");
        assert!(receive(&mut waiting, &changed(resolved), &mut classifier).0.is_empty());

        let mut count = 0;
        while let Some(query) = queries.pop() {
            assert!(queries.is_empty());
            assert_ne!(query["params"]["sessionId"], "s50");
            assert_eq!(waiting.requests.values().filter(|request| request.deadline.is_some()).count(), 1);
            let response = reply(&query, pending(&format!("p{count}")));
            let (next, pushes) = receive(&mut waiting, &response, &mut classifier);
            assert_eq!(pushes.len(), 1);
            assert!(next.len() <= 1);
            queries = next;
            count += 1;
        }
        assert_eq!(count, 99);
        assert!(waiting.next_deadline().is_none());
        assert!(waiting.requests.is_empty());
    }

    #[tokio::test]
    async fn recovered_push_survives_failure_to_send_the_next_lookup() {
        let mut waiting = Waiting::default();
        let mut classifier = Classifier::default();
        let first = session("waiting", 10);
        let mut second = first.clone();
        second["sessionId"] = json!("s2");
        let snapshot = json!({"id":2,"result":{"sessions":[first,second]}});
        let (queries, _) = receive(&mut waiting, &snapshot, &mut classifier);
        let (next_queries, pushes) =
            receive(&mut waiting, &reply(&queries[0], pending("p1")), &mut classifier);
        assert_eq!(next_queries.len(), 1);
        assert_eq!(next_queries[0]["params"]["sessionId"], "s2");
        assert_eq!(pushes.len(), 1);

        let mut reported = Vec::new();
        let mut sink = Box::pin(futures_util::sink::unfold(
            (),
            |(), _message: tokio_tungstenite::tungstenite::Message| {
                std::future::ready(Err::<(), _>("lookup send failed"))
            },
        ));
        let result =
            crate::notify::report_and_query(&mut sink, next_queries, pushes, |event| reported.push(event))
                .await;
        assert_eq!(result, Err("lookup send failed".into()));
        assert_eq!(reported.len(), 1, "a failed next query must not discard an already-seen push");
        assert_eq!(reported[0].permission_id.as_deref(), Some("p1"));

        // The watch reconnects, but the classifier survives and will not offer
        // p1 again. Its only chance to reach the reporter was before the failed send.
        let mut reconnected = Waiting::default();
        let (queries, _) = receive(&mut reconnected, &snapshot, &mut classifier);
        let (next, duplicate) =
            receive(&mut reconnected, &reply(&queries[0], pending("p1")), &mut classifier);
        assert!(duplicate.is_empty());
        let (_, recovered_second) =
            receive(&mut reconnected, &reply(&next[0], pending("p2")), &mut classifier);
        assert_eq!(recovered_second.len(), 1);
        assert_eq!(recovered_second[0].permission_id.as_deref(), Some("p2"));
    }
}
