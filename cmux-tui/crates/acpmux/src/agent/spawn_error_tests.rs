use super::*;

#[test]
fn out_of_descriptors_says_it_is_the_daemon_and_what_to_do() {
    let error = spawn_error("start host", std::io::Error::from_raw_os_error(libc::EMFILE));
    let text = format!("{error:#}");
    assert!(text.starts_with("start host: the acpmux daemon is out of open files"), "{text}");
    assert!(text.contains("acpmux daemon shutdown"), "{text}");
    let other = spawn_error("start host", std::io::Error::from_raw_os_error(libc::ENOENT));
    assert!(format!("{other:#}").starts_with("start host: "), "{other:#}");
}

#[tokio::test]
async fn direct_spawn_failure_does_not_expose_harness_argv() {
    const SENTINEL: &str = "argv-secret-must-not-leave-the-daemon";
    let profile: HarnessProfile = serde_json::from_value(serde_json::json!({
        "argv": ["/nonexistent/acpmux-test-harness", "--token", SENTINEL]
    }))
    .unwrap();
    let (inbound, _rx) = mpsc::channel(1);
    let tap: Tap = Arc::new(|_, _, _| Some(WriteTicket::done()));
    let (temp, supervisor) = (std::env::temp_dir(), crate::supervised::embedded());
    let error = match ChildAgent::spawn("missing", &profile, &temp, inbound, tap, &supervisor).await
    {
        Ok(_) => panic!("a missing harness started"),
        Err(error) => error,
    };
    assert!(!error.to_string().contains(SENTINEL), "spawn failure exposed harness argv: {error:#}");
}

#[tokio::test]
async fn a_durable_withdrawal_never_logs_an_unscoped_raw_cursor() -> anyhow::Result<()> {
    let profile: HarnessProfile = serde_json::from_value(serde_json::json!({
        "argv": ["python3", "-c", "import sys; sys.stdin.read()"]
    }))?;
    let cursors = Arc::new(std::sync::Mutex::new(Vec::new()));
    let recorded = cursors.clone();
    let tap: Tap = Arc::new(move |_, _, seq| {
        recorded.lock().unwrap_or_else(|e| e.into_inner()).push(seq);
        Some(WriteTicket::done())
    });
    let (tx, mut rx) = mpsc::channel(8);
    let agent = ChildAgent::spawn(
        "old",
        &profile,
        &std::env::temp_dir(),
        tx.clone(),
        tap,
        &crate::supervised::embedded(),
    )
    .await?;
    let cancel = Message::notification(
        crate::rpc::method::CANCEL_REQUEST,
        serde_json::json!({"requestId": 7}),
    );
    let pending =
        agent.on_host_entry(900, crate::agent_host::Entry::In { msg: cancel.to_value() }, &tx);
    let persist = async {
        if let Some(Inbound::Notification { persisted: Some(done), host_seq, .. }) = rx.recv().await
        {
            assert_eq!(host_seq, Some(900), "the durable marker owns the checkpoint");
            assert!(cursors.lock().unwrap_or_else(|e| e.into_inner()).is_empty());
            let _ = done.send(true);
        }
    };
    let result = tokio::time::timeout(std::time::Duration::from_secs(10), async {
        tokio::join!(pending, persist).0
    })
    .await;
    agent.kill().await;
    assert!(result?.is_some(), "the cancellation was not stored");
    assert_eq!(
        *cursors.lock().unwrap_or_else(|e| e.into_inner()),
        vec![None],
        "raw cancellation has no incarnation fence"
    );
    Ok(())
}

#[tokio::test]
async fn direct_children_give_withdrawals_distinct_request_owners() -> anyhow::Result<()> {
    let ask = Message::request(7, crate::rpc::method::SESSION_REQUEST_PERMISSION, Value::Null);
    let cancel = Message::notification(
        crate::rpc::method::CANCEL_REQUEST,
        serde_json::json!({"requestId": 7}),
    );
    let script = format!(
        "import sys; print({:?}, flush=True); print({:?}, flush=True); sys.stdin.read()",
        ask.to_line().trim(),
        cancel.to_line().trim()
    );
    let profile: HarnessProfile = serde_json::from_value(serde_json::json!({
        "argv": ["python3", "-c", script]
    }))?;
    let mut owners = Vec::new();
    for _ in 0..2 {
        let (inbound, mut rx) = mpsc::channel(8);
        let agent = ChildAgent::spawn(
            "direct",
            &profile,
            &std::env::temp_dir(),
            inbound,
            Arc::new(|_, _, _| Some(WriteTicket::done())),
            &crate::supervised::embedded(),
        )
        .await?;
        let messages = tokio::time::timeout(std::time::Duration::from_secs(10), async {
            (rx.recv().await, rx.recv().await)
        })
        .await;
        agent.kill().await;
        let (
            Some(Inbound::Request { host_incarnation: request, .. }),
            Some(Inbound::Notification { host_incarnation: cancel, .. }),
        ) = messages?
        else {
            anyhow::bail!("the direct child did not ask and withdraw its request");
        };
        assert!(request.is_some(), "a direct request needs its child's identity");
        assert_eq!(request, cancel, "a withdrawal must carry its request's owner");
        owners.push(request);
    }
    assert_ne!(owners[0], owners[1], "a replacement child reused its predecessor's owner");
    Ok(())
}
