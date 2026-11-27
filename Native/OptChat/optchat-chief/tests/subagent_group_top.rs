//! Lawrence 2026-10-28: a new workspace made inside a group goes to the TOP of that group by
//! default (`workspaces.newPlacement` `top`), as Cmd-N puts a new workspace at the top of the
//! sidebar. A Chief subagent's workspace joining the user's existing group was placed with no
//! index, so the daemon put it last in the group. `bottom` and `afterCurrent` keep that place.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::sync::{Arc, Mutex};

use optchat_chief::workspaces::place_in_personal_group_from;
use serde_json::{Value, json};

/// A session daemon that lists workspace `k1` and the user's group "Chief agents"; returns its socket
/// folder and every request it got.
fn daemon() -> (tempfile::TempDir, Arc<Mutex<Vec<Value>>>) {
    let dir = tempfile::tempdir().unwrap();
    let listener = UnixListener::bind(dir.path().join("cmux.sock")).unwrap();
    let requests = Arc::new(Mutex::new(Vec::new()));
    let seen = requests.clone();
    std::thread::spawn(move || {
        for conn in listener.incoming().flatten() {
            let seen = seen.clone();
            std::thread::spawn(move || {
                let mut out = conn.try_clone().unwrap();
                for line in BufReader::new(conn).lines() {
                    let Ok(line) = line else { return };
                    let req: Value = serde_json::from_str(&line).unwrap();
                    seen.lock().unwrap().push(req.clone());
                    let answer = if req["type"] == "request" {
                        let result = match req["operation"].as_str().unwrap_or("") {
                            "workspace_group.list" => {
                                json!([{"id": "grp_agents", "name": "Chief agents", "index": 0}])
                            }
                            _ => json!({"group_id": req["params"]["group"]}),
                        };
                        json!({"protocol": "cmux.protocol/2", "type": "response", "id": req["id"], "ok": true, "result": result})
                    } else {
                        let data = match req["cmd"].as_str().unwrap_or("") {
                            "identify" => {
                                json!({"app": "cmux", "version": "test", "protocol": 12, "capabilities": [],
                                "daemon_handoff": 1, "generation": "g", "pid": 1, "registry_id": "r",
                                "session": "main", "terminal_revision": 1, "workspace_revision": 1})
                            }
                            "list-workspaces" => json!({"workspaces": [
                                {"id": 7, "key": "k1", "resource_id": "ws_cbd7f86ef04cb1b8d1f2f7a235d6538e", "name": "a1", "active": false, "screens": []}
                            ]}),
                            _ => json!({}),
                        };
                        json!({"id": req["id"], "ok": true, "data": data})
                    };
                    let _ = writeln!(out, "{answer}");
                }
            });
        }
    });
    (dir, requests)
}

/// The `workspace.place` the Chief sent for `k1` into group "Chief agents", with settings `settings`.
fn placed(settings: Option<&str>) -> Value {
    let home = tempfile::tempdir().unwrap();
    if let Some(text) = settings {
        let config = home.path().join(".config/cmux");
        std::fs::create_dir_all(&config).unwrap();
        std::fs::write(config.join("cmux-next.json"), text).unwrap();
    }
    let (dir, requests) = daemon();
    place_in_personal_group_from(
        &dir.path().join("cmux.sock"),
        "k1",
        "Chief agents",
        home.path(),
    )
    .unwrap();
    let requests = requests.lock().unwrap();
    let place = requests
        .iter()
        .find(|r| r["operation"] == "workspace.place")
        .cloned();
    let place = place.unwrap_or_else(|| panic!("no workspace.place in {requests:?}"));
    assert_eq!(place["params"]["group"], "grp_agents");
    place
}

#[test]
fn by_default_a_subagent_workspace_goes_to_the_top_of_its_group() {
    assert_eq!(placed(None)["params"]["index"], json!(0));
}

#[test]
fn top_puts_a_subagent_workspace_first_in_its_group() {
    let place = placed(Some(r#"{"workspaces": {"newPlacement": "top"}}"#));
    assert_eq!(place["params"]["index"], json!(0));
}

#[test]
fn bottom_keeps_the_daemons_place_last_in_the_group() {
    let place = placed(Some(r#"{"workspaces": {"newPlacement": "bottom"}}"#));
    assert!(place["params"].get("index").is_none(), "{place}");
}
