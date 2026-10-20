use cmux::{Config, RunCommand, TerminalExitOutcome, TerminalLifecycle, TerminalWaitExitResult};
use cmux_rust_agent_dashboard::{
    CommandCheckOptions, NotificationTracker, RunOptions, run_command_check, run_connection,
};
use serde_json::{Value, json};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const SESSION_ID: &str = "session_11111111111111111111111111111111";
const WORKSPACE_ID: &str = "ws_22222222222222222222222222222222";
const AGENT_ID: &str = "agent_33333333333333333333333333333333";
const NOTIFICATION_ID: &str = "notification_44444444444444444444444444444444";
const MACHINE_ID: &str = "machine_55555555555555555555555555555555";
const TERMINAL_ID: &str = "term_66666666666666666666666666666666";
const SCREEN_ID: &str = "screen_77777777777777777777777777777777";
const PANE_ID: &str = "pane_88888888888888888888888888888888";
const TAB_ID: &str = "tab_99999999999999999999999999999999";

#[test]
fn public_resource_handles_drive_snapshots_filters_and_notification() {
    let socket = temp_socket();
    let listener = UnixListener::bind(&socket).expect("bind fake server");
    let requests = Arc::new(Mutex::new(Vec::new()));
    let server_requests = Arc::clone(&requests);
    let server = thread::spawn(move || {
        let (connection, _) = listener.accept().expect("accept resource connection");
        serve(connection, server_requests, None);
    });

    let options = RunOptions {
        agent_poll_interval: Duration::from_millis(20),
        watch_for: Some(Duration::ZERO),
        clear_screen: false,
        notify_blocked: true,
    };
    let shutdown = AtomicBool::new(false);
    let mut notifications = NotificationTracker::default();
    let mut output = Vec::new();
    run_connection(
        Config::from_socket_path(&socket).with_timeout(Duration::from_secs(1)),
        &options,
        &shutdown,
        &mut notifications,
        &mut output,
    )
    .expect("dashboard run");
    server.join().expect("fake server");
    let _ = fs::remove_file(&socket);

    let output = String::from_utf8(output).expect("UTF-8 dashboard");
    assert!(output.contains("session fake"));
    assert!(output.contains(&format!("blocked {AGENT_ID}")));
    assert!(output.contains(&format!("build [{WORKSPACE_ID}]")));
    let requests = requests.lock().expect("requests");
    assert!(requests.iter().any(|request| operation(request) == "session.get"));
    assert!(requests.iter().any(|request| operation(request) == "session.snapshot"));
    assert!(!requests.iter().any(|request| operation(request) == "agent.list"));
    let notification = requests
        .iter()
        .find(|request| operation(request) == "notification.create")
        .expect("notification request");
    assert_eq!(notification["params"]["level"], "warning");
    assert_eq!(notification["params"]["terminal_id"], TERMINAL_ID);
    assert!(requests.iter().all(|request| request.get("cmd").is_none()));
}

#[test]
fn reconnects_after_resource_transport_loss() {
    let socket = temp_socket();
    let listener = UnixListener::bind(&socket).expect("bind fake server");
    let requests = Arc::new(Mutex::new(Vec::new()));
    let shutdown = Arc::new(AtomicBool::new(false));
    let server_requests = Arc::clone(&requests);
    let server_shutdown = Arc::clone(&shutdown);
    let server = thread::spawn(move || {
        let (first, _) = listener.accept().expect("accept first connection");
        drop(first);
        let (replacement, _) = listener.accept().expect("accept replacement connection");
        serve(replacement, server_requests, Some(server_shutdown));
    });

    let options = RunOptions {
        agent_poll_interval: Duration::from_secs(1),
        watch_for: None,
        clear_screen: false,
        notify_blocked: false,
    };
    let mut output = Vec::new();
    let mut errors = Vec::new();
    cmux_rust_agent_dashboard::run_with_reconnect(
        Config::from_socket_path(&socket).with_timeout(Duration::from_secs(1)),
        &options,
        Duration::from_millis(10),
        Arc::clone(&shutdown),
        &mut output,
        &mut errors,
    )
    .expect("reconnecting dashboard");
    server.join().expect("fake reconnect server");
    let _ = fs::remove_file(&socket);

    assert!(String::from_utf8(output).expect("UTF-8 output").contains("session fake"));
    let errors = String::from_utf8(errors).expect("UTF-8 errors");
    assert!(errors.contains("dashboard connection failed:"));
    assert!(errors.contains("retrying in 10 ms"));
    assert!(shutdown.load(Ordering::Acquire));
}

#[test]
fn recovers_correlated_command_creation_and_decodes_durable_exit() {
    let socket = temp_socket();
    let listener = UnixListener::bind(&socket).expect("bind fake server");
    let requests = Arc::new(Mutex::new(Vec::new()));
    let server_requests = Arc::clone(&requests);
    let server = thread::spawn(move || {
        let (first, _) = listener.accept().expect("accept uncertain mutation connection");
        let mut first_reader = BufReader::new(first);
        let mut line = String::new();
        first_reader.read_line(&mut line).expect("read workspace.run");
        let request: Value = serde_json::from_str(line.trim()).expect("workspace.run JSON");
        server_requests.lock().expect("request log").push(request);
        drop(first_reader);

        let (second, _) = listener.accept().expect("accept recovery connection");
        let mut reader = BufReader::new(second.try_clone().expect("clone recovery connection"));
        let mut writer = second;
        for _ in 0..3 {
            line.clear();
            reader.read_line(&mut line).expect("read recovery request");
            let request: Value = serde_json::from_str(line.trim()).expect("recovery JSON");
            server_requests.lock().expect("request log").push(request.clone());
            let result = match operation(&request) {
                "session.creation.resolve" => json!({
                    "correlation_key": "dashboard-check",
                    "state": "created",
                    "recovery": "none",
                    "operation": "workspace.run",
                    "idempotency_key": "dashboard-check-attempt-1",
                    "created_path": terminal_created_path(),
                    "generation": "fake-generation",
                    "revision": "11"
                }),
                "terminal.wait_exit" => json!({
                    "state": "exited",
                    "terminal_id": TERMINAL_ID,
                    "lifecycle": "exited",
                    "outcome": {"kind": "exit", "code": 17},
                    "exited_at": "1700000000123",
                    "revision": "12"
                }),
                "terminal.get" => exited_terminal_snapshot(),
                other => panic!("unexpected recovery operation {other}"),
            };
            writeln!(
                writer,
                "{}",
                json!({
                    "protocol": "cmux.protocol/2",
                    "type": "response",
                    "id": request["id"],
                    "ok": true,
                    "result": result
                })
            )
            .expect("write recovery response");
        }
    });

    let client = cmux::Client::connect(
        Config::from_socket_path(&socket).with_timeout(Duration::from_secs(1)),
    )
    .expect("connect");
    let session = client.current_session();
    let result = run_command_check(
        &session,
        &session.current_workspace(),
        CommandCheckOptions {
            command: RunCommand::argv(["sh", "-c", "exit 17"]).expect("command"),
            correlation_key: "dashboard-check".to_string(),
            idempotency_key: "dashboard-check-attempt-1".to_string(),
            exit_timeout_ms: Some(1_000),
        },
    )
    .expect("recover command check");

    assert!(result.recovered_creation);
    assert_eq!(result.terminal_id.as_str(), TERMINAL_ID);
    let TerminalWaitExitResult::Exited(exit) = result.wait else {
        panic!("expected exited wait result");
    };
    assert_eq!(exit.outcome, TerminalExitOutcome::Exit { code: 17 });
    assert_eq!(result.snapshot.lifecycle, TerminalLifecycle::Exited);
    assert!(!result.snapshot.running);
    assert_eq!(
        result.snapshot.exit.as_ref().map(|exit| &exit.outcome),
        Some(&TerminalExitOutcome::Exit { code: 17 })
    );
    client.close().expect("close client");
    server.join().expect("fake recovery server");
    let _ = fs::remove_file(&socket);

    let requests = requests.lock().expect("requests");
    assert_eq!(
        requests.iter().map(operation).collect::<Vec<_>>(),
        ["workspace.run", "session.creation.resolve", "terminal.wait_exit", "terminal.get"]
    );
    assert_eq!(requests[0]["idempotency_key"], "dashboard-check-attempt-1");
    assert_eq!(requests[0]["params"]["correlation_key"], "dashboard-check");
    assert_eq!(requests[1]["params"]["correlation_key"], "dashboard-check");
    assert_eq!(requests[2]["params"]["timeout_ms"], "1000");
}

fn serve(
    stream: UnixStream,
    requests: Arc<Mutex<Vec<Value>>>,
    shutdown_after_refresh: Option<Arc<AtomicBool>>,
) {
    let reader = stream.try_clone().expect("clone connection");
    let mut reader = BufReader::new(reader);
    let mut writer = stream;
    let mut line = String::new();
    let mut snapshots = 0;
    while reader.read_line(&mut line).expect("read request") != 0 {
        let request: Value = serde_json::from_str(line.trim()).expect("request JSON");
        requests.lock().expect("request log").push(request.clone());
        let id = request["id"].clone();
        let operation = request["operation"].as_str().expect("operation");
        let result = match operation {
            "session.get" => json!({
                "id": SESSION_ID,
                "machine_id": MACHINE_ID,
                "name": "fake",
                "generation": "fake-generation",
                "revision": "7",
                "connected": true
            }),
            "session.snapshot" => {
                snapshots += 1;
                resource_snapshot()
            }
            "notification.create" => json!({
                "value": {
                    "id": NOTIFICATION_ID,
                    "session_id": SESSION_ID,
                    "title": "Agent needs input",
                    "body": format!("Agent {AGENT_ID} is blocked."),
                    "level": "warning",
                    "terminal_id": TERMINAL_ID,
                    "created_at_ms": "100",
                    "unread": true
                },
                "generation": "fake-generation",
                "revision": "8",
                "replayed": false
            }),
            other => panic!("unexpected operation {other}"),
        };
        let response = json!({
            "protocol": "cmux.protocol/2",
            "type": "response",
            "id": id,
            "ok": true,
            "result": result
        });
        writeln!(writer, "{response}").expect("write response");
        line.clear();
        if snapshots == 1
            && let Some(shutdown) = &shutdown_after_refresh
        {
            shutdown.store(true, Ordering::Release);
        }
    }
}

fn terminal_created_path() -> Value {
    json!({
        "kind": "terminal",
        "workspace_id": WORKSPACE_ID,
        "screen_id": SCREEN_ID,
        "pane_id": PANE_ID,
        "tab_id": TAB_ID,
        "terminal_id": TERMINAL_ID
    })
}

fn exited_terminal_snapshot() -> Value {
    json!({
        "id": TERMINAL_ID,
        "tab_id": TAB_ID,
        "tab_ids": [TAB_ID],
        "title": "health check",
        "cwd": "/tmp",
        "cols": 80,
        "rows": 24,
        "running": false,
        "lifecycle": "exited",
        "exit": {
            "outcome": {"kind": "exit", "code": 17},
            "exited_at": "1700000000123",
            "revision": "12"
        }
    })
}

fn resource_snapshot() -> Value {
    json!({
        "machine": {
            "id": MACHINE_ID,
            "name": "local",
            "origin": "local",
            "status": "running",
            "connectable": true,
            "deleted": false,
            "recoverable": false
        },
        "session": {
            "id": SESSION_ID,
            "machine_id": MACHINE_ID,
            "name": "fake",
            "generation": "fake-generation",
            "revision": "7",
            "connected": true
        },
        "workspaces": [{
            "id": WORKSPACE_ID,
            "session_id": SESSION_ID,
            "name": "build",
            "index": 0,
            "focused": true
        }],
        "screens": [],
        "panes": [],
        "tabs": [],
        "terminals": [],
        "browsers": [],
        "clients": [],
        "notifications": [],
        "agents": [{
            "id": AGENT_ID,
            "session_id": SESSION_ID,
            "terminal_id": TERMINAL_ID,
            "state": "blocked",
            "source": "socket",
            "updated_at_ms": "100",
            "source_session": "codex-test"
        }],
        "frontend_projections": [],
        "sidebar_views": [],
        "cursor": {
            "generation": "fake-generation",
            "revision": "7"
        }
    })
}

fn operation(request: &Value) -> &str {
    request["operation"].as_str().expect("operation")
}

fn temp_socket() -> PathBuf {
    static NEXT_SOCKET: AtomicU64 = AtomicU64::new(0);
    let nonce = SystemTime::now().duration_since(UNIX_EPOCH).expect("time").as_nanos();
    let sequence = NEXT_SOCKET.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir()
        .join(format!("cmux-agent-dashboard-{}-{nonce}-{sequence}.sock", std::process::id()))
}
