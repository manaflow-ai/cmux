use cmux_client::{
    ClientConfig, CmuxClient, CmuxError, MarkWorkspacesProviderManagedRequest, Optional,
    PingRequest, SubscribeRequest, SubscribeRequestTreeEvents,
};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

static NEXT_SOCKET: AtomicU64 = AtomicU64::new(1);

fn socket_path() -> PathBuf {
    std::env::temp_dir().join(format!(
        "cmux-rust-sdk-test-{}-{}.sock",
        std::process::id(),
        NEXT_SOCKET.fetch_add(1, Ordering::Relaxed)
    ))
}

fn read_request(reader: &mut BufReader<UnixStream>) -> Value {
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap()
}

fn send_response(stream: &mut UnixStream, request: &Value, data: Value) {
    writeln!(stream, "{}", json!({"id": request["id"], "ok": true, "data": data})).unwrap();
}

#[test]
fn external_consumer_uses_typed_commands_and_field_capability_guards() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());

        let identify = read_request(&mut reader);
        assert_eq!(identify["cmd"], "identify");
        send_response(
            &mut stream,
            &identify,
            json!({
                "app": "cmux-tui",
                "version": "0.4.0",
                "protocol": 10,
                "capabilities": [],
                "session": "test",
                "pid": 42,
                "registry_id": "registry",
                "generation": "generation",
                "workspace_revision": 3,
                "terminal_revision": 7,
                "daemon_handoff": 1
            }),
        );

        let ping = read_request(&mut reader);
        assert_eq!(ping["cmd"], "ping");
        send_response(&mut stream, &ping, json!({"ok": true, "version": "0.4.0", "protocol": 10}));
    });

    let mut client = CmuxClient::connect(
        ClientConfig::from_socket_path(&path).with_timeout(Duration::from_secs(1)),
    )
    .unwrap();
    let identify = client.identify_server().unwrap();
    assert_eq!(identify.protocol, 10);
    assert_eq!(client.ping(PingRequest::default()).unwrap().protocol, 10);

    let error = match client.subscribe(SubscribeRequest {
        tree_events: Optional::Value(SubscribeRequestTreeEvents::Coarse),
        surface: Optional::Value(7),
    }) {
        Ok(_) => panic!("surface subscribe unexpectedly bypassed capability guard"),
        Err(error) => error,
    };
    assert!(matches!(
        error,
        CmuxError::MissingCapability {
            command: "subscribe",
            capability: "surface-subscribe-filter",
        }
    ));

    client.close();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn provider_authority_is_denied_before_typed_or_known_raw_writes() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let (observed_tx, observed_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut observed = Vec::new();
        loop {
            let mut line = String::new();
            if reader.read_line(&mut line).unwrap() == 0 {
                break;
            }
            let request: Value = serde_json::from_str(&line).unwrap();
            observed.push(request["cmd"].as_str().unwrap().to_string());
            send_response(&mut stream, &request, json!({}));
        }
        observed_tx.send(observed).unwrap();
    });

    let mut client = CmuxClient::connect(ClientConfig::from_socket_path(&path)).unwrap();
    let typed = client.mark_workspaces_provider_managed(MarkWorkspacesProviderManagedRequest {
        authority: "provider.example".to_string(),
    });
    let Value::Object(raw_request) =
        json!({"cmd": "mark-workspaces-provider-managed", "authority": "provider.example"})
    else {
        unreachable!()
    };
    let raw = client.request_raw(raw_request);
    client.close();

    assert!(matches!(
        typed,
        Err(CmuxError::AuthorityDenied {
            command: "mark-workspaces-provider-managed",
            authority: "provider-authority",
        })
    ));
    assert!(matches!(
        raw,
        Err(CmuxError::AuthorityDenied {
            command: "mark-workspaces-provider-managed",
            authority: "provider-authority",
        })
    ));
    server.join().unwrap();
    assert!(observed_rx.recv().unwrap().is_empty());
    std::fs::remove_file(path).unwrap();
}

#[test]
fn provider_authority_can_be_explicitly_enabled() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let request = read_request(&mut BufReader::new(stream.try_clone().unwrap()));
        assert_eq!(request["cmd"], "mark-workspaces-provider-managed");
        send_response(&mut stream, &request, json!({}));
    });

    let config = ClientConfig::from_socket_path(&path).with_provider_authority(true);
    assert!(config.allow_provider_authority);
    let mut client = CmuxClient::connect(config).unwrap();
    client
        .mark_workspaces_provider_managed(MarkWorkspacesProviderManagedRequest {
            authority: "provider.example".to_string(),
        })
        .unwrap();
    client.close();

    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}
