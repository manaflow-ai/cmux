use cmux::Config;
use cmux_rust_agent_dashboard::{NotificationTracker, RunOptions, run_connection};
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
    assert!(requests.iter().any(|request| operation(request) == "workspace.list"));
    assert!(requests.iter().any(|request| operation(request) == "workspace.get"));
    assert_eq!(requests.iter().filter(|request| operation(request) == "agent.list").count(), 5);
    let notification = requests
        .iter()
        .find(|request| operation(request) == "notification.create")
        .expect("notification request");
    assert_eq!(notification["params"]["level"], "warning");
    assert_eq!(notification["params"].get("terminal_id"), None);
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

fn serve(
    stream: UnixStream,
    requests: Arc<Mutex<Vec<Value>>>,
    shutdown_after_refresh: Option<Arc<AtomicBool>>,
) {
    let reader = stream.try_clone().expect("clone connection");
    let mut reader = BufReader::new(reader);
    let mut writer = stream;
    let mut line = String::new();
    let mut agent_queries = 0;
    while reader.read_line(&mut line).expect("read request") != 0 {
        let request: Value = serde_json::from_str(line.trim()).expect("request JSON");
        requests.lock().expect("request log").push(request.clone());
        let id = request["id"].clone();
        let operation = request["operation"].as_str().expect("operation");
        let result = match operation {
            "session.get" => json!({
                "id": SESSION_ID,
                "name": "fake",
                "revision": "7"
            }),
            "workspace.list" => json!([{
                "id": WORKSPACE_ID,
                "name": "build",
                "session_id": SESSION_ID,
                "revision": "7"
            }]),
            "workspace.get" => json!({
                "id": WORKSPACE_ID,
                "name": "build",
                "session_id": SESSION_ID,
                "revision": "7"
            }),
            "agent.list" => {
                agent_queries += 1;
                if request["params"]["state"] == "blocked" {
                    json!([{
                        "id": AGENT_ID,
                        "session_id": SESSION_ID,
                        "revision": "7"
                    }])
                } else {
                    json!([])
                }
            }
            "notification.create" => json!({
                "value": {
                    "id": NOTIFICATION_ID,
                    "session_id": SESSION_ID,
                    "title": "Agent needs input",
                    "body": format!("Agent {AGENT_ID} is blocked."),
                    "level": "warning",
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
            "protocol": "cmux.protocol/1",
            "type": "response",
            "id": id,
            "ok": true,
            "result": result
        });
        writeln!(writer, "{response}").expect("write response");
        line.clear();
        if agent_queries == 5
            && let Some(shutdown) = &shutdown_after_refresh
        {
            shutdown.store(true, Ordering::Release);
        }
    }
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
