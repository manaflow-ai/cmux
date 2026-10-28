use super::*;
use std::collections::VecDeque;
use std::sync::Mutex;

/// The agent's socket as a script: each send takes the next reply (none left: no reply).
#[derive(Clone, Default)]
struct Fake(Arc<Mutex<FakeState>>);

#[derive(Default)]
struct FakeState {
    absent: bool,
    sent: Vec<Value>,
    replies: VecDeque<Option<Value>>,
    reply_text: Option<String>,
}

impl Io for Fake {
    fn present(&self) -> bool {
        !self.0.lock().unwrap().absent
    }
    async fn send(&self, line: String) -> Option<Value> {
        let mut st = self.0.lock().unwrap();
        let v: Value = serde_json::from_str(&line).unwrap();
        st.sent.push(v["handoff_report"].clone());
        st.replies.pop_front().flatten()
    }
    async fn last_reply(&self, _session: &str) -> Option<String> {
        self.0.lock().unwrap().reply_text.clone()
    }
}

impl Fake {
    fn answer(&self, replies: impl IntoIterator<Item = Option<Value>>) {
        self.0.lock().unwrap().replies.extend(replies);
    }
    /// The reports sent so far, as `(turn, status, summary)`, and forgets them.
    fn take(&self) -> Vec<(u64, String, Option<String>)> {
        let sent = std::mem::take(&mut self.0.lock().unwrap().sent);
        sent.iter()
            .map(|r| {
                assert_eq!(r["session"], "acp_s1");
                let summary = r.get("summary").and_then(Value::as_str).map(str::to_owned);
                (r["turn"].as_u64().unwrap(), r["status"].as_str().unwrap().to_owned(), summary)
            })
            .collect()
    }
}

fn ok(turn: u64, status: &str) -> Option<Value> {
    Some(
        json!({"ok": true, "handoff": {"id": "ho_x", "turn": turn, "state": "open", "status": status}}),
    )
}

fn refused(code: &str, turn: u64, status: &str) -> Option<Value> {
    Some(json!({"ok": false, "status": 409, "error": {"code": code, "message": "m"},
                "handoff": {"id": "ho_x", "turn": turn, "state": "open", "status": status}}))
}

fn not_found() -> Option<Value> {
    Some(
        json!({"ok": false, "status": 404, "error": {"code": "handoff.not_found", "message": "m"}}),
    )
}

const S: &str = "acp_s1";

fn reporter() -> (Reporter<Fake>, Fake) {
    let fake = Fake::default();
    (Reporter::new(fake.clone()), fake)
}

fn s(turn: u64, status: &str, summary: Option<&str>) -> (u64, String, Option<String>) {
    (turn, status.to_owned(), summary.map(str::to_owned))
}

#[test]
fn records_map_to_steps() {
    assert_eq!(step_of("turn_started", &json!({"prompt": "hi"})), Some(Step::Began));
    let bash = json!({"request": {"toolCall": {"title": "Run npm install", "kind": "execute"}}});
    assert_eq!(
        step_of("permission_request", &bash),
        Some(Step::Asks(Some("Permission: Run npm install".into())))
    );
    let ask = json!({"request": {"toolCall": {"title": "AskUserQuestion",
        "_meta": {"claude": {"tool": "AskUserQuestion"}}, "rawInput": {"questions": [{"question": "Ship it?"}]}}}});
    assert_eq!(step_of("permission_request", &ask), Some(Step::Asks(Some("Ship it?".into()))));
    assert_eq!(step_of("status", &json!({"status": "waiting"})), Some(Step::Asks(None)));
    assert_eq!(step_of("status", &json!({"status": "running"})), Some(Step::Runs));
    assert_eq!(step_of("status", &json!({"status": "closed"})), Some(Step::Closed));
    assert_eq!(step_of("status", &json!({"status": "ready"})), None);
    assert_eq!(
        step_of("turn_result", &json!({"status": "completed"})),
        Some(Step::Ended(End::Completed))
    );
    assert_eq!(
        step_of("turn_result", &json!({"status": "cancelled"})),
        Some(Step::Ended(End::Cancelled))
    );
    assert_eq!(
        step_of(
            "turn_result",
            &json!({"status": "failed", "error": "raw", "errorText": "Credit balance too low"})
        ),
        Some(Step::Ended(End::Failed("Credit balance too low".into())))
    );
    assert_eq!(step_of("agent_message_chunk", &json!({})), None);
}

#[test]
fn summaries_are_masked_and_cut() {
    // A fake token, assembled so no file holds one.
    let token = format!("gh{}_{}", "p", "aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jS1234");
    let failed = step_of(
        "turn_result",
        &json!({"status": "failed", "error": format!("push failed with {token}")}),
    );
    let Some(Step::Ended(End::Failed(why))) = failed else { panic!("{failed:?}") };
    assert!(!why.contains(&token), "{why}");
    let long = cut(&"word ".repeat(400), NOTE_CHARS);
    assert_eq!(long.chars().count(), NOTE_CHARS + 1);
    assert!(long.ends_with('…'));
}

#[tokio::test]
async fn a_turn_reports_running_needs_you_running_and_done() {
    let (mut r, fake) = reporter();
    fake.0.lock().unwrap().reply_text = Some("Fixed the flaky test.\n\nIt was a race.".into());
    fake.answer([ok(1, "running"), ok(1, "needs-you"), ok(1, "running"), ok(1, "done")]);
    r.step(S, Step::Began).await;
    r.step(S, Step::Runs).await; // already running: nothing to send
    r.step(S, Step::Asks(Some("Permission: Run npm install".into()))).await;
    r.step(S, Step::Asks(None)).await; // the status record of the same ask
    r.step(S, Step::Runs).await;
    r.step(S, Step::Ended(End::Completed)).await;
    assert_eq!(
        fake.take(),
        [
            s(1, "running", None),
            s(1, "needs-you", Some("Permission: Run npm install")),
            s(1, "running", None),
            s(1, "done", Some("Fixed the flaky test. It was a race.")),
        ]
    );
}

#[tokio::test]
async fn a_begin_learns_the_current_turn_from_a_stale_refusal() {
    let (mut r, fake) = reporter();
    // After a daemon restart the reporter starts from turn 1; the owner opened turn 3.
    fake.answer([refused("handoff.stale", 3, "starting"), ok(3, "running"), ok(3, "failed")]);
    r.step(S, Step::Began).await;
    r.step(S, Step::Ended(End::Failed("Credit balance too low".into()))).await;
    assert_eq!(
        fake.take(),
        [
            s(1, "running", None),
            s(3, "running", None),
            s(3, "failed", Some("Credit balance too low"))
        ]
    );
    // The next turn begins on the turn it learned.
    fake.answer([refused("handoff.stale", 4, "starting"), ok(4, "running")]);
    r.step(S, Step::Began).await;
    assert_eq!(fake.take(), [s(3, "running", None), s(4, "running", None)]);
}

#[tokio::test]
async fn a_late_report_never_lands_on_a_newer_turn() {
    let (mut r, fake) = reporter();
    fake.answer([ok(1, "running"), refused("handoff.stale", 2, "starting")]);
    r.step(S, Step::Began).await;
    // The owner stopped turn 1 and opened turn 2 meanwhile: turn 1's end is stale and is not
    // sent again on turn 2.
    r.step(S, Step::Ended(End::Completed)).await;
    assert_eq!(fake.take(), [s(1, "running", None), s(1, "done", None)]);
}

#[tokio::test]
async fn a_prompt_the_owner_did_not_open_a_turn_for_is_not_reported() {
    let (mut r, fake) = reporter();
    fake.answer([ok(1, "running"), ok(1, "done"), refused("handoff.turn_finished", 1, "done")]);
    r.step(S, Step::Began).await;
    r.step(S, Step::Ended(End::Completed)).await;
    // A second prompt from a client that did not open turn 2: its begin is refused, and
    // nothing of that turn is sent.
    r.step(S, Step::Began).await;
    r.step(S, Step::Asks(Some("Ship it?".into()))).await;
    r.step(S, Step::Ended(End::Completed)).await;
    assert_eq!(fake.take(), [s(1, "running", None), s(1, "done", None), s(1, "running", None)]);
}

#[tokio::test]
async fn a_session_with_no_hand_off_sends_one_report_a_turn() {
    let (mut r, fake) = reporter();
    fake.answer([not_found(), not_found()]);
    for _ in 0..2 {
        r.step(S, Step::Began).await;
        r.step(S, Step::Asks(None)).await;
        r.step(S, Step::Ended(End::Completed)).await;
    }
    assert_eq!(fake.take(), [s(1, "running", None), s(1, "running", None)]);
}

#[tokio::test]
async fn a_closed_hand_off_gets_no_more_reports() {
    let (mut r, fake) = reporter();
    fake.answer([
        ok(1, "running"),
        Some(json!({"ok": false, "status": 409,
        "error": {"code": "handoff.closed", "message": "m"},
        "handoff": {"id": "ho_x", "turn": 1, "state": "closed", "status": "cancelled"}})),
    ]);
    r.step(S, Step::Began).await;
    r.step(S, Step::Asks(None)).await;
    r.step(S, Step::Ended(End::Completed)).await;
    r.step(S, Step::Began).await;
    assert_eq!(fake.take(), [s(1, "running", None), s(1, "needs-you", None)]);
}

#[tokio::test]
async fn a_stopped_turn_and_a_closed_session_end_the_turn_failed() {
    let (mut r, fake) = reporter();
    fake.answer([
        ok(1, "running"),
        ok(1, "failed"),
        refused("handoff.stale", 2, "starting"),
        ok(2, "running"),
        ok(2, "failed"),
    ]);
    r.step(S, Step::Began).await;
    r.step(S, Step::Ended(End::Cancelled)).await;
    r.step(S, Step::Began).await;
    r.step(S, Step::Closed).await;
    // Closed again: the session was forgotten, nothing more is sent.
    r.step(S, Step::Closed).await;
    assert_eq!(
        fake.take(),
        [
            s(1, "running", None),
            s(1, "failed", Some("Stopped before it finished.")),
            s(1, "running", None),
            s(2, "running", None),
            s(2, "failed", Some("The session was closed before the turn finished.")),
        ]
    );
}

#[tokio::test(start_paused = true)]
async fn a_report_the_store_did_not_get_is_sent_again() {
    let (mut r, fake) = reporter();
    let busy = Some(json!({"ok": false, "error": {"code": "busy", "message": "m"}}));
    let unreachable =
        Some(json!({"ok": false, "error": {"code": "handoff.unreachable", "message": "m"}}));
    fake.answer([ok(1, "running"), busy, unreachable, ok(1, "done")]);
    r.step(S, Step::Began).await;
    r.step(S, Step::Ended(End::Completed)).await;
    assert_eq!(
        fake.take(),
        [s(1, "running", None), s(1, "done", None), s(1, "done", None), s(1, "done", None)]
    );
    // A refusal that is the answer (a bad bearer, an invalid report) is not retried.
    fake.answer([Some(
        json!({"ok": false, "status": 401, "error": {"code": "auth.unauthenticated", "message": "m"}}),
    )]);
    r.step(S, Step::Began).await;
    assert_eq!(fake.take(), [s(1, "running", None)]);
}

/// An agent from before hand-off reports reads the line and never answers: one report waits
/// for it, then the agent is left alone for a while instead of holding every step.
#[tokio::test(start_paused = true)]
async fn an_agent_that_never_answers_is_not_asked_again_for_a_while() {
    let (mut r, fake) = reporter();
    fake.answer([None]);
    r.step(S, Step::Began).await;
    r.step(S, Step::Asks(None)).await;
    r.step(S, Step::Ended(End::Completed)).await;
    r.step(S, Step::Began).await;
    assert_eq!(fake.take(), [s(1, "running", None)], "one try, no retries, no later steps");
    tokio::time::advance(SILENT_FOR).await;
    fake.answer([ok(1, "running")]);
    r.step(S, Step::Began).await;
    assert_eq!(fake.take(), [s(1, "running", None)]);
}

#[tokio::test]
async fn nothing_is_sent_without_the_agent_or_for_an_id_the_store_refuses() {
    let (mut r, fake) = reporter();
    fake.0.lock().unwrap().absent = true;
    r.step(S, Step::Began).await;
    fake.0.lock().unwrap().absent = false;
    r.step("not/a session", Step::Began).await;
    assert!(fake.0.lock().unwrap().sent.is_empty());
}
