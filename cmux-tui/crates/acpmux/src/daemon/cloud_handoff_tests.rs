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

fn done(turn: u64, reply: &str) -> Step {
    Step::Ended(End::Completed(Some(reply.to_owned())), Some(turn))
}

/// A failure acpmux does not retry by itself.
fn failed(why: &str) -> End {
    End::Failed { why: why.to_owned(), retried: false }
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
        step_of("turn_result", &json!({"status": "completed", "promptId": "handoff-2-a"})),
        Some(Step::Ended(End::Completed(None), Some(2)))
    );
    assert_eq!(
        step_of("turn_result", &json!({"status": "cancelled"})),
        Some(Step::Ended(End::Cancelled, None))
    );
    assert_eq!(
        step_of(
            "turn_result",
            &json!({"status": "failed", "error": "raw", "errorText": "Credit balance too low"}),
        ),
        Some(Step::Ended(failed("Credit balance too low"), None))
    );
    // A connection cut: acpmux continues the turn by itself.
    let cut_off = json!({"status": "failed", "errorText": "stream disconnected before completion", "promptId": "handoff-4-a~resume-1"});
    assert_eq!(
        step_of("turn_result", &cut_off),
        Some(Step::Ended(
            End::Failed { why: "stream disconnected before completion".into(), retried: true },
            Some(4)
        ))
    );
    for kind in ["auto_resume_settled", "auto_resume_exhausted", "auto_resume_skipped"] {
        assert_eq!(step_of(kind, &json!({"turnId": "t1"})), Some(Step::NoRetry), "{kind}");
    }
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
    let Some(Step::Ended(End::Failed { why, .. }, _)) = failed else { panic!("{failed:?}") };
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
    r.step(S, done(1, "Fixed the flaky test. It was a race.")).await;
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
    r.step(S, Step::Ended(failed("Credit balance too low"), Some(3))).await;
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
    r.step(S, Step::Ended(End::Completed(None), Some(1))).await;
    assert_eq!(fake.take(), [s(1, "running", None)]);
}

#[tokio::test]
async fn a_late_report_never_lands_on_a_newer_turn() {
    let (mut r, fake) = reporter();
    fake.answer([ok(1, "running"), refused("handoff.stale", 2, "starting")]);
    r.step(S, began(1)).await;
    // The owner stopped turn 1 and opened turn 2 meanwhile: turn 1's end is stale and is not
    // sent again on turn 2.
    r.step(S, Step::Ended(End::Completed(None), Some(1))).await;
    r.step(S, Step::Asks(None)).await;
    assert_eq!(fake.take(), [s(1, "running", None), s(1, "done", None)]);
}

#[tokio::test]
async fn a_prompt_that_names_no_turn_is_not_reported() {
    let (mut r, fake) = reporter();
    fake.answer([ok(1, "running"), ok(1, "done")]);
    r.step(S, began(1)).await;
    r.step(S, Step::Ended(End::Completed(None), Some(1))).await;
    // A second prompt from a client that opened no turn for it: nothing of that turn is sent.
    r.step(S, Step::Began(None)).await;
    r.step(S, Step::Asks(Some("Ship it?".into()))).await;
    r.step(S, Step::Ended(End::Completed(None), None)).await;
    assert_eq!(fake.take(), [s(1, "running", None), s(1, "done", None)]);
}

#[tokio::test]
async fn a_turn_the_store_finished_is_not_reported_again() {
    let (mut r, fake) = reporter();
    fake.answer([refused("handoff.turn_finished", 1, "done")]);
    r.step(S, began(1)).await;
    r.step(S, Step::Ended(End::Completed(None), Some(1))).await;
    assert_eq!(fake.take(), [s(1, "running", None)]);
}

#[tokio::test]
async fn a_session_with_no_hand_off_sends_one_report_a_turn() {
    let (mut r, fake) = reporter();
    fake.answer([not_found(), not_found()]);
    for turn in 1..=2 {
        r.step(S, began(turn)).await;
        r.step(S, Step::Asks(None)).await;
        r.step(S, Step::Ended(End::Completed(None), Some(turn))).await;
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
    r.step(S, Step::Ended(End::Completed(None), Some(1))).await;
    r.step(S, began(2)).await;
    assert_eq!(fake.take(), [s(1, "running", None), s(1, "needs-you", None)]);
}

#[tokio::test]
async fn a_stopped_turn_and_a_closed_session_end_the_turn_failed() {
    let (mut r, fake) = reporter();
    fake.answer([ok(1, "running"), ok(1, "failed"), ok(2, "running"), ok(2, "failed")]);
    r.step(S, began(1)).await;
    r.step(S, Step::Ended(End::Cancelled, Some(1))).await;
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
    r.step(S, Step::Ended(End::Completed(None), Some(1))).await;
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
    r.step(S, done(3, "Done.")).await;
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
    r.step(S, Step::Ended(End::Completed(None), Some(1))).await;
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
    r.step(S, Step::Ended(End::Completed(None), Some(2))).await;
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
    assert_eq!(r.closed.count(S), 1);
    assert!(r.closed.contains(S));
}

/// Past MAX_TRACKS sessions each reporting a turn, a new session is not followed.
#[tokio::test]
async fn the_followed_sessions_are_bounded() {
    let (mut r, fake) = reporter();
    for i in 0..MAX_TRACKS {
        r.tracks.insert(
            format!("acp_{i}"),
            Track { now: Now::Reporting { turn: 1, last: None }, refused: None },
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

/// After the queue dropped steps, no needs-you or running goes on a turn being reported (its
/// end may be lost, and these records name no turn); an end, which names its turn, still does.
#[tokio::test]
async fn forgotten_turns_report_no_needs_you_but_still_their_end() {
    let (mut r, fake) = reporter();
    fake.answer([ok(1, "running"), ok(1, "done")]);
    r.step(S, began(1)).await;
    r.forget_turns();
    r.step(S, Step::Asks(None)).await;
    r.step(S, Step::Ended(End::Completed(None), Some(1))).await;
    // An end of a prompt that names no turn ends nothing.
    r.step(S, Step::Ended(End::Completed(None), None)).await;
    assert_eq!(fake.take(), [s(1, "running", None), s(1, "done", None)]);
}

/// A turn that failed before it started (no `turn_started`) still reports its failure.
#[tokio::test]
async fn a_turn_that_failed_before_it_started_reports_its_failure() {
    let (mut r, fake) = reporter();
    fake.answer([ok(2, "failed")]);
    r.step(S, Step::Ended(failed("agent could not start"), Some(2))).await;
    assert_eq!(fake.take(), [s(2, "failed", Some("agent could not start"))]);
}

fn cut_off(turn: u64) -> Step {
    Step::Ended(End::Failed { why: "stream disconnected".into(), retried: true }, Some(turn))
}

/// A turn acpmux continues by itself is not failed on the hand-off: its continuation goes on
/// on the same turn, and its end is the turn's.
#[tokio::test]
async fn a_cut_turn_goes_on_with_its_continuation() {
    let (mut r, fake) = reporter();
    fake.answer([ok(1, "running"), ok(1, "running"), ok(1, "done")]);
    r.step(S, began(1)).await;
    r.step(S, cut_off(1)).await;
    assert_eq!(fake.take(), [s(1, "running", None)], "no failure while a continuation may come");
    // `handoff-1-a~resume-1` names turn 1.
    r.step(S, began(1)).await;
    r.step(S, done(1, "Picked up where it stopped.")).await;
    assert_eq!(
        fake.take(),
        [s(1, "running", None), s(1, "done", Some("Picked up where it stopped."))]
    );
}

/// A cut turn with no continuation coming is reported failed: no retry, another prompt, a close,
/// or too long a wait.
#[tokio::test(start_paused = true)]
async fn a_cut_turn_with_no_continuation_ends_failed() {
    let failed_1 = || s(1, "failed", Some("stream disconnected"));
    // No retry is decided.
    let (mut r, fake) = reporter();
    fake.answer([ok(1, "running"), ok(1, "failed")]);
    r.step(S, began(1)).await;
    r.step(S, cut_off(1)).await;
    r.step(S, Step::NoRetry).await;
    r.step(S, Step::NoRetry).await;
    assert_eq!(fake.take(), [s(1, "running", None), failed_1()]);
    // Another prompt takes the chat.
    let (mut r, fake) = reporter();
    fake.answer([ok(1, "running"), ok(1, "failed"), ok(2, "running")]);
    r.step(S, began(1)).await;
    r.step(S, cut_off(1)).await;
    r.step(S, began(2)).await;
    assert_eq!(fake.take(), [s(1, "running", None), failed_1(), s(2, "running", None)]);
    // The session closes.
    let (mut r, fake) = reporter();
    fake.answer([ok(1, "running"), ok(1, "failed")]);
    r.step(S, began(1)).await;
    r.step(S, cut_off(1)).await;
    r.step(S, Step::Closed).await;
    assert_eq!(fake.take(), [s(1, "running", None), failed_1()]);
    // Nothing comes for longer than any wait: the next step of the session ends it.
    let (mut r, fake) = reporter();
    fake.answer([ok(1, "running"), ok(1, "failed")]);
    r.step(S, began(1)).await;
    r.step(S, cut_off(1)).await;
    tokio::time::advance(DECIDE_WAIT).await;
    r.step(S, Step::Asks(None)).await;
    assert_eq!(fake.take(), [s(1, "running", None), failed_1()]);
}

/// With no further event at all, the worker's own deadline reports the turn: within DECIDE_WAIT
/// when no continuation was scheduled, within RETRY_WAIT_MAX of the last one that was.
#[tokio::test(start_paused = true)]
async fn a_cut_turn_is_ended_by_its_deadline_without_another_event() {
    let (mut r, fake) = reporter();
    fake.answer([ok(1, "running"), ok(1, "failed")]);
    r.step(S, began(1)).await;
    let failed_at = tokio::time::Instant::now();
    r.step(S, cut_off(1)).await;
    assert_eq!(r.next_deadline(), Some(failed_at + DECIDE_WAIT));
    r.step(S, Step::RetryScheduled).await;
    let scheduled = r.next_deadline().unwrap();
    assert_eq!(scheduled, tokio::time::Instant::now() + RETRY_WAIT_MAX);
    r.expire().await;
    assert_eq!(fake.take(), [s(1, "running", None)], "not due yet");
    tokio::time::advance(RETRY_WAIT_MAX).await;
    r.expire().await;
    assert_eq!(fake.take(), [s(1, "failed", Some("stream disconnected"))]);
    assert_eq!(r.next_deadline(), None);
}

/// The hub decides on the agent's own error or the recorded one: a cause in either holds the
/// turn for its continuation.
#[test]
fn a_cause_in_the_raw_error_holds_the_turn() {
    let msg = json!({"status": "failed", "error": "stream disconnected before completion",
        "errorText": "The turn failed.", "promptId": "handoff-1-a"});
    let Some(Step::Ended(End::Failed { why, retried }, Some(1))) = step_of("turn_result", &msg)
    else {
        panic!()
    };
    assert!(retried);
    assert_eq!(why, "The turn failed.");
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

/// A continuation whose event came in time counts, even when a busy worker gets to it after the
/// deadline: the deadline is judged by when the event was queued.
#[tokio::test(start_paused = true)]
async fn a_continuation_that_came_in_time_counts_however_late_it_is_handled() {
    let (mut r, fake) = reporter();
    fake.answer([ok(1, "running"), ok(1, "running"), ok(1, "done")]);
    r.step(S, began(1)).await;
    r.step(S, cut_off(1)).await;
    let came = tokio::time::Instant::now() + Duration::from_secs(30);
    // The worker was held by another report until well past DECIDE_WAIT.
    tokio::time::advance(DECIDE_WAIT * 3).await;
    r.step_at(S, Step::RetryScheduled, came).await;
    r.step_at(S, began(1), came + Duration::from_secs(10)).await;
    r.step(S, done(1, "Back.")).await;
    assert_eq!(
        fake.take(),
        [s(1, "running", None), s(1, "running", None), s(1, "done", Some("Back."))]
    );
}

/// An agent that stops answering while due turns are reported is not asked again for each one.
#[tokio::test(start_paused = true)]
async fn due_turns_stop_at_an_agent_that_stopped_answering() {
    let (mut r, fake) = reporter();
    fake.answer([ok(1, "running"), ok(1, "running"), Reply::Silent]);
    r.step("acp_a", began(1)).await;
    r.step("acp_b", began(1)).await;
    r.step("acp_a", cut_off(1)).await;
    r.step("acp_b", cut_off(1)).await;
    tokio::time::advance(DECIDE_WAIT).await;
    r.expire().await;
    let sent = std::mem::take(&mut fake.0.lock().unwrap().sent);
    assert_eq!(sent.len(), 3, "two begins and one failed report: {sent:?}");
    // The other due turn waits for the agent, not a timer that fires again at once.
    let next = r.next_deadline().expect("acp_b still waits");
    assert!(next >= tokio::time::Instant::now() + SILENT_FOR - Duration::from_secs(1), "{next:?}");
    // Once the agent is asked again, both are reported: b's failure, and a's again.
    tokio::time::advance(SILENT_FOR).await;
    fake.answer([ok(1, "failed"), ok(1, "failed")]);
    r.expire().await;
    let sent = std::mem::take(&mut fake.0.lock().unwrap().sent);
    assert_eq!(sent.len(), 2, "{sent:?}");
    assert_eq!(r.next_deadline(), None);
}

/// A hand-off the store closed stays closed for its session across a close and reopen.
#[tokio::test]
async fn a_closed_hand_off_stays_closed_after_the_session_reopens() {
    let (mut r, fake) = reporter();
    fake.answer([Reply::Answer(json!({"ok": false, "status": 409,
        "error": {"code": "handoff.closed", "message": "m"},
        "handoff": {"id": "ho_x", "turn": 1, "state": "closed", "status": "cancelled"}}))]);
    r.step(S, began(1)).await;
    r.step(S, Step::Closed).await;
    r.step(S, Step::Reopened).await;
    r.step(S, began(2)).await;
    r.step(S, Step::Ended(End::Completed(None), Some(2))).await;
    assert_eq!(fake.take(), [s(1, "running", None)]);
}

/// A turn's end the store did not get is sent again later, then given up after the last wait.
#[tokio::test(start_paused = true)]
async fn a_turn_end_the_store_did_not_get_is_sent_again_later() {
    let (mut r, fake) = reporter();
    fake.answer([ok(1, "running"), busy(), busy(), busy()]);
    r.step(S, began(1)).await;
    r.step(S, done(1, "Done.")).await;
    assert_eq!(fake.take().len(), 4);
    tokio::time::advance(LATER[0]).await;
    fake.answer([ok(1, "done")]);
    r.expire().await;
    assert_eq!(fake.take(), [s(1, "done", Some("Done."))]);
    assert_eq!(r.next_deadline(), None);
    // One the store never gets is given up after the last wait.
    fake.answer([ok(2, "running"), busy(), busy(), busy()]);
    r.step(S, began(2)).await;
    r.step(S, done(2, "Done.")).await;
    fake.take();
    for wait in LATER {
        tokio::time::advance(wait).await;
        fake.answer([busy(), busy(), busy()]);
        r.expire().await;
    }
    assert_eq!(fake.take().len(), 3 * LATER.len());
    assert_eq!(r.next_deadline(), None);
}

/// A turn whose continuation ran and finished while the agent was left alone is reported done
/// once the agent is asked again, never failed.
#[tokio::test(start_paused = true)]
async fn a_turn_that_finished_while_the_agent_was_silent_is_reported_done() {
    let (mut r, fake) = reporter();
    fake.answer([ok(1, "running")]);
    r.step(S, began(1)).await;
    r.step(S, cut_off(1)).await;
    r.silent_until = Some(tokio::time::Instant::now() + SILENT_FOR);
    r.step(S, Step::RetryScheduled).await;
    r.step(S, began(1)).await;
    r.step(S, done(1, "Back.")).await;
    assert_eq!(fake.take(), [s(1, "running", None)]);
    tokio::time::advance(SILENT_FOR + LATER[0]).await;
    fake.answer([ok(1, "done")]);
    r.expire().await;
    assert_eq!(fake.take(), [s(1, "done", Some("Back."))]);
    assert_eq!(r.next_deadline(), None);
}

/// A session closed while its turn waits for a continuation and the agent is left alone still
/// reports the turn failed once the agent is asked again.
#[tokio::test(start_paused = true)]
async fn a_held_turn_closed_while_the_agent_is_silent_is_reported_later() {
    let (mut r, fake) = reporter();
    fake.answer([ok(1, "running")]);
    r.step(S, began(1)).await;
    r.step(S, cut_off(1)).await;
    r.silent_until = Some(tokio::time::Instant::now() + SILENT_FOR);
    r.step(S, Step::Closed).await;
    assert_eq!(fake.take(), [s(1, "running", None)]);
    tokio::time::advance(SILENT_FOR + LATER[0]).await;
    fake.answer([ok(1, "failed")]);
    r.expire().await;
    assert_eq!(fake.take(), [s(1, "failed", Some("stream disconnected"))]);
}

/// The word the input cut goes through is dropped: a secret's head never goes out unmasked,
/// even when whitespace before it collapses into the summary.
#[test]
fn a_word_through_the_input_cut_is_dropped() {
    let text = format!("{}{}", " ".repeat(INPUT_CHARS - 4), "SECRETHEADTAIL");
    let out = cut(&text, NOTE_CHARS);
    assert!(!out.contains("SECR"), "{out}");
    let text = format!("ok {}{}", " ".repeat(INPUT_CHARS - 7), "SECRETHEADTAIL");
    assert_eq!(cut(&text, NOTE_CHARS), "ok…");
}

/// While the agent's socket is gone (an agent restart), a turn's end and a continuation still
/// move the session's state, and the end is sent once the socket is back.
#[tokio::test(start_paused = true)]
async fn a_turn_that_ends_while_the_socket_is_gone_is_reported_once_it_is_back() {
    let (mut r, fake) = reporter();
    fake.answer([ok(1, "running")]);
    r.step(S, began(1)).await;
    fake.0.lock().unwrap().absent = true;
    r.step(S, done(1, "Done.")).await;
    fake.0.lock().unwrap().absent = false;
    tokio::time::advance(LATER[0]).await;
    fake.answer([ok(1, "done")]);
    r.expire().await;
    assert_eq!(fake.take(), [s(1, "running", None), s(1, "done", Some("Done."))]);
    // A continuation that runs and finishes while the socket is gone is done, never failed.
    fake.answer([ok(2, "running")]);
    r.step(S, began(2)).await;
    r.step(S, cut_off(2)).await;
    fake.0.lock().unwrap().absent = true;
    r.step(S, Step::RetryScheduled).await;
    r.step(S, began(2)).await;
    r.step(S, done(2, "Back.")).await;
    fake.0.lock().unwrap().absent = false;
    tokio::time::advance(LATER[0]).await;
    fake.answer([ok(2, "done")]);
    r.expire().await;
    assert_eq!(fake.take(), [s(2, "running", None), s(2, "done", Some("Back."))]);
    assert_eq!(r.next_deadline(), None);
}

/// A needs-you whose answer never came may have reached the store, so the turn running again
/// is reported.
#[tokio::test(start_paused = true)]
async fn running_again_is_reported_after_an_unanswered_needs_you() {
    let (mut r, fake) = reporter();
    fake.answer([ok(1, "running"), busy(), busy(), busy(), ok(1, "running")]);
    r.step(S, began(1)).await;
    r.step(S, Step::Asks(None)).await;
    r.step(S, Step::Runs).await;
    let sent = fake.take();
    assert_eq!(sent.len(), 5, "{sent:?}");
    assert_eq!(sent[4], s(1, "running", None));
}

/// A session holding a failed turn for its continuation says so for that turn only (the worker
/// keeps that begin through a queue loss).
#[tokio::test]
async fn a_held_turn_is_held_for_its_own_continuation_only() {
    let (mut r, fake) = reporter();
    fake.answer([ok(1, "running")]);
    r.step(S, began(1)).await;
    assert!(!r.holds(S, Some(1)));
    r.step(S, cut_off(1)).await;
    assert!(r.holds(S, Some(1)));
    assert!(!r.holds(S, Some(2)));
    assert!(!r.holds(S, None));
}

/// A continuation's begin from before a queue loss ends the hold without following the turn:
/// a later prompt's needs-you is not reported on it, and the turn's end still is.
#[tokio::test(start_paused = true)]
async fn a_begin_from_before_a_loss_ends_the_hold_and_follows_nothing() {
    let (mut r, fake) = reporter();
    fake.answer([ok(1, "running")]);
    r.step(S, began(1)).await;
    r.step(S, cut_off(1)).await;
    r.forget_turns();
    r.release(S, Some(2));
    assert!(r.holds(S, Some(1)));
    r.release(S, Some(1));
    assert!(!r.holds(S, Some(1)));
    assert_eq!(r.next_deadline(), None);
    r.step(S, Step::Asks(None)).await;
    fake.answer([ok(1, "done")]);
    r.step(S, done(1, "Back.")).await;
    assert_eq!(fake.take(), [s(1, "running", None), s(1, "done", Some("Back."))]);
}
