//! a423 (2026-10-21, Lawrence: "all workspaces must be the same. is there weird state
//! ownership stuff in that regard?"): subagent workspaces an older host made on the Chief's
//! owner daemon (`cmux-chief-<id>`) move into the user's session (the app's daemon) when the
//! host starts: the same key, the name the user saw (without the Chief-made `aN · `), the
//! same tabs (the agent chat on the SAME acpmux session, the terminal in the same directory,
//! browser pages) and the user's "Chief agents" group when it was in one (#27712: no other
//! group, and none is made). The old workspace closes
//! only once the new one holds every chat tab, so no chat is ever lost.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use optchat_chief::workspaces::adopt_owner_workspaces;
use serde_json::{Value, json};

type Log = Arc<Mutex<Vec<Value>>>;

/// A fake session daemon at `socket`: `answer` gives each request's data (None: refused).
fn serve(
    socket: PathBuf,
    answer: impl Fn(&Value, &Log) -> Option<Value> + Send + Sync + 'static,
) -> Log {
    let log: Log = Arc::default();
    let listener = UnixListener::bind(&socket).unwrap();
    let (log2, answer) = (log.clone(), Arc::new(answer));
    std::thread::spawn(move || {
        for conn in listener.incoming().flatten() {
            let (log, answer) = (log2.clone(), answer.clone());
            std::thread::spawn(move || {
                let mut out = conn.try_clone().unwrap();
                for line in BufReader::new(conn).lines() {
                    let Ok(line) = line else { return };
                    let req: Value = serde_json::from_str(&line).unwrap();
                    log.lock().unwrap().push(req.clone());
                    let data = answer(&req, &log);
                    let reply = if req["type"] == "request" {
                        match data {
                            Some(result) => {
                                json!({"protocol": "cmux.protocol/2", "type": "response", "id": req["id"], "ok": true, "result": result})
                            }
                            None => {
                                json!({"protocol": "cmux.protocol/2", "type": "response", "id": req["id"], "ok": false, "error": {"code": "refused", "message": "refused"}})
                            }
                        }
                    } else {
                        match data {
                            Some(data) => json!({"id": req["id"], "ok": true, "data": data}),
                            None => {
                                json!({"id": req["id"], "ok": false, "error": {"code": "operation_failed", "message": "refused"}})
                            }
                        }
                    };
                    let _ = writeln!(out, "{reply}");
                }
            });
        }
    });
    log
}

fn sent(log: &Log, cmd: &str) -> Vec<Value> {
    log.lock()
        .unwrap()
        .iter()
        .filter(|r| r["cmd"] == cmd || r["operation"] == cmd)
        .cloned()
        .collect()
}

/// The owner daemon's tree: one subagent workspace with a terminal and its chat, in group
/// "Chief agents", and a terminal running a command (left alone).
fn owner_tree() -> Value {
    json!({"groups": [{"id": "chief-agents", "name": "Chief agents"}], "workspaces": [
        {"id": 1, "key": "k-1", "kind": "normal", "name": "a421 · Panes performance", "group": "chief-agents",
         "resource_id": "ws_old1", "screens": [{"panes": [{"id": 5, "tabs": [
            {"kind": "pty", "cwd": "/Users/x/fun/cmux", "title": "x@mac:~/fun/cmux", "dead": false, "conversation": null},
            // A page listed before the chat still moves (it opens after the chat's pane exists).
            {"kind": "browser", "url": "https://example.com/", "browser_engine": "cef", "browser_profile_id": "default", "conversation": null},
            {"kind": "conversation", "conversation": {"agent_session": {"host": "chief:h0me", "host_name": "mac", "session": "sess-421", "harness": "claude"}}}
         ]}]}]},
        // An idle shell and no chat: nothing worth moving; it stays.
        {"id": 3, "key": "k-shell", "kind": "normal", "name": "Shell only", "group": null, "resource_id": "ws_old3",
         "screens": [{"panes": [{"id": 7, "tabs": [
            {"kind": "pty", "cwd": "/tmp", "title": "x@mac:/tmp", "dead": false, "conversation": null}
         ]}]}]},
        {"id": 2, "key": "k-busy", "kind": "normal", "name": "Busy one", "group": null, "resource_id": "ws_old2",
         "screens": [{"panes": [{"id": 6, "tabs": [
            {"kind": "pty", "cwd": "/tmp", "title": "cargo test", "dead": false, "conversation": null}
         ]}]}]}
    ]})
}

/// The app's daemon: it lists what was created, has the personal group "chief agents".
fn app_answer(chat_ok: bool) -> impl Fn(&Value, &Log) -> Option<Value> + Send + Sync + 'static {
    move |req: &Value, log: &Log| {
        let created = log
            .lock()
            .unwrap()
            .iter()
            .any(|r| r["cmd"] == "create-workspace");
        match (req["cmd"].as_str(), req["operation"].as_str()) {
            (Some("set-client-info"), _) => Some(json!({})),
            (Some("identify"), _) => Some(json!({"app": "cmux", "version": "test", "protocol": 12,
                "capabilities": ["workspace-groups-v1", "agent-session-tabs-v1"], "daemon_handoff": 1,
                "generation": "g", "pid": 1, "registry_id": "r", "session": "cmux-app",
                "terminal_revision": 1, "workspace_revision": 1})),
            (Some("list-workspaces"), _) => Some(json!({"groups": [], "workspaces": if created {
                json!([{"id": 70, "key": "k-1", "kind": "normal", "name": "Panes performance", "resource_id": "ws_new1", "screens": [{"panes": [{"id": 90, "tabs": []}]}]}])
            } else { json!([]) }})),
            (Some("create-workspace"), _) => Some(json!({"workspace": 70, "key": req["key"]})),
            (Some("create-terminal"), _) => {
                Some(json!({"pane": 90, "surface": 91, "workspace": 70}))
            }
            (Some("new-conversation-tab"), _) if chat_ok => Some(
                json!({"surface": 92, "conversation": {"agent_session": req["agent_session"]}}),
            ),
            (Some("new-conversation-tab"), _) => None,
            (Some("new-frontend-browser-tab"), _) => Some(json!({"surface": 93})),
            (Some("close-workspace"), _) => Some(json!({"closed": true})),
            (_, Some("workspace_group.list")) => {
                Some(json!([{"id": "grp_agents", "name": "chief agents", "index": 0}]))
            }
            (_, Some("workspace.place")) => {
                Some(json!({"value": {"group_id": req["params"]["group"]}}))
            }
            _ => None,
        }
    }
}

fn owner_answer() -> impl Fn(&Value, &Log) -> Option<Value> + Send + Sync + 'static {
    |req: &Value, _log: &Log| match req["cmd"].as_str() {
        Some("set-client-info") => Some(json!({})),
        Some("list-workspaces") => Some(owner_tree()),
        Some("close-workspace") => Some(json!({"closed": true})),
        _ => None,
    }
}

#[test]
fn an_owner_session_workspace_moves_into_the_users_session_with_its_chat() {
    let dir = tempfile::tempdir().unwrap();
    let (owner_sock, app_sock) = (dir.path().join("owner.sock"), dir.path().join("app.sock"));
    let owner = serve(owner_sock.clone(), owner_answer());
    let app = serve(app_sock.clone(), app_answer(true));
    let moved = adopt_owner_workspaces(&owner_sock, &app_sock).unwrap();
    assert_eq!(moved, 1, "the busy one stays: {:?}", app.lock().unwrap());

    let created = sent(&app, "create-workspace");
    assert_eq!(created.len(), 1);
    assert_eq!(
        created[0]["key"], "k-1",
        "the same key: CMUX_WORKSPACE_ID still names it"
    );
    assert_eq!(
        created[0]["name"], "Panes performance",
        "the name the user saw"
    );
    // The idle shell is not re-created (Lawrence 2026-10-21): no terminal, no
    // host, no PTY; the chat goes into the new workspace itself.
    assert!(
        sent(&app, "create-terminal").is_empty(),
        "an idle shell is never re-created: {:?}",
        sent(&app, "create-terminal")
    );
    let chat = sent(&app, "new-conversation-tab");
    assert_eq!(chat[0]["workspace"], 70);
    assert_eq!(
        chat[0]["agent_session"]["session"], "sess-421",
        "the same acpmux session"
    );
    assert_eq!(chat[0]["agent_session"]["host"], "chief:h0me");
    let page = sent(&app, "new-frontend-browser-tab");
    assert_eq!(page[0]["url"], "https://example.com/");
    let placed = sent(&app, "workspace.place");
    assert_eq!(placed[0]["params"]["workspace"], "ws_new1");
    assert_eq!(
        placed[0]["params"]["group"], "grp_agents",
        "the user's group of that name, any case"
    );
    // Conversation tabs are read in their canonical form.
    let hello = sent(&owner, "set-client-info");
    assert!(
        hello[0]["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|c| c == "agent-session-tabs-v1")
    );

    let closed = sent(&owner, "close-workspace");
    assert_eq!(closed.len(), 1);
    assert_eq!(closed[0]["key"], "k-1");
}

#[test]
fn an_old_workspace_stays_when_its_chat_could_not_move() {
    let dir = tempfile::tempdir().unwrap();
    let (owner_sock, app_sock) = (dir.path().join("owner.sock"), dir.path().join("app.sock"));
    let owner = serve(owner_sock.clone(), owner_answer());
    let app = serve(app_sock.clone(), app_answer(false));
    let moved = adopt_owner_workspaces(&owner_sock, &app_sock).unwrap();
    assert_eq!(moved, 0);
    assert!(
        sent(&owner, "close-workspace").is_empty(),
        "no chat is ever lost"
    );
    // The half-made copy goes; the next start tries again.
    let undone = sent(&app, "close-workspace");
    assert_eq!(undone.len(), 1, "{:?}", app.lock().unwrap());
    assert_eq!(undone[0]["key"], "k-1");
}
