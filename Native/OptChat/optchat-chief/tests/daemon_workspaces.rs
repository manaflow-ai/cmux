//! A Chief host without a cmux app (the always-on brain on a server, 2026-10-06
//! bug) makes each subagent's workspace in its OWN session daemon: the
//! subagent runs on this machine, so its workspace belongs to this machine's
//! session (data-model.md 1.2), and every cmux app connected to that session
//! shows it, even while the user's laptop sleeps. One workspace per
//! subagent, named by the caller's key, with a terminal in the subagent's
//! directory and the agent chat tab on the SAME acpmux session, owned by this
//! install. A daemon without agent session tabs is refused, never half done.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::Path;
use std::sync::{Arc, Mutex};

use optchat_chief::workspaces::{DaemonWorkspaces, Workspaces};
use serde_json::{Value, json};

fn serve(
    listener: UnixListener,
    capabilities: Vec<&'static str>,
    requests: Arc<Mutex<Vec<Value>>>,
) {
    std::thread::spawn(move || {
        for conn in listener.incoming().flatten() {
            let (requests, capabilities) = (requests.clone(), capabilities.clone());
            std::thread::spawn(move || {
                let mut out = conn.try_clone().unwrap();
                for line in BufReader::new(conn.try_clone().unwrap()).lines() {
                    let Ok(line) = line else { return };
                    let req: Value = serde_json::from_str(&line).unwrap();
                    requests.lock().unwrap().push(req.clone());
                    // The real daemon (server.rs workspace_mutation) refuses a mutation_id
                    // without its origin, and an origin without its mutation_id.
                    if req.get("mutation_id").is_some() != req.get("origin").is_some() {
                        let _ = writeln!(
                            out,
                            "{}",
                            json!({"id": req["id"], "ok": false,
                            "error": "origin and mutation_id must be provided together"})
                        );
                        continue;
                    }
                    // The real daemon (server.rs workspace_mutation) refuses
                    // one of origin and mutation_id without the other.
                    if req.get("origin").is_some() != req.get("mutation_id").is_some() {
                        let _ = writeln!(
                            out,
                            "{}",
                            json!({"id": req["id"], "ok": false, "error": {"code": "invalid_params", "message": "origin and mutation_id must be provided together"}})
                        );
                        continue;
                    }
                    let data = match req["cmd"].as_str().unwrap() {
                        "identify" => {
                            json!({"app": "cmux", "version": "test", "protocol": 12, "capabilities": capabilities,
                                "daemon_handoff": 1, "generation": "g", "pid": 1, "registry_id": "r",
                                "session": "main", "terminal_revision": 1, "workspace_revision": 1})
                        }
                        "create-workspace" => json!({
                            "generation": "g", "index": 3, "key": req["key"], "registry_id": "r",
                            "replayed": false, "workspace": 7, "workspace_revision": 1
                        }),
                        "create-terminal" => json!({
                            "already_exited": false, "exit": null, "generation": "g", "key": "t",
                            "lifecycle": "running", "pane": 9, "registry_id": "r", "replayed": false,
                            "screen": 8, "surface": 10, "terminal_id": "term_1",
                            "terminal_incarnation": null, "terminal_revision": 1, "workspace": 7
                        }),
                        "new-conversation-tab" => json!({
                            "content_resource_id": null, "conversation": {"agent_session": req["agent_session"]},
                            "replayed": false, "surface": 11, "tab_resource_id": null
                        }),
                        _ => json!({}),
                    };
                    let _ = writeln!(
                        out,
                        "{}",
                        json!({"id": req["id"], "ok": true, "data": data})
                    );
                }
            });
        }
    });
}

fn workspaces(
    caps: Vec<&'static str>,
) -> (DaemonWorkspaces, Arc<Mutex<Vec<Value>>>, tempfile::TempDir) {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("cmux.sock");
    let requests = Arc::new(Mutex::new(Vec::new()));
    serve(UnixListener::bind(&socket).unwrap(), caps, requests.clone());
    let w = DaemonWorkspaces {
        daemon: socket,
        host: "install:inst_test".into(),
        host_name: "cmux-lawrence".into(),
        harness: Some("claude-sr".into()),
    };
    (w, requests, dir)
}

fn commands(requests: &Mutex<Vec<Value>>, cmd: &str) -> Vec<Value> {
    requests
        .lock()
        .unwrap()
        .iter()
        .filter(|r| r["cmd"] == cmd)
        .cloned()
        .collect()
}

#[test]
fn a_subagent_workspace_is_made_in_the_hosts_own_session() {
    let (w, requests, _dir) = workspaces(vec![
        "workspace-registry-v1",
        "conversation-tabs-v1",
        "agent-session-tabs-v1",
    ]);
    let key = w
        .open(
            &optchat_chief::workspaces::new_key(),
            "sess-1",
            "a1 · summarize",
            Path::new("/Users/x/fun/repo"),
        )
        .unwrap();
    let created = commands(&requests, "create-workspace");
    assert_eq!(created.len(), 1);
    assert_eq!(
        created[0]["key"],
        key.as_str(),
        "the caller's key names the workspace"
    );
    assert_eq!(created[0]["name"], "a1 · summarize");
    let terminal = commands(&requests, "create-terminal");
    assert_eq!(terminal[0]["workspace"], 7);
    assert_eq!(terminal[0]["cwd"], "/Users/x/fun/repo");
    let tab = commands(&requests, "new-conversation-tab");
    assert_eq!(tab[0]["pane"], 9);
    assert_eq!(
        tab[0]["agent_session"],
        json!({"host": "install:inst_test", "host_name": "cmux-lawrence", "session": "sess-1", "harness": "claude-sr"})
    );
    let place = w.place();
    assert!(place.contains("cmux-lawrence"), "{place}");
}

#[test]
fn a_daemon_without_agent_session_tabs_is_refused_before_any_write() {
    let (w, requests, _dir) = workspaces(vec!["workspace-registry-v1", "conversation-tabs-v1"]);
    let err = w
        .open(
            &optchat_chief::workspaces::new_key(),
            "sess-1",
            "a1 · x",
            Path::new("/tmp"),
        )
        .unwrap_err();
    assert!(err.contains("agent-session-tabs-v1"), "{err}");
    assert!(
        commands(&requests, "create-workspace").is_empty(),
        "nothing half made"
    );
}
