//! `acpmux fork-run` against a fake Cloud API on loopback: the route, the credential's header,
//! the answer and the refusal each verb gives.

use std::io::{Read as _, Write as _};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};

use clap::Parser as _;
use serde_json::{Value, json};

use super::{ForkRunCmd, execute, render};
use crate::cli::command::{Cli, Command};
use crate::cli::errors::AppError;

const VM: &str = "vm_abcdefghij0123456789";

/// One request the fake saw: its request line, its headers and its body.
type Seen = (String, String, Value);

/// A loopback API answering `replies` in turn (the last one again after them).
fn fake(replies: Vec<(u16, Value)>) -> (String, Arc<Mutex<Vec<Seen>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let seen = Arc::new(Mutex::new(Vec::new()));
    let log = Arc::clone(&seen);
    std::thread::spawn(move || {
        for (n, stream) in listener.incoming().enumerate() {
            let Ok(mut stream) = stream else { continue };
            let mut buffer = Vec::new();
            let mut chunk = [0_u8; 16384];
            let (head, body) = loop {
                let Ok(read) = stream.read(&mut chunk) else { break (String::new(), Vec::new()) };
                buffer.extend_from_slice(&chunk[..read]);
                let Some(end) = buffer.windows(4).position(|w| w == b"\r\n\r\n") else {
                    if read == 0 {
                        break (String::new(), Vec::new());
                    }
                    continue;
                };
                let head = String::from_utf8_lossy(&buffer[..end]).into_owned();
                let length = head
                    .lines()
                    .find_map(|l| {
                        l.to_ascii_lowercase().strip_prefix("content-length:").map(str::to_owned)
                    })
                    .and_then(|v| v.trim().parse::<usize>().ok())
                    .unwrap_or(0);
                if buffer.len() >= end + 4 + length || read == 0 {
                    break (head, buffer[end + 4..].to_vec());
                }
            };
            let (line, headers) = head.split_once("\r\n").unwrap_or((&head, ""));
            let body = serde_json::from_slice(&body).unwrap_or(Value::Null);
            log.lock().unwrap().push((line.to_owned(), headers.to_ascii_lowercase(), body));
            let (status, reply) = replies[n.min(replies.len() - 1)].clone();
            let reply = reply.to_string();
            let _ = write!(
                stream,
                "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{reply}",
                reply.len()
            );
        }
    });
    (origin, seen)
}

fn run_json(state: &str) -> Value {
    json!({
        "id": "fr_1", "workspace": "ws_1", "sourceMachine": VM, "clientKey": "k1", "state": state,
        "children": [
            {"id": "c_claude", "harness": "claude", "state": "ready", "machineId": "vm_child1"},
            {"id": "c_codex", "harness": "codex", "state": "pending"},
        ],
        "version": 3, "createdAt": 1, "updatedAt": 2,
    })
}

fn parse(args: &[&str]) -> ForkRunCmd {
    match Cli::try_parse_from(args).unwrap().command {
        Some(Command::ForkRun(cmd)) => cmd,
        _ => panic!("not fork-run"),
    }
}

/// The command against `origin`, with the token and team from a fake environment.
fn go(origin: &str, args: &[&str]) -> Result<Value, AppError> {
    let mut argv = vec!["acpmux", "fork-run"];
    argv.extend_from_slice(args);
    let cmd = parse(&argv);
    let origin = origin.to_owned();
    let env = move |name: &str| match name {
        "CMUX_CLOUD_API_URL" => Some(origin.clone()),
        "CMUX_CLOUD_ACCESS_TOKEN" => Some("tok-secret".to_owned()),
        "CMUX_CLOUD_TEAM" => Some("team-1".to_owned()),
        _ => None,
    };
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    runtime.block_on(execute(cmd, &env)).map_err(|e| e.downcast::<AppError>().expect("an AppError"))
}

#[test]
fn start_posts_one_fork_per_harness_and_answers_the_run() {
    let (origin, seen) = fake(vec![(201, run_json("restoring"))]);
    let answer = go(
        &origin,
        &[
            "start",
            "--workspace",
            "ws_1",
            "--machine",
            VM,
            "--harness",
            "claude,codex",
            "--session",
            "s1",
            "--key",
            "k1",
        ],
    )
    .unwrap();
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].0, "POST /v1/workspaces/ws_1/fork-runs HTTP/1.1");
    assert!(seen[0].1.contains("authorization: bearer tok-secret"));
    assert!(seen[0].1.contains("x-cmux-team: team-1"));
    assert_eq!(
        seen[0].2,
        json!({"clientKey": "k1", "sourceMachine": VM, "harnesses": ["claude", "codex"], "session": "s1"})
    );
    assert_eq!(answer["id"], "fr_1");
    assert_eq!(answer["state"], "restoring");
    assert_eq!(answer["clientKey"], "k1");
    assert_eq!(answer["children"][0]["machineId"], "vm_child1");
    let text = render(&answer);
    assert!(text.starts_with("fork run fr_1: restoring\n  key k1"), "{text}");
    assert!(text.contains("  c_claude  claude  ready  vm_child1\n"), "{text}");
    assert!(text.contains("  c_codex  codex  pending  -\n"), "{text}");
}

#[test]
fn start_without_a_key_sends_a_fresh_one() {
    let (origin, seen) = fake(vec![(201, run_json("admitting"))]);
    let answer =
        go(&origin, &["start", "--workspace", "ws_1", "--machine", VM, "--harness", "pi"]).unwrap();
    let key = seen.lock().unwrap()[0].2["clientKey"].as_str().unwrap().to_owned();
    assert!(key.starts_with("acpmux-fork-"), "{key}");
    assert_eq!(answer["clientKey"], key);
}

#[test]
fn status_waits_until_the_run_is_ready() {
    let (origin, seen) = fake(vec![(200, run_json("restoring")), (200, run_json("ready"))]);
    let answer = go(&origin, &["status", "fr_1", "--workspace", "ws_1", "--wait", "10"]).unwrap();
    assert_eq!(answer["state"], "ready");
    let seen = seen.lock().unwrap();
    assert_eq!(seen.len(), 2);
    assert_eq!(seen[1].0, "GET /v1/workspaces/ws_1/fork-runs/fr_1 HTTP/1.1");
}

#[test]
fn status_past_its_wait_is_a_timeout_carrying_the_run() {
    let (origin, _) = fake(vec![(200, run_json("restoring"))]);
    let error = go(&origin, &["status", "fr_1", "--workspace", "ws_1", "--wait", "1"]).unwrap_err();
    assert_eq!(error.code.name(), "timeout");
    assert_eq!(error.data.unwrap()["state"], "restoring");
}

#[test]
fn select_posts_the_child_and_answers_the_kept_one() {
    let mut kept = run_json("ready");
    kept["selectedChild"] = json!("c_claude");
    let (origin, seen) = fake(vec![(200, kept)]);
    let answer = go(&origin, &["select", "fr_1", "c_claude", "--workspace", "ws_1"]).unwrap();
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].0, "POST /v1/workspaces/ws_1/fork-runs/fr_1/select HTTP/1.1");
    assert_eq!(seen[0].2, json!({"childId": "c_claude"}));
    assert_eq!(answer["selectedChild"], "c_claude");
    assert!(render(&answer).starts_with("fork run fr_1: ready (kept c_claude)\n"));
}

#[test]
fn a_refusal_names_the_platforms_code_and_never_the_token() {
    let body = json!({"_tag": "ForkRunSelectionConflict", "code": "fork_run.selection_conflict",
        "message": "another child is selected"});
    let (origin, _) = fake(vec![(409, body)]);
    let error = go(&origin, &["select", "fr_1", "c_codex", "--workspace", "ws_1"]).unwrap_err();
    assert_eq!(error.code.name(), "runtime");
    assert_eq!(error.detail, "fork_run.selection_conflict");
    assert!(error.message.contains("already kept another fork"), "{}", error.message);
    assert_eq!(error.data.as_ref().unwrap()["status"], 409);
    assert!(!format!("{error:?}").contains("tok-secret"));
}

#[test]
fn no_credential_is_a_usage_error_that_sends_nothing() {
    let cmd = parse(&["acpmux", "fork-run", "status", "fr_1", "--workspace", "ws_1"]);
    let env = |name: &str| (name == "CMUX_CLOUD_API_URL").then(|| "https://api.example".to_owned());
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let error = runtime.block_on(execute(cmd, &env)).unwrap_err().downcast::<AppError>().unwrap();
    assert_eq!(error.code.name(), "usage");
    assert!(error.message.contains("CMUX_CLOUD_ACCESS_TOKEN"), "{}", error.message);
}

#[test]
fn start_needs_a_machine_and_a_harness() {
    for args in [
        &["acpmux", "fork-run", "start", "--workspace", "ws_1", "--harness", "claude"][..],
        &["acpmux", "fork-run", "start", "--workspace", "ws_1", "--machine", VM][..],
    ] {
        assert!(Cli::try_parse_from(args).is_err(), "{args:?}");
    }
}

#[test]
fn a_failed_start_names_its_key_for_the_retry() {
    let (origin, _) = fake(vec![(503, json!({"code": "fork_run.provider_unavailable"}))]);
    let error = go(
        &origin,
        &["start", "--workspace", "ws_1", "--machine", VM, "--harness", "claude", "--key", "k9"],
    )
    .unwrap_err();
    assert_eq!(error.detail, "fork_run.provider_unavailable");
    assert!(error.message.contains("--key k9"), "{}", error.message);
    assert_eq!(error.data.unwrap()["clientKey"], "k9");
}

#[test]
fn a_refusal_echoing_the_token_is_redacted() {
    let (origin, _) =
        fake(vec![(400, json!({"code": "fork_run.invalid", "message": "bad tok-secret"}))]);
    let error = go(&origin, &["status", "fr_1", "--workspace", "ws_1"]).unwrap_err();
    assert!(!format!("{error:?}").contains("tok-secret"), "{error:?}");
}

#[test]
fn a_short_wait_still_reads_again_at_its_deadline() {
    let (origin, seen) = fake(vec![(200, run_json("restoring")), (200, run_json("ready"))]);
    let answer = go(&origin, &["status", "fr_1", "--workspace", "ws_1", "--wait", "1"]).unwrap();
    assert_eq!(answer["state"], "ready");
    assert_eq!(seen.lock().unwrap().len(), 2);
}
