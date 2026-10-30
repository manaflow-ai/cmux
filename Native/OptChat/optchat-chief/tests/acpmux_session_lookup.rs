//! The harness gate's session lookup against a fake acpmux daemon that paces
//! session lists, as a busy acpmux does: the Chief asks for the one session,
//! so a paced list never refuses a turn ("acpmux did not say which harness
//! runs ...: session lists are paced").

mod common;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex};

use optchat_chief::acpmux::{Acpmux, AgentEvent, AgentPort};
use serde_json::{Value, json};

/// Answers the link's first session list, then paces every later one;
/// `_acpmux/info` answers for `s-7` only.
fn serve(listener: UnixListener) {
    let lists = Arc::new(AtomicUsize::new(0));
    std::thread::spawn(move || {
        for conn in listener.incoming().flatten() {
            let lists = lists.clone();
            std::thread::spawn(move || {
                let mut out = conn.try_clone().unwrap();
                for line in BufReader::new(conn).lines() {
                    let Ok(line) = line else { return };
                    let req: Value = serde_json::from_str(&line).unwrap();
                    let id = req["id"].clone();
                    let result = |r: Value| json!({"jsonrpc": "2.0", "id": id, "result": r});
                    let error = |code: i64, message: &str| {
                        let error = json!({"code": code, "message": message});
                        json!({"jsonrpc": "2.0", "id": id, "error": error})
                    };
                    let reply = match req["method"].as_str().unwrap_or_default() {
                        "_acpmux/watch" => result(json!({})),
                        "_acpmux/harnesses" => result(common::catalog()),
                        "_acpmux/sessions" if lists.fetch_add(1, Ordering::SeqCst) == 0 => {
                            result(json!({"sessions": []}))
                        }
                        "_acpmux/sessions" => {
                            error(-32000, "session lists are paced: try again in 30839 ms")
                        }
                        "_acpmux/info" if ["s-7", "s-"].contains(
                            &req["params"]["sessionId"].as_str().unwrap_or_default(),
                        ) =>
                        {
                            result(json!({
                                "sessionId": "s-7", "name": "kid", "harness": "claude-sr",
                                "status": "idle", "logsLoading": false
                            }))
                        }
                        "_acpmux/info" => error(-32002, "no session with the id"),
                        _ => result(json!({})),
                    };
                    if req.get("id").is_some() {
                        writeln!(out, "{reply}").unwrap();
                    }
                }
            });
        }
    });
}

#[test]
fn a_paced_session_list_does_not_hide_a_sessions_harness() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("acpmux.sock");
    serve(UnixListener::bind(&socket).unwrap());

    let acpmux = Acpmux::new(socket, None, Vec::new());
    let (tx, rx) = channel();
    let sink = Mutex::new(tx);
    acpmux.spawn_link(
        Arc::new(move |e| sink.lock().unwrap().send(e).unwrap()),
        Arc::new(|_: &str| {}),
    );
    while !matches!(rx.recv_timeout(common::WAIT).unwrap(), AgentEvent::Up(_)) {}

    let summary = acpmux.session("s-7").expect("a paced list does not fail the lookup");
    assert_eq!(summary.map(|s| s.harness).as_deref(), Some("claude-sr"));
    assert_eq!(acpmux.session("gone").expect("an unknown session is no error"), None);
    // acpmux resolves a key by id prefix too: another session's row is not this one's.
    assert_eq!(acpmux.session("s-").expect("a prefix match is no error"), None);
}
