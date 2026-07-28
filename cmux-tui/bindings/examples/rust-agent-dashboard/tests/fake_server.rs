use cmux_client::ClientConfig;
use cmux_rust_agent_dashboard::{NotificationTracker, RunOptions, run_connection};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[test]
fn public_sdk_drives_a_snapshot_delta_poll_and_typed_notification() {
    let socket = temp_socket();
    let listener = UnixListener::bind(&socket).expect("bind fake server");
    let requests = Arc::new(Mutex::new(Vec::new()));
    let server_requests = Arc::clone(&requests);
    let server = thread::spawn(move || {
        let (control, _) = listener.accept().expect("accept command connection");
        let control_requests = Arc::clone(&server_requests);
        let control = thread::spawn(move || serve_control(control, control_requests));

        let (subscription, _) = listener.accept().expect("accept subscription connection");
        serve_subscription(subscription, server_requests);
        control.join().expect("control server");
    });

    let options = RunOptions {
        agent_poll_interval: Duration::from_millis(20),
        watch_for: Some(Duration::from_millis(90)),
        clear_screen: false,
        notify_blocked: true,
    };
    let shutdown = AtomicBool::new(false);
    let mut notifications = NotificationTracker::default();
    let mut output = Vec::new();
    run_connection(
        ClientConfig::from_socket_path(&socket).with_timeout(Duration::from_secs(1)),
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
    assert!(output.contains("surface:9 blocked workspace:build"));
    let requests = requests.lock().expect("requests");
    assert!(requests.iter().any(|line| line.contains(r#""cmd":"identify""#)));
    assert!(requests.iter().any(|line| {
        line.contains(r#""cmd":"subscribe""#) && line.contains(r#""tree_events":"deltas""#)
    }));
    assert!(
        requests.iter().filter(|line| line.contains(r#""cmd":"list-workspaces""#)).count() >= 2
    );
    assert!(requests.iter().filter(|line| line.contains(r#""cmd":"list-agents""#)).count() >= 2);
    assert!(requests.iter().any(|line| {
        line.contains(r#""cmd":"notify""#)
            && line.contains(r#""level":"warning""#)
            && line.contains(r#""surface":9"#)
    }));
    assert!(!requests.iter().any(|line| line.contains("request_raw")));
}

#[test]
fn reconnects_after_transport_loss_and_closes_the_replacement_cleanly() {
    let socket = temp_socket();
    let listener = UnixListener::bind(&socket).expect("bind fake server");
    let requests = Arc::new(Mutex::new(Vec::new()));
    let shutdown = Arc::new(AtomicBool::new(false));
    let server_requests = Arc::clone(&requests);
    let server_shutdown = Arc::clone(&shutdown);
    let server = thread::spawn(move || {
        let (first_control, _) = listener.accept().expect("accept first command connection");
        let first_requests = Arc::clone(&server_requests);
        let first_control = thread::spawn(move || {
            serve_control_for_session(first_control, first_requests, "first", None)
        });
        let (first_subscription, _) =
            listener.accept().expect("accept first subscription connection");
        acknowledge_subscription(first_subscription, Arc::clone(&server_requests), false);
        first_control.join().expect("first control server");

        let (second_control, _) = listener.accept().expect("accept replacement command connection");
        let second_requests = Arc::clone(&server_requests);
        let second_shutdown = Arc::clone(&server_shutdown);
        let second_control = thread::spawn(move || {
            serve_control_for_session(
                second_control,
                second_requests,
                "replacement",
                Some(second_shutdown),
            )
        });
        let (second_subscription, _) =
            listener.accept().expect("accept replacement subscription connection");
        serve_subscription(second_subscription, server_requests);
        second_control.join().expect("replacement control server");
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
        ClientConfig::from_socket_path(&socket).with_timeout(Duration::from_secs(1)),
        &options,
        Duration::from_millis(10),
        Arc::clone(&shutdown),
        &mut output,
        &mut errors,
    )
    .expect("reconnecting dashboard");
    server.join().expect("fake reconnect server");
    let _ = fs::remove_file(&socket);

    let output = String::from_utf8(output).expect("UTF-8 dashboard");
    let errors = String::from_utf8(errors).expect("UTF-8 errors");
    assert!(output.contains("session first"));
    assert!(output.contains("session replacement"));
    assert!(errors.contains("dashboard connection failed:"), "missing failure report: {errors:?}");
    assert!(errors.contains("retrying in 10 ms"));
    assert!(shutdown.load(Ordering::Acquire));
}

fn serve_control(stream: UnixStream, requests: Arc<Mutex<Vec<String>>>) {
    serve_control_for_session(stream, requests, "fake", None);
}

fn serve_control_for_session(
    stream: UnixStream,
    requests: Arc<Mutex<Vec<String>>>,
    session: &str,
    shutdown_after_agents: Option<Arc<AtomicBool>>,
) {
    let reader = stream.try_clone().expect("clone control");
    let mut reader = BufReader::new(reader);
    let mut writer = stream;
    let mut line = String::new();
    while reader.read_line(&mut line).expect("read command") != 0 {
        requests.lock().expect("request log").push(line.trim().to_string());
        let id = request_id(&line);
        let response = if line.contains(r#""cmd":"identify""#) {
            format!(
                r#"{{"id":{id},"ok":true,"data":{{"app":"cmux-tui","version":"0.1.0","protocol":10,"capabilities":[],"session":"{session}","pid":42,"registry_id":"registry","generation":"generation","workspace_revision":1,"terminal_revision":0,"daemon_handoff":1}}}}"#
            )
        } else if line.contains(r#""cmd":"list-workspaces""#) {
            format!(
                r#"{{"id":{id},"ok":true,"data":{{"workspaces":[{{"active":true,"id":1,"name":"build","screens":[{{"active":true,"active_pane":3,"id":2,"layout":{{"type":"leaf","pane":3}},"name":null,"panes":[{{"active_tab":0,"id":3,"name":null,"tabs":[{{"browser_source":null,"dead":false,"kind":"pty","name":null,"size":null,"surface":9,"title":"agent"}}]}}],"zoomed_pane":null}}]}}]}}}}"#
            )
        } else if line.contains(r#""cmd":"list-agents""#) {
            format!(
                r#"{{"id":{id},"ok":true,"data":{{"agents":[{{"session":"agent-1","source":"hook","state":"blocked","surface":9,"updated_at_ms":100}}]}}}}"#
            )
        } else if line.contains(r#""cmd":"notify""#) {
            format!(r#"{{"id":{id},"ok":true,"data":{{"notification":77}}}}"#)
        } else {
            format!(r#"{{"id":{id},"ok":false,"error":"unexpected command"}}"#)
        };
        writeln!(writer, "{response}").expect("write response");
        if line.contains(r#""cmd":"list-agents""#)
            && let Some(shutdown) = &shutdown_after_agents
        {
            shutdown.store(true, Ordering::Release);
        }
        line.clear();
    }
}

fn serve_subscription(stream: UnixStream, requests: Arc<Mutex<Vec<String>>>) {
    acknowledge_subscription(stream, requests, true);
}

fn acknowledge_subscription(
    stream: UnixStream,
    requests: Arc<Mutex<Vec<String>>>,
    wait_for_close: bool,
) {
    let reader = stream.try_clone().expect("clone subscription");
    let mut reader = BufReader::new(reader);
    let mut writer = stream;
    let mut line = String::new();
    reader.read_line(&mut line).expect("read subscribe");
    requests.lock().expect("request log").push(line.trim().to_string());
    let id = request_id(&line);

    // This event intentionally precedes the acknowledgement. A real consumer
    // must not lose it while establishing the stream.
    writeln!(writer, r#"{{"event":"tree-changed"}}"#).expect("write pre-ack event");
    writeln!(writer, r#"{{"id":{id},"ok":true,"data":{{}}}}"#).expect("write subscribe ack");

    if wait_for_close {
        line.clear();
        while reader.read_line(&mut line).expect("wait for client close") != 0 {
            line.clear();
        }
    }
}

fn request_id(line: &str) -> u64 {
    let marker = r#""id":"#;
    let start = line.find(marker).expect("request id") + marker.len();
    line[start..]
        .chars()
        .take_while(char::is_ascii_digit)
        .collect::<String>()
        .parse()
        .expect("numeric request id")
}

fn temp_socket() -> PathBuf {
    static NEXT_SOCKET: AtomicU64 = AtomicU64::new(0);
    let nonce = SystemTime::now().duration_since(UNIX_EPOCH).expect("time").as_nanos();
    let sequence = NEXT_SOCKET.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!(
        "cmux-agent-dashboard-{}-{nonce}-{sequence}.sock",
        std::process::id()
    ))
}
