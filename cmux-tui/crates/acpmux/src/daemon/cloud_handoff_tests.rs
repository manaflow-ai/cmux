use super::*;
use std::collections::VecDeque;
use std::sync::Mutex;

/// The agent's socket as a script: each send takes the next reply (a send with none left fails
/// the test).
#[derive(Clone, Default)]
struct Fake(Arc<Mutex<FakeState>>);

#[derive(Default)]
struct FakeState {
    absent: bool,
    sent: Vec<Value>,
    replies: VecDeque<Reply>,
}

impl Io for Fake {
    fn present(&self) -> bool {
        !self.0.lock().unwrap().absent
    }
    async fn send(&self, line: String) -> Reply {
        let mut st = self.0.lock().unwrap();
        let v: Value = serde_json::from_str(&line).unwrap();
        st.sent.push(v["handoff_report"].clone());
        st.replies.pop_front().unwrap_or_else(|| panic!("no reply scripted for {line}"))
    }
}

impl Fake {
    fn answer(&self, replies: impl IntoIterator<Item = Reply>) {
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

/// A turn whose prompt names hand-off turn `n`.
fn began(n: u64) -> Step {
    Step::Began(Some(n))
}

fn ok(turn: u64, status: &str) -> Reply {
    Reply::Answer(
        json!({"ok": true, "handoff": {"id": "ho_x", "turn": turn, "state": "open", "status": status}}),
    )
}

fn refused(code: &str, turn: u64, status: &str) -> Reply {
    Reply::Answer(json!({"ok": false, "status": 409, "error": {"code": code, "message": "m"},
                "handoff": {"id": "ho_x", "turn": turn, "state": "open", "status": status}}))
}

fn not_found() -> Reply {
    Reply::Answer(
        json!({"ok": false, "status": 404, "error": {"code": "handoff.not_found", "message": "m"}}),
    )
}

fn busy() -> Reply {
    Reply::Answer(json!({"ok": false, "error": {"code": "busy", "message": "m"}}))
}

fn done(reply: &str) -> Step {
    Step::Ended(End::Completed(Some(reply.to_owned())))
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
    assert_eq!(
        step_of("turn_started", &json!({"prompt": "hi", "promptId": "handoff-3-9f2c"})),
        Some(Step::Began(Some(3)))
    );
    assert_eq!(
        step_of("turn_started", &json!({"prompt": "hi", "promptId": "p1"})),
        Some(Step::Began(None))
    );
    assert_eq!(step_of("reopened", &json!({})), Some(Step::Reopened));
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
        Some(Step::Ended(End::Completed(None)))
    );
    assert_eq!(
        step_of("turn_result", &json!({"status": "cancelled"})),
        Some(Step::Ended(End::Cancelled))
    );
    assert_eq!(
        step_of(
            "turn_result",
            &json!({"status": "failed", "error": "raw", "errorText": "Credit balance too low"}),
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

#[test]
fn a_prompt_id_names_its_turn() {
    assert_eq!(named_turn(Some("handoff-1-a")), Some(1));
    assert_eq!(named_turn(Some("handoff-42")), Some(42));
    assert_eq!(named_turn(Some("handoff-7-a~resume-2")), Some(7), "an auto-resumed attempt");
    for other in ["", "handoff-", "handoff-0-a", "handoff-01-a", "handoff-x-1", "p1", "HANDOFF-1-a"]
    {
        assert_eq!(named_turn(Some(other)), None, "{other}");
    }
    assert_eq!(named_turn(Some("handoff-9999999999999999-a")), None, "past a safe integer");
    assert_eq!(named_turn(None), None);
}

#[tokio::test]
async fn a_turn_reports_running_needs_you_running_and_done() {
    let (mut r, fake) = reporter();
    fake.answer([ok(1, "running"), ok(1, "needs-you"), ok(1, "running"), ok(1, "done")]);
    r.step(S, began(1)).await;
    r.step(S, Step::Runs).await; // already running: nothing to send
    r.step(S, Step::Asks(Some("Permission: Run npm install".into()))).await;
    r.step(S, Step::Asks(None)).await; // the status record of the same ask
    r.step(S, Step::Runs).await;
    r.step(S, done("Fixed the flaky test. It was a race.")).await;
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

/// Each turn reports on the turn its prompt names, never one learned from an earlier answer.
#[tokio::test]
async fn each_turn_reports_on_the_turn_its_prompt_names() {
    let (mut r, fake) = reporter();
    fake.answer([ok(3, "running"), ok(3, "failed"), ok(4, "running")]);
    r.step(S, began(3)).await;
    r.step(S, Step::Ended(End::Failed("Credit balance too low".into()))).await;
    r.step(S, began(4)).await;
    assert_eq!(
        fake.take(),
        [
            s(3, "running", None),
            s(3, "failed", Some("Credit balance too low")),
            s(4, "running", None)
        ]
    );
}

/// A begin that waited in the queue while the owner opened a newer turn stays on its own turn:
/// the store refuses it as stale, and nothing of that turn is sent.
#[tokio::test]
async fn a_queued_begin_never_lands_on_a_newer_turn() {
    let (mut r, fake) = reporter();
    fake.answer([refused("handoff.stale", 2, "starting")]);
    r.step(S, began(1)).await;
    r.step(S, Step::Asks(None)).await;
    r.step(S, Step::Ended(End::Completed(None))).await;
    assert_eq!(fake.take(), [s(1, "running", None)]);
}

#[tokio::test]
async fn a_late_report_never_lands_on_a_newer_turn() {
    let (mut r, fake) = reporter();
    fake.answer([ok(1, "running"), refused("handoff.stale", 2, "starting")]);
    r.step(S, began(1)).await;
    // The owner stopped turn 1 and opened turn 2 meanwhile: turn 1's end is stale and is not
    // sent again on turn 2.
    r.step(S, Step::Ended(End::Completed(None))).await;
    r.step(S, Step::Asks(None)).await;
    assert_eq!(fake.take(), [s(1, "running", None), s(1, "done", None)]);
}

#[tokio::test]
async fn a_prompt_that_names_no_turn_is_not_reported() {
    let (mut r, fake) = reporter();
    fake.answer([ok(1, "running"), ok(1, "done")]);
    r.step(S, began(1)).await;
    r.step(S, Step::Ended(End::Completed(None))).await;
    // A second prompt from a client that opened no turn for it: nothing of that turn is sent.
    r.step(S, Step::Began(None)).await;
    r.step(S, Step::Asks(Some("Ship it?".into()))).await;
    r.step(S, Step::Ended(End::Completed(None))).await;
    assert_eq!(fake.take(), [s(1, "running", None), s(1, "done", None)]);
}

#[tokio::test]
async fn a_turn_the_store_finished_is_not_reported_again() {
    let (mut r, fake) = reporter();
    fake.answer([refused("handoff.turn_finished", 1, "done")]);
    r.step(S, began(1)).await;
    r.step(S, Step::Ended(End::Completed(None))).await;
    assert_eq!(fake.take(), [s(1, "running", None)]);
}

#[tokio::test]
async fn a_session_with_no_hand_off_sends_one_report_a_turn() {
    let (mut r, fake) = reporter();
    fake.answer([not_found(), not_found()]);
    for turn in 1..=2 {
        r.step(S, began(turn)).await;
        r.step(S, Step::Asks(None)).await;
        r.step(S, Step::Ended(End::Completed(None))).await;
    }
    assert_eq!(fake.take(), [s(1, "running", None), s(2, "running", None)]);
}

#[tokio::test]
async fn a_closed_hand_off_gets_no_more_reports() {
    let (mut r, fake) = reporter();
    fake.answer([
        ok(1, "running"),
        Reply::Answer(json!({"ok": false, "status": 409,
        "error": {"code": "handoff.closed", "message": "m"},
        "handoff": {"id": "ho_x", "turn": 1, "state": "closed", "status": "cancelled"}})),
    ]);
    r.step(S, began(1)).await;
    r.step(S, Step::Asks(None)).await;
    r.step(S, Step::Ended(End::Completed(None))).await;
    r.step(S, began(2)).await;
    assert_eq!(fake.take(), [s(1, "running", None), s(1, "needs-you", None)]);
}

#[tokio::test]
async fn a_stopped_turn_and_a_closed_session_end_the_turn_failed() {
    let (mut r, fake) = reporter();
    fake.answer([ok(1, "running"), ok(1, "failed"), ok(2, "running"), ok(2, "failed")]);
    r.step(S, began(1)).await;
    r.step(S, Step::Ended(End::Cancelled)).await;
    r.step(S, began(2)).await;
    r.step(S, Step::Closed).await;
    // Closed again: nothing more is sent.
    r.step(S, Step::Closed).await;
    assert_eq!(
        fake.take(),
        [
            s(1, "running", None),
            s(1, "failed", Some("Stopped before it finished.")),
            s(2, "running", None),
            s(2, "failed", Some("The session was closed before the turn finished.")),
        ]
    );
}

#[tokio::test(start_paused = true)]
async fn a_report_the_store_did_not_get_is_sent_again() {
    let (mut r, fake) = reporter();
    let unreachable = Reply::Answer(
        json!({"ok": false, "error": {"code": "handoff.unreachable", "message": "m"}}),
    );
    fake.answer([ok(1, "running"), busy(), unreachable, ok(1, "done")]);
    r.step(S, began(1)).await;
    r.step(S, Step::Ended(End::Completed(None))).await;
    assert_eq!(
        fake.take(),
        [s(1, "running", None), s(1, "done", None), s(1, "done", None), s(1, "done", None)]
    );
    // A refusal that is the answer (a bad bearer, an invalid report) is not retried.
    fake.answer([Reply::Answer(
        json!({"ok": false, "status": 401, "error": {"code": "auth.unauthenticated", "message": "m"}}),
    )]);
    r.step(S, began(2)).await;
    assert_eq!(fake.take(), [s(2, "running", None)]);
}

/// The store did not answer a begin: the turn's later reports still go to its turn.
#[tokio::test(start_paused = true)]
async fn an_unanswered_begin_keeps_its_turn() {
    let (mut r, fake) = reporter();
    fake.answer([busy(), busy(), busy(), ok(3, "done")]);
    r.step(S, began(3)).await;
    r.step(S, done("Done.")).await;
    assert_eq!(
        fake.take(),
        [
            s(3, "running", None),
            s(3, "running", None),
            s(3, "running", None),
            s(3, "done", Some("Done."))
        ]
    );
}

/// An agent from before hand-off reports reads the line and never answers: one report waits
/// for it, then the agent is left alone for a while instead of holding every step.
#[tokio::test(start_paused = true)]
async fn an_agent_that_never_answers_is_not_asked_again_for_a_while() {
    let (mut r, fake) = reporter();
    fake.answer([Reply::Silent]);
    r.step(S, began(1)).await;
    r.step(S, Step::Asks(None)).await;
    r.step(S, Step::Ended(End::Completed(None))).await;
    r.step(S, began(2)).await;
    assert_eq!(fake.take(), [s(1, "running", None)], "one try, no retries, no later steps");
    tokio::time::advance(SILENT_FOR).await;
    fake.answer([ok(3, "running")]);
    r.step(S, began(3)).await;
    assert_eq!(fake.take(), [s(3, "running", None)]);
}

/// An agent that could not be reached is tried again and is not taken for one that never
/// answers: the next step is still sent.
#[tokio::test(start_paused = true)]
async fn an_unreachable_agent_is_tried_again_and_not_left_alone() {
    let (mut r, fake) = reporter();
    fake.answer([Reply::Failed, Reply::Failed, ok(1, "running"), ok(1, "needs-you")]);
    r.step(S, began(1)).await;
    r.step(S, Step::Asks(None)).await;
    assert_eq!(
        fake.take(),
        [
            s(1, "running", None),
            s(1, "running", None),
            s(1, "running", None),
            s(1, "needs-you", None)
        ]
    );
}

/// Records that arrive after a session closed report nothing until it reopens.
#[tokio::test]
async fn a_closed_session_reports_nothing_until_it_reopens() {
    let (mut r, fake) = reporter();
    fake.answer([ok(1, "running"), ok(1, "failed")]);
    r.step(S, began(1)).await;
    r.step(S, Step::Closed).await;
    r.step(S, began(2)).await;
    r.step(S, Step::Asks(Some("Ship it?".into()))).await;
    r.step(S, Step::Ended(End::Completed(None))).await;
    assert_eq!(
        fake.take(),
        [
            s(1, "running", None),
            s(1, "failed", Some("The session was closed before the turn finished."))
        ]
    );
    fake.answer([ok(2, "running")]);
    r.step(S, Step::Reopened).await;
    r.step(S, began(2)).await;
    assert_eq!(fake.take(), [s(2, "running", None)]);
}

/// A session that closes while the agent's socket is missing is still remembered as closed.
#[tokio::test]
async fn a_session_closed_without_the_agent_stays_closed() {
    let (mut r, fake) = reporter();
    fake.answer([ok(1, "running")]);
    r.step(S, began(1)).await;
    fake.0.lock().unwrap().absent = true;
    r.step(S, Step::Closed).await;
    fake.0.lock().unwrap().absent = false;
    r.step(S, began(2)).await;
    assert_eq!(fake.take(), [s(1, "running", None)]);
    fake.answer([ok(2, "running")]);
    r.step(S, Step::Reopened).await;
    r.step(S, began(2)).await;
    assert_eq!(fake.take(), [s(2, "running", None)]);
}

/// A session closed, reopened and closed again is remembered once, so forgetting the oldest
/// closed sessions never forgets one that is closed now.
#[tokio::test]
async fn a_session_closed_twice_is_remembered_once() {
    let (mut r, _fake) = reporter();
    r.step(S, Step::Closed).await;
    r.step(S, Step::Reopened).await;
    r.step(S, Step::Closed).await;
    assert_eq!(r.closed_order.iter().filter(|id| *id == S).count(), 1);
    assert!(r.closed.contains(S));
}

/// Past MAX_TRACKS sessions each reporting a turn, a new session is not followed.
#[tokio::test]
async fn the_followed_sessions_are_bounded() {
    let (mut r, fake) = reporter();
    for i in 0..MAX_TRACKS {
        r.tracks.insert(
            format!("acp_{i}"),
            Track { now: Now::Reporting { turn: 1, last: None }, closed: false },
        );
    }
    r.step(S, began(1)).await;
    assert_eq!(r.tracks.len(), MAX_TRACKS);
    assert!(fake.0.lock().unwrap().sent.is_empty());
    // A quiet session makes room.
    r.tracks.get_mut("acp_0").unwrap().now = Now::Quiet;
    fake.answer([ok(1, "running")]);
    r.step(S, began(1)).await;
    assert!(r.tracks.len() <= MAX_TRACKS);
    assert_eq!(fake.take(), [s(1, "running", None)]);
}

/// After the queue dropped steps, no turn being reported goes on: its end may be lost.
#[tokio::test]
async fn forgetting_turns_stops_their_reports() {
    let (mut r, fake) = reporter();
    fake.answer([ok(1, "running")]);
    r.step(S, began(1)).await;
    r.forget_turns();
    r.step(S, Step::Asks(None)).await;
    r.step(S, Step::Ended(End::Completed(None))).await;
    assert_eq!(fake.take(), [s(1, "running", None)]);
}

#[tokio::test]
async fn nothing_is_sent_without_the_agent_or_for_an_id_the_store_refuses() {
    let (mut r, fake) = reporter();
    fake.0.lock().unwrap().absent = true;
    r.step(S, began(1)).await;
    fake.0.lock().unwrap().absent = false;
    r.step("not/a session", began(1)).await;
    assert!(fake.0.lock().unwrap().sent.is_empty());
}
