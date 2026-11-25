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

/// A lookup that never answers in this long fails, as an error answer does: it is asked again
/// later (`LOOKUP_RETRY`), never by reading the watch list again.
const INFO_TIMEOUT: Duration = Duration::from_secs(10);
/// A failed lookup is asked again this long after, doubling each time, up to `LOOKUP_TRIES` asks
/// in all; then it waits for the chat's next change. A chat waiting on the person does not change
/// until they answer, so without a retry one passing failure lost its push for good.
const LOOKUP_RETRY: Duration = Duration::from_secs(30);
const LOOKUP_TRIES: u32 = 4;
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
    /// Failed lookups asked again at their `retry_at`: queued once it comes.
    delayed: Vec<u64>,
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
    /// Asks of this state's lookup that failed so far.
    failed: u32,
    /// A retry's time to be asked (`delayed`); none for a first ask.
    retry_at: Option<Instant>,
}

impl Pending {
    fn new(session: String, state: InputState) -> Self {
        Self { session, state, deadline: None, failed: 0, retry_at: None }
    }
}

impl Waiting {
    pub(crate) fn next_deadline(&self) -> Option<Instant> {
        let lookup = self.active.and_then(|id| self.requests.get(&id)?.deadline);
        // A retry can start only with no lookup out: while one is, its own deadline wakes us.
        let retry = if self.active.is_none() {
            self.delayed.iter().filter_map(|id| self.requests.get(id)?.retry_at).min()
        } else {
            None
        };
        lookup.into_iter().chain(retry).chain(self.page_deadline).min()
    }

    /// `next_deadline` came: a page of the list that never answered ends the watch (the next one
    /// reads the list from its start), but a lookup that never answered fails as an error answer
    /// does (`fail`), and a retry whose time came is sent.
    pub(crate) fn expire(&mut self, now: Instant) -> Result<Vec<Value>, String> {
        if self.page_deadline.is_some_and(|at| at <= now) {
            return Err("acpmux session page timed out".into());
        }
        if let Some(id) = self.active
            && self.requests.get(&id).and_then(|request| request.deadline).is_some_and(|at| at <= now)
            && let Some(request) = self.requests.remove(&id)
        {
            // Still in the server's slot until it answers; a late answer is no longer `active`.
            self.active = None;
            tracing::debug!(session = %request.session, "pending-input lookup timed out");
            self.fail(id, request, now);
        }
        Ok(self.start_next(now))
    }

    /// A lookup that failed or never answered, of the chat's current state: asked again later
    /// under a new id, with a deadline doubling from `LOOKUP_RETRY`, up to `LOOKUP_TRIES` asks.
    /// Then the state is kept, so only the chat's next change asks again. The watch and its list
    /// are never read again for it: that read the whole session list on every reconnect, and a
    /// chat whose lookup always failed (a slow or gone machine) did so every 30 s for as long as
    /// hostd ran (Leo's Mac, 2026-11-19: 10 GB from acpmux to hostd in a few hours).
    fn fail(&mut self, id: u64, request: Pending, now: Instant) {
        if self.sessions.get(&request.session) != Some(&(request.state.clone(), id)) {
            return;
        }
        let failed = request.failed + 1;
        if failed >= LOOKUP_TRIES {
            tracing::debug!(session = %request.session, failed, "pending-input lookup gave up");
            return;
        }
        let Some(next) = self.next_id.checked_add(1) else { return };
        let next = next.max(10);
        self.next_id = next;
        let retry_at = now + LOOKUP_RETRY * 2u32.pow(failed - 1);
        self.sessions.insert(request.session.clone(), (request.state.clone(), next));
        self.requests.insert(
            next,
            Pending { failed, retry_at: Some(retry_at), ..Pending::new(request.session, request.state) },
        );
        self.delayed.push(next);
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
            queries.extend(self.start_next(Instant::now()));
            return Ok((queries, vec![]));
        }
        if let Some(id) = message.get("id").and_then(Value::as_u64)
            && self.active == Some(id)
            && let Some(request) = self.requests.remove(&id)
        {
            self.active = None;
            let now = Instant::now();
            if self.sessions.get(&request.session) != Some(&(request.state.clone(), id)) {
                return Ok((self.start_next(now), vec![]));
            }
            if message.get("error").is_some() {
                // This chat's lookup only, asked again later (`fail`); the watch goes on.
                tracing::debug!(session = %request.session, "pending-input lookup failed");
                self.fail(id, request, now);
                return Ok((self.start_next(now), vec![]));
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
            return Ok((self.start_next(Instant::now()), pushes));
        }
        if message.get("method").and_then(Value::as_str) == Some("_acpmux/session_changed")
            && let Some(session) = message.pointer("/params/session")
        {
            self.observe(session)?;
        }
        Ok((self.start_next(Instant::now()), classifier.handle(message).into_iter().collect()))
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
        self.requests.insert(id, Pending::new(session_id.to_owned(), state));
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
    /// A retry whose time came (`fail`) is queued behind the lookups already waiting.
    fn start_next(&mut self, now: Instant) -> Vec<Value> {
        if self.active.is_some() {
            return vec![];
        }
        let requests = &self.requests;
        let (due, later): (Vec<u64>, Vec<u64>) = self
            .delayed
            .iter()
            .partition(|id| requests.get(id).and_then(|request| request.retry_at).is_none_or(|at| at <= now));
        self.delayed = later;
        self.queued.extend(due);
        let Some(id) = self.queued.pop_front() else { return vec![] };
        let Some(request) = self.requests.get_mut(&id) else { return vec![] };
        request.deadline = Some(now + INFO_TIMEOUT);
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
            self.delayed.retain(|delayed| *delayed != id);
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
    fn existing_turn_pushes_still_pass_through_and_a_failed_lookup_keeps_the_watch() {
        let mut waiting = Waiting::default();
        let mut classifier = Classifier::default();
        let done = json!({"method":"_acpmux/session_changed","params":{"recordKind":"turn_result",
            "session":{"sessionId":"s1","indicator":"done","lastTurn":{"turnId":"t1","status":"completed"}}}});
        let (_, pushes) = receive(&mut waiting, &done, &mut classifier);
        assert_eq!(pushes.len(), 1);
        assert_eq!(pushes[0].kind, "completed");
        let (queries, _) = receive(&mut waiting, &changed(session("waiting", 10)), &mut classifier);
        let error = json!({"id":queries[0]["id"],"error":{"code":-32000,"message":"gone"}});
        let (queries, pushes) = waiting.receive(&error, &mut classifier).expect("the watch goes on");
        assert!(queries.is_empty() && pushes.is_empty(), "asked again later, not at once");
        assert!(waiting.next_deadline().is_some(), "its retry is due later");
    }

    /// A chat waiting on the person does not change until they answer: a lookup of it that fails
    /// once is asked again after `LOOKUP_RETRY`, doubling, up to `LOOKUP_TRIES` asks; never by
    /// reading the list again. Then it waits for the chat's next change, which asks afresh.
    #[test]
    fn a_failed_lookup_is_asked_again_after_its_backoff_then_gives_up_until_a_change() {
        let mut waiting = Waiting::default();
        let mut classifier = Classifier::default();
        let (mut queries, _) = receive(&mut waiting, &changed(session("waiting", 10)), &mut classifier);
        let mut waits = Vec::new();
        for failed in 1..=LOOKUP_TRIES {
            assert_eq!(queries.len(), 1, "ask {failed}");
            assert_eq!(queries[0]["method"], "_acpmux/info");
            assert_eq!(queries[0]["params"]["sessionId"], "s1");
            // A failure counts its wait from when it is heard (the real now).
            let start = Instant::now();
            let error = json!({"id":queries[0]["id"],"error":{"code":-32000,"message":"busy"}});
            let (now, _) = waiting.receive(&error, &mut classifier).expect("the watch goes on");
            assert!(now.is_empty(), "never at once");
            if failed == LOOKUP_TRIES {
                break;
            }
            let due = waiting.next_deadline().expect("a retry is due");
            waits.push((due - start).as_secs());
            assert!(
                waiting.expire(due - Duration::from_millis(1)).unwrap().is_empty(),
                "not before its time"
            );
            queries = waiting.expire(due).expect("the watch goes on");
        }
        assert_eq!(waits, [30, 60, 120], "doubling from 30 s");
        assert!(waiting.next_deadline().is_none(), "gave up after {LOOKUP_TRIES} asks");
        // The same state is not asked again; its next change is, with its tries anew.
        assert!(receive(&mut waiting, &changed(session("waiting", 10)), &mut classifier).0.is_empty());
        let (queries, _) = receive(&mut waiting, &changed(session("waiting", 11)), &mut classifier);
        assert_eq!(queries.len(), 1);
        assert_eq!(waiting.requests[&queries[0]["id"].as_u64().unwrap()].failed, 0);
        // A retry answered: its push goes, once.
        let error = json!({"id":queries[0]["id"],"error":{"code":-32000,"message":"busy"}});
        waiting.receive(&error, &mut classifier).unwrap();
        let retry = waiting.expire(waiting.next_deadline().unwrap()).unwrap();
        let (_, pushes) = receive(&mut waiting, &reply(&retry[0], pending("p1")), &mut classifier);
        assert_eq!(pushes.len(), 1);
        assert!(waiting.next_deadline().is_none());
    }

    /// A chat whose lookup never answers (a slow or gone machine) ends only that lookup: the next
    /// chat's goes out and the watch stays. Ending the watch read the whole session list again
    /// each reconnect, every 30 s for as long as hostd ran (2026-11-19, 10 GB in a few hours).
    #[test]
    fn a_lookup_that_never_answers_ends_itself_not_the_watch() {
        let mut waiting = Waiting::default();
        let mut classifier = Classifier::default();
        let first = session("waiting", 10);
        let mut second = first.clone();
        second["sessionId"] = json!("s2");
        let snapshot = json!({"id":2,"result":{"sessions":[first,second]}});
        let (queries, _) = receive(&mut waiting, &snapshot, &mut classifier);
        assert_eq!(queries[0]["params"]["sessionId"], "s1");
        let due = waiting.next_deadline().expect("the lookup's deadline");
        assert!(waiting.expire(due - Duration::from_millis(1)).unwrap().is_empty(), "not yet due");
        let next = waiting.expire(due).expect("the watch goes on");
        assert_eq!(next.len(), 1);
        assert_eq!(next[0]["params"]["sessionId"], "s2");
        // s1's late answer is not s2's.
        let (more, pushes) = receive(&mut waiting, &reply(&queries[0], pending("p1")), &mut classifier);
        assert!(more.is_empty() && pushes.is_empty());
        let (_, pushes) = receive(&mut waiting, &reply(&next[0], pending("p2")), &mut classifier);
        assert_eq!(pushes.len(), 1);
        assert_eq!(pushes[0].permission_id.as_deref(), Some("p2"));
    }

    #[test]
    fn a_list_page_that_never_answers_ends_the_watch() {
        let mut waiting = Waiting::default();
        let mut classifier = Classifier::default();
        let first = json!({"id":2,"result":{"sessions":[],"nextCursor":"c1"}});
        let (queries, _) = receive(&mut waiting, &first, &mut classifier);
        assert_eq!(queries[0]["method"], "_acpmux/sessions");
        let due = waiting.next_deadline().expect("the page's deadline");
        assert!(waiting.expire(due).is_err());
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
