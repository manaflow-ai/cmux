//! A new viewer on an old daemon (Leo, 2026-11-16: "prove it correct"): `attach-surface`'s
//! `hybrid_stream` and `hybrid_frame` need `agent-cli-hybrid-v1`. A daemon from before the
//! hybrid stream never lists it, so the SDK refuses the resume fields before it sends anything,
//! and the viewer's plain attach gets the PTY's bytes as `output` events, as it always did.
// Unix sockets; the Windows suite is separate.
#![cfg(unix)]

use cmux::raw::{AttachSurfaceRequest, Client, ClientConfig, Error, IdentifyRequest, Optional};
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
        "cmux-sdk-hybrid-cap-{}-{}.sock",
        std::process::id(),
        NEXT_SOCKET.fetch_add(1, Ordering::Relaxed)
    ))
}

fn read(reader: &mut BufReader<UnixStream>) -> Option<Value> {
    let mut line = String::new();
    match reader.read_line(&mut line) {
        Ok(0) | Err(_) => None,
        Ok(_) => Some(serde_json::from_str(&line).unwrap()),
    }
}

/// A daemon that lists `capabilities` in `identify`; each later connection's first request is
/// recorded, answered, and followed by one `output` event of "plain".
fn daemon(
    capabilities: &'static [&'static str],
    connections: usize,
) -> (PathBuf, thread::JoinHandle<Vec<Value>>) {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let handle = thread::spawn(move || {
        let mut requests = Vec::new();
        for n in 0..connections {
            let (stream, _) = listener.accept().unwrap();
            let mut writer = stream.try_clone().unwrap();
            let mut reader = BufReader::new(stream);
            if n == 0 {
                let identify = read(&mut reader).expect("identify");
                assert_eq!(identify["cmd"], "identify");
                let data = json!({"app": "cmux-tui", "version": "0.1.0", "protocol": 12,
                                  "capabilities": capabilities, "session": "main", "pid": 1,
                                  "registry_id": "reg", "generation": "gen-1", "daemon_handoff": 1,
                                  "terminal_revision": 1, "workspace_revision": 0});
                writeln!(writer, "{}", json!({"id": identify["id"], "ok": true, "data": data}))
                    .unwrap();
                continue;
            }
            let Some(request) = read(&mut reader) else { break };
            let id = request["id"].clone();
            requests.push(request);
            // A viewer that has what it wanted may hang up before the event goes out.
            let _ = writeln!(writer, "{}", json!({"id": id, "ok": true, "data": {}}));
            let event = json!({"event": "output", "surface": 7, "data": "cGxhaW4="});
            let _ = writeln!(writer, "{event}");
        }
        requests
    });
    (path, handle)
}

fn client(path: &PathBuf) -> Client {
    let config = ClientConfig::from_socket_path(path).with_timeout(Duration::from_secs(5));
    let mut client = Client::connect(config).unwrap();
    client.identify(IdentifyRequest::default()).unwrap();
    client
}

fn resume() -> AttachSurfaceRequest {
    AttachSurfaceRequest {
        surface: Optional::Value(7),
        hybrid_stream: Optional::Value("0b7c8f9e".to_string()),
        hybrid_frame: Optional::Value(12),
        ..AttachSurfaceRequest::default()
    }
}

#[test]
fn a_new_viewer_on_an_old_daemon_falls_back_to_bytes() {
    let (path, daemon) = daemon(&["attach-initial-size", "size-lease-v1"], 2);
    let mut client = client(&path);
    let Err(error) = client.attach_surface(resume()) else {
        panic!("an old daemon took a hybrid attach");
    };
    assert!(
        matches!(error, Error::MissingCapability { capability: "agent-cli-hybrid-v1", .. }),
        "{error:?}"
    );
    let plain =
        AttachSurfaceRequest { surface: Optional::Value(7), ..AttachSurfaceRequest::default() };
    let mut stream = client.attach_surface(plain).unwrap();
    let event = stream.recv_frame_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(event, json!({"event": "output", "surface": 7, "data": "cGxhaW4="}));
    drop(stream);
    drop(client);
    let sent = daemon.join().unwrap();
    assert_eq!(sent.len(), 1, "only the plain attach reached the daemon: {sent:?}");
    assert_eq!(sent[0]["cmd"], "attach-surface");
    assert!(sent[0].get("hybrid_stream").is_none() && sent[0].get("hybrid_frame").is_none());
    let _ = std::fs::remove_file(&path);
}

#[test]
fn a_new_viewer_on_a_new_daemon_names_its_frame() {
    let (path, daemon) = daemon(&["agent-cli-hybrid-v1", "agent-cli-hybrid-v2"], 2);
    let mut client = client(&path);
    let stream = client.attach_surface(resume()).unwrap();
    drop(stream);
    drop(client);
    let sent = daemon.join().unwrap();
    assert_eq!(sent[0]["hybrid_stream"], "0b7c8f9e");
    assert_eq!(sent[0]["hybrid_frame"], 12);
    let _ = std::fs::remove_file(&path);
}
