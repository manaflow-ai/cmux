use super::*;

/// `acpmux wait` names what a session waits on the person for. An agent's
/// question (AskUserQuestion, a Codex user-input request) reaches acpmux as a
/// permission request, but it is never shown as one (Leo 2026-10-21).
#[test]
fn a_waiting_question_is_never_shown_as_a_permission() {
    let question = json!({
        "status": "waiting", "pendingPermissions": 1,
        "waitingOn": "question", "waitingPrompt": "Which database should I use?",
    });
    let line = wait_state(&question);
    assert!(!line.contains("permission"), "{line}");
    assert_eq!(line, "asks a question: Which database should I use?");
    let untitled = json!({"status": "waiting", "pendingPermissions": 1, "waitingOn": "question"});
    assert_eq!(wait_state(&untitled), "asks a question");
    assert_eq!(wait_notice("lane", &question), "lane asks a question");
}

#[test]
fn a_tool_permission_and_a_finished_session_read_as_before() {
    let permission =
        json!({"status": "waiting", "pendingPermissions": 2, "waitingOn": "permission"});
    assert_eq!(wait_state(&permission), "waiting for permission (2)");
    assert_eq!(wait_notice("lane", &permission), "lane needs a permission");
    let idle = json!({"status": "idle", "pendingPermissions": 0});
    assert_eq!(wait_state(&idle), "idle");
    assert_eq!(wait_notice("lane", &idle), "lane finished");
}

/// A failed turn reads as failed, with its error and the retry that waits, never as done
/// (gui-push, 2026-10-20: "acpmux wait --print after a turn that failed (capacity) prints the
/// previous turn's reply, not the error, so a failed turn reads as done").
#[test]
fn a_failed_turn_reads_as_failed_with_its_error_and_its_retry() {
    let failed = json!({"status": "ready", "turn": null,
        "lastTurn": {"status": "failed", "errorText": "API Error: 503 no accounts", "error": "x"}});
    assert_eq!(failed_turn(&failed).as_deref(), Some("API Error: 503 no accounts"));
    let bare = json!({"status": "ready", "lastTurn": {"status": "failed", "detail": "stalled"}});
    assert_eq!(failed_turn(&bare).as_deref(), Some("stalled"));
    let done = json!({"status": "ready", "lastTurn": {"status": "completed"}});
    assert_eq!(failed_turn(&done), None);
    // A turn runs again (the retry fired): it is no longer the failed one.
    let running =
        json!({"status": "running", "turn": {"turnId": "t2"}, "lastTurn": {"status": "failed"}});
    assert_eq!(failed_turn(&running), None);

    let now = 1_000_000;
    let row = json!({"name": "my lane", "status": "ready", "pendingPermissions": 0,
        "error": "API Error: 503 no accounts",
        "retry": {"attempt": 2, "of": 4, "reason": "capacity", "nextAt": now + 64_500}});
    assert_eq!(wait_state(&row), "ready: turn failed, retry waits");
    assert_eq!(wait_notice("lane", &row), "lane's turn failed");
    assert_eq!(
        failure_lines(&row, now),
        [
            "error: API Error: 503 no accounts",
            "retry 2 of 4 waits out capacity: the provider or the gateway is full; the next \
             attempt runs in 1m05s (`acpmux retry 'my lane'` runs it now)",
        ]
    );
    let row = json!({"name": "lane", "status": "ready", "error": "bad request", "retry": null});
    assert_eq!(wait_state(&row), "ready: turn failed");
    assert_eq!(
        failure_lines(&row, now),
        [
            "error: bad request",
            "no automatic retry waits; `acpmux retry lane` sends the turn again"
        ]
    );
    assert!(failure_lines(&json!({"name": "lane", "status": "ready"}), now).is_empty());
}

#[cfg(unix)]
#[tokio::test]
async fn matching_wait_includes_name_resolution_in_its_timeout() {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    let dir = cmux_unix_socket::short_test_dir("wait-budget");
    let socket = dir.path().join("s");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (read, mut write) = stream.into_split();
        let mut lines = BufReader::new(read).lines();
        while let Some(line) = lines.next_line().await.unwrap() {
            let msg: Value = serde_json::from_str(&line).unwrap();
            let Some(id) = msg.get("id") else { continue };
            let result = match msg["method"].as_str().unwrap() {
                method::INITIALIZE => json!({}),
                method::MUX_INFO => {
                    tokio::time::sleep(std::time::Duration::from_millis(800)).await;
                    json!({"sessionId": "s"})
                }
                method::MUX_ATTACH => json!({"events": []}),
                other => panic!("unexpected request: {other}"),
            };
            let response = json!({"jsonrpc": "2.0", "id": id, "result": result});
            write.write_all(format!("{response}\n").as_bytes()).await.unwrap();
        }
    });
    let client = Client::connect(&socket).await.unwrap();
    let started = tokio::time::Instant::now();
    let error = wait(
        client,
        WaitOpts {
            sessions: vec!["name".into()],
            until: vec![],
            all: false,
            timeout: Some(1),
            print: false,
            notify: false,
            matcher: Some(Matcher::Text("absent".into())),
        },
        true,
    )
    .await
    .unwrap_err();
    server.abort();
    assert_eq!(crate::cli::errors::classify(&error).code, Code::Timeout);
    assert!(
        started.elapsed() < std::time::Duration::from_millis(1500),
        "name resolution reset the matching timeout: {:?}",
        started.elapsed()
    );
}
