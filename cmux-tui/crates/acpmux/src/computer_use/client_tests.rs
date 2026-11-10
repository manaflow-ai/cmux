//! The worker client against a fake worker on a real Unix socket: restarts
//! mid-call, retries that reuse the call id, refusals passed through, and an
//! MCP server that lists its tools with no worker at all.
#![cfg(unix)]

use std::collections::{HashMap, HashSet};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};

use super::*;

/// What the fake worker does with a call.
#[derive(Clone, Copy, PartialEq)]
enum Behavior {
    /// Answer `{body: {ran: name}}`.
    Answer,
    /// Read the call, then drop the connection without answering, once per
    /// call id (a worker that crashed mid-call).
    CrashOnce,
    /// Answer an `app_denied` refusal.
    Refuse,
    /// Answer as the engine does once the person stopped the session.
    Stopped,
}

/// A worker: one socket, one secret, answering per [`Behavior`], and
/// deduplicating by `call_id` like the real one.
struct FakeWorker {
    socket: PathBuf,
    secret: String,
    /// Each tools/call line it read, in order.
    seen: Arc<Mutex<Vec<Value>>>,
    /// Calls it ran (a call id runs once).
    ran: Arc<AtomicUsize>,
}

impl FakeWorker {
    fn start(
        dir: &std::path::Path,
        name: &str,
        behavior: Behavior,
        done: Arc<Mutex<HashMap<String, Value>>>,
    ) -> Self {
        let socket = dir.join(name);
        let _ = std::fs::remove_file(&socket);
        let listener = UnixListener::bind(&socket).unwrap();
        let secret = format!("secret-{name}");
        let seen = Arc::new(Mutex::new(Vec::new()));
        let ran = Arc::new(AtomicUsize::new(0));
        let (s, seen2, ran2) = (secret.clone(), seen.clone(), ran.clone());
        std::thread::spawn(move || {
            let crashed: Mutex<HashSet<String>> = Mutex::new(HashSet::new());
            for stream in listener.incoming() {
                let Ok(stream) = stream else { break };
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut out = stream;
                let mut line = String::new();
                if reader.read_line(&mut line).unwrap_or(0) == 0 {
                    continue;
                }
                let hello: Value = serde_json::from_str(&line).unwrap_or(Value::Null);
                if hello["secret"] != json!(s) {
                    let _ = writeln!(
                        out,
                        "{}",
                        json!({"ok": false, "error": "refused", "reason": "secret"})
                    );
                    continue;
                }
                let _ = writeln!(
                    out,
                    "{}",
                    json!({"ok": true, "protocol": 1, "capabilities": ["cmux-computer-use-v1"]})
                );
                let mut line = String::new();
                if reader.read_line(&mut line).unwrap_or(0) == 0 {
                    continue;
                }
                let request: Value = serde_json::from_str(&line).unwrap();
                seen2.lock().unwrap().push(request.clone());
                if request["method"] != "tools/call" {
                    let _ =
                        writeln!(out, "{}", json!({"id": request["id"], "ok": true, "result": {}}));
                    continue;
                }
                let call_id = request["call_id"].as_str().unwrap_or_default().to_owned();
                if behavior == Behavior::CrashOnce
                    && crashed.lock().unwrap().insert(call_id.clone())
                {
                    // The call ran, then the worker died before it answered.
                    ran2.fetch_add(1, Ordering::SeqCst);
                    let result = json!({"is_error": false, "code": null, "body": {"ran": request["name"]}, "png": null});
                    done.lock().unwrap().insert(call_id, result);
                    drop(out);
                    continue;
                }
                let result = if let Some(result) = done.lock().unwrap().get(&call_id).cloned() {
                    result // a retry of a call that already ran: its result, not a second run
                } else if behavior == Behavior::Stopped {
                    cmux_computer_use::stop::stopped().to_json()
                } else if behavior == Behavior::Refuse {
                    json!({"is_error": true, "code": "app_denied", "body": {"error": "Keychain Access is denied", "code": "app_denied"}, "png": null})
                } else {
                    ran2.fetch_add(1, Ordering::SeqCst);
                    json!({"is_error": false, "code": null, "body": {"ran": request["name"]}, "png": null})
                };
                done.lock().unwrap().insert(call_id, result.clone());
                let _ =
                    writeln!(out, "{}", json!({"id": request["id"], "ok": true, "result": result}));
            }
        });
        Self { socket, secret, seen, ran }
    }

    fn ready(&self) -> Value {
        json!({"state": "ready", "socket": self.socket, "secret": self.secret, "pid": 1})
    }
}

/// The daemon: answers the endpoint from `answers` in turn (the last one
/// repeats), counting asks.
#[derive(Clone)]
struct FakeDaemon {
    answers: Arc<Mutex<Vec<Result<Value, DaemonError>>>>,
    asks: Arc<AtomicUsize>,
    remote: Arc<Mutex<Vec<Value>>>,
    workspace_reads: Arc<AtomicUsize>,
}

impl FakeDaemon {
    fn new(answers: Vec<Result<Value, DaemonError>>) -> Self {
        Self {
            answers: Arc::new(Mutex::new(answers)),
            asks: Arc::default(),
            remote: Arc::default(),
            workspace_reads: Arc::default(),
        }
    }
}

impl Daemon for FakeDaemon {
    fn endpoint(&self) -> Result<Value, DaemonError> {
        self.asks.fetch_add(1, Ordering::SeqCst);
        let mut answers = self.answers.lock().unwrap();
        if answers.len() > 1 { answers.remove(0) } else { answers[0].clone() }
    }
    fn remote_call(&self, params: Value) -> Result<Value, DaemonError> {
        self.remote.lock().unwrap().push(params.clone());
        Ok(
            json!({"result": {"is_error": false, "code": null, "body": {"remote": params["machine"]}, "png": null}}),
        )
    }
    fn machines(&self) -> Result<Value, DaemonError> {
        Ok(json!({"machines": [{"name": "studio", "reachable": true, "computer_use": "ready"}]}))
    }
    fn workspace_name(&self, id: &str) -> Option<String> {
        self.workspace_reads.fetch_add(1, Ordering::SeqCst);
        workspace_name_in(
            &json!({"workspaces": [{"id": "1F2E", "name": "  cmux \u{7}rewrite  "}, {"id": "other", "name": "Other"}]}),
            id,
        )
    }
}

fn caller(daemon: FakeDaemon) -> Caller<FakeDaemon> {
    let mut caller = Caller::new(daemon, "s-1".into(), "Claude Code".into());
    caller.sleep = |_| std::thread::sleep(Duration::from_millis(5));
    caller
}

fn tmp() -> tempfile::TempDir {
    // A short path: a Unix socket path has a small limit.
    tempfile::Builder::new().prefix("cu").tempdir_in("/tmp").unwrap()
}

#[test]
fn a_call_reaches_the_worker_with_its_session_label_and_call_id() {
    let dir = tmp();
    let worker = FakeWorker::start(dir.path(), "w", Behavior::Answer, Arc::default());
    let caller = caller(FakeDaemon::new(vec![Ok(worker.ready())]));
    let out = caller.call("list_windows", &json!({"app_id": "com.apple.Notes"}), "call-1");
    let Outcome::Output(out) = out else { panic!("{out:?}") };
    assert_eq!(out.body, json!({"ran": "list_windows"}));
    let seen = worker.seen.lock().unwrap();
    assert_eq!(seen[0]["session"], "s-1");
    assert_eq!(seen[0]["label"], "Claude Code");
    assert_eq!(seen[0]["call_id"], "call-1");
    assert_eq!(seen[0]["arguments"], json!({"app_id": "com.apple.Notes"}));
    // A local call never claims an origin: the worker treats it as local.
    assert!(seen[0].get("origin").is_none(), "{}", seen[0]);
}

/// The agent cursor's tag: the workspace's name by default (read from the daemon once), the
/// agent's `cursor_tag` once it sets one (taken out of the tool's arguments and kept for the
/// later calls), back to the workspace's name when it sets an empty one; a remote call carries it.
#[test]
fn a_call_carries_the_cursor_tag_the_agent_set_else_its_workspace_name() {
    let dir = tmp();
    let worker = FakeWorker::start(dir.path(), "w", Behavior::Answer, Arc::default());
    let daemon = FakeDaemon::new(vec![Ok(worker.ready())]);
    let reads = daemon.workspace_reads.clone();
    let remote = daemon.remote.clone();
    let caller = caller(daemon).with_workspace(Some("1f2e".into()));
    caller.call("click", &json!({"window_id": "w1"}), "t-1");
    caller.call("click", &json!({"window_id": "w1", "cursor_tag": "Fixing\nthe build"}), "t-2");
    caller.call("screenshot", &json!({"window_id": "w1"}), "t-3");
    caller.call("click", &json!({"window_id": "w1", "cursor_tag": "  "}), "t-4");
    caller.call("click", &json!({"window_id": "w1", "machine": "studio"}), "t-5");
    let seen = worker.seen.lock().unwrap();
    let tags: Vec<_> = seen.iter().map(|r| r["tag"].clone()).collect();
    assert_eq!(
        tags,
        [
            json!("cmux rewrite"),
            json!("Fixing the build"),
            json!("Fixing the build"),
            json!("cmux rewrite")
        ]
    );
    assert!(
        seen.iter().all(|r| r["arguments"].get("cursor_tag").is_none()),
        "the tag never reaches the tool"
    );
    assert_eq!(reads.load(Ordering::SeqCst), 1, "the workspace's name is read once");
    assert_eq!(remote.lock().unwrap()[0]["tag"], "cmux rewrite");
    // No workspace and no tag of its own: no tag.
    let bare = FakeWorker::start(dir.path(), "b", Behavior::Answer, Arc::default());
    let caller = Caller::new(FakeDaemon::new(vec![Ok(bare.ready())]), "s-2".into(), "Codex".into());
    caller.call("click", &json!({"window_id": "w1"}), "t-6");
    assert!(bare.seen.lock().unwrap()[0].get("tag").is_none());
    assert_eq!(
        cmux_computer_use::tools::safe_tag(&"x".repeat(80)).map(|t| t.chars().count()),
        Some(60)
    );
}

/// The worker dies mid-call and comes back on a new socket with a new
/// secret: the bridge asks the daemon again and resends the SAME call id,
/// and the call runs once.
#[test]
fn a_worker_restart_mid_call_retries_the_same_call_id_and_runs_once() {
    let dir = tmp();
    let done = Arc::new(Mutex::new(HashMap::new()));
    let first = FakeWorker::start(dir.path(), "a", Behavior::CrashOnce, done.clone());
    let second = FakeWorker::start(dir.path(), "b", Behavior::Answer, done);
    let daemon = FakeDaemon::new(vec![
        Ok(first.ready()),
        Ok(json!({"state": "starting"})),
        Ok(second.ready()),
    ]);
    let asks = daemon.asks.clone();
    let caller = caller(daemon);
    let out = caller.call("click", &json!({"window_id": "w1", "x": 1, "y": 2}), "call-r");
    let Outcome::Output(out) = out else { panic!("a restart surfaced as {out:?}") };
    assert!(!out.is_error, "{out:?}");
    assert_eq!(out.body, json!({"ran": "click"}));
    assert_eq!(first.seen.lock().unwrap()[0]["call_id"], "call-r");
    assert_eq!(second.seen.lock().unwrap()[0]["call_id"], "call-r");
    assert_eq!(
        first.ran.load(Ordering::SeqCst) + second.ran.load(Ordering::SeqCst),
        1,
        "ran twice"
    );
    assert_eq!(asks.load(Ordering::SeqCst), 3, "asked the daemon again after the restart");
}

/// A stale secret (the worker restarted on the same socket) is a transport
/// failure: the daemon is asked again, never an error for the agent.
#[test]
fn a_refused_secret_asks_the_daemon_again() {
    let dir = tmp();
    let worker = FakeWorker::start(dir.path(), "w", Behavior::Answer, Arc::default());
    let mut stale = worker.ready();
    stale["secret"] = json!("old");
    let caller = caller(FakeDaemon::new(vec![Ok(stale), Ok(worker.ready())]));
    let out = caller.call("status", &json!({}), "call-s");
    assert!(matches!(out, Outcome::Output(ref o) if !o.is_error), "{out:?}");
}

#[test]
fn a_refusal_reaches_the_agent_unchanged() {
    let dir = tmp();
    let worker = FakeWorker::start(dir.path(), "w", Behavior::Refuse, Arc::default());
    let caller = caller(FakeDaemon::new(vec![Ok(worker.ready())]));
    let out = caller.call("click", &json!({"window_id": "k"}), "call-d");
    let mcp = out.to_mcp();
    assert_eq!(mcp["isError"], true, "{mcp}");
    let text = mcp["content"][0]["text"].as_str().unwrap();
    assert!(text.contains("app_denied") && text.contains("Keychain Access is denied"), "{text}");
    // Exactly one attempt: a refusal is never retried.
    assert_eq!(worker.seen.lock().unwrap().len(), 1);
}

#[test]
fn the_persons_stop_reaches_the_agent_word_for_word_and_is_never_retried() {
    let dir = tmp();
    let worker = FakeWorker::start(dir.path(), "w", Behavior::Stopped, Arc::default());
    let caller = caller(FakeDaemon::new(vec![Ok(worker.ready())]));
    let mcp = caller.call("click", &json!({"window_id": "k"}), "call-s").to_mcp();
    assert_eq!(mcp["isError"], true, "{mcp}");
    let text: Value = serde_json::from_str(mcp["content"][0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(text["code"], cmux_computer_use::stop::STOPPED_CODE);
    assert_eq!(text["error"], cmux_computer_use::stop::STOPPED_MESSAGE);
    assert!(text["error"].as_str().unwrap().contains("Do not retry or work around it"));
    assert_eq!(worker.seen.lock().unwrap().len(), 1);
}

#[test]
fn computer_use_off_is_a_tool_error_but_status_still_answers() {
    let caller =
        caller(FakeDaemon::new(vec![Ok(json!({"state": "off", "reason": "mode is off"}))]));
    let mcp = caller.call("click", &json!({}), "c").to_mcp();
    assert_eq!(mcp["isError"], true);
    assert!(mcp["content"][0]["text"].as_str().unwrap().contains("computer_use_off"), "{mcp}");
    let Outcome::Output(status) = caller.call("status", &json!({}), "c2") else { panic!() };
    assert!(!status.is_error);
    assert_eq!(status.body["mode"], "off");
}

/// A worker that never comes back within the budget ends as one plain tool
/// error that says Computer Use restarts by itself.
#[test]
fn a_worker_away_for_the_whole_budget_is_one_plain_error() {
    let caller = caller(FakeDaemon::new(vec![Err(DaemonError::Unreachable("no daemon".into()))]))
        .with_budget(Duration::from_millis(200));
    let Outcome::Failed { code, message } = caller.call("status", &json!({}), "c") else {
        panic!()
    };
    assert_eq!(code, "computer_use_unavailable");
    assert!(message.contains("restarts by itself"), "{message}");
}

/// An old daemon without `computer-use-endpoint` refuses: waiting never
/// helps, so the call fails at once.
#[test]
fn a_daemon_without_the_endpoint_fails_at_once() {
    let daemon = FakeDaemon::new(vec![Err(DaemonError::Refused {
        code: "unknown_command".into(),
        message: "unknown command computer-use-endpoint".into(),
    })]);
    let caller = caller(daemon).with_budget(Duration::from_secs(30));
    let started = std::time::Instant::now();
    let out = caller.call("status", &json!({}), "c");
    assert!(matches!(out, Outcome::Failed { .. }), "{out:?}");
    assert!(started.elapsed() < Duration::from_secs(5));
}

#[test]
fn machine_goes_through_the_daemon_route_and_list_machines_is_local() {
    let daemon = FakeDaemon::new(vec![Err(DaemonError::Unreachable("unused".into()))]);
    let remote = daemon.remote.clone();
    let caller = caller(daemon);
    let Outcome::Output(out) =
        caller.call("screenshot", &json!({"machine": "studio", "window_id": "w"}), "c-m")
    else {
        panic!()
    };
    assert_eq!(out.body, json!({"remote": "studio"}));
    let sent = remote.lock().unwrap()[0].clone();
    assert_eq!(sent["call_id"], "c-m");
    assert_eq!(sent["session"], "s-1");
    // The machine leaves the tool's own arguments.
    assert_eq!(sent["arguments"], json!({"window_id": "w"}));
    let Outcome::Output(list) = caller.call("list_machines", &json!({}), "c-l") else { panic!() };
    assert_eq!(list.body["machines"][0]["name"], "studio");
}

/// A daemon running a call another machine sent puts the origin it took from
/// the link on the request, and never sends the call on to a third machine.
#[test]
fn a_relayed_call_carries_its_link_origin_and_runs_only_here() {
    let dir = tmp();
    let worker = FakeWorker::start(dir.path(), "w", Behavior::Answer, Arc::default());
    let origin = json!({"kind": "remote", "machine": "laptop", "same_account": true});
    let caller = caller(FakeDaemon::new(vec![Ok(worker.ready())])).with_origin(origin.clone());
    assert!(matches!(caller.call("status", &json!({}), "c"), Outcome::Output(_)));
    assert_eq!(worker.seen.lock().unwrap()[0]["origin"], origin);
    for (name, args) in [("click", json!({"machine": "third"})), ("list_machines", json!({}))] {
        let out = caller.call(name, &args, "c2");
        assert!(
            matches!(out, Outcome::Failed { ref code, .. } if code == "computer_use_remote_denied"),
            "{out:?}"
        );
    }
}

#[test]
fn the_endpoint_states_parse() {
    assert!(matches!(
        EndpointState::parse(&json!({"state": "ready", "socket": "/s", "secret": "ab"})),
        EndpointState::Ready(_)
    ));
    assert!(matches!(
        EndpointState::parse(&json!({"state": "ready", "socket": ""})),
        EndpointState::Unavailable(_)
    ));
    assert!(matches!(EndpointState::parse(&json!({"state": "off"})), EndpointState::Off(_)));
    assert!(matches!(
        EndpointState::parse(&json!({"state": "starting"})),
        EndpointState::Starting(_)
    ));
    assert!(matches!(EndpointState::parse(&json!({})), EndpointState::Unavailable(_)));
    // The secret is never printed.
    let ready =
        EndpointState::parse(&json!({"state": "ready", "socket": "/s", "secret": "topsecret"}));
    assert!(!format!("{ready:?}").contains("topsecret"));
}

/// The MCP server answers initialize and tools/list with no daemon and no
/// worker, and a call with none answers a tool error, not a dropped pipe.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_mcp_server_lists_its_tools_with_no_worker() {
    let daemon = FakeDaemon::new(vec![Err(DaemonError::Unreachable("no daemon".into()))]);
    let caller = Arc::new(caller(daemon).with_budget(Duration::from_millis(100)));
    let input = [
        json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "clientInfo": {"name": "codex"}}}),
        json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
        json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}),
        json!({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "status", "arguments": {}}}),
        json!({"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "nope"}}),
    ]
    .iter()
    .map(|m| format!("{m}\n"))
    .collect::<String>();
    let (out_w, out_r) = tokio::io::duplex(1 << 20);
    let input = tokio::io::BufReader::new(std::io::Cursor::new(input.into_bytes()));
    let reader = tokio::spawn(async move {
        use tokio::io::AsyncReadExt;
        let mut text = String::new();
        let mut out_r = out_r;
        let _ = out_r.read_to_string(&mut text).await;
        text
    });
    // Keep stdin open until the call answered: serve ends with its input.
    super::super::mcp::serve(caller.clone(), input, out_w).await.unwrap();
    let text = reader.await.unwrap();
    let replies: HashMap<i64, Value> = text
        .lines()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .filter_map(|v| Some((v["id"].as_i64()?, v)))
        .collect();
    let init = &replies[&1]["result"];
    assert_eq!(init["serverInfo"]["name"], "cmux-computer-use");
    // The client is Codex, which has its own Computer Use: cmux's comes second.
    assert_eq!(init["instructions"], super::super::mcp::DEFER_INSTRUCTIONS);
    assert_eq!(replies[&2]["result"], super::super::mcp::tools_list(true));
    assert_eq!(replies[&4]["result"]["isError"], true);
    assert_eq!(caller.label(), "codex", "the agent's name for the person's cards");
}
