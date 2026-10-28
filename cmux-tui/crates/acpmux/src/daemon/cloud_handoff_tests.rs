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

/// When the owner opened the turns the refusals name (API time).
const OPENED: &str = "2026-10-28T12:00:00.000Z";
const OPENED_MS: u64 = 1_793_188_800_000;
/// A turn that began here just after the owner opened it.
const BEGAN: Step = Step::Began { at: OPENED_MS + 500 };

fn ok(turn: u64, status: &str) -> Reply {
    Reply::Answer(
        json!({"ok": true, "handoff": {"id": "ho_x", "turn": turn, "state": "open", "status": status, "statusAt": OPENED}}),
    )
}

fn refused(code: &str, turn: u64, status: &str) -> Reply {
    Reply::Answer(json!({"ok": false, "status": 409, "error": {"code": code, "message": "m"},
                "handoff": {"id": "ho_x", "turn": turn, "state": "open", "status": status, "statusAt": OPENED}}))
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
    assert_eq!(step_of("turn_started", &json!({"prompt": "hi"}), 7), Some(Step::Began { at: 7 }));
    assert_eq!(step_of("reopened", &json!({}), 7), Some(Step::Reopened));
    let bash = json!({"request": {"toolCall": {"title": "Run npm install", "kind": "execute"}}});
    assert_eq!(
        step_of("permission_request", &bash, 0),
        Some(Step::Asks(Some("Permission: Run npm install".into())))
    );
    let ask = json!({"request": {"toolCall": {"title": "AskUserQuestion",
        "_meta": {"claude": {"tool": "AskUserQuestion"}}, "rawInput": {"questions": [{"question": "Ship it?"}]}}}});
    assert_eq!(step_of("permission_request", &ask, 0), Some(Step::Asks(Some("Ship it?".into()))));
    assert_eq!(step_of("status", &json!({"status": "waiting"}), 0), Some(Step::Asks(None)));
    assert_eq!(step_of("status", &json!({"status": "running"}), 0), Some(Step::Runs));
    assert_eq!(step_of("status", &json!({"status": "closed"}), 0), Some(Step::Closed));
    assert_eq!(step_of("status", &json!({"status": "ready"}), 0), None);
    assert_eq!(
        step_of("turn_result", &json!({"status": "completed"}), 0),
        Some(Step::Ended(End::Completed(None)))
    );
    assert_eq!(
        step_of("turn_result", &json!({"status": "cancelled"}), 0),
        Some(Step::Ended(End::Cancelled))
    );
    assert_eq!(
        step_of(
            "turn_result",
            &json!({"status": "failed", "error": "raw", "errorText": "Credit balance too low"}),
            0
        ),
        Some(Step::Ended(End::Failed("Credit balance too low".into())))
    );
    assert_eq!(step_of("agent_message_chunk", &json!({}), 0), None);
}

#[test]
fn summaries_are_masked_and_cut() {
    // A fake token, assembled so no file holds one.
    let token = format!("gh{}_{}", "p", "aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jS1234");
    let failed = step_of(
        "turn_result",
        &json!({"status": "failed", "error": format!("push failed with {token}")}),
        0,
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
    fake.answer([ok(1, "running"), ok(1, "needs-you"), ok(1, "running"), ok(1, "done")]);
    r.step(S, BEGAN).await;
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

#[tokio::test]
async fn a_begin_learns_the_current_turn_from_a_stale_refusal() {
    let (mut r, fake) = reporter();
    // After a daemon restart the reporter starts from turn 1; the owner opened turn 3.
    fake.answer([refused("handoff.stale", 3, "starting"), ok(3, "running"), ok(3, "failed")]);
    r.step(S, BEGAN).await;
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
    r.step(S, BEGAN).await;
    assert_eq!(fake.take(), [s(3, "running", None), s(4, "running", None)]);
}

#[tokio::test]
async fn a_late_report_never_lands_on_a_newer_turn() {
    let (mut r, fake) = reporter();
    fake.answer([ok(1, "running"), refused("handoff.stale", 2, "starting")]);
    r.step(S, BEGAN).await;
    // The owner stopped turn 1 and opened turn 2 meanwhile: turn 1's end is stale and is not
    // sent again on turn 2.
    r.step(S, Step::Ended(End::Completed(None))).await;
    assert_eq!(fake.take(), [s(1, "running", None), s(1, "done", None)]);
}

#[tokio::test]
async fn a_prompt_the_owner_did_not_open_a_turn_for_is_not_reported() {
    let (mut r, fake) = reporter();
    fake.answer([ok(1, "running"), ok(1, "done"), refused("handoff.turn_finished", 1, "done")]);
    r.step(S, BEGAN).await;
    r.step(S, Step::Ended(End::Completed(None))).await;
    // A second prompt from a client that did not open turn 2: its begin is refused, and
    // nothing of that turn is sent.
    r.step(S, BEGAN).await;
    r.step(S, Step::Asks(Some("Ship it?".into()))).await;
    r.step(S, Step::Ended(End::Completed(None))).await;
    assert_eq!(fake.take(), [s(1, "running", None), s(1, "done", None), s(1, "running", None)]);
}

#[tokio::test]
async fn a_session_with_no_hand_off_sends_one_report_a_turn() {
    let (mut r, fake) = reporter();
    fake.answer([not_found(), not_found()]);
    for _ in 0..2 {
        r.step(S, BEGAN).await;
        r.step(S, Step::Asks(None)).await;
        r.step(S, Step::Ended(End::Completed(None))).await;
    }
    assert_eq!(fake.take(), [s(1, "running", None), s(1, "running", None)]);
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
    r.step(S, BEGAN).await;
    r.step(S, Step::Asks(None)).await;
    r.step(S, Step::Ended(End::Completed(None))).await;
    r.step(S, BEGAN).await;
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
    r.step(S, BEGAN).await;
    r.step(S, Step::Ended(End::Cancelled)).await;
    r.step(S, BEGAN).await;
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
    let unreachable = Reply::Answer(
        json!({"ok": false, "error": {"code": "handoff.unreachable", "message": "m"}}),
    );
    fake.answer([ok(1, "running"), busy(), unreachable, ok(1, "done")]);
    r.step(S, BEGAN).await;
    r.step(S, Step::Ended(End::Completed(None))).await;
    assert_eq!(
        fake.take(),
        [s(1, "running", None), s(1, "done", None), s(1, "done", None), s(1, "done", None)]
    );
    // A refusal that is the answer (a bad bearer, an invalid report) is not retried.
    fake.answer([Reply::Answer(
        json!({"ok": false, "status": 401, "error": {"code": "auth.unauthenticated", "message": "m"}}),
    )]);
    r.step(S, BEGAN).await;
    assert_eq!(fake.take(), [s(1, "running", None)]);
}

/// An agent from before hand-off reports reads the line and never answers: one report waits
/// for it, then the agent is left alone for a while instead of holding every step.
#[tokio::test(start_paused = true)]
async fn an_agent_that_never_answers_is_not_asked_again_for_a_while() {
    let (mut r, fake) = reporter();
    fake.answer([Reply::Silent]);
    r.step(S, BEGAN).await;
    r.step(S, Step::Asks(None)).await;
    r.step(S, Step::Ended(End::Completed(None))).await;
    r.step(S, BEGAN).await;
    assert_eq!(fake.take(), [s(1, "running", None)], "one try, no retries, no later steps");
    tokio::time::advance(SILENT_FOR).await;
    fake.answer([ok(1, "running")]);
    r.step(S, BEGAN).await;
    assert_eq!(fake.take(), [s(1, "running", None)]);
}

#[tokio::test]
async fn nothing_is_sent_without_the_agent_or_for_an_id_the_store_refuses() {
    let (mut r, fake) = reporter();
    fake.0.lock().unwrap().absent = true;
    r.step(S, BEGAN).await;
    fake.0.lock().unwrap().absent = false;
    r.step("not/a session", BEGAN).await;
    assert!(fake.0.lock().unwrap().sent.is_empty());
}

/// A begin that waited in the queue while the owner opened a newer turn keeps off it: the turn
/// the refusal names was opened after this one began.
#[tokio::test]
async fn a_queued_begin_never_takes_a_turn_opened_after_it() {
    let (mut r, fake) = reporter();
    let long_before = Step::Began { at: OPENED_MS - SKEW_MS - 1 };
    fake.answer([refused("handoff.stale", 3, "starting")]);
    r.step(S, long_before).await;
    r.step(S, Step::Asks(None)).await;
    r.step(S, Step::Ended(End::Completed(None))).await;
    assert_eq!(fake.take(), [s(1, "running", None)]);
    // Within the clock skew it is the same turn.
    let just_before = Step::Began { at: OPENED_MS - SKEW_MS };
    fake.answer([refused("handoff.stale", 4, "starting"), ok(4, "running")]);
    r.step(S, just_before).await;
    assert_eq!(fake.take(), [s(3, "running", None), s(4, "running", None)]);
}

/// A turn something already reported on (another daemon, an earlier begin) is not taken.
#[tokio::test]
async fn a_begin_never_takes_a_turn_already_reported_on() {
    let (mut r, fake) = reporter();
    fake.answer([refused("handoff.stale", 3, "running")]);
    r.step(S, BEGAN).await;
    r.step(S, Step::Ended(End::Completed(None))).await;
    assert_eq!(fake.take(), [s(1, "running", None)]);
}

/// The store did not answer the begin's second report: the turn's later reports still go to the
/// turn the refusal named, never back to the one first tried.
#[tokio::test(start_paused = true)]
async fn an_unanswered_begin_keeps_the_turn_it_was_sent_on() {
    let (mut r, fake) = reporter();
    fake.answer([refused("handoff.stale", 3, "starting"), busy(), busy(), busy(), ok(3, "done")]);
    r.step(S, BEGAN).await;
    r.step(S, done("Done.")).await;
    assert_eq!(
        fake.take(),
        [
            s(1, "running", None),
            s(3, "running", None),
            s(3, "running", None),
            s(3, "running", None),
            s(3, "done", Some("Done.")),
        ]
    );
}

/// An agent that could not be reached is tried again and is not taken for one that never
/// answers: the next step is still sent.
#[tokio::test(start_paused = true)]
async fn an_unreachable_agent_is_tried_again_and_not_left_alone() {
    let (mut r, fake) = reporter();
    fake.answer([Reply::Failed, Reply::Failed, ok(1, "running"), ok(1, "needs-you")]);
    r.step(S, BEGAN).await;
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
    r.step(S, BEGAN).await;
    r.step(S, Step::Closed).await;
    r.step(S, BEGAN).await;
    r.step(S, Step::Asks(Some("Ship it?".into()))).await;
    r.step(S, Step::Ended(End::Completed(None))).await;
    assert_eq!(
        fake.take(),
        [
            s(1, "running", None),
            s(1, "failed", Some("The session was closed before the turn finished.")),
        ]
    );
    fake.answer([refused("handoff.stale", 2, "starting"), ok(2, "running")]);
    r.step(S, Step::Reopened).await;
    r.step(S, BEGAN).await;
    assert_eq!(fake.take(), [s(1, "running", None), s(2, "running", None)]);
}

/// A session that closes while the agent's socket is missing is still remembered as closed.
#[tokio::test]
async fn a_session_closed_without_the_agent_stays_closed() {
    let (mut r, fake) = reporter();
    fake.answer([ok(1, "running")]);
    r.step(S, BEGAN).await;
    fake.0.lock().unwrap().absent = true;
    r.step(S, Step::Closed).await;
    fake.0.lock().unwrap().absent = false;
    r.step(S, BEGAN).await;
    assert_eq!(fake.take(), [s(1, "running", None)]);
    fake.answer([ok(1, "running")]);
    r.step(S, Step::Reopened).await;
    r.step(S, BEGAN).await;
    assert_eq!(fake.take(), [s(1, "running", None)]);
}
