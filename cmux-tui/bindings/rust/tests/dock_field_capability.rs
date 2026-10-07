//! R87 DOCK-WIRE: `move-tab-to-column`'s `dock` field needs `dock-columns-v1`.
//!
//! A daemon from before the rename serves `edge-docks-v1` but reads the pin
//! from `sticky`, so it would ignore `dock` and make a plain column. The SDK
//! refuses the field before it sends the request.

use cmux::raw::{
    Client, ClientConfig, ColumnPin, Error, IdentifyRequest, MoveTabToColumnRequest, Optional,
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
        "cmux-sdk-dock-field-{}-{}.sock",
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

/// A fake daemon that answers `identify` with `capabilities` and then
/// reports the next command it receives, if any.
fn daemon(capabilities: &'static [&'static str]) -> (PathBuf, thread::JoinHandle<Option<Value>>) {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let handle = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut writer = stream.try_clone().unwrap();
        let mut reader = BufReader::new(stream);
        let identify = read(&mut reader).expect("identify");
        assert_eq!(identify["cmd"], "identify");
        let data = json!({"app": "cmux-tui", "version": "0.1.0", "protocol": 12,
                          "capabilities": capabilities, "session": "main", "pid": 1,
                          "registry_id": "reg", "generation": "gen-1", "daemon_handoff": 1,
                          "terminal_revision": 1, "workspace_revision": 0});
        writeln!(writer, "{}", json!({"id": identify["id"], "ok": true, "data": data})).unwrap();
        let next = read(&mut reader);
        if let Some(request) = &next {
            writeln!(writer, "{}", json!({"id": request["id"], "ok": true, "data": {}})).unwrap();
        }
        next
    });
    (path, handle)
}

fn docked_move() -> MoveTabToColumnRequest {
    MoveTabToColumnRequest {
        after_column: Optional::Missing,
        dock: Optional::Value(ColumnPin {
            edge: "right".to_string(),
            mode: "docked".to_string(),
            role: Optional::Missing,
        }),
        pane: Optional::Value(3),
        respawn: Optional::Missing,
        screen: Optional::Missing,
        surface: 7,
        transaction: Optional::Missing,
        width: Optional::Missing,
    }
}

#[test]
fn a_dock_on_move_tab_to_column_needs_dock_columns_v1() {
    let (path, daemon) = daemon(&["tab-drag-v1", "edge-docks-v1"]);
    let config = ClientConfig::from_socket_path(&path).with_timeout(Duration::from_secs(5));
    let mut client = Client::connect(config).unwrap();
    client.identify(IdentifyRequest {}).unwrap();
    let error = client.move_tab_to_column(docked_move()).unwrap_err();
    assert!(
        matches!(error, Error::MissingCapability { capability: "dock-columns-v1", .. }),
        "{error:?}"
    );
    drop(client);
    assert_eq!(daemon.join().unwrap(), None, "the request is never sent");
    let _ = std::fs::remove_file(&path);
}

#[test]
fn a_dock_on_move_tab_to_column_is_sent_to_a_dock_columns_daemon() {
    let (path, daemon) = daemon(&["tab-drag-v1", "edge-docks-v1", "dock-columns-v1"]);
    let config = ClientConfig::from_socket_path(&path).with_timeout(Duration::from_secs(5));
    let mut client = Client::connect(config).unwrap();
    client.identify(IdentifyRequest {}).unwrap();
    client.move_tab_to_column(docked_move()).unwrap();
    drop(client);
    let sent = daemon.join().unwrap().expect("the request is sent");
    assert_eq!(sent["cmd"], "move-tab-to-column");
    assert_eq!(sent["dock"], json!({"edge": "right", "mode": "docked"}));
    let _ = std::fs::remove_file(&path);
}
