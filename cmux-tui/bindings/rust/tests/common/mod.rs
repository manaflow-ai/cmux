//! A one-connection mock daemon for the SDK's request/response tests: the
//! test reads each request the SDK sends, checks it, and writes the reply.
#![allow(dead_code)] // each test binary uses part of it

use serde_json::{Map, Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::Duration;

pub const SESSION: &str = "session_00000000000000000000000000000002";
pub const WORKSPACE: &str = "ws_00000000000000000000000000000003";
pub const SCREEN: &str = "screen_00000000000000000000000000000005";
pub const PANE: &str = "pane_00000000000000000000000000000006";
pub const TAB: &str = "tab_00000000000000000000000000000007";
pub const TAB_2: &str = "tab_00000000000000000000000000000008";

static NEXT_SOCKET: AtomicU64 = AtomicU64::new(1);

/// A mock daemon on a fresh socket that serves one connection with `serve`.
pub fn mock(
    serve: impl FnOnce(&mut UnixStream, &mut BufReader<UnixStream>) + Send + 'static,
) -> Mock {
    let path = std::env::temp_dir().join(format!(
        "cmux-sdk-mock-{}-{}.sock",
        std::process::id(),
        NEXT_SOCKET.fetch_add(1, Ordering::Relaxed)
    ));
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        serve(&mut stream, &mut reader);
    });
    Mock { path, server: Some(server) }
}

pub struct Mock {
    path: PathBuf,
    server: Option<thread::JoinHandle<()>>,
}

impl Mock {
    pub fn client(&self) -> cmux::Client {
        let config =
            cmux::Config::from_socket_path(&self.path).with_timeout(Duration::from_secs(2));
        cmux::Client::connect(config).unwrap()
    }

    pub fn session(&self, client: &cmux::Client) -> cmux::Session {
        client.session(cmux::SessionId::parse(SESSION).unwrap())
    }

    pub fn raw(&self) -> cmux::raw::Client {
        let config = cmux::raw::ClientConfig::from_socket_path(&self.path)
            .with_timeout(Duration::from_secs(2));
        cmux::raw::Client::connect(config).unwrap()
    }

    pub fn finish(mut self) {
        self.server.take().unwrap().join().unwrap();
    }
}

impl Drop for Mock {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

pub fn read_line(reader: &mut BufReader<UnixStream>) -> Value {
    let mut line = String::new();
    assert_ne!(reader.read_line(&mut line).unwrap(), 0, "the client closed early");
    serde_json::from_str(&line).unwrap()
}

/// The next protocol/2 request, which must be `operation`.
pub fn request(reader: &mut BufReader<UnixStream>, operation: &str) -> Value {
    let value = read_line(reader);
    assert_eq!(value["protocol"], "cmux.protocol/2");
    assert_eq!(value["type"], "request");
    assert_eq!(value["operation"], operation, "{value}");
    value
}

pub fn respond(stream: &mut UnixStream, request: &Value, body: Value) {
    let mut response = Map::from_iter([
        ("protocol".to_string(), json!("cmux.protocol/2")),
        ("type".to_string(), json!("response")),
        ("id".to_string(), request["id"].clone()),
    ]);
    response.extend(body.as_object().unwrap().clone());
    writeln!(stream, "{}", Value::Object(response)).unwrap();
}

pub fn read_ok(stream: &mut UnixStream, request: &Value, result: Value) {
    respond(stream, request, json!({"ok": true, "result": result}));
}

pub fn mutation_ok(stream: &mut UnixStream, request: &Value, value: Value) {
    assert!(request["idempotency_key"].is_string(), "{request}");
    let result = json!({"value": value, "generation": "g", "revision": "9", "replayed": false});
    respond(stream, request, json!({"ok": true, "result": result}));
}

/// The next protocol-12 command, which must be `cmd`.
pub fn command(reader: &mut BufReader<UnixStream>, cmd: &str) -> Value {
    let value = read_line(reader);
    assert_eq!(value["cmd"], cmd, "{value}");
    value
}

pub fn reply(stream: &mut UnixStream, request: &Value, body: Value) {
    let mut response = Map::from_iter([("id".to_string(), request["id"].clone())]);
    response.extend(body.as_object().unwrap().clone());
    writeln!(stream, "{}", Value::Object(response)).unwrap();
}

/// Answers the protocol-12 `identify` with `capabilities`.
pub fn identify(
    stream: &mut UnixStream,
    reader: &mut BufReader<UnixStream>,
    capabilities: &[&str],
) {
    let identify = command(reader, "identify");
    let data = json!({"app": "cmux-tui", "capabilities": capabilities, "daemon_handoff": 1,
                      "generation": "g", "pid": 1, "protocol": 12, "registry_id": "r",
                      "session": "mock", "terminal_revision": 0, "version": "0",
                      "workspace_revision": 0});
    reply(stream, &identify, json!({"ok": true, "data": data}));
}
