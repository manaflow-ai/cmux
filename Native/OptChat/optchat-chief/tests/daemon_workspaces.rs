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

/// Marks a fake that is the app's own daemon (the user's session), with personal groups.
const PERSONAL: &str = "test-personal-session";

/// Marks a fake whose subagent workspace has a terminal running a command.
const BUSY: &str = "test-busy-terminal";

fn serve(
    listener: UnixListener,
    capabilities: Vec<&'static str>,
    refused: Vec<&'static str>,
    requests: Arc<Mutex<Vec<Value>>>,
) {
    let created_key = Arc::new(Mutex::new(Value::Null));
    std::thread::spawn(move || {
        for conn in listener.incoming().flatten() {
            let (requests, capabilities) = (requests.clone(), capabilities.clone());
            let refused = refused.clone();
            let created_key = created_key.clone();
            std::thread::spawn(move || {
                let mut out = conn.try_clone().unwrap();
                for line in BufReader::new(conn.try_clone().unwrap()).lines() {
                    let Ok(line) = line else { return };
                    let req: Value = serde_json::from_str(&line).unwrap();
                    requests.lock().unwrap().push(req.clone());
                    // cmux.protocol/2 resource ops: the personal groups and placements of the
                    // app's session (what `cmux workspace group <g> add` sends).
                    if req["type"] == "request" {
                        let personal = capabilities.contains(&PERSONAL);
                        let result = match req["operation"].as_str().unwrap() {
                            _ if !personal => None,
                            "workspace_group.list" => Some(json!([
                                {"id": "grp_user_sidebar", "name": "Sidebar & Tabs", "index": 0, "room_id": "default"}
                            ])),
                            "workspace_group.create" => {
                                // A mutation answers the group as its `value`.
                                Some(
                                    json!({"generation": "g", "replayed": false, "revision": "1",
                                    "value": {"id": "grp_new", "name": req["params"]["name"], "index": 1}}),
                                )
                            }
                            "workspace.place" => Some(json!({"group_id": req["params"]["group"]})),
                            _ => None,
                        };
                        let answer = match result {
                            Some(result) => {
                                json!({"protocol": "cmux.protocol/2", "type": "response", "id": req["id"], "ok": true, "result": result})
                            }
                            None => {
                                json!({"protocol": "cmux.protocol/2", "type": "response", "id": req["id"], "ok": false,
                                "error": {"code": "operation.unsupported", "message": "unsupported", "retryable": false}})
                            }
                        };
                        let _ = writeln!(out, "{answer}");
                        continue;
                    }
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
                    if refused.contains(&req["cmd"].as_str().unwrap()) {
                        let _ = writeln!(
                            out,
                            "{}",
                            json!({"id": req["id"], "ok": false, "error": {"code": "operation_failed", "message": "refused"}})
                        );
                        continue;
                    }
                    if req["cmd"] == "create-workspace" {
                        *created_key.lock().unwrap() = req["key"].clone();
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
                        // The real tree (tree_json.rs) carries each workspace's key and public id.
                        "list-workspaces" => {
                            // BUSY: the subagent's terminal runs a command (its title is the
                            // command, not `user@host:dir`).
                            let title = if capabilities.contains(&BUSY) {
                                "cargo test"
                            } else {
                                "x@mac:~/fun"
                            };
                            json!({"workspaces": [
                                {"id": 6, "key": "other", "resource_id": "ws_00000000000000000000000000000006", "name": "Home", "active": true, "screens": []},
                                {"id": 7, "key": created_key.lock().unwrap().clone(), "resource_id": "ws_cbd7f86ef04cb1b8d1f2f7a235d6538e", "name": "a1 · summarize", "active": false,
                                 "screens": [{"panes": [{"tabs": [{"kind": "pty", "dead": false, "title": title}]}]}]}
                            ]})
                        }
                        // The user's own group by a topic name is reused.
                        "list-workspace-groups" => json!({"groups": [
                            {"id": "grp_user_sidebar", "name": "Sidebar & Tabs", "collapsed": false}
                        ]}),
                        "close-workspace" => json!({
                            "generation": "g", "index": 3, "key": req["key"], "registry_id": "r",
                            "replayed": false, "workspace": 7, "workspace_revision": 2
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
    workspaces_refusing(caps, vec![])
}

fn workspaces_refusing(
    caps: Vec<&'static str>,
    refused: Vec<&'static str>,
) -> (DaemonWorkspaces, Arc<Mutex<Vec<Value>>>, tempfile::TempDir) {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("cmux.sock");
    let requests = Arc::new(Mutex::new(Vec::new()));
    let capabilities_personal = caps.contains(&PERSONAL);
    serve(
        UnixListener::bind(&socket).unwrap(),
        caps,
        refused,
        requests.clone(),
    );
    let w = DaemonWorkspaces {
        daemon: socket,
        host: "install:inst_test".into(),
        host_name: "cmux-lawrence".into(),
        harness: Some("claude-sr".into()),
        personal: capabilities_personal,
        fallback: None,
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
            "Chief agents",
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
            "Chief agents",
            Path::new("/tmp"),
        )
        .unwrap_err();
    assert!(err.contains("agent-session-tabs-v1"), "{err}");
    assert!(
        commands(&requests, "create-workspace").is_empty(),
        "nothing half made"
    );
}

const GROUPED: [&str; 4] = [
    "workspace-registry-v1",
    "conversation-tabs-v1",
    "agent-session-tabs-v1",
    "workspace-groups-v1",
];

fn open(w: &DaemonWorkspaces) -> Result<String, String> {
    w.open(
        &optchat_chief::workspaces::new_key(),
        "sess-1",
        "a1 · x",
        "Chief agents",
        Path::new("/tmp"),
    )
}

/// Lawrence 2026-10-18: "use groups more aggressively so that you can
/// organize and the user feels less overwhelmed".
#[test]
fn a_subagent_workspace_goes_into_the_chief_agents_group() {
    let (w, requests, _dir) = workspaces(GROUPED.to_vec());
    let key = open(&w).unwrap();
    let group = commands(&requests, "create-workspace-group");
    assert_eq!(group.len(), 1);
    assert_eq!(
        group[0]["group"], "chief-agents",
        "a fixed id: one group for every spawn"
    );
    assert_eq!(group[0]["name"], "Chief agents");
    let moved = commands(&requests, "move-workspace-to-group");
    assert_eq!(moved.len(), 1);
    assert_eq!(moved[0]["workspace"], 7);
    assert_eq!(moved[0]["group"], "chief-agents");
    assert_eq!(
        moved[0]["mutation_id"],
        format!("optchat-subagent-group-{key}")
    );
    assert_eq!(commands(&requests, "new-conversation-tab").len(), 1);
}

#[test]
fn a_daemon_without_groups_gets_no_group_requests() {
    let (w, requests, _dir) = workspaces(GROUPED[..3].to_vec());
    open(&w).unwrap();
    assert!(commands(&requests, "create-workspace-group").is_empty());
    assert!(commands(&requests, "move-workspace-to-group").is_empty());
}

#[test]
fn a_refused_group_never_stops_the_subagent_start() {
    let (w, requests, _dir) = workspaces_refusing(
        GROUPED.to_vec(),
        vec!["create-workspace-group", "move-workspace-to-group"],
    );
    open(&w).unwrap();
    assert_eq!(commands(&requests, "create-terminal").len(), 1);
    assert_eq!(commands(&requests, "new-conversation-tab").len(), 1);
}

fn open_in(w: &DaemonWorkspaces, group: &str) -> Result<String, String> {
    w.open(
        &optchat_chief::workspaces::new_key(),
        "sess-1",
        "a1 · Sidebar group drag",
        group,
        Path::new("/tmp"),
    )
}

/// Lawrence 2026-10-19: "you need to group it better as well": a topic the
/// session has no group for gets one, with a stable id per topic.
#[test]
fn a_subagent_workspace_goes_into_a_new_topic_group() {
    let (w, requests, _dir) = workspaces(GROUPED.to_vec());
    open_in(&w, "Home & chat").unwrap();
    let group = commands(&requests, "create-workspace-group");
    assert_eq!(group.len(), 1);
    assert_eq!(group[0]["group"], "chief-topic-home-chat");
    assert_eq!(group[0]["name"], "Home & chat");
    let moved = commands(&requests, "move-workspace-to-group");
    assert_eq!(moved[0]["group"], "chief-topic-home-chat");
    assert_eq!(moved[0]["workspace"], 7);
}

/// The user's own group of that topic (any case) is reused, never doubled.
#[test]
fn a_topic_group_the_session_has_is_reused() {
    let (w, requests, _dir) = workspaces(GROUPED.to_vec());
    open_in(&w, "Sidebar & tabs").unwrap();
    assert!(commands(&requests, "create-workspace-group").is_empty());
    let moved = commands(&requests, "move-workspace-to-group");
    assert_eq!(moved.len(), 1);
    assert_eq!(moved[0]["group"], "grp_user_sidebar");
}

/// a313 (2026-10-20): the user asked to pin a306's workspace at the top, and
/// nothing could find it: the spawn reply named only a UUID key, and an agent's
/// `cmux` talks to the app's daemon, not the Chief's owner daemon that holds
/// the subagent workspaces. The host names each one by its public id and session.
#[test]
fn a_subagent_workspace_is_located_by_its_public_id_and_session() {
    let (w, _requests, _dir) = workspaces(GROUPED.to_vec());
    let key = w
        .open(
            &optchat_chief::workspaces::new_key(),
            "sess-1",
            "a1 · summarize",
            "Chief agents",
            Path::new("/tmp"),
        )
        .unwrap();
    let found = w.locate(&key).expect("the daemon names the workspace");
    assert_eq!(found.id, "ws_cbd7f86ef04cb1b8d1f2f7a235d6538e");
    assert_eq!(found.session, "main");
    assert_eq!(
        found.move_to_top(),
        "cmux workspace ws_cbd7f86ef04cb1b8d1f2f7a235d6538e move --index 0"
    );
    assert!(w.locate("no-such-key").is_none());
}

/// a423 (2026-10-21, Lawrence: "do the workspaces u spin up, are they different in any way
/// from workspaces i spin up? they should not be"): a Chief the app started makes each
/// subagent workspace on the app's daemon, the session that holds the user's own workspaces,
/// never on the Chief's owner daemon (`cmux-chief-<id>`), which the app showed apart under a
/// "Chief" header. Without the app there is no user session here: None.
#[test]
fn an_app_started_chief_makes_subagent_workspaces_in_the_users_session() {
    use optchat_chief::workspaces::subagent_daemon;
    use std::path::PathBuf;
    let owner = "/x/cmux-chief-h0me.sock";
    let app = |k: &str| match k {
        "CMUX_SOCKET_PATH" => Some("/x/app.sock".to_owned()),
        "CMUX_APP_DAEMON_SOCKET" => Some("/x/state/app-daemon.sock".to_owned()),
        _ => None,
    };
    assert_eq!(
        subagent_daemon(owner, &app),
        Some(PathBuf::from("/x/state/app-daemon.sock"))
    );
    let no_app = |_: &str| None;
    assert_eq!(subagent_daemon(owner, &no_app), None);
}

/// a423: in the user's session (the app's daemon) a subagent workspace joins a sidebar group
/// the way a workspace the user groups does (`cmux workspace group <g> add`): the session's
/// personal group by that name (any case) through `workspace.place`, never the daemon's older
/// shared groups (`move-workspace-to-group`), which the app does not show for that session.
#[test]
fn in_the_users_session_a_subagent_workspace_joins_a_personal_group() {
    let mut caps = GROUPED.to_vec();
    caps.push(PERSONAL);
    let (w, requests, _dir) = workspaces(caps);
    open_in(&w, "Sidebar & tabs").unwrap();
    let ops = |op: &str| -> Vec<Value> {
        requests
            .lock()
            .unwrap()
            .iter()
            .filter(|r| r["operation"] == op)
            .cloned()
            .collect()
    };
    assert!(
        ops("workspace_group.create").is_empty(),
        "the user's group is reused"
    );
    let placed = ops("workspace.place");
    assert_eq!(placed.len(), 1, "{:?}", requests.lock().unwrap());
    assert_eq!(placed[0]["params"]["group"], "grp_user_sidebar");
    assert_eq!(
        placed[0]["params"]["workspace"],
        "ws_cbd7f86ef04cb1b8d1f2f7a235d6538e"
    );
    assert!(placed[0]["idempotency_key"].is_string());
    assert!(commands(&requests, "move-workspace-to-group").is_empty());
    assert!(commands(&requests, "create-workspace-group").is_empty());

    // A topic the session has no group for gets a new personal group.
    let mut caps = GROUPED.to_vec();
    caps.push(PERSONAL);
    let (w, requests, _dir) = workspaces(caps);
    open_in(&w, "Performance").unwrap();
    let created: Vec<Value> = requests
        .lock()
        .unwrap()
        .iter()
        .filter(|r| r["operation"] == "workspace_group.create")
        .cloned()
        .collect();
    assert_eq!(created.len(), 1);
    assert_eq!(created[0]["params"]["name"], "Performance");
    let placed: Vec<Value> = requests
        .lock()
        .unwrap()
        .iter()
        .filter(|r| r["operation"] == "workspace.place")
        .cloned()
        .collect();
    assert_eq!(placed[0]["params"]["group"], "grp_new");
}

/// a622-a627 (Oct 23) and 25 more: create-workspace succeeded, create-terminal
/// failed ("failed to spawn PTY command ... os error 2"), and the workspace stayed:
/// an empty sidebar row with no chat, never cleaned up. A failed open closes the
/// workspace it made.
#[test]
fn a_workspace_whose_terminal_fails_is_closed_not_left_empty() {
    let (w, requests, _dir) = workspaces_refusing(GROUPED.to_vec(), vec!["create-terminal"]);
    let key = optchat_chief::workspaces::new_key();
    let err = w
        .open(&key, "sess-1", "a1 · x", "Chief agents", Path::new("/tmp"))
        .unwrap_err();
    assert!(err.contains("create-terminal"), "{err}");
    let closed = commands(&requests, "close-workspace");
    assert_eq!(
        closed.len(),
        1,
        "the half-made workspace is closed: {closed:?}"
    );
    assert_eq!(closed[0]["key"], key.as_str());
}

#[test]
fn with_no_app_behind_its_link_a_subagent_workspace_goes_to_the_hosts_own_daemon() {
    // A scratch Chief the `cmux chief` CLI started (Oct 25): the host gets the app links
    // (`state/app-daemon.sock`), but no cmux app opened this home, so the link dangles. Every
    // spawn answered "the session daemon: cannot connect to cmux session"; the workspace must
    // go to the host's own session daemon instead.
    let (owner, requests, dir) = workspaces(vec![
        "workspace-registry-v1",
        "conversation-tabs-v1",
        "agent-session-tabs-v1",
    ]);
    std::fs::create_dir_all(dir.path().join("state")).unwrap();
    let link = dir.path().join("state/app-daemon.sock");
    std::os::unix::fs::symlink(dir.path().join("gone/daemon.sock"), &link).unwrap();
    let w = DaemonWorkspaces {
        daemon: link,
        host: "chief:0123abcd".into(),
        host_name: "cmux-lawrence".into(),
        harness: Some("claude".into()),
        personal: true,
        fallback: Some(owner.daemon.clone()),
    };
    let key = open(&w).expect("the workspace is made on the host's own daemon");
    let created = commands(&requests, "create-workspace");
    assert_eq!(created.len(), 1, "made on the owner daemon");
    assert_eq!(created[0]["key"], key.as_str());
    assert_eq!(commands(&requests, "new-conversation-tab").len(), 1);
    let place = w.place();
    assert!(
        !place.contains("beside your own workspaces"),
        "the answer must not claim the user's session: {place}"
    );
}

/// A short task's workspace closes when its subagent finishes, but never one
/// whose terminal still runs a command (the person may have started it there).
#[test]
fn an_idle_close_closes_a_workspace_with_idle_terminals_only() {
    let (w, requests, _dir) = workspaces(GROUPED.to_vec());
    let key = open(&w).unwrap();
    assert_eq!(w.close_idle(&key), Ok(true));
    assert_eq!(commands(&requests, "close-workspace").len(), 1);

    let mut caps = GROUPED.to_vec();
    caps.push(BUSY);
    let (w, requests, _dir) = workspaces(caps);
    let key = open(&w).unwrap();
    assert_eq!(w.close_idle(&key), Ok(false), "a busy terminal keeps it");
    assert!(commands(&requests, "close-workspace").is_empty());
}
