use super::*;

#[test]
fn preflight_keeps_unknown_dirt_distinct_from_clean_and_running_from_other_refusals() {
    let unknown = serde_json::to_value(Preflight { running: true, dirty: None }).unwrap();
    assert_eq!(unknown, json!({"running": true, "dirty": null}));
    let both = serde_json::to_value(Preflight { running: true, dirty: Some(true) }).unwrap();
    assert_eq!(both, json!({"running": true, "dirty": true}));
    let starting = json!({"status": "ready", "turn": {"turnId": "one"}});
    assert_eq!(session_refusal_code(&starting, false), Some("running_turn"));
    assert_eq!(session_refusal_code(&starting, true), None);
    assert_eq!(session_refusal_code(&json!({"status": "running", "moving": true}), false), None);
    assert_eq!(session_refusal_code(&json!({"status": "running", "movedTo": {}}), false), None);
}

#[test]
fn after_turn_and_interrupt_are_distinct_mutually_exclusive_cli_choices() {
    use crate::cli::command::{Cli, Command, flatten};
    use clap::Parser;
    let args = ["acpmux", "session", "move", "chat", "--machine", "auto", "--after-turn"];
    let cli = Cli::try_parse_from(args).unwrap();
    assert!(matches!(
        flatten(cli.command.unwrap()),
        Command::MoveSessions { after_turn: true, interrupt: false, .. }
    ));
    let conflict = args.into_iter().chain(["--interrupt"]);
    assert!(Cli::try_parse_from(conflict).is_err());
}

#[cfg(unix)]
#[tokio::test]
async fn after_turn_waits_once_then_refuses_a_new_turn_without_interrupting_it() {
    use crate::rpc::Message;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("daemon.sock");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let original = json!({"status": "running", "turn": {"turnId": "first", "startedAt": 42}});
    let (waiting, observed) = tokio::sync::oneshot::channel();
    let (finish, finished) = tokio::sync::oneshot::channel();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (rd, mut wr) = stream.into_split();
        let mut lines = BufReader::new(rd).lines();
        let mut waiting = Some(waiting);
        let mut finished = Some(finished);
        for expected in [method::INITIALIZE, method::MUX_WAIT, method::MUX_INFO] {
            let line = lines.next_line().await.unwrap().unwrap();
            let Message::Request { id, method: called, params } = Message::parse(&line).unwrap()
            else {
                panic!("expected request");
            };
            assert_eq!(called, expected);
            let reply = match expected {
                method::INITIALIZE => json!({}),
                method::MUX_WAIT => {
                    let params = params.unwrap();
                    assert_eq!(params["turnEnded"]["turnId"], "first");
                    assert_eq!(params["sessions"], json!(["chat"]));
                    assert_eq!(params["timeoutMs"], 900_000);
                    waiting.take().unwrap().send(()).unwrap();
                    finished.take().unwrap().await.unwrap();
                    json!({"timedOut": false, "resolved": [{"status": "ready"}]})
                }
                _ => {
                    json!({"sessionId": "chat", "status": "running", "turn": {"turnId": "second"}, "queued": 2})
                }
            };
            wr.write_all(Message::ok(id, reply).to_line().as_bytes()).await.unwrap();
        }
    });
    let client = Client::connect(&socket).await.unwrap();
    let moving = tokio::spawn(async move { after_turn(&client, "chat", &original).await });
    observed.await.unwrap();
    assert!(!moving.is_finished(), "the move must wait for the daemon's turn condition");
    finish.send(()).unwrap();
    let latest = moving.await.unwrap().unwrap();
    assert_eq!(latest["queued"], 2);
    assert_eq!(session_refusal_code(&latest, false), Some("running_turn"));
    assert!(plan::refusal(&latest, false).unwrap().contains("--after-turn"));
    server.await.unwrap();
}

#[cfg(unix)]
#[tokio::test]
async fn after_turn_timeout_names_the_next_action_and_does_not_continue_the_move() {
    use crate::rpc::Message;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("daemon.sock");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (rd, mut wr) = stream.into_split();
        let mut lines = BufReader::new(rd).lines();
        for expected in [method::INITIALIZE, method::MUX_WAIT] {
            let line = lines.next_line().await.unwrap().unwrap();
            let Message::Request { id, method: called, .. } = Message::parse(&line).unwrap() else {
                panic!("expected request");
            };
            assert_eq!(called, expected);
            let result =
                if called == method::INITIALIZE { json!({}) } else { json!({"timedOut": true}) };
            wr.write_all(Message::ok(id, result).to_line().as_bytes()).await.unwrap();
        }
    });
    let client = Client::connect(&socket).await.unwrap();
    let err = after_turn(&client, "chat", &json!({"turn": {"turnId": "one"}})).await.unwrap_err();
    assert!(err.to_string().contains("chat stayed here"));
    assert!(err.to_string().contains("--after-turn again"));
    server.await.unwrap();
}
