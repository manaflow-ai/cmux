//! The Chief's `cloud_workspace` tool (#25596) over a real Unix socket that
//! answers `action.run` as the app's control socket does, and the tool's
//! place in the model's tool list and the CLI.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use optchat_chief::cloud_workspace::{CloudWorkspaces, Request};
use optchat_chief::tools::{Call, Command};
use serde_json::{Value, json};

/// A control socket that answers each `action.run` by its action and keeps
/// every request it read.
fn fake_app(answer: fn(&str) -> Value) -> (PathBuf, Arc<Mutex<Vec<Value>>>, tempfile::TempDir) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("control.sock");
    let listener = UnixListener::bind(&path).unwrap();
    let seen = Arc::new(Mutex::new(Vec::new()));
    let kept = seen.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let mut stream = stream.unwrap();
            let mut line = String::new();
            BufReader::new(&stream).read_line(&mut line).unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            let action = request["params"]["action"]
                .as_str()
                .unwrap_or_default()
                .to_owned();
            kept.lock().unwrap().push(request);
            let reply = json!({"ok": true, "result": {"action": action, "ran": true, "result": answer(&action)}});
            writeln!(stream, "{reply}").unwrap();
        }
    });
    (path, seen, dir)
}

fn tool(path: &std::path::Path) -> CloudWorkspaces {
    let socket = path.display().to_string();
    CloudWorkspaces::from_env(&move |key: &str| (key == "CMUX_SOCKET_PATH").then(|| socket.clone()))
        .expect("an app socket")
}

#[test]
fn a_chief_request_makes_a_machine_and_its_sidebar_workspace_through_the_app() {
    let (path, seen, _dir) = fake_app(|action| match action {
        "cloudListMachines" => {
            json!({"loaded": true, "machines": [], "account": {"signed_in": true}})
        }
        "newCloudMachine" => {
            json!({"machine_id": "vm-1", "target": "machine:vm-1", "title": "fix-login-bug", "workspace_id": "ws_9"})
        }
        _ => json!({}),
    });
    let answer = tool(&path)
        .call(&Request {
            title: "Fix login bug".into(),
            size: Some("small".into()),
            machine: None,
        })
        .unwrap();
    assert!(answer.starts_with("outcome: done."), "{answer}");
    assert!(
        answer.contains("machine:vm-1") && answer.contains("ws_9"),
        "{answer}"
    );
    let seen = seen.lock().unwrap();
    let actions: Vec<&str> = seen
        .iter()
        .map(|r| r["params"]["action"].as_str().unwrap())
        .collect();
    assert_eq!(actions, ["cloudListMachines", "newCloudMachine"]);
    let create = &seen[1]["params"];
    assert_eq!(
        create["args"],
        json!({"name": "fix-login-bug", "size": "small"})
    );
    // A script run: the app asks the person before an agent's create costs money.
    assert_eq!(create["origin"], "script");
    assert_eq!(create["wait"], true);
}

#[test]
fn another_workspace_on_a_named_machine_targets_it() {
    let (path, seen, _dir) = fake_app(|_| json!({"machine_id": "vm-2", "workspace_id": "ws_4"}));
    let answer = tool(&path)
        .call(&Request {
            title: "Review".into(),
            size: None,
            machine: Some("machine:vm-2".into()),
        })
        .unwrap();
    assert!(answer.contains("ws_4"), "{answer}");
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0]["params"]["action"], "newCloudWorkspace");
    assert_eq!(seen[0]["params"]["target"], "machine:vm-2");
    assert_eq!(
        seen[0]["params"]["idempotency_key"],
        "optchat-cloud-workspace-machine:vm-2-review-0"
    );
}

#[test]
fn without_an_app_there_is_no_tool_backend() {
    assert!(CloudWorkspaces::from_env(&|_| None).is_none());
}

#[test]
fn the_chief_lists_the_tool_and_a_subagent_does_not() {
    let names = |list: Value| -> Vec<String> {
        list.as_array()
            .unwrap()
            .iter()
            .map(|t| t["name"].as_str().unwrap().to_owned())
            .collect()
    };
    assert!(names(optchat_chief::mcp::tools_for(false)).contains(&"cloud_workspace".to_owned()));
    assert!(!names(optchat_chief::mcp::tools_for(true)).contains(&"cloud_workspace".to_owned()));
}

#[test]
fn the_call_parses_from_the_model_and_the_cli() {
    let from_model = Call::parse(
        "cloud_workspace",
        &json!({"title": " Fix login bug ", "size": "large"}),
    )
    .unwrap();
    let expected = Call::CloudWorkspace(Request {
        title: "Fix login bug".into(),
        size: Some("large".into()),
        machine: None,
    });
    assert_eq!(format!("{from_model:?}"), format!("{expected:?}"));
    assert!(Call::parse("cloud_workspace", &json!({})).is_err());
    match optchat_chief::tools::command(
        "cloud-workspace",
        &["--size", "large", "Fix", "login", "bug"],
    )
    .unwrap()
    {
        Command::Call(call) => assert_eq!(format!("{call:?}"), format!("{expected:?}")),
        _ => panic!("not a call"),
    }
}
