use base64::Engine;
use cmux::{Client, Config, SessionId, SidebarViewId, StreamEndReason};
use cmux_sidebar_monitor_example::{MonitorConfig, MonitorPhase, SidebarMonitor};
use crossterm::event::{Event, KeyCode, KeyEvent, KeyModifiers};
use ratatui::Terminal;
use ratatui::backend::TestBackend;
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

fn socket_path() -> PathBuf {
    std::env::temp_dir().join(format!(
        "cmux-sidebar-monitor-{}-{}.sock",
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
    let response = json!({
        "protocol": "cmux.protocol/2",
        "type": "response",
        "id": request["id"],
        "ok": true,
        "result": result
    });
    drop(result);
    writeln!(stream, "{response}").unwrap();
}

fn mutation_result(request: &Value, value: Value, revision: u64) -> Value {
    assert!(request["idempotency_key"].is_string());
    let result = json!({
        "value": value,
        "generation": "monitor-test",
        "revision": revision.to_string(),
        "replayed": false
    });
    drop(value);
    result
}

fn sidebar_snapshot(columns: u16, rows: u16) -> Value {
    json!({
        "id": VIEW,
        "session_id": SESSION,
        "cols": columns,
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

fn accept_attachment(listener: &UnixListener) -> (UnixStream, BufReader<UnixStream>, String) {
    let (mut stream, _) = listener.accept().unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let attach = request(&mut reader);
    assert_eq!(attach["operation"], "sidebar_view.attach");
    assert_eq!(attach["params"]["machine"], "current");
    assert_eq!(attach["params"]["session"], SESSION);
    assert_eq!(attach["params"]["sidebar_view"], VIEW);
    let stream_id = attach["params"]["stream_id"].as_str().unwrap().to_string();
    success(&mut stream, &attach, json!({"stream_id": stream_id}));
    (stream, reader, stream_id)
}

fn send_snapshot(stream: &mut UnixStream, stream_id: &str, text: &str) {
    writeln!(
        stream,
        "{}",
        json!({
            "protocol": "cmux.protocol/2",
            "type": "stream_item",
            "stream_id": stream_id,
            "sequence": "0",
            "cursor": {"generation": "monitor-test", "revision": "4"},
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
                                "text": text,
                                "fg": "#00ff00",
                                "bg": null,
                                "attrs": 1
                            }]
                        },
                        {
                            "row": 1,
                            "runs": [{
                                "text": "press r to reload",
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

fn send_patch(stream: &mut UnixStream, stream_id: &str, sequence: u64, text: &str) {
    writeln!(
        stream,
        "{}",
        json!({
            "protocol": "cmux.protocol/2",
            "type": "stream_item",
            "stream_id": stream_id,
            "sequence": sequence.to_string(),
            "cursor": {"generation": "monitor-test", "revision": "5"},
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
                            "fg": "#00ffff",
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

fn send_unknown(stream: &mut UnixStream, stream_id: &str) {
    writeln!(
        stream,
        "{}",
        json!({
            "protocol": "cmux.protocol/2",
            "type": "stream_item",
            "stream_id": stream_id,
            "sequence": "1",
            "item": {
                "kind": "future_badge",
                "badge": {"text": "new in 1.1"}
            }
        })
    )
    .unwrap();
}

fn send_end(
    stream: &mut UnixStream,
    stream_id: &str,
    reason: &str,
    revision: u64,
    recovery: Option<&str>,
) {
    let mut envelope = json!({
        "protocol": "cmux.protocol/2",
        "type": "stream_end",
        "stream_id": stream_id,
        "reason": reason,
        "cursor": {
            "generation": "monitor-test",
            "revision": revision.to_string()
        }
    });
    if let Some(recovery) = recovery {
        envelope["recovery"] = Value::String(recovery.to_string());
    }
    writeln!(stream, "{envelope}").unwrap();
}

fn connect(path: &PathBuf) -> Client {
    Client::connect(
        Config::from_socket_path(path)
            .with_timeout(Duration::from_secs(3))
            .with_stream_limits(32, 1024 * 1024),
    )
    .unwrap()
}

fn view(client: &Client) -> cmux::SidebarView {
    client
        .session(SessionId::parse(SESSION).unwrap())
        .sidebar_view(SidebarViewId::parse(VIEW).unwrap())
}

fn wait_until(monitor: &mut SidebarMonitor, condition: impl Fn(&SidebarMonitor) -> bool) {
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        monitor.poll_updates().unwrap();
        if condition(monitor) {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "monitor condition timed out: status={:?}, model={:?}",
            monitor.status(),
            monitor.model()
        );
        thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn recovers_gap_preserves_unknown_events_handles_control_and_terminal_end() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (mut control, _) = listener.accept().unwrap();
        control.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
        let mut control_reader = BufReader::new(control.try_clone().unwrap());

        let (mut first, _first_reader, first_id) = accept_attachment(&listener);
        send_snapshot(&mut first, &first_id, "before gap");
        send_end(&mut first, &first_id, "gap", 4, Some("reopen_from_snapshot"));

        let (mut second, _second_reader, second_id) = accept_attachment(&listener);
        send_snapshot(&mut second, &second_id, "after gap");
        send_unknown(&mut second, &second_id);

        let resize = request(&mut control_reader);
        assert_eq!(resize["operation"], "sidebar_view.resize");
        assert_eq!(resize["params"]["cols"], 40);
        assert_eq!(resize["params"]["rows"], 12);
        success(&mut control, &resize, mutation_result(&resize, sidebar_snapshot(40, 12), 5));

        let input = request(&mut control_reader);
        assert_eq!(input["operation"], "sidebar_view.input");
        let encoded = input["params"]["data_base64"].as_str().unwrap();
        let data = base64::engine::general_purpose::STANDARD.decode(encoded).unwrap();
        let event: Value = serde_json::from_slice(&data).unwrap();
        assert_eq!(event["kind"], "key");
        assert_eq!(event["code"], "j");
        success(&mut control, &input, mutation_result(&input, json!({}), 6));

        let reload = request(&mut control_reader);
        assert_eq!(reload["operation"], "sidebar_view.reload");
        success(&mut control, &reload, mutation_result(&reload, sidebar_snapshot(40, 12), 7));
        send_patch(&mut second, &second_id, 2, "reloaded");
        send_end(&mut second, &second_id, "completed", 7, None);
    });

    let client = connect(&path);
    let mut monitor = SidebarMonitor::start(
        view(&client),
        MonitorConfig {
            queue_capacity: 16,
            max_recoveries: 2,
            recovery_delay: Duration::ZERO,
            title: "Agents".to_string(),
        },
    )
    .unwrap();

    wait_until(&mut monitor, |monitor| {
        monitor.status().gap_recoveries == 1
            && monitor.model().rows.first().is_some_and(|row| row.runs[0].text == "after gap")
    });
    assert_eq!(monitor.model().status.as_deref(), Some("unknown event: future_badge"));
    assert_eq!(monitor.model().unknown_events, 1);
    let unknown = monitor.model().last_unknown.as_ref().unwrap();
    assert_eq!(unknown.kind, "future_badge");
    let raw: Value = unknown.raw.deserialize().unwrap();
    assert_eq!(raw["kind"], "future_badge");
    assert_eq!(raw["badge"]["text"], "new in 1.1");
    let gap = monitor.status().last_gap.as_ref().unwrap();
    assert_eq!(gap.reason, StreamEndReason::Gap);
    assert_eq!(gap.recovery.as_deref(), Some("reopen_from_snapshot"));
    assert_eq!(gap.cursor.as_ref().unwrap().revision, 4);

    monitor.resize(40, 12).unwrap();
    assert!(
        monitor
            .handle_event(&Event::Key(KeyEvent::new(KeyCode::Char('j'), KeyModifiers::NONE,)))
            .unwrap()
    );
    monitor.reload().unwrap();

    wait_until(&mut monitor, |monitor| {
        matches!(monitor.status().phase, MonitorPhase::Ended(StreamEndReason::Completed))
    });
    assert_eq!(monitor.model().rows[0].runs[0].text, "reloaded");
    let end = monitor.status().terminal_end.as_ref().unwrap();
    assert_eq!(end.reason, StreamEndReason::Completed);
    assert_eq!(end.cursor.as_ref().unwrap().revision, 7);

    let backend = TestBackend::new(48, 8);
    let mut terminal = Terminal::new(backend).unwrap();
    terminal.draw(|frame| frame.render_widget(monitor.widget(), frame.area())).unwrap();
    let rendered = terminal
        .backend()
        .buffer()
        .content
        .iter()
        .map(ratatui::buffer::Cell::symbol)
        .collect::<String>();
    assert!(rendered.contains("Agents"));
    assert!(rendered.contains("reloaded"));
    assert!(rendered.contains("ended: completed"));

    monitor.shutdown().unwrap();
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn shutdown_cancels_the_current_recovered_lease_and_waits_for_canceled_end() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (control, _) = listener.accept().unwrap();
        let (mut stream, mut reader, stream_id) = accept_attachment(&listener);
        send_snapshot(&mut stream, &stream_id, "live");

        let cancel = request(&mut reader);
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
        send_end(&mut stream, &stream_id, "canceled", 4, None);
        drop(control);
    });

    let client = connect(&path);
    let mut monitor = SidebarMonitor::start(
        view(&client),
        MonitorConfig { recovery_delay: Duration::ZERO, ..MonitorConfig::default() },
    )
    .unwrap();
    wait_until(&mut monitor, |monitor| {
        monitor.model().rows.first().is_some_and(|row| row.runs[0].text == "live")
    });
    monitor.shutdown().unwrap();
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn bounded_local_queue_recovers_by_canceling_and_reopening_for_a_snapshot() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let (overflow_sender, overflow_receiver) = mpsc::channel();
    let (resume_sender, resume_receiver) = mpsc::channel();
    let server = thread::spawn(move || {
        let (control, _) = listener.accept().unwrap();
        let (mut first, mut first_reader, first_id) = accept_attachment(&listener);
        send_snapshot(&mut first, &first_id, "queued");
        send_patch(&mut first, &first_id, 1, "overflow");

        let cancel = request(&mut first_reader);
        assert_eq!(cancel["operation"], "stream.cancel");
        overflow_sender.send(()).unwrap();
        success(&mut first, &cancel, json!({}));
        send_end(&mut first, &first_id, "canceled", 5, None);

        let (mut second, mut second_reader, second_id) = accept_attachment(&listener);
        resume_receiver.recv_timeout(Duration::from_secs(3)).unwrap();
        send_snapshot(&mut second, &second_id, "recovered from local overflow");

        let cancel = request(&mut second_reader);
        assert_eq!(cancel["operation"], "stream.cancel");
        success(&mut second, &cancel, json!({}));
        send_end(&mut second, &second_id, "canceled", 6, None);
        drop(control);
    });

    let client = connect(&path);
    let mut monitor = SidebarMonitor::start(
        view(&client),
        MonitorConfig {
            queue_capacity: 1,
            max_recoveries: 2,
            recovery_delay: Duration::ZERO,
            title: "Bounded".to_string(),
        },
    )
    .unwrap();
    overflow_receiver.recv_timeout(Duration::from_secs(3)).unwrap();
    monitor.poll_updates().unwrap();
    resume_sender.send(()).unwrap();
    wait_until(&mut monitor, |monitor| {
        monitor.status().local_queue_recoveries == 1
            && monitor
                .model()
                .rows
                .first()
                .is_some_and(|row| row.runs[0].text == "recovered from local overflow")
    });

    monitor.shutdown().unwrap();
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn rejects_unbounded_configuration_before_opening_a_stream() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let client = connect(&path);
    let error = SidebarMonitor::start(
        view(&client),
        MonitorConfig { queue_capacity: 0, ..MonitorConfig::default() },
    )
    .err()
    .unwrap();
    assert!(error.to_string().contains("queue_capacity"));
    drop(listener);
    client.close().unwrap();
    std::fs::remove_file(path).unwrap();
}
