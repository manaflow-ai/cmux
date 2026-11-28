use super::*;

/// A connection that never ends.
fn open() -> tokio::sync::watch::Receiver<bool> {
    let (tx, rx) = tokio::sync::watch::channel(false);
    std::mem::forget(tx);
    rx
}

/// A session pid no other test uses: the registry is process-wide.
fn session(n: u32) -> u32 {
    4_000_000 + n
}

#[tokio::test]
async fn with_no_relay_the_daemon_delivers_itself() {
    assert!(deliver(session(1), Path::new("/nonexistent"), "x\n").await.is_none());
    assert!(!attached(session(1)));
}

/// The relay takes the exact lines the daemon would have written, writes them, and its `done`
/// answers the waiting delivery: Ok, or the relay's own error.
#[tokio::test]
async fn a_delivery_goes_through_the_attached_relay_and_its_answer_comes_back() {
    let pid = session(2);
    // The relay's first poll attaches it; nothing waits yet, and its connection has ended.
    let (_closed, ended) = tokio::sync::watch::channel(true);
    let first = poll_for(pid, &json!({}), ended).await.expect("poll");
    assert_eq!(first["deliveries"], json!([]));
    assert!(attached(pid));

    for outcome in [None, Some("could not reach the session's inbox")] {
        let sent = tokio::spawn(async move {
            deliver(pid, Path::new("/tmp/inbox.sock"), "{\"type\":\"user\"}\n").await
        });
        let got = poll_for(pid, &json!({}), open()).await.expect("poll");
        let list = got["deliveries"].as_array().expect("deliveries");
        assert_eq!(list.len(), 1, "{got}");
        assert_eq!(list[0]["frames"], "{\"type\":\"user\"}\n");
        assert_eq!(list[0]["socket"], "/tmp/inbox.sock");
        let id = list[0]["id"].as_str().expect("id").to_owned();
        let done = match outcome {
            None => json!({"done": [{"id": id}]}),
            Some(e) => json!({"done": [{"id": id, "error": e}]}),
        };
        let (_closed, ended) = tokio::sync::watch::channel(true);
        poll_for(pid, &done, ended).await.expect("ack");
        let answer = sent.await.expect("join").expect("relayed");
        assert_eq!(answer, outcome.map_or(Ok(()), |e| Err(e.to_owned())));
    }
}

/// Any number of deliveries wait for one relay: past the old limit of 256, every one is handed
/// over and answered.
#[tokio::test]
async fn a_relay_takes_more_than_256_waiting_deliveries() {
    let pid = session(4);
    let (_closed, ended) = tokio::sync::watch::channel(true);
    poll_for(pid, &json!({}), ended).await.expect("poll");
    let sent: Vec<_> = (0..300)
        .map(|n| {
            tokio::spawn(async move {
                deliver(pid, Path::new("/tmp/inbox.sock"), &format!("{n}\n")).await
            })
        })
        .collect();
    while relays().get(&pid).map_or(0, |e| e.pending.len()) < 300 {
        tokio::task::yield_now().await;
    }
    let mut done = Vec::new();
    while done.len() < 300 {
        let got = poll_for(pid, &json!({}), open()).await.expect("poll");
        for d in got["deliveries"].as_array().expect("deliveries") {
            done.push(json!({"id": d["id"]}));
        }
    }
    let (_closed, ended) = tokio::sync::watch::channel(true);
    poll_for(pid, &json!({"done": done}), ended).await.expect("ack");
    for s in sent {
        assert_eq!(s.await.expect("join"), Some(Ok(())));
    }
}

/// A relay that stopped polling is no longer attached: its session's deliveries go back to the
/// daemon instead of waiting for it.
#[tokio::test]
async fn a_relay_gone_quiet_is_detached() {
    let pid = session(3);
    {
        let mut all = relays();
        let mut entry = Entry::new();
        entry.last_poll = Instant::now().checked_sub(ATTACHED_FOR * 2).expect("past");
        all.insert(pid, entry);
    }
    assert!(!attached(pid));
    assert!(deliver(pid, Path::new("/nonexistent"), "x\n").await.is_none());
    assert!(!relays().contains_key(&pid));
}

/// The relay's writer is the daemon's: the same lines reach the inbox socket.
#[cfg(unix)]
#[tokio::test]
async fn write_frames_writes_the_lines_to_the_inbox() {
    use tokio::io::AsyncReadExt;
    let dir = tempfile::tempdir().expect("tempdir");
    let socket = dir.path().join("inbox.sock");
    let listener = tokio::net::UnixListener::bind(&socket).expect("bind");
    let frames = crate::claude_peers::frames(Some("tok"), "hello", "u-1", "acpmux:coord");
    let read = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.expect("accept");
        let mut got = String::new();
        stream.read_to_string(&mut got).await.expect("read");
        got
    });
    let written = write_one(&json!({"id": "d1", "socket": socket, "frames": frames})).await;
    assert_eq!(written, json!({"id": "d1"}));
    assert_eq!(read.await.expect("join"), frames);
    let missing = write_one(&json!({"id": "d2", "socket": dir.path().join("none")})).await;
    assert!(missing["error"].is_string(), "{missing}");
}

/// A process no Claude Code session runs is refused for good, so its server stops polling.
#[test]
fn no_session_and_an_unknown_method_are_refusals_for_good() {
    let no_session = anyhow::Error::new(crate::client::DaemonError(
        RpcError::invalid_params("x").with_data(json!({"reason": NO_SESSION})),
    ));
    assert!(refused_for_good(&no_session));
    let old_daemon = anyhow::Error::new(crate::client::DaemonError(RpcError::method_not_found(
        crate::rpc::method::MUX_INBOX_RELAY,
    )));
    assert!(refused_for_good(&old_daemon));
    let other = anyhow::Error::new(crate::client::DaemonError(RpcError::internal("busy")));
    assert!(!refused_for_good(&other));
    assert!(!refused_for_good(&anyhow::anyhow!("connection closed")));
}

/// The test process runs under no Claude Code session the registry lists.
#[test]
fn a_process_no_session_runs_serves_none() {
    assert_eq!(session_of(std::process::id(), &[]), None);
}

/// In its own session, the relay opens the daemon's message line with the session's own token,
/// never the daemon's (a peer key for a chat only the bridge setting listed); for another inbox
/// it writes the daemon's lines unchanged.
#[test]
fn the_relay_opens_its_own_inbox_with_its_own_token() {
    let daemon = crate::claude_peers::frames(Some("peer-key"), "hi", "u-2", "acpmux:coord");
    let own = Some(("/tmp/cc-socks/1.sock".to_owned(), "child-token".to_owned()));
    let mine = own_frames("/tmp/cc-socks/1.sock", &daemon, &own);
    assert_eq!(mine, crate::claude_peers::frames(Some("child-token"), "hi", "u-2", "acpmux:coord"));
    assert_eq!(own_frames("/tmp/cc-socks/2.sock", &daemon, &own), daemon);
    assert_eq!(own_frames("/tmp/cc-socks/1.sock", &daemon, &None), daemon);
}
