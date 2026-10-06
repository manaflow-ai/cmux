//! The host lives inside its acpmux daemon's lifetime (home-state-ownership.md
//! section 3): after the daemon it started or joined shuts down (Quit, end
//! sessions), the host never starts another one; it reports the end and the
//! brain stops. On sbmix-v4 (cmux-lawrence-2, 2026-10-06) the host stayed alive
//! with ppid 1 after the app ended its sessions and spawned `acpmux daemon run`
//! again.

mod common;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex};

use optchat_chief::acpmux::{Acpmux, AgentEvent};
use serde_json::{Value, json};

/// A daemon that serves one connection, then shuts down: the connection
/// closes and the socket goes, as `acpmux` does on `_acpmux/shutdown`.
fn serve_once_then_shut_down(listener: UnixListener, socket: std::path::PathBuf) {
    std::thread::spawn(move || {
        let Some(Ok(conn)) = listener.incoming().next() else { return };
        let mut out = conn.try_clone().unwrap();
        for line in BufReader::new(conn).lines() {
            let Ok(line) = line else { return };
            let req: Value = serde_json::from_str(&line).unwrap();
            let id = req["id"].clone();
            let result = if req["method"] == "_acpmux/sessions" { json!({"sessions": []}) } else { json!({}) };
            writeln!(out, "{}", json!({"jsonrpc": "2.0", "id": id, "result": result})).unwrap();
            if req["method"] == "_acpmux/watch" {
                // Up is reported after the watch; then the daemon ends.
                std::thread::sleep(std::time::Duration::from_millis(200));
                drop(listener);
                let _ = std::fs::remove_file(&socket);
                let _ = out.shutdown(std::net::Shutdown::Both);
                return;
            }
        }
    });
}

#[test]
fn after_its_acpmux_daemon_shuts_down_the_host_starts_no_other() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("acpmux.sock");
    let marker = dir.path().join("respawned");
    let bin = dir.path().join("acpmux");
    std::fs::write(&bin, format!("#!/bin/sh\ntouch '{}'\nsleep 30\n", marker.display())).unwrap();
    std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
    // SAFETY: this test binary runs this one test; nothing else reads the env meanwhile.
    unsafe {
        std::env::set_var("ACPMUX_BIN", &bin);
        std::env::set_var("ACPMUX_HOME", dir.path());
    }
    serve_once_then_shut_down(UnixListener::bind(&socket).unwrap(), socket.clone());
    let acpmux = Acpmux::new(socket, None, Vec::new());
    let (tx, rx) = channel();
    let sink = Mutex::new(tx);
    acpmux.spawn_link(Arc::new(move |e| { let _ = sink.lock().unwrap().send(e); }), Arc::new(|_: &str| {}));
    let mut seen = Vec::new();
    let ended = loop {
        match rx.recv_timeout(common::WAIT) {
            Ok(AgentEvent::Ended) => break true,
            Ok(event) => seen.push(format!("{event:?}")),
            Err(_) => break false,
        }
    };
    assert!(ended, "the link reports the daemon's end; saw {seen:?}");
    std::thread::sleep(std::time::Duration::from_millis(1500));
    assert!(!marker.exists(), "no acpmux daemon was started again");
}
