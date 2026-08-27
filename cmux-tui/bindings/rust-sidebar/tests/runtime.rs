use base64::Engine;
use cmux::{Config, SessionId, SidebarViewId, StreamEndReason};
use cmux_sidebar::{SidebarConfig, SidebarRuntime, SidebarRuntimeState};
use crossterm::event::{Event, KeyCode, KeyEvent, KeyModifiers};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

const SESSION: &str = "session_00000000000000000000000000000001";
const VIEW: &str = "sidebar_view_00000000000000000000000000000002";
static NEXT_SOCKET: AtomicU64 = AtomicU64::new(1);

fn test_duration(duration: Duration) -> Duration {
    let scale = std::env::var("CMUX_TEST_TIMEOUT_SCALE")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .filter(|scale| *scale > 0)
        .unwrap_or(1);
    duration.saturating_mul(scale)
}

fn socket_path() -> PathBuf {
    std::env::temp_dir().join(format!(
        "cmux-sidebar-test-{}-{}.sock",
        std::process::id(),
        NEXT_SOCKET.fetch_add(1, Ordering::Relaxed)
    ))
}

fn request(reader: &mut BufReader<UnixStream>) -> Value {
    let mut line = String::new();
    assert_ne!(reader.read_line(&mut line).unwrap(), 0);
    let value: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(value["protocol"], "cmux.protocol/2");
    assert_eq!(value["type"], "request");
    value
}

fn success(stream: &mut UnixStream, request: &Value, result: Value) {
    writeln!(
        stream,
        "{}",
        json!({
            "protocol": "cmux.protocol/2",
            "type": "response",
            "id": request["id"],
            "ok": true,
            "result": result
        })
    )
    .unwrap();
}

fn mutation_result(request: &Value, value: Value) -> Value {
    assert!(request["idempotency_key"].is_string());
    json!({
        "value": value,
        "generation": "sidebar-test",
        "revision": "3",
        "replayed": false
    })
}

fn sidebar_snapshot(cols: u16, rows: u16) -> Value {
    json!({
        "id": VIEW,
        "session_id": SESSION,
        "cols": cols,
        "rows": rows,
        "running": true
    })
}

fn render_cursor() -> Value {
    json!({
        "x": 0,
        "y": 0,
        "style": "block",
        "blink": false,
        "visible": false,
        "color": null
    })
}

fn snapshot(stream: &mut UnixStream, stream_id: &str, sequence: u64) {
    writeln!(
        stream,
        "{}",
        json!({
            "protocol": "cmux.protocol/2",
            "type": "stream_item",
            "stream_id": stream_id,
            "sequence": sequence.to_string(),
            "item": {
                "kind": "snapshot",
                "sidebar_view": sidebar_snapshot(32, 2),
                "render": {
                    "size": {"cols": 32, "rows": 2},
                    "cursor": render_cursor(),
                    "default_fg": "#ffffff",
                    "default_bg": "#000000",
                    "scrollback_rows": 0,
                    "rows": [
                        {
                            "row": 0,
                            "runs": [{
                                "text": "agent one",
                                "fg": "#00ff00",
                                "bg": null,
                                "attrs": 1
                            }]
                        },
                        {
                            "row": 1,
                            "runs": [{
                                "text": "agent two",
                                "fg": null,
                                "bg": null,
                                "attrs": 0
                            }]
                        }
                    ]
                }
            }
        })
    )
    .unwrap();
}

fn patch(stream: &mut UnixStream, stream_id: &str, sequence: u64, text: &str) {
    writeln!(
        stream,
        "{}",
        json!({
            "protocol": "cmux.protocol/2",
            "type": "stream_item",
            "stream_id": stream_id,
            "sequence": sequence.to_string(),
            "item": {
                "kind": "patch",
                "sidebar_view_id": VIEW,
                "render": {
                    "cursor": render_cursor(),
                    "full_reset": false,
                    "rows": [{
                        "row": 0,
                        "runs": [{
                            "text": text,
                            "fg": null,
                            "bg": null,
                            "attrs": 0
                        }]
                    }]
                }
            }
        })
    )
    .unwrap();
}

fn end_canceled(stream: &mut UnixStream, stream_id: &str) {
    writeln!(
        stream,
        "{}",
        json!({
            "protocol": "cmux.protocol/2",
            "type": "stream_end",
            "stream_id": stream_id,
            "reason": "canceled"
        })
    )
    .unwrap();
}

fn end_gap(stream: &mut UnixStream, stream_id: &str) {
    writeln!(
        stream,
        "{}",
        json!({
            "protocol": "cmux.protocol/2",
            "type": "stream_end",
            "stream_id": stream_id,
            "reason": "gap",
            "cursor": {
                "generation": "sidebar-test",
                "revision": "9"
            },
            "recovery": "reopen_from_snapshot"
        })
    )
    .unwrap();
}

#[test]
fn runtime_receives_render_snapshots_forwards_input_and_cancels_cleanly() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (mut control, _) = listener.accept().unwrap();
        let mut control_reader = BufReader::new(control.try_clone().unwrap());

        let resize = request(&mut control_reader);
        assert_eq!(resize["operation"], "sidebar_view.resize");
        assert_eq!(
            resize["params"],
            json!({
                "machine": "current",
                "session": SESSION,
                "sidebar_view": VIEW,
                "cols": 32,
                "rows": 2
            })
        );
        success(&mut control, &resize, mutation_result(&resize, sidebar_snapshot(32, 2)));

        let (mut stream, _) = listener.accept().unwrap();
        let mut stream_reader = BufReader::new(stream.try_clone().unwrap());
        let attach = request(&mut stream_reader);
        assert_eq!(attach["operation"], "sidebar_view.attach");
        let stream_id = attach["params"]["stream_id"].as_str().unwrap().to_string();
        assert_eq!(
            attach["params"],
            json!({
                "machine": "current",
                "session": SESSION,
                "sidebar_view": VIEW,
                "stream_id": stream_id
            })
        );
        success(&mut stream, &attach, json!({"stream_id": stream_id}));
        snapshot(&mut stream, &stream_id, 0);

        let input = request(&mut control_reader);
        assert_eq!(input["operation"], "sidebar_view.input");
        let encoded = input["params"]["data_base64"].as_str().unwrap();
        let decoded = base64::engine::general_purpose::STANDARD.decode(encoded).unwrap();
        let event: Value = serde_json::from_slice(&decoded).unwrap();
        assert_eq!(event["kind"], "key");
        assert_eq!(event["code"], "j");
        success(&mut control, &input, mutation_result(&input, json!({})));

        let cancel = request(&mut stream_reader);
        assert_eq!(cancel["operation"], "stream.cancel");
        assert_eq!(
            cancel["params"],
            json!({
                "machine": "current",
                "session": SESSION,
                "stream": stream_id
            })
        );
        success(&mut stream, &cancel, json!({}));
        end_canceled(&mut stream, &stream_id);
    });

    let client =
        cmux::Client::connect(Config::from_socket_path(&path).with_timeout(Duration::from_secs(2)))
            .unwrap();
    let view = client
        .session(SessionId::parse(SESSION).unwrap())
        .sidebar_view(SidebarViewId::parse(VIEW).unwrap());
    let mut runtime = SidebarRuntime::start(
        view,
        SidebarConfig {
            queue_capacity: 4,
            initial_columns: Some(32),
            initial_rows: Some(2),
            fallback_title: "Workers".to_string(),
        },
    )
    .unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    while runtime.poll_updates() == 0 {
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(runtime.model().title, "Workers");
    assert_eq!(runtime.model().rows.len(), 2);
    assert_eq!(runtime.model().rows[0].runs[0].text, "agent one");
    runtime
        .handle_event(&Event::Key(KeyEvent::new(KeyCode::Char('j'), KeyModifiers::NONE)))
        .unwrap();
    runtime.shutdown().unwrap();
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn runtime_remains_attached_across_idle_request_timeout_and_accepts_late_snapshot() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let request_timeout = test_duration(Duration::from_millis(250));
    let (release_snapshot_tx, release_snapshot_rx) = mpsc::channel();
    let (snapshot_sent_tx, snapshot_sent_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let (control, _) = listener.accept().unwrap();
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let attach = request(&mut reader);
        assert_eq!(attach["operation"], "sidebar_view.attach");
        let stream_id = attach["params"]["stream_id"].as_str().unwrap().to_string();
        success(&mut stream, &attach, json!({"stream_id": stream_id}));

        release_snapshot_rx.recv_timeout(test_duration(Duration::from_secs(2))).unwrap();
        snapshot(&mut stream, &stream_id, 0);
        snapshot_sent_tx.send(()).unwrap();

        let cancel = request(&mut reader);
        assert_eq!(cancel["operation"], "stream.cancel");
        success(&mut stream, &cancel, json!({}));
        end_canceled(&mut stream, &stream_id);
        drop(control);
    });

    let client =
        cmux::Client::connect(Config::from_socket_path(&path).with_timeout(request_timeout))
            .unwrap();
    let view = client
        .session(SessionId::parse(SESSION).unwrap())
        .sidebar_view(SidebarViewId::parse(VIEW).unwrap());
    let mut runtime = SidebarRuntime::start(view, SidebarConfig::default()).unwrap();

    thread::sleep(request_timeout.saturating_mul(2));
    assert_eq!(runtime.poll_updates(), 0);
    assert!(matches!(runtime.state(), SidebarRuntimeState::Attached));
    assert!(runtime.model().error.is_none());
    release_snapshot_tx.send(()).unwrap();
    snapshot_sent_rx.recv_timeout(test_duration(Duration::from_secs(2))).unwrap();
    let deadline = Instant::now() + test_duration(Duration::from_secs(1));
    while runtime.poll_updates() == 0 {
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(5));
    }
    assert!(matches!(runtime.state(), SidebarRuntimeState::Attached));
    assert_eq!(runtime.model().rows[0].runs[0].text, "agent one");

    runtime.shutdown().unwrap();
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn bounded_queue_overflow_cancels_and_reports_recovery() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let (overflow_tx, overflow_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let (control, _) = listener.accept().unwrap();
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let attach = request(&mut reader);
        let stream_id = attach["params"]["stream_id"].as_str().unwrap().to_string();
        success(&mut stream, &attach, json!({"stream_id": stream_id}));
        snapshot(&mut stream, &stream_id, 0);
        patch(&mut stream, &stream_id, 1, "two");
        patch(&mut stream, &stream_id, 2, "three");
        let cancel = request(&mut reader);
        assert_eq!(cancel["operation"], "stream.cancel");
        success(&mut stream, &cancel, json!({}));
        end_canceled(&mut stream, &stream_id);
        overflow_tx.send(()).unwrap();
        drop(control);
    });

    let client = cmux::Client::connect(
        Config::from_socket_path(&path).with_timeout(test_duration(Duration::from_secs(2))),
    )
    .unwrap();
    let view = client
        .session(SessionId::parse(SESSION).unwrap())
        .sidebar_view(SidebarViewId::parse(VIEW).unwrap());
    let mut runtime = SidebarRuntime::start(
        view,
        SidebarConfig { queue_capacity: 1, ..SidebarConfig::default() },
    )
    .unwrap();
    overflow_rx
        .recv_timeout(test_duration(Duration::from_secs(2)))
        .expect("sidebar worker did not cancel the overflowing stream");
    let deadline = Instant::now() + test_duration(Duration::from_secs(2));
    loop {
        runtime.poll_updates();
        if runtime.model().error.is_some() {
            break;
        }
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(5));
    }
    assert!(runtime.model().error.as_deref().unwrap().contains("overflowed"));
    runtime.shutdown().unwrap();
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn preserves_structured_gap_and_reattaches_without_discarding_the_last_frame() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (control, _) = listener.accept().unwrap();

        let (mut first, _) = listener.accept().unwrap();
        let mut first_reader = BufReader::new(first.try_clone().unwrap());
        let first_attach = request(&mut first_reader);
        let first_id = first_attach["params"]["stream_id"].as_str().unwrap().to_string();
        success(&mut first, &first_attach, json!({"stream_id": first_id}));
        snapshot(&mut first, &first_id, 0);
        end_gap(&mut first, &first_id);

        let (mut second, _) = listener.accept().unwrap();
        let mut second_reader = BufReader::new(second.try_clone().unwrap());
        let second_attach = request(&mut second_reader);
        let second_id = second_attach["params"]["stream_id"].as_str().unwrap().to_string();
        success(&mut second, &second_attach, json!({"stream_id": second_id}));
        patch(&mut second, &second_id, 0, "recovered");

        let cancel = request(&mut second_reader);
        assert_eq!(cancel["operation"], "stream.cancel");
        success(&mut second, &cancel, json!({}));
        end_canceled(&mut second, &second_id);
        drop(control);
    });

    let client =
        cmux::Client::connect(Config::from_socket_path(&path).with_timeout(Duration::from_secs(2)))
            .unwrap();
    let view = client
        .session(SessionId::parse(SESSION).unwrap())
        .sidebar_view(SidebarViewId::parse(VIEW).unwrap());
    let mut runtime = SidebarRuntime::start(view, SidebarConfig::default()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        runtime.poll_updates();
        if matches!(
            runtime.state(),
            SidebarRuntimeState::Ended(end) if end.reason == StreamEndReason::Gap
        ) {
            break;
        }
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(5));
    }
    let SidebarRuntimeState::Ended(gap) = runtime.state() else {
        unreachable!();
    };
    assert_eq!(gap.cursor.as_ref().unwrap().revision, 9);
    assert_eq!(gap.recovery.as_deref(), Some("reopen_from_snapshot"));
    assert_eq!(runtime.model().rows[0].runs[0].text, "agent one");

    runtime.reattach().unwrap();
    loop {
        runtime.poll_updates();
        if runtime.model().rows.first().is_some_and(|row| row.runs[0].text == "recovered") {
            break;
        }
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(5));
    }
    assert!(matches!(runtime.state(), SidebarRuntimeState::Attached));

    runtime.shutdown().unwrap();
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}
