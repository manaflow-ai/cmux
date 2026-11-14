//! The generic `Client::call` and `Client::subscribe`: any daemon operation
//! by name, through the typed calls' envelope, limits and error decoding.
//! Each test runs the SDK against a mock daemon and checks the exact
//! requests.
// Unix sockets; the Windows suite is separate.
#![cfg(unix)]

use cmux::{
    CallKind, ChatTarget, ChatTargetRefusal, Config, Error, MutationOptions, StreamEndReason,
    StreamPoll,
};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::Duration;

static NEXT_SOCKET: AtomicU64 = AtomicU64::new(1);

fn socket_path() -> PathBuf {
    std::env::temp_dir().join(format!(
        "cmux-generic-call-{}-{}.sock",
        std::process::id(),
        NEXT_SOCKET.fetch_add(1, Ordering::Relaxed)
    ))
}

fn connect(path: &PathBuf) -> cmux::Client {
    cmux::Client::connect(Config::from_socket_path(path).with_timeout(Duration::from_secs(2)))
        .unwrap()
}

fn request(reader: &mut BufReader<UnixStream>) -> Value {
    let mut line = String::new();
    assert_ne!(reader.read_line(&mut line).unwrap(), 0, "the client closed early");
    let value: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(value["protocol"], "cmux.protocol/2");
    assert_eq!(value["type"], "request");
    value
}

fn respond(stream: &mut UnixStream, request: &Value, body: Value) {
    let mut envelope = json!({
        "protocol": "cmux.protocol/2",
        "type": "response",
        "id": request["id"],
    });
    envelope.as_object_mut().unwrap().extend(body.as_object().unwrap().clone());
    writeln!(stream, "{envelope}").unwrap();
}

#[test]
fn an_operation_the_sdk_does_not_know_is_sent_and_its_refusal_decoded() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let known = request(&mut reader);
        assert_eq!(known["operation"], "future.thing.list");
        assert!(known.get("idempotency_key").is_none(), "{known}");
        assert_eq!(known["params"], json!({"limit": 2}));
        respond(&mut stream, &known, json!({"ok": true, "result": {"items": [1, 2]}}));
        let unknown = request(&mut reader);
        assert_eq!(unknown["operation"], "future.thing.gone");
        respond(
            &mut stream,
            &unknown,
            json!({"ok": false, "error": {"code": "operation.unsupported",
                   "message": "unknown operation", "details": {}, "retryable": false}}),
        );
    });

    let client = connect(&path);
    let listed = client.call("future.thing.list", CallKind::Read, json!({"limit": 2})).unwrap();
    assert_eq!(listed, json!({"items": [1, 2]}));
    match client.call("future.thing.gone", CallKind::Read, Value::Null).unwrap_err() {
        Error::Protocol { code, message, retryable, .. } => {
            assert_eq!(code, "operation.unsupported");
            assert_eq!(message, "unknown operation");
            assert!(!retryable);
        }
        other => panic!("unexpected error: {other:?}"),
    }
    // Refused before anything is sent: the server saw two requests only.
    assert!(matches!(
        client.call(" ", CallKind::Read, Value::Null).unwrap_err(),
        Error::InvalidArgument(_)
    ));
    assert!(matches!(
        client.call("future.thing.list", CallKind::Read, json!([1])).unwrap_err(),
        Error::InvalidArgument(_)
    ));
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn a_mutation_retried_after_a_lost_reply_sends_the_same_key() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        // First attempt: the daemon reads the request and the connection
        // drops before the reply, so the outcome is unknown.
        let (stream, _) = listener.accept().unwrap();
        let first = request(&mut BufReader::new(stream));
        // Retry on a new connection: the daemon replays the first outcome.
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let retry = request(&mut reader);
        assert_eq!(retry["idempotency_key"], first["idempotency_key"]);
        assert_eq!(retry["params"], first["params"]);
        let result = json!({"value": {"sent": true}, "generation": "g", "revision": "4",
                            "replayed": true});
        respond(&mut stream, &retry, json!({"ok": true, "result": result}));
        first
    });

    let client = connect(&path);
    let options = MutationOptions::new("send-7").unwrap();
    let params = json!({"conversation": "conv_1", "text": "hi"});
    let error = client
        .call("conversation.send", CallKind::Mutation(options.clone()), params.clone())
        .unwrap_err();
    match error {
        Error::MutationTransport { operation, idempotency_key, .. } => {
            assert_eq!(operation, "conversation.send");
            assert_eq!(idempotency_key, "send-7");
        }
        other => panic!("unexpected error: {other:?}"),
    }
    let replayed = client.call("conversation.send", CallKind::Mutation(options), params).unwrap();
    assert_eq!(replayed["value"], json!({"sent": true}));
    assert_eq!(replayed["replayed"], json!(true));
    let first = server.join().unwrap();
    assert_eq!(first["operation"], "conversation.send");
    assert_eq!(first["idempotency_key"], "send-7");
    client.close().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn a_generic_stream_yields_items_unchanged_and_cancels() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let _control = listener.accept().unwrap().0;
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let open = request(&mut reader);
        assert_eq!(open["operation"], "future.thing.events");
        assert_eq!(open["params"]["conversation"], "conv_1");
        let stream_id = open["params"]["stream_id"].as_str().unwrap().to_string();
        respond(&mut stream, &open, json!({"ok": true, "result": {"stream_id": stream_id}}));
        writeln!(
            stream,
            "{}",
            json!({"protocol": "cmux.protocol/2", "type": "stream_item",
                   "stream_id": stream_id, "sequence": "0",
                   "item": {"kind": "anything", "n": 1}})
        )
        .unwrap();
        let cancel = request(&mut reader);
        assert_eq!(cancel["operation"], "stream.cancel");
        assert_eq!(cancel["params"]["stream"], stream_id);
        respond(&mut stream, &cancel, json!({"ok": true, "result": {}}));
        writeln!(
            stream,
            "{}",
            json!({"protocol": "cmux.protocol/2", "type": "stream_end",
                   "stream_id": stream_id, "reason": "canceled"})
        )
        .unwrap();
    });

    let client = connect(&path);
    let mut events =
        client.subscribe("future.thing.events", json!({"conversation": "conv_1"})).unwrap();
    let item = events.recv().unwrap().unwrap();
    assert_eq!(item.sequence, 0);
    assert_eq!(item.value, json!({"kind": "anything", "n": 1}));
    events.cancel().unwrap();
    assert!(events.recv().unwrap().is_none());
    assert_eq!(events.end().unwrap().reason, StreamEndReason::Canceled);
    assert!(matches!(events.recv_timeout(Duration::from_millis(10)).unwrap(), StreamPoll::End));
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn an_origin_claim_rides_on_every_request_of_its_handle_only() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let claimed = request(&mut reader);
        assert_eq!(claimed["origin"], json!({"claim": "agent"}));
        respond(&mut stream, &claimed, json!({"ok": true, "result": {}}));
        let plain = request(&mut reader);
        assert!(plain.get("origin").is_none(), "{plain}");
        respond(&mut stream, &plain, json!({"ok": true, "result": {}}));
    });

    let client = connect(&path);
    let agent = client.with_origin_claim("agent").unwrap();
    agent.call("conversation.list", CallKind::Read, Value::Null).unwrap();
    client.call("conversation.list", CallKind::Read, Value::Null).unwrap();
    assert!(matches!(client.with_origin_claim("root"), Err(Error::InvalidArgument(_))));
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn a_chat_target_reads_the_catalog_on_every_call() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        for capabilities in [json!(["agent_session"]), json!(["terminal"])] {
            let list = request(&mut reader);
            assert_eq!(list["operation"], "machine.list");
            assert_eq!(list["params"], json!({"catalog": true}));
            let machines = json!({"machines": [{"id": "machine_box", "origin": "ssh",
                "status": "running", "capabilities": capabilities}]});
            respond(&mut stream, &list, json!({"ok": true, "result": machines}));
        }
    });

    let client = connect(&path);
    let target = client.chat_target("machine_box", false).unwrap();
    assert_eq!(target, Ok(ChatTarget::Device { id: "machine_box".into(), local: false }));
    // The device dropped agent sessions: the next call sees it.
    let refused = client.chat_target("machine_box", false).unwrap();
    assert_eq!(refused, Err(ChatTargetRefusal::NotPermitted { id: "machine_box".into() }));
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn a_claimed_stream_sends_its_cancel_with_the_same_claim() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let _control = listener.accept().unwrap().0;
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let open = request(&mut reader);
        assert_eq!(open["origin"], json!({"claim": "agent"}));
        let stream_id = open["params"]["stream_id"].as_str().unwrap().to_string();
        respond(&mut stream, &open, json!({"ok": true, "result": {"stream_id": stream_id}}));
        let cancel = request(&mut reader);
        assert_eq!(cancel["operation"], "stream.cancel");
        assert_eq!(cancel["origin"], json!({"claim": "agent"}), "{cancel}");
        respond(&mut stream, &cancel, json!({"ok": true, "result": {}}));
        writeln!(
            stream,
            "{}",
            json!({"protocol": "cmux.protocol/2", "type": "stream_end",
                   "stream_id": stream_id, "reason": "canceled"})
        )
        .unwrap();
    });

    let client = connect(&path);
    let agent = client.with_origin_claim("agent").unwrap();
    let mut events = agent.subscribe("conversation.events", json!({"conversation": "c"})).unwrap();
    events.cancel().unwrap();
    assert_eq!(events.end().unwrap().reason, StreamEndReason::Canceled);
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}
