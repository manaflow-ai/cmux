//! The compactor runner (section 4) with fake models.

mod common;

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use common::*;
use optchat_host::*;

/// A recorded call: its node, the context it saw, the nodes done before it.
type Call = (NodeId, String, Vec<NodeId>);

#[test]
fn nodes_are_built_in_spec_order() {
    let dir = tempfile::tempdir().unwrap();
    // Each call records its node, the context it saw, and which nodes were done.
    let done: Arc<Mutex<Vec<NodeId>>> = Arc::default();
    let calls: Arc<Mutex<Vec<Call>>> = Arc::default();
    let running = Arc::new(AtomicUsize::new(0));
    let peak = Arc::new(AtomicUsize::new(0));
    let model = {
        let (done, calls, running, peak) =
            (done.clone(), calls.clone(), running.clone(), peak.clone());
        Arc::new(Fake(move |r: &CompactRequest, _: &[Followup]| {
            let now = running.fetch_add(1, Ordering::SeqCst) + 1;
            peak.fetch_max(now, Ordering::SeqCst);
            calls
                .lock()
                .unwrap()
                .push((r.node, r.context.clone(), done.lock().unwrap().clone()));
            std::thread::sleep(Duration::from_millis(2));
            done.lock().unwrap().push(r.node);
            running.fetch_sub(1, Ordering::SeqCst);
            // 300 bytes: two children never fit in 512, so merges need the model too.
            Ok(Reply::text(summary(r.node, 300)))
        }))
    };
    let chat = open(dir.path(), 128_000, model);
    // Append everything at once: the compactor must still go in order.
    for n in 0..256 {
        chat.append(Kind::User, &long(n)).unwrap();
    }
    assert!(chat.wait_idle(None, WAIT));
    let calls = calls.lock().unwrap();
    // Every message is compressed once.
    let mut level0: Vec<u64> = calls.iter().filter(|c| c.0.l == 0).map(|c| c.0.i).collect();
    level0.sort();
    assert_eq!(level0, (0..256).collect::<Vec<_>>());
    for (node, context, done_before) in calls.iter() {
        // No call ever sees a placeholder (spec 4); its view ends at the node.
        assert!(!context.contains("not summarized yet"), "{node:?}");
        let upto = if node.l == 0 { node.start() } else { node.end() };
        for line in context.lines().filter(|l| l.contains('|')) {
            let (id, n) = line.split('|').next().unwrap().split_once('+').unwrap();
            let end: u64 = id.parse::<u64>().unwrap() + n.parse::<u64>().unwrap();
            assert!(end <= upto, "{node:?} saw {line:.20}");
        }
        if node.l == 0 {
            // Spec 4 (gist 3c190e0): a message's node starts once fewer than
            // AHEAD lines before it are still unbuilt.
            let unbuilt = (0..node.i)
                .filter(|j| !done_before.contains(&NodeId::new(0, *j)))
                .count();
            assert!(unbuilt < optchat_core::AHEAD, "{node:?} started with {unbuilt} unbuilt before it");
        } else {
            let a = NodeId::new(node.l - 1, 2 * node.i);
            let b = NodeId::new(node.l - 1, 2 * node.i + 1);
            assert!(
                done_before.contains(&a) && done_before.contains(&b),
                "{node:?}"
            );
        }
    }
    // The whole tree over 256 messages: 256 + 128 + ... + 1 nodes.
    assert_eq!(calls.len(), 511);
    assert_eq!(chat.status().built, 511);
    assert!(peak.load(Ordering::SeqCst) <= optchat_core::JOBS);
}

#[test]
fn a_failed_node_retries_after_the_fixed_wait_and_reports_once() {
    let dir = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new());
    let failures = Arc::new(AtomicUsize::new(2));
    let model = {
        let failures = failures.clone();
        Arc::new(Fake(move |r: &CompactRequest, _: &[Followup]| {
            if failures.load(Ordering::SeqCst) > 0 {
                failures.fetch_sub(1, Ordering::SeqCst);
                return Err(ModelError::new("overloaded"));
            }
            Ok(Reply::text(summary(r.node, 200)))
        }))
    };
    let (config, reports) = config(128_000);
    let chat = OptChat::open_with(dir.path(), config, model, clock.clone()).unwrap();
    chat.append(Kind::User, &long(0)).unwrap();

    assert!(clock.wait_for_sleepers(1, Duration::from_secs(30)));
    let status = chat.status();
    assert_eq!(
        status.failures,
        vec![Failure {
            node: NodeId::new(0, 0),
            error: "overloaded".into()
        }]
    );
    assert_eq!(status.busy, vec![NodeId::new(0, 0)]);
    assert!(!chat.settle(None, Some(Duration::from_millis(50))));
    // Not before RETRY.
    clock.advance(RETRY - Duration::from_secs(1));
    assert_eq!(clock.sleepers(), 1);
    clock.advance(Duration::from_secs(1));
    // Fails again: waits again, not reported again. The first sleeper left
    // `sleep` before the second call started, so the sleeper seen now is new.
    while failures.load(Ordering::SeqCst) > 0 {
        std::thread::yield_now();
    }
    assert!(clock.wait_for_sleepers(1, Duration::from_secs(30)));
    clock.advance(RETRY);
    assert!(chat.settle(None, WAIT));
    let node_failed = reports
        .lock()
        .unwrap()
        .iter()
        .filter(|r| matches!(r, Report::NodeFailed { .. }))
        .count();
    assert_eq!(node_failed, 1);
    assert!(chat.status().failures.is_empty());
}

#[test]
fn the_size_loop_retries_in_the_same_conversation() {
    let dir = tempfile::tempdir().unwrap();
    let seen: Arc<Mutex<Vec<Vec<Followup>>>> = Arc::default();
    let model = {
        let seen = seen.clone();
        Arc::new(Fake(move |r: &CompactRequest, f: &[Followup]| {
            seen.lock().unwrap().push(f.to_vec());
            if r.node.l > 0 {
                return Ok(Reply::text(summary(r.node, 100)));
            }
            Ok(Reply::text(match f.len() {
                0 => "a".repeat(700),
                _ => "b".repeat(400),
            }))
        }))
    };
    let chat = open(dir.path(), 128_000, model);
    chat.append(Kind::User, &long(0)).unwrap();
    assert!(chat.wait_idle(None, WAIT));
    let seen = seen.lock().unwrap();
    assert_eq!(seen.len(), 2);
    assert_eq!(seen[1].len(), 1);
    assert_eq!(seen[1][0].reply.text, "a".repeat(700));
    assert!(seen[1][0]
        .retry
        .starts_with("Too long: your line is 700 bytes, over the 512-byte limit."));
    assert!(seen[1][0].retry.ends_with("| ← LIMIT"));
    assert_eq!(chat.zoom(0, 1).unwrap(), format!("0+0|user: {}", long(0)));
    assert!(chat
        .render_view()
        .text
        .contains(&format!("0+1|{}", "b".repeat(400))));
}

#[test]
fn a_stubborn_node_keeps_its_shortest_try() {
    let dir = tempfile::tempdir().unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    let model = {
        let calls = calls.clone();
        Arc::new(Fake(move |_: &CompactRequest, f: &[Followup]| {
            calls.fetch_add(1, Ordering::SeqCst);
            // 600, 590, 580, 570, 560 bytes: always over.
            Ok(Reply::text("c".repeat(600 - 10 * f.len())))
        }))
    };
    let chat = open(dir.path(), 128_000, model);
    chat.append(Kind::User, &long(0)).unwrap();
    assert!(chat.wait_idle(None, WAIT));
    assert_eq!(calls.load(Ordering::SeqCst), 5);
    assert!(chat
        .render_view()
        .text
        .contains(&format!("0+1|{}\n", "c".repeat(560))));
}

#[test]
fn settle_wakes_when_the_last_line_is_built() {
    let dir = tempfile::tempdir().unwrap();
    let (release, gate) = mpsc::channel::<()>();
    let gate = Mutex::new(gate);
    let model = Arc::new(Fake(move |r: &CompactRequest, _: &[Followup]| {
        gate.lock().unwrap().recv().unwrap();
        Ok(Reply::text(summary(r.node, 200)))
    }));
    let chat = Arc::new(open(dir.path(), 128_000, model));
    chat.append(Kind::User, &long(0)).unwrap();
    assert_eq!(chat.status().unbuilt, 1);
    assert!(chat
        .render_view()
        .text
        .contains("0+1|(not summarized yet: zoom it)"));

    // A timeout and a cancel both end the wait with false.
    assert!(!chat.settle(None, Some(Duration::from_millis(20))));
    let cancel = chat.cancel_handle();
    let waiter = {
        let (chat, cancel) = (chat.clone(), cancel.clone());
        std::thread::spawn(move || chat.settle(Some(&cancel), None))
    };
    cancel.cancel();
    assert!(!waiter.join().unwrap());

    let waiter = {
        let chat = chat.clone();
        std::thread::spawn(move || chat.settle(None, None))
    };
    release.send(()).unwrap();
    assert!(waiter.join().unwrap());
    assert_eq!(chat.status().unbuilt, 0);
}

#[test]
fn shutdown_drops_late_results() {
    let dir = tempfile::tempdir().unwrap();
    let (release, gate) = mpsc::channel::<()>();
    let gate = Mutex::new(gate);
    let model = Arc::new(Fake(move |r: &CompactRequest, _: &[Followup]| {
        let _ = gate.lock().unwrap().recv();
        Ok(Reply::text(format!("LATE {}", r.node.name())))
    }));
    let chat = open(dir.path(), 128_000, model);
    chat.append(Kind::User, &long(0)).unwrap();
    chat.shutdown();
    assert!(!chat.settle(None, None));
    release.send(()).unwrap();
    // The late result was not written: a new owner sees the node unbuilt.
    let reopened = open(dir.path(), 128_000, instant(200));
    assert!(reopened.wait_idle(None, WAIT));
    drop(chat);
    let view = reopened.render_view().text;
    assert!(
        view.contains("0+1|sum 0+1") && !view.contains("LATE"),
        "{view}"
    );
}

/// A model that counts its ended conversations.
struct Ending {
    replies: Mutex<Vec<Result<Reply, ModelError>>>,
    calls: AtomicUsize,
    ended: Mutex<Vec<NodeId>>,
}

impl Ending {
    fn new(replies: Vec<Result<Reply, ModelError>>) -> Ending {
        Ending {
            replies: Mutex::new(replies),
            calls: AtomicUsize::new(0),
            ended: Mutex::new(Vec::new()),
        }
    }
}

impl CompactModel for Ending {
    fn call(&self, _: &CompactRequest, _: &[Followup]) -> Result<Reply, ModelError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.replies.lock().unwrap().remove(0)
    }
    fn end(&self, request: &CompactRequest) {
        self.ended.lock().unwrap().push(request.node);
    }
}

fn node_request(step: &str) -> CompactRequest {
    CompactRequest {
        node: NodeId::new(0, 4),
        system: "SYS".into(),
        context: "<chat>\n</chat>".into(),
        step: step.into(),
        cut: None,
    }
}

/// The acpmux route keeps one session per node across the size loop and
/// kills it when the node is done or failed: `run_node` ends the
/// conversation exactly once, whatever the outcome.
#[test]
fn run_node_ends_the_conversation_once_on_every_outcome() {
    let long = "x".repeat(700);
    let model = Ending::new(vec![Ok(Reply::text(long)), Ok(Reply::text("short line"))]);
    assert_eq!(run_node(&model, &node_request("S")).unwrap(), "short line");
    assert_eq!(model.calls.load(Ordering::SeqCst), 2, "one size-loop retry");
    assert_eq!(*model.ended.lock().unwrap(), vec![NodeId::new(0, 4)]);

    let model = Ending::new(vec![Err(ModelError::new("HTTP 429"))]);
    assert!(run_node(&model, &node_request("S")).is_err());
    assert_eq!(
        model.ended.lock().unwrap().len(),
        1,
        "a failed node is ended too"
    );

    let model = Ending::new(vec![Ok(Reply::text("   "))]);
    assert!(run_node(&model, &node_request("S")).is_err());
    assert_eq!(
        model.ended.lock().unwrap().len(),
        1,
        "an empty reply is ended too"
    );
}

#[test]
fn a_cut_request_line_starts_with_the_cut() {
    let model = Ending::new(vec![Ok(Reply::text("user: a long log"))]);
    let request = CompactRequest {
        cut: Some("(cut: 10 of 20 characters not shown) ".into()),
        ..node_request("S")
    };
    assert_eq!(
        run_node(&model, &request).unwrap(),
        "(cut: 10 of 20 characters not shown) user: a long log"
    );
}

#[test]
fn the_probe_builds_one_node_and_ends_it() {
    let model = Ending::new(vec![Ok(Reply::text("user: ping"))]);
    assert_eq!(probe(&model, "SYS").unwrap(), "user: ping");
    assert_eq!(*model.ended.lock().unwrap(), vec![PROBE_NODE]);
    let failing = Ending::new(vec![Err(ModelError::new("HTTP 429: rate_limit_error"))]);
    assert!(probe(&failing, "SYS").unwrap_err().message.contains("429"));
}

// Audit round 3, m1: the size loop retries a cut line that would pass NODE
// once the prefix is added.
#[test]
fn a_cut_line_is_retried_against_its_reduced_room() {
    let prefix = "(cut: 10 of 20 characters unread) ".to_owned();
    let model = Ending::new(vec![
        Ok(Reply::text("x".repeat(500))),
        Ok(Reply::text("user: short")),
    ]);
    let request = CompactRequest {
        cut: Some(prefix.clone()),
        ..node_request("S")
    };
    assert_eq!(
        run_node(&model, &request).unwrap(),
        format!("{prefix}user: short")
    );
}

/// A model that reports its response start before it answers.
struct Starting<F>(F);

impl<F> CompactModel for Starting<F>
where
    F: Fn(&CompactRequest, &dyn Fn()) -> Result<Reply, ModelError> + Send + Sync,
{
    fn call(&self, request: &CompactRequest, _: &[Followup]) -> Result<Reply, ModelError> {
        (self.0)(request, &|| {})
    }

    fn call_started(
        &self,
        request: &CompactRequest,
        _: &[Followup],
        started: &dyn Fn(),
    ) -> Result<Reply, ModelError> {
        (self.0)(request, started)
    }
}

/// Single-flight (spec 3.3): calls that wait for another call writing the
/// same marked prefix go as soon as that call's response starts, when the
/// cache entry exists, not when its whole reply is in; and they go together,
/// since the entry is there for all of them (hq-6d gap 3a).
#[test]
fn single_flight_releases_waiting_calls_together_when_the_writers_response_starts() {
    let dir = tempfile::tempdir().unwrap();
    let gate = Arc::new((Mutex::new(false), std::sync::Condvar::new()));
    let (entered_tx, entered) = mpsc::channel::<NodeId>();
    let entered_tx = Mutex::new(entered_tx);
    let calls = Arc::new(AtomicUsize::new(0));
    let model = {
        let (calls, gate) = (calls.clone(), gate.clone());
        Arc::new(Starting(move |r: &CompactRequest, started: &dyn Fn()| {
            let k = calls.fetch_add(1, Ordering::SeqCst);
            entered_tx.lock().unwrap().send(r.node).unwrap();
            if k == 0 {
                // The writer's response starts; the others never report one.
                started();
            }
            // Every reply takes long.
            let (open, cv) = &*gate;
            let open = open.lock().unwrap();
            let _ = cv
                .wait_timeout_while(open, Duration::from_secs(20), |o| !*o)
                .unwrap();
            Ok(Reply::text(summary(r.node, 200)))
        }))
    };
    let chat = open(dir.path(), 128_000, model);
    // Three long messages on an empty chat: every call marks the same prefix.
    for n in 0..3 {
        chat.append(Kind::User, &long(n)).unwrap();
    }
    let first = entered.recv_timeout(Duration::from_secs(10)).unwrap();
    let others: Vec<_> = (0..2)
        .map(|_| entered.recv_timeout(Duration::from_secs(3)))
        .collect();
    *gate.0.lock().unwrap() = true;
    gate.1.notify_all();
    assert!(
        others.iter().all(Result::is_ok),
        "waiting calls did not all go at the writer's response start ({} writing): {others:?}",
        first.name()
    );
    assert!(chat.wait_idle(None, WAIT));
}
