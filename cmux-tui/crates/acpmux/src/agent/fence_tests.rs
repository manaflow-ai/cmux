use super::*;

/// Review 81 of #23322: the Codex bridge's empty batch (a translation that gives the
/// app-server nothing) queues nothing on the agent's stdin, so the reader that sends one
/// before it hands on an answer never waits on a full stdin queue.
#[tokio::test]
async fn an_empty_batch_of_server_lines_queues_nothing() {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let profile: HarnessProfile =
        serde_json::from_value(serde_json::json!({"argv": ["/usr/bin/env", "python3", fake]}))
            .unwrap();
    let (inbound, _rx) = mpsc::channel(16);
    let tap: Tap = Arc::new(|_, _, _| true);
    let agent = ChildAgent::spawn("fake", &profile, &std::env::temp_dir(), inbound, tap)
        .await
        .expect("the stand-in agent starts");
    // Its writer holds one line, so what is queued after it stays queued.
    let (arrived_tx, arrived) = oneshot::channel();
    let (release, release_rx) = oneshot::channel();
    *agent.input_seam.lock().unwrap() =
        Some(("held-line".to_owned(), false, arrived_tx, release_rx));
    agent.stdin_tx.send(("\"held-line\"\n".to_owned(), None)).await.unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(10), arrived)
        .await
        .expect("the writer holds the line")
        .unwrap();
    let room = agent.stdin_tx.capacity();
    assert!(agent.codex_lines(Vec::new(), None).await);
    assert_eq!(agent.stdin_tx.capacity(), room, "an empty batch took a place on stdin");
    // Review 82: Claude's translator gives no line too (a late answer to a withdrawn
    // elicitation, `claude_stdio/outbound.rs`).
    agent.claude_lines(Vec::new(), None).await.unwrap();
    assert_eq!(agent.stdin_tx.capacity(), room, "an empty Claude batch took a place on stdin");
    let _ = release.send(());
    agent.kill().await;
}

/// Review 87 of #23322: an agent whose leader exited and left a descendant holding its
/// stdin: a cut of the message its writer has stops that writer, so nothing more of the
/// message reaches the descendant after the cut.
#[tokio::test]
async fn a_cut_stops_the_writer_of_a_stdin_a_descendant_kept() {
    let out = std::env::temp_dir().join(format!("acpmux-kept-{}", std::process::id()));
    let _ = std::fs::remove_file(&out);
    // A background job gets /dev/null for stdin unless it is passed on explicitly; the
    // descendant leaves the agent's process group, so only a stopped writer keeps it out.
    let copy = "import os, time; os.setsid(); time.sleep(3); os.execvp('cat', ['cat'])";
    let script =
        format!("exec 3<&0; python3 -c \"{copy}\" <&3 3<&- > '{}' & exit 0", out.display());
    let argv = serde_json::json!({"argv": ["/bin/sh", "-c", script]});
    let profile: HarnessProfile = serde_json::from_value(argv).unwrap();
    let (inbound, _rx) = mpsc::channel(16);
    let tap: Tap = Arc::new(|_, _, _| true);
    let agent = ChildAgent::spawn("kept", &profile, &std::env::temp_dir(), inbound, tap)
        .await
        .expect("the agent starts");
    let fence = Fence::default();
    let line = "x".repeat(1 << 20);
    let note = Message::notification("note", serde_json::json!({"text": line}));
    agent.write_fenced(&note, Some(&fence)).await.unwrap();
    // The pipe is full and its leader is gone.
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    assert!(fence.cut_or_end(std::time::Duration::from_secs(1)).await, "the cut is proven");
    tokio::time::sleep(std::time::Duration::from_secs(5)).await;
    let read = std::fs::metadata(&out).map(|m| m.len()).unwrap_or(0);
    let _ = std::fs::remove_file(&out);
    assert!(read < (1 << 20), "a cut message reached the agent after the cut ({read} bytes)");
}

/// Review 87 of #23322, round 2: a direct agent whose leader exited while a descendant that
/// never reads kept its stdin: the message its writer has settles once the agent ended,
/// with no cut, so a family hold on it is not held for ever.
#[tokio::test]
async fn a_message_a_descendant_never_reads_settles_once_its_agent_ended() {
    let pid_file = std::env::temp_dir().join(format!("acpmux-stuck-{}", std::process::id()));
    let _ = std::fs::remove_file(&pid_file);
    let hold = format!(
        "import os, time; os.setsid(); open('{}', 'w').write(str(os.getpid())); time.sleep(30)",
        pid_file.display()
    );
    let script = format!("exec 3<&0; python3 -c \"{hold}\" <&3 3<&- >/dev/null 2>&1 & exit 0");
    let argv = serde_json::json!({"argv": ["/bin/sh", "-c", script]});
    let profile: HarnessProfile = serde_json::from_value(argv).unwrap();
    let (inbound, _rx) = mpsc::channel(16);
    let tap: Tap = Arc::new(|_, _, _| true);
    let agent = ChildAgent::spawn("stuck", &profile, &std::env::temp_dir(), inbound, tap)
        .await
        .expect("the agent starts");
    let fence = Fence::default();
    let line = "x".repeat(1 << 20);
    let note = Message::notification("note", serde_json::json!({"text": line}));
    agent.write_fenced(&note, Some(&fence)).await.unwrap();
    let settled = tokio::time::timeout(std::time::Duration::from_secs(10), fence.settled()).await;
    if let Some(pid) = std::fs::read_to_string(&pid_file).ok().and_then(|p| p.parse().ok()) {
        // SAFETY: the descendant this test started, still holding its pid while it sleeps.
        unsafe { libc::kill(pid, libc::SIGKILL) };
    }
    let _ = std::fs::remove_file(&pid_file);
    assert!(settled.is_ok(), "a message its ended agent never took was still unsettled");
    assert!(!fence.is_cut(), "it was written in part, so it is not a cut");
}

/// Review 88 of #23322: Claude's translator lets go of a permission ask once it translated
/// the answer, so a translated answer is as good as taken: a cut never drops it while it is
/// queued, which would leave Claude waiting on an ask nothing can answer again; the cut
/// ends that agent instead.
#[tokio::test]
async fn an_answer_a_translator_took_is_not_cut_while_queued() {
    let ask = serde_json::json!({"type": "control_request", "request_id": "ask-1",
            "request": {"subtype": "can_use_tool", "tool_name": "Bash", "input": {}}});
    let script = format!("echo '{ask}'; exec sleep 30");
    let argv = serde_json::json!({"argv": ["/bin/sh"]});
    let profile: HarnessProfile = serde_json::from_value(argv).unwrap();
    let (inbound, mut rx) = mpsc::channel(16);
    let tap: Tap = Arc::new(|_, _, _| true);
    let tr = crate::claude_stdio::Translator::new("acp-1".into(), "default", "haiku", "default");
    let command = Some(("/bin/sh".to_owned(), vec!["-c".to_owned(), script]));
    let agent = ChildAgent::spawn_with(
        "translated",
        &profile,
        &std::env::temp_dir(),
        inbound,
        tap,
        command,
        Some(tr),
        None,
    )
    .await
    .expect("the agent starts");
    let id = tokio::time::timeout(std::time::Duration::from_secs(10), async {
        loop {
            match rx.recv().await {
                Some(Inbound::Request { id, .. }) => break id,
                Some(_) => continue,
                None => panic!("the agent ended before it asked"),
            }
        }
    })
    .await
    .expect("Claude's ask reaches the hub");
    // Its writer holds one line, so the answer stays queued behind it.
    let (arrived_tx, arrived) = oneshot::channel();
    let (release, release_rx) = oneshot::channel();
    *agent.input_seam.lock().unwrap() =
        Some(("held-line".to_owned(), false, arrived_tx, release_rx));
    agent.stdin_tx.send(("\"held-line\"\n".to_owned(), None)).await.unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(10), arrived)
        .await
        .expect("the writer holds the line")
        .unwrap();
    let fence = Fence::default();
    let allow = serde_json::json!({"outcome": {"outcome": "selected", "optionId": "allow_once"}});
    agent.respond_fenced(id, Ok(allow), Some(&fence)).await.unwrap();
    fence.cut();
    assert!(!fence.is_cut(), "a cut dropped an answer its translator had already let go of");
    assert!(fence.cut_or_end(std::time::Duration::from_secs(1)).await, "its agent ended");
    assert!(!agent.is_alive().await, "the agent of a translated answer was left running");
    let _ = release.send(());
}

/// Review 87 of #23322, round 3: a direct agent's message is written only once its writer
/// wrote it. An answer that came first (one the Codex bridge makes up once its app-server
/// exits) does not settle it while its writer still has it.
#[tokio::test]
async fn only_its_writer_settles_a_direct_agents_message() {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let profile: HarnessProfile =
        serde_json::from_value(serde_json::json!({"argv": ["/usr/bin/env", "python3", fake]}))
            .unwrap();
    let (inbound, _rx) = mpsc::channel(16);
    let tap: Tap = Arc::new(|_, _, _| true);
    let agent = ChildAgent::spawn("fake", &profile, &std::env::temp_dir(), inbound, tap)
        .await
        .expect("the stand-in agent starts");
    // Its writer holds the request while it writes it.
    let (arrived_tx, arrived) = oneshot::channel();
    let (release, release_rx) = oneshot::channel();
    *agent.input_seam.lock().unwrap() =
        Some(("held-request".to_owned(), true, arrived_tx, release_rx));
    let fence = Fence::default();
    let request = {
        let (agent, fence) = (agent.clone(), fence.clone());
        tokio::spawn(async move {
            let params = serde_json::json!({});
            agent.request_with_hook("held-request", params, Some(&fence), || {}).await
        })
    };
    tokio::time::timeout(std::time::Duration::from_secs(10), arrived)
        .await
        .expect("the writer holds the request")
        .unwrap();
    let waiting: Vec<_> = agent.pending.lock().await.map.drain().map(|(_, tx)| tx).collect();
    for tx in waiting {
        let _ = tx.send(Err(RpcError::internal("the app-server exited")));
    }
    let _ = tokio::time::timeout(std::time::Duration::from_secs(5), request).await;
    let settled = fence.is_settled();
    let _ = release.send(());
    agent.kill().await;
    assert!(!settled, "an answer settled a message its writer had not written");
}

/// Review 87 of #23322, round 3: a message a translator took (`hand_on`) that its agent's
/// closed writer never takes settles, so no holder waits on it.
#[tokio::test]
async fn a_translated_message_its_closed_writer_never_took_settles() {
    let argv = serde_json::json!({"argv": ["/bin/sh"]});
    let profile: HarnessProfile = serde_json::from_value(argv).unwrap();
    let (inbound, _rx) = mpsc::channel(16);
    let tap: Tap = Arc::new(|_, _, _| true);
    let tr = crate::claude_stdio::Translator::new("acp-1".into(), "default", "haiku", "default");
    let command = Some(("/bin/sh".to_owned(), vec!["-c".to_owned(), "exit 0".to_owned()]));
    let agent = ChildAgent::spawn_with(
        "gone",
        &profile,
        &std::env::temp_dir(),
        inbound,
        tap,
        command,
        Some(tr),
        None,
    )
    .await
    .expect("the agent starts");
    tokio::time::timeout(std::time::Duration::from_secs(10), agent.stdin_tx.closed())
        .await
        .expect("its writer stops once it ended");
    let fence = Fence::default();
    // Claude's translator turns a cancel into an interrupt line for its stdin.
    let params = serde_json::json!({"sessionId": "acp-1"});
    let cancel = Message::notification(crate::rpc::method::SESSION_CANCEL, params);
    assert!(agent.write_fenced(&cancel, Some(&fence)).await.is_err());
    assert!(fence.is_settled(), "a message its closed writer never took was left unsettled");
}

/// Review 87 of #23322, round 4: a cut that stops a writer before it ever ran still settles
/// what that writer had queued, one a translator took included.
#[tokio::test]
async fn a_writer_stopped_before_it_ran_settles_its_queue() {
    let argv = serde_json::json!({"argv": ["/bin/sh"]});
    let profile: HarnessProfile = serde_json::from_value(argv).unwrap();
    let (inbound, _rx) = mpsc::channel(16);
    let tap: Tap = Arc::new(|_, _, _| true);
    let tr = crate::claude_stdio::Translator::new("acp-1".into(), "default", "haiku", "default");
    let command = Some(("/bin/sh".to_owned(), vec!["-c".to_owned(), "exec sleep 30".to_owned()]));
    let agent = ChildAgent::spawn_with(
        "unpolled",
        &profile,
        &std::env::temp_dir(),
        inbound,
        tap,
        command,
        Some(tr),
        None,
    )
    .await
    .expect("the agent starts");
    // Two translated messages, queued before the writer first runs (this runtime has one
    // thread, and nothing here yields to it).
    let params = serde_json::json!({"sessionId": "acp-1"});
    let cancel = Message::notification(crate::rpc::method::SESSION_CANCEL, params);
    let (first, second) = (Fence::default(), Fence::default());
    agent.write_fenced(&cancel, Some(&first)).await.unwrap();
    agent.write_fenced(&cancel, Some(&second)).await.unwrap();
    assert!(second.cut_or_end(std::time::Duration::from_secs(1)).await, "the cut is proven");
    let settled = first.is_settled();
    agent.kill().await;
    assert!(settled, "a message its unstarted writer had queued was left unsettled");
}
