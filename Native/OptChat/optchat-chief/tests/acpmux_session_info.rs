//! Which harness runs a session is read from `_acpmux/info`, never from the
//! paced session list: a daemon whose lists are paced ("session lists are
//! paced: try again in 35374 ms") refused every Chief turn, subagent prompt
//! and memory compactor session that asked it.

mod common;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex};

use optchat_chief::acpmux::{Acpmux, AgentEvent, AgentPort};
use optchat_chief::harness_gate;
use serde_json::{Value, json};

/// A daemon whose `_acpmux/info` knows `s-1` (on `claude`, named
/// `optchat-compactor`) and resolves its name and the prefixes `s-` and
/// `optchat` to it too, as acpmux's `Hub::resolve` does; `dup` is a name two
/// sessions share, `optchat-twin` a peer's session that acpmux forwards by its
/// bare name (only `local/s-1` resolves as local), `builder/review` a peer's session (its peer answers with
/// the bare name `review`), and `p-down` a peer session whose link is down.
/// With `paced`, every `_acpmux/sessions` is refused as a busy acpmux refuses
/// it; else it lists them all. The watch answers with the list.
fn serve(listener: UnixListener, requests: Arc<Mutex<Vec<Value>>>, paced: bool) {
    std::thread::spawn(move || {
        for conn in listener.incoming().flatten() {
            let requests = requests.clone();
            std::thread::spawn(move || {
                let mut out = conn.try_clone().unwrap();
                for line in BufReader::new(conn).lines() {
                    let Ok(line) = line else { return };
                    let req: Value = serde_json::from_str(&line).unwrap();
                    requests.lock().unwrap().push(req.clone());
                    let id = req["id"].clone();
                    let ok = |result: Value| json!({"jsonrpc": "2.0", "id": id, "result": result});
                    let err = |code: i64, message: &str, data: Value| json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message, "data": data}});
                    let s1 = json!({"sessionId": "s-1", "name": "optchat-compactor", "harness": "claude", "status": "idle"});
                    let row = |id: &str, name: &str| json!({"sessionId": id, "name": name, "harness": "codex", "status": "idle"});
                    let reply = match req["method"].as_str().unwrap() {
                        "_acpmux/watch" => ok(json!({"sessions": [s1]})),
                        "_acpmux/sessions" if !paced => ok(json!({"sessions": [
                            s1,
                            row("d-1", "dup"),
                            row("d-2", "dup"),
                            row("p-1", "builder/review"),
                            row("p-down", "builder/down"),
                            row("p-twin", "builder/optchat-twin"),
                        ]})),
                        "_acpmux/sessions" => err(
                            -32000,
                            "session lists are paced: try again in 35374 ms",
                            json!({"reason": "list.paced", "retryable": true, "retryAfterMs": 35374}),
                        ),
                        "_acpmux/info" => match req["params"]["sessionId"].as_str() {
                            Some("s-1" | "local/s-1" | "s-" | "optchat-compactor" | "optchat") => {
                                let mut detail = s1.clone();
                                detail["logsLoading"] = json!(false);
                                ok(detail)
                            }
                            Some("dup" | "d-") => err(
                                -32602,
                                "\"dup\" matches 2 sessions; use the id",
                                Value::Null,
                            ),
                            Some("builder/review" | "p-1") => ok(row("p-1", "review")),
                            // A peer's session with a bare name no local one has:
                            // acpmux forwards it and the peer answers as its own.
                            Some("optchat-twin" | "p-twin") => ok(row("p-twin", "optchat-twin")),
                            Some("") => err(-32602, "sessionId is required", Value::Null),
                            Some("p-down" | "builder/down") => {
                                err(-32000, "peer builder is not connected", Value::Null)
                            }
                            Some(other) => err(
                                -32002,
                                &format!("no session matches {other:?}"),
                                Value::Null,
                            ),
                            None => err(-32602, "sessionId is required", Value::Null),
                        },
                        "_acpmux/harnesses" => ok(common::catalog()),
                        _ => ok(json!({})),
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
fn a_sessions_harness_is_read_without_the_paced_list() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("acpmux.sock");
    let requests = Arc::new(Mutex::new(Vec::new()));
    serve(UnixListener::bind(&socket).unwrap(), requests.clone(), true);

    let acpmux = Acpmux::new(socket, None, Vec::new());
    let (tx, rx) = channel();
    let sink_tx = Mutex::new(tx);
    acpmux.spawn_link(
        Arc::new(move |e| {
            let _ = sink_tx.lock().unwrap().send(e);
        }),
        Arc::new(|_: &str| {}),
    );
    // The link comes up on the watch's own list.
    let up = loop {
        if let AgentEvent::Up(list) = rx.recv_timeout(common::WAIT).unwrap() {
            break list;
        }
    };
    assert_eq!(up.len(), 1);
    assert_eq!(up[0].session_id, "s-1");

    let summary = acpmux.session("s-1").unwrap().expect("s-1 exists");
    assert_eq!(summary.harness, "claude");
    assert!(acpmux.session("gone").unwrap().is_none(), "no such session");
    // A prefix acpmux resolves to another session is not that session.
    assert!(acpmux.session("s-").unwrap().is_none());

    // A leftover session found by its name, never by a longer name's prefix.
    assert_eq!(
        acpmux.find("optchat-compactor").unwrap().as_deref(),
        Some("s-1")
    );
    assert_eq!(acpmux.find("optchat").unwrap(), None);
    assert_eq!(acpmux.find("optchat-turn").unwrap(), None);
    // A peer's session of the same bare name is not this daemon's (the list
    // names it `builder/optchat-twin`): never found, so never ended, by it.
    assert_eq!(acpmux.find("optchat-twin").unwrap(), None);

    // The compactor's gate: claude-sr asked, acpmux runs it on claude.
    let admitted = harness_gate::admit(&common::catalog(), "claude-sr").unwrap();
    let actual = harness_gate::session_harness(&*acpmux, "s-1", &admitted).unwrap();
    assert_eq!(actual.profile, "claude");
    assert_eq!(actual.requested, "claude-sr");
    let gone = harness_gate::session_harness(&*acpmux, "gone", &admitted).unwrap();
    assert_eq!(gone, admitted);

    let requests = requests.lock().unwrap();
    let methods: Vec<&str> = requests
        .iter()
        .filter_map(|r| r["method"].as_str())
        .collect();
    assert!(
        !methods.contains(&"_acpmux/sessions"),
        "no paced list was asked for: {methods:?}"
    );
    let info = requests
        .iter()
        .find(|r| r["method"] == "_acpmux/info")
        .unwrap();
    assert_eq!(
        info["params"],
        json!({"sessionId": "s-1", "waitLogs": false})
    );
}

#[test]
fn the_list_answers_only_what_info_cannot() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("acpmux.sock");
    let requests = Arc::new(Mutex::new(Vec::new()));
    serve(
        UnixListener::bind(&socket).unwrap(),
        requests.clone(),
        false,
    );
    let acpmux = Acpmux::new(socket, None, Vec::new());
    acpmux.spawn_link(Arc::new(|_| {}), Arc::new(|_: &str| {}));
    let lists = || {
        requests
            .lock()
            .unwrap()
            .iter()
            .filter(|r| r["method"] == "_acpmux/sessions")
            .count()
    };
    let deadline = std::time::Instant::now() + common::WAIT;
    while acpmux.session("s-1").is_err() {
        assert!(
            std::time::Instant::now() < deadline,
            "the link never came up"
        );
        std::thread::sleep(std::time::Duration::from_millis(20));
    }

    // A peer's session: found by its listed name and by id, from info alone.
    assert_eq!(
        acpmux.find("builder/review").unwrap().as_deref(),
        Some("p-1")
    );
    assert_eq!(acpmux.session("p-1").unwrap().unwrap().name, "review");
    // A prefix of several is no session.
    assert!(acpmux.session("d-").unwrap().is_none());
    assert_eq!(lists(), 0, "info answered all of these");
    // Bad params are not "no session": the list is asked.
    assert!(acpmux.session("").unwrap().is_none());
    assert_eq!(lists(), 1);

    // A name two sessions share: the list says which.
    assert_eq!(acpmux.find("dup").unwrap().as_deref(), Some("d-1"));
    assert_eq!(lists(), 2);
    // Info fails (the peer's link is down): the list's mirrored row answers.
    let down = acpmux.session("p-down").unwrap().expect("listed");
    assert_eq!(down.name, "builder/down");
    assert_eq!(
        acpmux.find("builder/down").unwrap().as_deref(),
        Some("p-down")
    );
    assert_eq!(lists(), 4);
}
