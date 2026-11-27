use super::*;
use serde_json::json;

fn pending() -> Arc<Mutex<Pending>> {
    Arc::new(Mutex::new(Pending {
        map: HashMap::new(),
        orphans: Default::default(),
        cancelled: Default::default(),
    }))
}

/// F1: the agent's answer comes between the cancel and the cleanup of its entry (the pending
/// map was busy as the request was dropped). It reaches a waiter that is gone, so it is
/// dropped and logged as late, never lost unlogged, and an agent that already answered hears
/// no cancel.
#[tokio::test]
async fn an_answer_between_the_cancel_and_the_cleanup_is_dropped_as_late() {
    let pending = pending();
    let (waiter, waiting) = oneshot::channel();
    pending.lock().await.map.insert(key(&Value::from(7)), waiter);
    let (stdin, mut written) = mpsc::channel(8);
    let abandoned = Abandoned {
        pending: pending.clone(),
        sink: CancelSink::Direct(stdin),
        id: 7,
        method: "session/set_mode".into(),
        armed: true,
        forget_on_drop: false,
    };
    let mut busy = pending.lock().await;
    let (cancel, cancelled) = oneshot::channel();
    cancel.send(()).unwrap();
    let served = crate::request_cancel::until_cancelled(cancelled, async move {
        let _abandoned = abandoned;
        let _waiting = waiting;
        std::future::pending::<()>().await
    })
    .await;
    assert!(served.is_none(), "the request gave up");
    // The reader takes the answer's entry while the cleanup waits for the map.
    let late = busy.take(&Value::from(7)).expect("the entry is still there");
    assert!(late.send(Ok(json!({}))).is_err(), "its waiter is gone");
    drop(busy);
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
    while pending.lock().await.cancelled.dropped == 0 && tokio::time::Instant::now() < deadline {
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    let p = pending.lock().await;
    assert_eq!(p.cancelled.dropped, 1, "dropped as late, and logged");
    assert!(p.cancelled.is_empty(), "no id kept for an answer that came");
    assert!(p.map.is_empty());
    drop(p);
    assert!(written.try_recv().is_err(), "an agent that answered hears no cancel");
}

/// F4: `request_within` dropped by its client's cancel forgets its pending entry and tells the
/// agent, as `request` does, instead of holding the agent request until it answers.
#[tokio::test]
async fn a_cancelled_request_within_forgets_its_entry_and_tells_the_agent() {
    let hold = std::env::temp_dir().join(format!("amx-within-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&hold).unwrap();
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let profile: HarnessProfile = serde_json::from_value(json!({
        "argv": ["python3", fake],
        "env": {"FAKE_SET_MODE_HOLD": hold.display().to_string()},
    }))
    .unwrap();
    let (tx, _rx) = mpsc::channel(16);
    let tap: Tap = Arc::new(|_, _, _| true);
    let agent = ChildAgent::spawn("acp", &profile, &std::env::temp_dir(), tx, tap).await.unwrap();
    let (cancel, cancelled) = oneshot::channel();
    let asking = agent.clone();
    let task = tokio::spawn(async move {
        let within = std::time::Duration::from_secs(120);
        let ask = asking.request_within(
            "session/set_mode",
            json!({"sessionId": "s", "modeId": "m"}),
            within,
        );
        crate::request_cancel::until_cancelled(cancelled, ask).await
    });
    let read = |name: &str| std::fs::read_to_string(hold.join(name)).unwrap_or_default();
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(20);
    while read("held").trim() != "1" {
        assert!(tokio::time::Instant::now() < deadline, "the agent never held the request");
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    assert_eq!(agent.pending_requests().await, 1);
    cancel.send(()).unwrap();
    assert!(task.await.unwrap().is_none(), "the request gave up");
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(20);
    while read("cancels").is_empty() && tokio::time::Instant::now() < deadline {
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    assert_eq!(agent.pending_requests().await, 0, "no entry left behind");
    let cancels: Vec<Value> =
        serde_json::from_str(&read("cancels")).expect("the agent heard one cancel");
    assert_eq!(cancels.len(), 1, "{cancels:?}");
    agent.kill().await;
    let _ = std::fs::remove_dir_all(&hold);
}
