use cmux::{
    BrowserAttachOptions, BrowserCreateOptions, BrowserId, BrowserMouseButton, BrowserMouseKind,
    BrowserMouseOptions, CancellationToken, CellPixelsOptions, ClientMetadataOptions,
    ClientSizingOptions, Config, CopyOptions, CreatePaneOptions, CreateScreenOptions,
    CreateWorkspaceOptions, CreationRecovery, CreationState, Direction, Error, EventStreamOptions,
    InitialContent, LabelOptions, MutationOptions, PairingDecision, PairingResolveOptions,
    PixelSize, ReadHistoryOptions, ReadScreenOptions, RendererGrantOptions, RequestOptions,
    ResourceChange, ResourceEntitySnapshot, RunCommand, RunOptions, Selector, SessionEvent,
    SessionId, ShutdownOptions, Size, SplitOptions, StreamEndReason, StreamPoll,
    TerminalAttachOptions, TerminalCreateOptions, TerminalDefaultsOptions, TerminalExitOutcome,
    TerminalId, TerminalLifecycle, TerminalSnapshot, TerminalWaitExitResult, UndoLayoutOptions,
    Update, WaitOptions, WheelOptions, WorkspaceId,
};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

const MACHINE: &str = "machine_00000000000000000000000000000001";
const SESSION: &str = "session_00000000000000000000000000000002";
const WORKSPACE_A: &str = "ws_00000000000000000000000000000003";
const WORKSPACE_B: &str = "ws_00000000000000000000000000000004";
const SCREEN: &str = "screen_00000000000000000000000000000005";
const PANE: &str = "pane_00000000000000000000000000000006";
const TAB: &str = "tab_00000000000000000000000000000007";
const TERMINAL: &str = "term_00000000000000000000000000000008";
const BROWSER: &str = "browser_0000000000000000000000000000000d";
const CLIENT: &str = "client_00000000000000000000000000000009";
const PAIRING_REQUEST: &str = "pairing_0000000000000000000000000000000c";

static NEXT_SOCKET: AtomicU64 = AtomicU64::new(1);

fn socket_path() -> PathBuf {
    std::env::temp_dir().join(format!(
        "cmux-resource-rust-test-{}-{}.sock",
        std::process::id(),
        NEXT_SOCKET.fetch_add(1, Ordering::Relaxed)
    ))
}

fn scaled_test_duration(duration: Duration) -> Duration {
    let scale = std::env::var("CMUX_TEST_TIMEOUT_SCALE")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(1)
        .max(1);
    duration.saturating_mul(scale)
}

fn request(reader: &mut BufReader<UnixStream>) -> Value {
    let mut line = String::new();
    assert_ne!(reader.read_line(&mut line).unwrap(), 0);
    let value: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(value["protocol"], "cmux.protocol/2");
    assert_eq!(value["type"], "request");
    assert!(value["id"].is_string());
    assert!(value["params"].is_object());
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
            "result": result,
        })
    )
    .unwrap();
}

fn failure(stream: &mut UnixStream, request: &Value, code: &str, message: &str, details: Value) {
    writeln!(
        stream,
        "{}",
        json!({
            "protocol": "cmux.protocol/2",
            "type": "response",
            "id": request["id"],
            "ok": false,
            "error": {
                "code": code,
                "message": message,
                "details": details,
                "retryable": false,
            },
        })
    )
    .unwrap();
}

fn assert_connection_closed_without_request(reader: &mut BufReader<UnixStream>, context: &str) {
    if reader.get_ref().set_read_timeout(Some(Duration::from_millis(500))).is_err() {
        // macOS can reject SO_RCVTIMEO after the peer has already shut down
        // both halves. A nonblocking read still distinguishes EOF from a live
        // connection without allowing the test to hang.
        reader
            .get_ref()
            .set_nonblocking(true)
            .unwrap_or_else(|error| panic!("{context} close setup failed: {error}"));
    }
    let mut possible_request = String::new();
    match reader.read_line(&mut possible_request) {
        Ok(0) => {}
        Ok(_) => panic!("{context} sent an unexpected request: {possible_request}"),
        Err(error)
            if matches!(
                error.kind(),
                std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
            ) =>
        {
            panic!("{context} did not close its dedicated connection")
        }
        Err(error) => panic!("{context} close check failed: {error}"),
    }
}

fn mutation_result(request: &Value, value: Value) -> Value {
    assert!(request["idempotency_key"].is_string());
    json!({
        "value": value,
        "generation": "generation-a",
        "revision": "17",
        "replayed": false
    })
}

fn machine_snapshot() -> Value {
    json!({
        "id": MACHINE,
        "name": "fixture",
        "origin": "local",
        "status": "running",
        "connectable": true,
        "deleted": false,
        "recoverable": false
    })
}

fn client_snapshot() -> Value {
    json!({
        "id": CLIENT,
        "session_id": SESSION,
        "name": null,
        "client_kind": null,
        "transport": "unix",
        "connected_seconds": "1",
        "attached_terminal_ids": [],
        "sizes": [],
        "self": true
    })
}

fn screen_snapshot(name: Value) -> Value {
    json!({
        "id": SCREEN,
        "workspace_id": WORKSPACE_A,
        "name": name,
        "index": 0,
        "focused": true,
        "layout": {
            "version": 1,
            "screen_id": SCREEN,
            "active_pane_id": PANE,
            "zoomed_pane_id": null,
            "root": {
                "kind": "leaf",
                "pane_id": PANE,
                "tab_ids": []
            }
        }
    })
}

fn terminal_screen(text: &str) -> Value {
    json!({
        "text": text,
        "cols": 80,
        "rows": 24,
        "cursor_row": 0,
        "cursor_col": 0,
        "cursor_visible": true
    })
}

fn session_snapshot(revision: &str) -> Value {
    json!({
        "id": SESSION,
        "machine_id": MACHINE,
        "generation": "g",
        "revision": revision,
        "connected": true
    })
}

fn terminal_snapshot() -> Value {
    json!({
        "id": TERMINAL,
        "tab_ids": [TAB],
        "title": "fixture",
        "cwd": "/tmp",
        "cols": 80,
        "rows": 24,
        "running": true,
        "lifecycle": "running"
    })
}

fn resource_snapshot() -> Value {
    json!({
        "machine": machine_snapshot(),
        "session": session_snapshot("1"),
        "workspaces": [],
        "screens": [],
        "panes": [],
        "tabs": [],
        "terminals": [],
        "browsers": [],
        "clients": [],
        "notifications": [],
        "agents": [],
        "frontend_projections": [],
        "sidebar_views": [],
        "cursor": {"generation": "g", "revision": "1"}
    })
}

fn connect(path: &PathBuf) -> cmux::Client {
    cmux::Client::connect(Config::from_socket_path(path).with_timeout(Duration::from_secs(2)))
        .unwrap()
}

#[test]
fn duplicate_names_return_all_exact_matches_without_collapsing() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let request = request(&mut BufReader::new(stream.try_clone().unwrap()));
        assert_eq!(request["operation"], "workspace.list");
        assert_eq!(request["params"], json!({"machine": "current", "session": "current"}));
        assert!(request.get("idempotency_key").is_none());
        success(
            &mut stream,
            &request,
            json!([
                {"id": WORKSPACE_A, "name": "api", "session_id": SESSION, "index": 0, "focused": true},
                {"id": WORKSPACE_B, "name": "api", "session_id": SESSION, "index": 1, "focused": false},
                {
                    "id": "ws_0000000000000000000000000000000a",
                    "name": "other",
                    "session_id": SESSION,
                    "index": 2,
                    "focused": false
                }
            ]),
        );
    });

    let client = connect(&path);
    let workspaces = client.current_session().find_workspaces_by_name("api").unwrap();
    assert_eq!(workspaces.len(), 2);
    assert_eq!(workspaces[0].id().unwrap().as_str(), WORKSPACE_A);
    assert_eq!(workspaces[1].id().unwrap().as_str(), WORKSPACE_B);
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn create_and_run_preserve_receipts_paths_and_command_modes() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());

        let create = request(&mut reader);
        assert_eq!(create["operation"], "workspace.create");
        assert_eq!(create["idempotency_key"], "create-key");
        assert_eq!(
            create["params"],
            json!({
                "machine": "current",
                "session": SESSION,
                "name": "",
                "initial_content": "empty",
                "expected_revision": "16"
            })
        );
        success(
            &mut stream,
            &create,
            mutation_result(&create, json!({"kind": "workspace", "workspace_id": WORKSPACE_A})),
        );

        let exact = request(&mut reader);
        assert_eq!(exact["operation"], "workspace.run");
        assert_eq!(exact["params"]["workspace"], WORKSPACE_A);
        assert_eq!(exact["params"]["argv"], json!(["printf", "", "$HOME"]));
        assert!(exact["params"].get("shell").is_none());
        success(
            &mut stream,
            &exact,
            mutation_result(
                &exact,
                json!({
                    "kind": "terminal",
                    "workspace_id": WORKSPACE_A,
                    "screen_id": SCREEN,
                    "pane_id": PANE,
                    "tab_id": TAB,
                    "terminal_id": TERMINAL
                }),
            ),
        );

        let shell = request(&mut reader);
        assert_eq!(shell["operation"], "workspace.run");
        assert_eq!(shell["params"]["shell"], "printf '%s' \"$HOME\"");
        assert!(shell["params"].get("argv").is_none());
        success(
            &mut stream,
            &shell,
            mutation_result(
                &shell,
                json!({
                    "kind": "terminal",
                    "workspace_id": WORKSPACE_A,
                    "screen_id": SCREEN,
                    "pane_id": PANE,
                    "tab_id": TAB,
                    "terminal_id": TERMINAL
                }),
            ),
        );
    });

    let client = connect(&path);
    let session = client.session(SessionId::parse(SESSION).unwrap());
    let created = session
        .create_workspace_with(
            CreateWorkspaceOptions {
                name: Some(String::new()),
                initial_content: InitialContent::Empty,
                correlation_key: None,
            },
            MutationOptions::new("create-key").unwrap().with_expected_revision(16),
        )
        .unwrap();
    assert_eq!(created.resource.id().unwrap().as_str(), WORKSPACE_A);
    assert_eq!(created.generation, "generation-a");
    assert_eq!(created.revision, 17);
    assert!(!created.replayed);

    let exact = created.resource.run(RunCommand::argv(["printf", "", "$HOME"]).unwrap()).unwrap();
    assert_eq!(exact.resource.id().unwrap().as_str(), TERMINAL);
    assert_eq!(exact.value.tab_id().unwrap().as_str(), TAB);

    created.resource.run(RunCommand::shell("printf '%s' \"$HOME\"").unwrap()).unwrap();
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn every_created_path_operation_sends_a_validated_correlation_key() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        for operation in [
            "workspace.create",
            "workspace.run",
            "screen.create",
            "pane.create",
            "pane.run",
            "pane.split",
            "tab.create_terminal",
            "tab.create_browser",
        ] {
            let request = request(&mut reader);
            assert_eq!(request["operation"], operation);
            assert_eq!(request["params"]["correlation_key"], "creation-correlation");
            if operation == "pane.split" {
                assert_eq!(request["params"]["viewport_width"], 0.5);
            }
            writeln!(
                stream,
                "{}",
                json!({
                    "protocol": "cmux.protocol/2",
                    "type": "response",
                    "id": request["id"],
                    "ok": false,
                    "error": {
                        "code": "operation.failed",
                        "message": "fixture stop",
                        "details": {
                            "operation": operation,
                            "reason": "fixture"
                        },
                        "retryable": false
                    }
                })
            )
            .unwrap();
        }
    });

    let invalid = CreateScreenOptions::default().correlation_key("").unwrap_err();
    assert!(matches!(invalid, Error::InvalidArgument(_)));
    let invalid = CreateScreenOptions::default().correlation_key("🔥".repeat(33)).unwrap_err();
    assert!(matches!(invalid, Error::InvalidArgument(_)));

    let client = connect(&path);
    let session = client.session(SessionId::parse(SESSION).unwrap());
    let workspace = session.workspace(WorkspaceId::parse(WORKSPACE_A).unwrap());
    let screen = workspace.screen(cmux::ScreenId::parse(SCREEN).unwrap());
    let pane = screen.pane(cmux::PaneId::parse(PANE).unwrap());
    session
        .create_workspace_with(
            CreateWorkspaceOptions::default().correlation_key("creation-correlation").unwrap(),
            MutationOptions::new("correlation-1").unwrap(),
        )
        .err()
        .unwrap();
    workspace
        .run_with(
            RunOptions::command(RunCommand::argv(["true"]).unwrap())
                .correlation_key("creation-correlation")
                .unwrap(),
            MutationOptions::new("correlation-2").unwrap(),
        )
        .err()
        .unwrap();
    workspace
        .create_screen_with(
            CreateScreenOptions::default().correlation_key("creation-correlation").unwrap(),
            MutationOptions::new("correlation-3").unwrap(),
        )
        .err()
        .unwrap();
    screen
        .create_pane_with(
            CreatePaneOptions::default().correlation_key("creation-correlation").unwrap(),
            MutationOptions::new("correlation-4").unwrap(),
        )
        .err()
        .unwrap();
    pane.run_with(
        RunOptions::command(RunCommand::argv(["true"]).unwrap())
            .correlation_key("creation-correlation")
            .unwrap(),
        MutationOptions::new("correlation-5").unwrap(),
    )
    .err()
    .unwrap();
    pane.split_with(
        SplitOptions::new(Direction::Right)
            .viewport_width(0.5)
            .correlation_key("creation-correlation")
            .unwrap(),
        MutationOptions::new("correlation-6").unwrap(),
    )
    .err()
    .unwrap();
    pane.create_terminal_with(
        TerminalCreateOptions::default().correlation_key("creation-correlation").unwrap(),
        MutationOptions::new("correlation-7").unwrap(),
    )
    .err()
    .unwrap();
    pane.create_browser_with(
        BrowserCreateOptions::new("https://example.com")
            .correlation_key("creation-correlation")
            .unwrap(),
        MutationOptions::new("correlation-8").unwrap(),
    )
    .err()
    .unwrap();

    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn workspace_rename_preserves_the_flat_canonical_value_and_explicit_route() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let rename = request(&mut BufReader::new(stream.try_clone().unwrap()));
        assert_eq!(rename["operation"], "workspace.rename");
        assert_eq!(rename["idempotency_key"], "rename-key");
        assert_eq!(
            rename["params"],
            json!({
                "machine": "current",
                "session": SESSION,
                "workspace": WORKSPACE_A,
                "name": "renamed",
                "expected_revision": "16"
            })
        );
        success(
            &mut stream,
            &rename,
            mutation_result(
                &rename,
                json!({
                    "id": WORKSPACE_A,
                    "session_id": SESSION,
                    "name": "renamed",
                    "index": 2,
                    "focused": true
                }),
            ),
        );
    });

    let client = connect(&path);
    let renamed = client
        .session(SessionId::parse(SESSION).unwrap())
        .workspace(WorkspaceId::parse(WORKSPACE_A).unwrap())
        .rename_with(
            "renamed",
            MutationOptions::new("rename-key").unwrap().with_expected_revision(16),
        )
        .unwrap();
    assert_eq!(renamed.value.id.as_str(), WORKSPACE_A);
    assert_eq!(renamed.value.name, "renamed");
    assert_eq!(renamed.generation, "generation-a");
    assert_eq!(renamed.revision, 17);
    assert!(!renamed.replayed);
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn nullable_names_encode_clear_and_empty_distinctly() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        for expected in [Value::Null, Value::String(String::new())] {
            let rename = request(&mut reader);
            assert_eq!(rename["operation"], "screen.rename");
            assert_eq!(rename["params"]["name"], expected);
            success(&mut stream, &rename, mutation_result(&rename, screen_snapshot(expected)));
        }
    });

    let client = connect(&path);
    let screen = client
        .current_session()
        .workspace(WorkspaceId::parse(WORKSPACE_A).unwrap())
        .screen(cmux::ScreenId::parse(SCREEN).unwrap());
    screen.set_name_with(LabelOptions::clear(), MutationOptions::new("clear").unwrap()).unwrap();
    screen.set_name_with(LabelOptions::set(""), MutationOptions::new("empty").unwrap()).unwrap();
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn browser_pointer_input_encodes_required_frame_sequence_as_decimal() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());

        let mouse = request(&mut reader);
        assert_eq!(mouse["operation"], "browser.input.mouse");
        assert_eq!(
            mouse["params"],
            json!({
                "machine": "current",
                "session": SESSION,
                "browser": BROWSER,
                "kind": "down",
                "x_px": 12.5,
                "y_px": 8.25,
                "pointer_frame_seq": "18446744073709551615",
                "button": "left",
                "click_count": 2
            })
        );
        success(&mut stream, &mouse, mutation_result(&mouse, json!({})));

        let wheel = request(&mut reader);
        assert_eq!(wheel["operation"], "browser.input.wheel");
        assert_eq!(
            wheel["params"],
            json!({
                "machine": "current",
                "session": SESSION,
                "browser": BROWSER,
                "delta_x": -1.5,
                "delta_y": 2.25,
                "x_px": 100.0,
                "y_px": 200.0,
                "pointer_frame_seq": "9007199254740993"
            })
        );
        success(&mut stream, &wheel, mutation_result(&wheel, json!({})));
    });

    let client = connect(&path);
    let browser = client
        .session(SessionId::parse(SESSION).unwrap())
        .browser(BrowserId::parse(BROWSER).unwrap());
    browser
        .mouse_with(
            BrowserMouseOptions {
                kind: BrowserMouseKind::Down,
                x_px: 12.5,
                y_px: 8.25,
                pointer_frame_seq: u64::MAX,
                button: Some(BrowserMouseButton::Left),
                click_count: Some(2),
            },
            MutationOptions::new("mouse").unwrap(),
        )
        .unwrap();
    browser
        .wheel_with(
            WheelOptions {
                delta_x: -1.5,
                delta_y: 2.25,
                x_px: 100.0,
                y_px: 200.0,
                pointer_frame_seq: 9_007_199_254_740_993,
            },
            MutationOptions::new("wheel").unwrap(),
        )
        .unwrap();
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn structured_errors_retain_all_protocol_fields() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let request = request(&mut BufReader::new(stream.try_clone().unwrap()));
        writeln!(
            stream,
            "{}",
            json!({
                "protocol": "cmux.protocol/2",
                "type": "response",
                "id": request["id"],
                "ok": false,
                "error": {
                    "code": "selector.ambiguous",
                    "message": "two workspaces match",
                    "details": {"candidates": [WORKSPACE_A, WORKSPACE_B]},
                    "retryable": false
                }
            })
        )
        .unwrap();
    });

    let client = connect(&path);
    let error = client.current_session().workspace(Selector::name("api")).refresh().unwrap_err();
    match error {
        Error::Protocol { code, message, details, retryable } => {
            assert_eq!(code, "selector.ambiguous");
            assert_eq!(message, "two workspaces match");
            assert_eq!(details["candidates"].as_array().unwrap().len(), 2);
            assert!(!retryable);
        }
        other => panic!("unexpected error: {other:?}"),
    }
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn layout_undo_confirmation_token_and_details_are_typed() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let request = request(&mut BufReader::new(stream.try_clone().unwrap()));
        assert_eq!(request["operation"], "screen.layout.undo");
        assert_eq!(request["params"]["confirm_close"], true);
        assert_eq!(request["params"]["confirmation_token"], "stale-preview");
        assert_eq!(request["params"]["expected_revision"], "8");
        writeln!(
            stream,
            "{}",
            json!({
                "protocol": "cmux.protocol/2",
                "type": "response",
                "id": request["id"],
                "ok": false,
                "error": {
                    "code": "confirmation.required",
                    "message": "layout preview changed",
                    "details": {
                        "confirmation_token": "fresh-preview",
                        "revision": "9",
                        "closes_panes": [PANE]
                    },
                    "retryable": false
                }
            })
        )
        .unwrap();
    });

    let client = connect(&path);
    let screen = client
        .current_session()
        .workspace(WorkspaceId::parse(WORKSPACE_A).unwrap())
        .screen(cmux::ScreenId::parse(SCREEN).unwrap());
    let missing = screen
        .undo_layout(UndoLayoutOptions { confirm_close: true, confirmation_token: None })
        .unwrap_err();
    assert!(matches!(missing, Error::InvalidArgument(_)));
    let error = screen
        .undo_layout_with(
            UndoLayoutOptions {
                confirm_close: true,
                confirmation_token: Some("stale-preview".to_string()),
            },
            MutationOptions::new("undo-confirm").unwrap().with_expected_revision(8),
        )
        .unwrap_err();
    match error {
        Error::ConfirmationRequired { message, details } => {
            assert_eq!(message, "layout preview changed");
            assert_eq!(details.confirmation_token, "fresh-preview");
            assert_eq!(details.revision, 9);
            assert_eq!(details.closes_panes[0].as_str(), PANE);
        }
        other => panic!("unexpected error: {other:?}"),
    }
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn indeterminate_mutations_preserve_recovery_details_and_are_never_retried() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let request = request(&mut reader);
        assert_eq!(request["operation"], "workspace.rename");
        assert_eq!(request["idempotency_key"], "rename-once");
        let details = json!({
            "idempotency_key": "rename-once",
            "operation": "workspace.rename",
            "recovery": "inspect_state_then_retry_with_new_key"
        });
        writeln!(
            stream,
            "{}",
            json!({
                "protocol": "cmux.protocol/2",
                "type": "response",
                "id": request["id"],
                "ok": false,
                "error": {
                    "code": "mutation.indeterminate",
                    "message": "external effect outcome is unknown",
                    "details": details,
                    "retryable": false
                }
            })
        )
        .unwrap();

        stream.set_read_timeout(Some(Duration::from_millis(200))).unwrap();
        let mut possible_retry = String::new();
        match reader.read_line(&mut possible_retry) {
            Ok(0) => {}
            Ok(_) => panic!("SDK retried an indeterminate mutation: {possible_retry}"),
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) => {}
            Err(error) => panic!("unexpected read error: {error}"),
        }
    });

    let client = connect(&path);
    let error = client
        .current_session()
        .workspace(WorkspaceId::parse(WORKSPACE_A).unwrap())
        .rename_with("renamed", MutationOptions::new("rename-once").unwrap())
        .unwrap_err();
    match error {
        Error::Protocol { code, details, retryable, .. } => {
            assert_eq!(code, "mutation.indeterminate");
            assert_eq!(
                details,
                json!({
                    "idempotency_key": "rename-once",
                    "operation": "workspace.rename",
                    "recovery": "inspect_state_then_retry_with_new_key"
                })
            );
            assert!(!retryable);
        }
        other => panic!("unexpected error: {other:?}"),
    }
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn exact_mutation_key_is_exposed_on_transport_disconnect() {
    for explicit_key in [None, Some("caller-owned")] {
        let path = socket_path();
        let listener = UnixListener::bind(&path).unwrap();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            request(&mut BufReader::new(stream))
        });

        let client = connect(&path);
        let workspace =
            client.current_session().workspace(WorkspaceId::parse(WORKSPACE_A).unwrap());
        let error = match explicit_key {
            Some(key) => {
                workspace.rename_with("renamed", MutationOptions::new(key).unwrap()).unwrap_err()
            }
            None => workspace.rename("renamed").unwrap_err(),
        };
        let observed = server.join().unwrap();
        assert_eq!(observed["operation"], "workspace.rename");
        match (explicit_key, error) {
            (_, Error::MutationTransport { operation, idempotency_key, source }) => {
                assert_eq!(operation, "workspace.rename");
                assert_eq!(observed["idempotency_key"], idempotency_key);
                match explicit_key {
                    Some(key) => assert_eq!(idempotency_key, key),
                    None => assert!(idempotency_key.starts_with("rust-")),
                }
                assert!(matches!(*source, Error::Connection(_)));
            }
            (_, other) => panic!("unexpected disconnect error: {other:?}"),
        }
        client.close().unwrap();
        std::fs::remove_file(path).unwrap();
    }
}

#[test]
fn stream_open_requires_an_exact_success_ack_and_closes_ambiguous_transports() {
    for case in ["non-object", "missing-id", "mismatched-id", "unknown-field", "bad-cursor"] {
        let path = socket_path();
        let listener = UnixListener::bind(&path).unwrap();
        let server = thread::spawn(move || {
            let _control = listener.accept().unwrap().0;
            let (mut stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let open = request(&mut reader);
            let stream_id = open["params"]["stream_id"].as_str().unwrap().to_string();
            let result = match case {
                "non-object" => json!(stream_id),
                "missing-id" => json!({}),
                "mismatched-id" => {
                    json!({"stream_id":"stream_ffffffffffffffffffffffffffffffff"})
                }
                "unknown-field" => json!({"stream_id":stream_id,"extra":true}),
                "bad-cursor" => json!({
                    "stream_id":stream_id,
                    "cursor":{"generation":"g","revision":1},
                }),
                _ => unreachable!(),
            };
            success(&mut stream, &open, result);
            assert_connection_closed_without_request(&mut reader, case);
        });

        let client = connect(&path);
        let error = match client.current_session().events(EventStreamOptions::default()) {
            Ok(_) => panic!("{case} success ACK must fail"),
            Err(error) => error,
        };
        assert!(matches!(error, Error::UnexpectedEnvelope(_)), "{case}: {error:?}");
        client.close().unwrap();
        server.join().unwrap();
        std::fs::remove_file(path).unwrap();
    }
}

#[test]
fn valid_stream_open_rejection_preserves_the_error_without_canceling() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let _control = listener.accept().unwrap().0;
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let open = request(&mut reader);
        failure(
            &mut stream,
            &open,
            "selector.not_found",
            "sidebar is absent",
            json!({"resource":"sidebar_view","selector":"current"}),
        );
        assert_connection_closed_without_request(&mut reader, "rejected stream open");
    });

    let client = connect(&path);
    let error = match client.current_session().events(EventStreamOptions::default()) {
        Ok(_) => panic!("rejected stream open must fail"),
        Err(error) => error,
    };
    match error {
        Error::Protocol { code, message, details, retryable } => {
            assert_eq!(code, "selector.not_found");
            assert_eq!(message, "sidebar is absent");
            assert_eq!(details, json!({"resource":"sidebar_view","selector":"current"}));
            assert!(!retryable);
        }
        other => panic!("stream rejection changed error: {other:?}"),
    }
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn streams_are_typed_and_cancel_uses_the_same_scoped_connection() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let (release_tx, release_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let (control, _) = listener.accept().unwrap();
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let open = request(&mut reader);
        assert_eq!(open["operation"], "session.events");
        let stream_id = open["params"]["stream_id"].as_str().unwrap().to_string();
        success(&mut stream, &open, json!({"stream_id": stream_id}));
        release_rx.recv().unwrap();
        writeln!(
            stream,
            "{}",
            json!({
                "protocol": "cmux.protocol/2",
                "type": "stream_item",
                "stream_id": stream_id,
                "sequence": "0",
                "cursor": {"generation": "g", "revision": "1"},
                "item": {
                    "kind": "snapshot",
                    "cursor": {"generation": "g", "revision": "1"},
                    "reset_reason": "initial",
                    "snapshot": resource_snapshot()
                }
            })
        )
        .unwrap();
        writeln!(
            stream,
            "{}",
            json!({
                "protocol": "cmux.protocol/2",
                "type": "stream_item",
                "stream_id": stream_id,
                "sequence": "1",
                "cursor": {"generation": "g", "revision": "2"},
                "item": {
                    "kind": "delta",
                    "cursor": {"generation": "g", "revision": "2"},
                    "previous_revision": "1",
                    "revision": "2",
                    "changes": [{
                        "kind": "upsert",
                        "sequence": 7,
                        "resource": "terminal",
                        "id": TERMINAL,
                        "value": terminal_snapshot()
                    }]
                }
            })
        )
        .unwrap();
        writeln!(
            stream,
            "{}",
            json!({
                "protocol": "cmux.protocol/2",
                "type": "stream_item",
                "stream_id": stream_id,
                "sequence": "2",
                "item": {"kind": "future_event", "payload": 1}
            })
        )
        .unwrap();

        let cancel = request(&mut reader);
        assert_eq!(cancel["operation"], "stream.cancel");
        assert_eq!(
            cancel["params"],
            json!({"machine": "current", "session": SESSION, "stream": stream_id})
        );
        success(&mut stream, &cancel, json!({}));
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
        drop(control);
    });

    let client = connect(&path);
    let mut events = client
        .session(SessionId::parse(SESSION).unwrap())
        .events(EventStreamOptions::default())
        .unwrap();
    assert!(matches!(
        events.next_timeout(Duration::from_millis(20)).unwrap(),
        StreamPoll::TimedOut
    ));
    assert!(events.end().is_none());
    release_tx.send(()).unwrap();

    let snapshot = events.recv().unwrap().unwrap();
    match snapshot.value {
        SessionEvent::Snapshot(event) => {
            assert_eq!(event.snapshot.machine.id.as_str(), MACHINE);
            assert_eq!(event.snapshot.session.id.as_str(), SESSION);
        }
        other => panic!("unexpected session event: {other:?}"),
    }

    let delta = events.recv().unwrap().unwrap();
    match delta.value {
        SessionEvent::Delta(event) => match &event.changes[0] {
            ResourceChange::Upsert {
                value: ResourceEntitySnapshot::Terminal(terminal), ..
            } => assert_eq!(terminal.id.as_str(), TERMINAL),
            other => panic!("unexpected resource change: {other:?}"),
        },
        other => panic!("unexpected session event: {other:?}"),
    }

    let unknown = events.recv().unwrap().unwrap();
    assert!(matches!(unknown.value, SessionEvent::Unknown { .. }));
    events.cancel().unwrap();
    events.cancel().unwrap();
    assert!(events.recv().unwrap().is_none());
    assert_eq!(events.end().unwrap().reason, StreamEndReason::Canceled);
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn acknowledged_stream_remains_open_past_the_request_timeout() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let request_timeout = scaled_test_duration(Duration::from_millis(250));
    let idle_delay = request_timeout.saturating_mul(2);
    let (release_first_half, wait_for_first_half) = mpsc::channel();
    let (release_second_half, wait_for_second_half) = mpsc::channel();
    let server = thread::spawn(move || {
        let (control, _) = listener.accept().unwrap();
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let open = request(&mut reader);
        assert_eq!(open["operation"], "session.events");
        let stream_id = open["params"]["stream_id"].as_str().unwrap().to_string();
        success(&mut stream, &open, json!({"stream_id": stream_id}));

        // The request deadline bounds only opening the stream. An acknowledged
        // stream may remain healthy and idle for longer than that deadline.
        wait_for_first_half.recv().unwrap();
        let item = serde_json::to_vec(&json!({
            "protocol": "cmux.protocol/2",
            "type": "stream_item",
            "stream_id": stream_id,
            "sequence": "0",
            "item": {"kind": "future_event", "after_idle": true}
        }))
        .unwrap();
        let midpoint = item.len() / 2;
        stream.write_all(&item[..midpoint]).unwrap();
        stream.flush().unwrap();
        wait_for_second_half.recv().unwrap();
        stream.write_all(&item[midpoint..]).unwrap();
        stream.write_all(b"\n").unwrap();

        let cancel = request(&mut reader);
        assert_eq!(cancel["operation"], "stream.cancel");
        success(&mut stream, &cancel, json!({}));
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
        drop(control);
    });

    let client =
        cmux::Client::connect(Config::from_socket_path(&path).with_timeout(request_timeout))
            .unwrap();
    let mut events = client
        .session(SessionId::parse(SESSION).unwrap())
        .events(EventStreamOptions::default())
        .unwrap();
    let release = thread::spawn(move || {
        thread::sleep(idle_delay);
        release_first_half.send(()).unwrap();
        thread::sleep(idle_delay);
        release_second_half.send(()).unwrap();
    });
    let item = events.recv().unwrap().unwrap();
    assert!(matches!(item.value, SessionEvent::Unknown { .. }));
    release.join().unwrap();
    events.cancel().unwrap();
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn attachment_resize_and_release_use_each_owned_stream_connection() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let control = listener.accept().unwrap().0;

        let (mut terminal_stream, _) = listener.accept().unwrap();
        let mut terminal_reader = BufReader::new(terminal_stream.try_clone().unwrap());
        let terminal_open = request(&mut terminal_reader);
        assert_eq!(terminal_open["operation"], "terminal.attach");
        let terminal_stream_id = terminal_open["params"]["stream_id"].as_str().unwrap().to_string();
        writeln!(
            terminal_stream,
            "{}",
            json!({
                "protocol": "cmux.protocol/2",
                "type": "stream_item",
                "stream_id": terminal_stream_id,
                "sequence": "0",
                "item": {"kind": "pre_ack_terminal_item"}
            })
        )
        .unwrap();
        success(
            &mut terminal_stream,
            &terminal_open,
            json!({"stream_id": terminal_stream_id, "attachment_lease": "terminal-lease"}),
        );

        let terminal_resize = request(&mut terminal_reader);
        assert_eq!(terminal_resize["operation"], "terminal.viewer.resize");
        assert_eq!(
            terminal_resize["params"],
            json!({
                "machine": "current",
                "session": SESSION,
                "terminal": TERMINAL,
                "attachment_lease": "terminal-lease",
                "cols": 100,
                "rows": 30
            })
        );
        writeln!(
            terminal_stream,
            "{}",
            json!({
                "protocol": "cmux.protocol/2",
                "type": "stream_item",
                "stream_id": terminal_stream_id,
                "sequence": "1",
                "item": {"kind": "future_terminal_item"}
            })
        )
        .unwrap();
        success(
            &mut terminal_stream,
            &terminal_resize,
            json!({
                "accepted": true,
                "size": {"cols": 100, "rows": 30},
                "outcome": "applied"
            }),
        );

        let terminal_release = request(&mut terminal_reader);
        assert_eq!(terminal_release["operation"], "terminal.viewer.release");
        assert_eq!(
            terminal_release["params"],
            json!({
                "machine": "current",
                "session": SESSION,
                "terminal": TERMINAL,
                "attachment_lease": "terminal-lease"
            })
        );
        success(&mut terminal_stream, &terminal_release, json!({"outcome": "applied"}));

        let terminal_cancel = request(&mut terminal_reader);
        assert_eq!(terminal_cancel["operation"], "stream.cancel");
        success(&mut terminal_stream, &terminal_cancel, json!({}));
        writeln!(
            terminal_stream,
            "{}",
            json!({
                "protocol": "cmux.protocol/2",
                "type": "stream_end",
                "stream_id": terminal_stream_id,
                "reason": "canceled"
            })
        )
        .unwrap();

        let (mut browser_stream, _) = listener.accept().unwrap();
        let mut browser_reader = BufReader::new(browser_stream.try_clone().unwrap());
        let browser_open = request(&mut browser_reader);
        assert_eq!(browser_open["operation"], "browser.attach");
        let browser_stream_id = browser_open["params"]["stream_id"].as_str().unwrap().to_string();
        success(
            &mut browser_stream,
            &browser_open,
            json!({"stream_id": browser_stream_id, "attachment_lease": "browser-lease"}),
        );

        let browser_resize = request(&mut browser_reader);
        assert_eq!(browser_resize["operation"], "browser.viewer.resize");
        assert_eq!(
            browser_resize["params"],
            json!({
                "machine": "current",
                "session": SESSION,
                "browser": BROWSER,
                "attachment_lease": "browser-lease",
                "width_px": 1280,
                "height_px": 720
            })
        );
        success(
            &mut browser_stream,
            &browser_resize,
            json!({
                "accepted": true,
                "size": {"width_px": 1280, "height_px": 720},
                "outcome": "applied"
            }),
        );

        let browser_release = request(&mut browser_reader);
        assert_eq!(browser_release["operation"], "browser.viewer.release");
        assert_eq!(
            browser_release["params"],
            json!({
                "machine": "current",
                "session": SESSION,
                "browser": BROWSER,
                "attachment_lease": "browser-lease"
            })
        );
        success(&mut browser_stream, &browser_release, json!({"outcome": "applied"}));

        let browser_cancel = request(&mut browser_reader);
        assert_eq!(browser_cancel["operation"], "stream.cancel");
        success(&mut browser_stream, &browser_cancel, json!({}));
        writeln!(
            browser_stream,
            "{}",
            json!({
                "protocol": "cmux.protocol/2",
                "type": "stream_end",
                "stream_id": browser_stream_id,
                "reason": "canceled"
            })
        )
        .unwrap();
        drop(control);
    });

    let client = connect(&path);
    let session = client.session(SessionId::parse(SESSION).unwrap());
    let mut terminal = session
        .terminal(TerminalId::parse(TERMINAL).unwrap())
        .attach(TerminalAttachOptions::default())
        .unwrap();
    assert_eq!(terminal.resize(Size::new(100, 30).unwrap()).unwrap().size.cols, 100);
    for _ in 0..2 {
        assert!(matches!(
            terminal.recv().unwrap().unwrap().value,
            cmux::TerminalAttachmentItem::Unknown { .. }
        ));
    }
    terminal.release().unwrap();
    terminal.cancel().unwrap();

    let mut browser = session
        .browser(BrowserId::parse(BROWSER).unwrap())
        .attach(BrowserAttachOptions::default())
        .unwrap();
    assert_eq!(browser.resize(PixelSize::new(1280, 720).unwrap()).unwrap().size.width_px, 1280);
    browser.release().unwrap();
    browser.cancel().unwrap();
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn pre_ack_stream_limits_close_and_isolate_the_control_connection() {
    for overflow_by_bytes in [false, true] {
        let path = socket_path();
        let listener = UnixListener::bind(&path).unwrap();
        let server = thread::spawn(move || {
            let control = listener.accept().unwrap().0;
            let mut control_reader = BufReader::new(control.try_clone().unwrap());
            let (mut stream, _) = listener.accept().unwrap();
            let mut stream_reader = BufReader::new(stream.try_clone().unwrap());
            let opened = request(&mut stream_reader);
            assert_eq!(opened["operation"], "session.events");
            let stream_id = opened["params"]["stream_id"].as_str().unwrap().to_string();

            let item = |sequence: &str, blob: &str| {
                json!({
                    "protocol": "cmux.protocol/2",
                    "type": "stream_item",
                    "stream_id": stream_id,
                    "sequence": sequence,
                    "item": {"kind": "future.event", "blob": blob}
                })
            };
            writeln!(
                stream,
                "{}",
                item("1", &"x".repeat(if overflow_by_bytes { 1024 } else { 1 }))
            )
            .unwrap();
            if !overflow_by_bytes {
                writeln!(stream, "{}", item("2", "y")).unwrap();
            }

            assert_connection_closed_without_request(&mut stream_reader, "failed stream open");

            let ping = request(&mut control_reader);
            assert_eq!(ping["operation"], "session.ping");
            success(
                &mut control.try_clone().unwrap(),
                &ping,
                json!({
                    "alive": true,
                    "cursor": {"generation": "g", "revision": "1"}
                }),
            );
        });

        let (items, bytes) = if overflow_by_bytes { (4, 256) } else { (1, 4096) };
        let client =
            cmux::Client::connect(Config::from_socket_path(&path).with_stream_limits(items, bytes))
                .unwrap();
        let session = client.session(SessionId::parse(SESSION).unwrap());
        let error = match session.events(EventStreamOptions::default()) {
            Ok(_) => panic!("pre-ack overflow must fail the stream open"),
            Err(error) => error,
        };
        assert!(matches!(
            error,
            Error::StreamEnded {
                ref reason,
                recovery: Some(_),
                error: None,
            } if reason == "gap"
        ));
        assert!(session.ping().unwrap().alive);
        client.close().unwrap();
        server.join().unwrap();
        std::fs::remove_file(path).unwrap();
    }
}

#[test]
fn explicit_cancel_is_deadline_bounded_and_closes_after_uncertain_cleanup() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let _control = listener.accept().unwrap().0;
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let open = request(&mut reader);
        let stream_id = open["params"]["stream_id"].as_str().unwrap().to_string();
        success(&mut stream, &open, json!({"stream_id":stream_id}));
        let cancel = request(&mut reader);
        assert_eq!(cancel["operation"], "stream.cancel");
        thread::sleep(Duration::from_millis(350));
        writeln!(
            stream,
            "{}",
            json!({
                "protocol":"cmux.protocol/2",
                "type":"stream_item",
                "stream_id":stream_id,
                "sequence":"0",
                "item":{"kind":"future_event"},
            })
        )
        .unwrap();
        assert_connection_closed_without_request(&mut reader, "timed-out stream cancel");
    });

    let client = cmux::Client::connect(
        Config::from_socket_path(&path).with_timeout(Duration::from_millis(500)),
    )
    .unwrap();
    let mut events = client.current_session().events(EventStreamOptions::default()).unwrap();
    let started = std::time::Instant::now();
    assert!(matches!(events.cancel(), Err(Error::Timeout(_))));
    assert!(started.elapsed() < Duration::from_millis(700));
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn invalid_cancel_responses_close_and_never_send_a_second_cancel() {
    for case in [
        "wrong-id",
        "non-empty-result",
        "duplicate-response",
        "duplicate-end",
        "wrong-end-id",
        "wrong-end-reason",
        "unknown-response-field",
        "success-with-error",
        "failure-with-result",
        "unknown-response-error-field",
        "malformed-known-pre-end-item",
        "valid-known-post-end-item",
        "malformed-known-stale-item",
        "unknown-end-field",
        "unknown-error-field",
    ] {
        let path = socket_path();
        let listener = UnixListener::bind(&path).unwrap();
        let server = thread::spawn(move || {
            let _control = listener.accept().unwrap().0;
            let (mut stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let open = request(&mut reader);
            let stream_id = open["params"]["stream_id"].as_str().unwrap().to_string();
            success(&mut stream, &open, json!({"stream_id":stream_id}));
            let cancel = request(&mut reader);
            assert_eq!(cancel["operation"], "stream.cancel");
            match case {
                "wrong-id" => {
                    success(&mut stream, &json!({"id":"wrong-cancel-response"}), json!({}));
                }
                "non-empty-result" => {
                    success(&mut stream, &cancel, json!({"unexpected":true}));
                }
                "duplicate-response" => {
                    success(&mut stream, &cancel, json!({}));
                    success(&mut stream, &cancel, json!({}));
                }
                "duplicate-end" => {
                    for _ in 0..2 {
                        writeln!(
                            stream,
                            "{}",
                            json!({
                                "protocol":"cmux.protocol/2",
                                "type":"stream_end",
                                "stream_id":stream_id,
                                "reason":"canceled",
                            })
                        )
                        .unwrap();
                    }
                }
                "wrong-end-id" => {
                    success(&mut stream, &cancel, json!({}));
                    writeln!(
                        stream,
                        "{}",
                        json!({
                            "protocol":"cmux.protocol/2",
                            "type":"stream_end",
                            "stream_id":"stream_ffffffffffffffffffffffffffffffff",
                            "reason":"canceled",
                        })
                    )
                    .unwrap();
                }
                "wrong-end-reason" => {
                    success(&mut stream, &cancel, json!({}));
                    writeln!(
                        stream,
                        "{}",
                        json!({
                            "protocol":"cmux.protocol/2",
                            "type":"stream_end",
                            "stream_id":stream_id,
                            "reason":"completed",
                        })
                    )
                    .unwrap();
                }
                "unknown-response-field" => {
                    writeln!(
                        stream,
                        "{}",
                        json!({
                            "protocol":"cmux.protocol/2",
                            "type":"response",
                            "id":cancel["id"],
                            "ok":true,
                            "result":{},
                            "future":true,
                        })
                    )
                    .unwrap();
                }
                "success-with-error" => {
                    writeln!(
                        stream,
                        "{}",
                        json!({
                            "protocol":"cmux.protocol/2",
                            "type":"response",
                            "id":cancel["id"],
                            "ok":true,
                            "result":{},
                            "error":{
                                "code":"operation.failed",
                                "message":"fixture",
                                "details":{},
                                "retryable":false,
                            },
                        })
                    )
                    .unwrap();
                }
                "failure-with-result" => {
                    writeln!(
                        stream,
                        "{}",
                        json!({
                            "protocol":"cmux.protocol/2",
                            "type":"response",
                            "id":cancel["id"],
                            "ok":false,
                            "result":{},
                            "error":{
                                "code":"operation.failed",
                                "message":"fixture",
                                "details":{},
                                "retryable":false,
                            },
                        })
                    )
                    .unwrap();
                }
                "unknown-response-error-field" => {
                    writeln!(
                        stream,
                        "{}",
                        json!({
                            "protocol":"cmux.protocol/2",
                            "type":"response",
                            "id":cancel["id"],
                            "ok":false,
                            "error":{
                                "code":"operation.failed",
                                "message":"fixture",
                                "details":{},
                                "retryable":false,
                                "future":true,
                            },
                        })
                    )
                    .unwrap();
                }
                "malformed-known-pre-end-item" => {
                    writeln!(
                        stream,
                        "{}",
                        json!({
                            "protocol":"cmux.protocol/2",
                            "type":"stream_item",
                            "stream_id":stream_id,
                            "sequence":"0",
                            "cursor":{"generation":"g","revision":"1"},
                            "item":{
                                "kind":"snapshot",
                                "cursor":{"generation":"g","revision":"1"},
                                "snapshot":resource_snapshot(),
                                "future":true,
                            },
                        })
                    )
                    .unwrap();
                    // The malformed item must close the peer immediately, so
                    // fixture cleanup frames would race the expected close.
                }
                "valid-known-post-end-item" => {
                    writeln!(
                        stream,
                        "{}",
                        json!({
                            "protocol":"cmux.protocol/2",
                            "type":"stream_end",
                            "stream_id":stream_id,
                            "reason":"canceled",
                        })
                    )
                    .unwrap();
                    writeln!(
                        stream,
                        "{}",
                        json!({
                            "protocol":"cmux.protocol/2",
                            "type":"stream_item",
                            "stream_id":stream_id,
                            "sequence":"0",
                            "cursor":{"generation":"g","revision":"1"},
                            "item":{
                                "kind":"snapshot",
                                "cursor":{"generation":"g","revision":"1"},
                                "reset_reason":"initial",
                                "snapshot":resource_snapshot(),
                            },
                        })
                    )
                    .unwrap();
                    // The post-end item is the violation. A later response
                    // would race the expected close on fast socket peers.
                }
                "malformed-known-stale-item" => {
                    writeln!(
                        stream,
                        "{}",
                        json!({
                            "protocol":"cmux.protocol/2",
                            "type":"stream_end",
                            "stream_id":stream_id,
                            "reason":"canceled",
                        })
                    )
                    .unwrap();
                    writeln!(
                        stream,
                        "{}",
                        json!({
                            "protocol":"cmux.protocol/2",
                            "type":"stream_item",
                            "stream_id":stream_id,
                            "sequence":"0",
                            "item":{
                                "kind":"snapshot",
                                "future":true,
                            },
                        })
                    )
                    .unwrap();
                    // The stale malformed item must close the peer before any
                    // remaining cancellation frames are accepted.
                }
                "unknown-end-field" => {
                    success(&mut stream, &cancel, json!({}));
                    writeln!(
                        stream,
                        "{}",
                        json!({
                            "protocol":"cmux.protocol/2",
                            "type":"stream_end",
                            "stream_id":stream_id,
                            "reason":"canceled",
                            "future":true,
                        })
                    )
                    .unwrap();
                }
                "unknown-error-field" => {
                    success(&mut stream, &cancel, json!({}));
                    writeln!(
                        stream,
                        "{}",
                        json!({
                            "protocol":"cmux.protocol/2",
                            "type":"stream_end",
                            "stream_id":stream_id,
                            "reason":"error",
                            "error":{
                                "code":"operation.failed",
                                "message":"fixture",
                                "details":{},
                                "retryable":false,
                                "future":true,
                            },
                        })
                    )
                    .unwrap();
                }
                _ => unreachable!(),
            }
            assert_connection_closed_without_request(&mut reader, case);
        });

        let client = connect(&path);
        let mut events = client.current_session().events(EventStreamOptions::default()).unwrap();
        let detached = events.cancellation();
        let first = events.cancel().unwrap_err();
        assert!(matches!(&first, Error::UnexpectedEnvelope(_)), "{case}: {first:?}");
        let first_debug = format!("{first:?}");
        let repeated = events.cancel().unwrap_err();
        assert_eq!(format!("{repeated:?}"), first_debug, "{case}");
        detached.cancel().unwrap();
        client.close().unwrap();
        server.join().unwrap();
        std::fs::remove_file(path).unwrap();
    }
}

#[test]
fn live_stream_overflow_sends_one_cancel_and_prevents_reuse() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let _control = listener.accept().unwrap().0;
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let open = request(&mut reader);
        let stream_id = open["params"]["stream_id"].as_str().unwrap().to_string();
        success(
            &mut stream,
            &open,
            json!({"stream_id":stream_id, "attachment_lease":"overflow-lease"}),
        );

        let resize = request(&mut reader);
        assert_eq!(resize["operation"], "terminal.viewer.resize");
        for sequence in 0..2 {
            writeln!(
                stream,
                "{}",
                json!({
                    "protocol":"cmux.protocol/2",
                    "type":"stream_item",
                    "stream_id":stream_id,
                    "sequence":sequence.to_string(),
                    "item":{"kind":"future_terminal_item"},
                })
            )
            .unwrap();
        }
        let cancel = request(&mut reader);
        assert_eq!(cancel["operation"], "stream.cancel");
        assert_eq!(cancel["params"]["stream"], stream_id);
        assert_connection_closed_without_request(&mut reader, "overflowed stream");
    });

    let client =
        cmux::Client::connect(Config::from_socket_path(&path).with_stream_limits(1, 4 * 1024))
            .unwrap();
    let mut terminal = client
        .current_session()
        .terminal(TerminalId::parse(TERMINAL).unwrap())
        .attach(TerminalAttachOptions::default())
        .unwrap();
    assert!(matches!(
        terminal.resize(Size::new(100, 30).unwrap()),
        Err(Error::StreamEnded { ref reason, .. }) if reason == "gap"
    ));
    terminal.cancel().unwrap();
    drop(terminal);
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn cancel_discards_unread_items_and_waits_for_response_and_end() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (_control, _) = listener.accept().unwrap();
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let open = request(&mut reader);
        let stream_id = open["params"]["stream_id"].as_str().unwrap().to_string();
        success(&mut stream, &open, json!({"stream_id": stream_id}));
        writeln!(
            stream,
            "{}",
            json!({
                "protocol": "cmux.protocol/2",
                "type": "stream_item",
                "stream_id": stream_id,
                "sequence": "0",
                "item": {"kind": "future_event", "stale": true}
            })
        )
        .unwrap();

        let cancel = request(&mut reader);
        assert_eq!(cancel["operation"], "stream.cancel");
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
        success(&mut stream, &cancel, json!({}));

        stream.set_read_timeout(Some(Duration::from_millis(200))).unwrap();
        let mut possible_second_cancel = String::new();
        match reader.read_line(&mut possible_second_cancel) {
            Ok(0) => {}
            Ok(_) => panic!("second cancel sent another request: {possible_second_cancel}"),
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) => {}
            Err(error) => panic!("unexpected read error: {error}"),
        }
    });

    let client = connect(&path);
    let mut events = client
        .session(SessionId::parse(SESSION).unwrap())
        .events(EventStreamOptions::default())
        .unwrap();
    events.cancel().unwrap();
    events.cancel().unwrap();
    assert_eq!(events.end().unwrap().reason, StreamEndReason::Canceled);
    assert!(events.recv().unwrap().is_none());
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn dropping_completed_and_gap_streams_does_not_send_cancel() {
    for (reason, recovery) in [("completed", None), ("gap", Some("resubscribe"))] {
        let path = socket_path();
        let listener = UnixListener::bind(&path).unwrap();
        let server = thread::spawn(move || {
            let (_control, _) = listener.accept().unwrap();
            let (mut stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let open = request(&mut reader);
            let stream_id = open["params"]["stream_id"].as_str().unwrap().to_string();
            success(&mut stream, &open, json!({"stream_id": stream_id}));

            let mut end = json!({
                "protocol": "cmux.protocol/2",
                "type": "stream_end",
                "stream_id": stream_id,
                "reason": reason
            });
            if let Some(recovery) = recovery {
                end["recovery"] = json!(recovery);
            }
            writeln!(stream, "{end}").unwrap();

            assert_connection_closed_without_request(&mut reader, reason);
        });

        let client = connect(&path);
        let mut events = client
            .session(SessionId::parse(SESSION).unwrap())
            .events(EventStreamOptions::default())
            .unwrap();
        if reason == "completed" {
            assert!(events.recv().unwrap().is_none());
        } else {
            match events.recv().unwrap_err() {
                Error::StreamEnded { reason, recovery, .. } => {
                    assert_eq!(reason, "gap");
                    assert_eq!(recovery.as_deref(), Some("resubscribe"));
                }
                other => panic!("unexpected gap error: {other:?}"),
            }
        }
        drop(events);
        client.close().unwrap();
        server.join().unwrap();
        std::fs::remove_file(path).unwrap();
    }
}

#[test]
fn renderer_grant_is_typed_and_redacts_the_one_use_token() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let grant = request(&mut BufReader::new(stream.try_clone().unwrap()));
        assert_eq!(grant["operation"], "terminal.renderer_grant.create");
        assert_eq!(grant["params"]["ttl_ms"], 5_000);
        assert!(grant.get("idempotency_key").is_none());
        success(
            &mut stream,
            &grant,
            json!({
                "endpoint": "unix:///tmp/renderer.sock",
                "terminal_id": TERMINAL,
                "token": "secret-token",
                "rights": ["render"],
                "ttl_ms": 5_000
            }),
        );
    });

    let client = connect(&path);
    let grant = client
        .current_session()
        .terminal(TerminalId::parse(TERMINAL).unwrap())
        .create_renderer_grant(RendererGrantOptions { ttl_ms: Some(5_000) })
        .unwrap();
    assert_eq!(grant.expose_token(), "secret-token");
    assert_eq!(grant.terminal_id.as_str(), TERMINAL);
    let debug = format!("{grant:?}");
    assert!(debug.contains("[REDACTED]"));
    assert!(!debug.contains("secret-token"));
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn connection_controls_have_no_idempotency_key_and_sizing_is_terminal_scoped() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());

        let metadata = request(&mut reader);
        assert_eq!(metadata["operation"], "client.metadata.update");
        assert!(metadata.get("idempotency_key").is_none());
        assert_eq!(metadata["params"]["name"], Value::Null);
        assert_eq!(metadata["params"]["kind"], "");
        success(&mut stream, &metadata, client_snapshot());

        let sizing = request(&mut reader);
        assert_eq!(sizing["operation"], "client.sizing.set");
        assert!(sizing.get("idempotency_key").is_none());
        assert_eq!(
            sizing["params"],
            json!({
                "machine": "current",
                "session": SESSION,
                "terminal": TERMINAL,
                "client": CLIENT,
                "enabled": true,
                "exclusive": false
            })
        );
        success(&mut stream, &sizing, client_snapshot());
    });

    let client = connect(&path);
    let session = client.session(SessionId::parse(SESSION).unwrap());
    let connected = session.connected_client(cmux::ConnectedClientId::parse(CLIENT).unwrap());
    connected
        .update_metadata(ClientMetadataOptions {
            name: Update::Clear,
            kind: Update::Set(String::new()),
        })
        .unwrap();
    let terminal = session.terminal(TerminalId::parse(TERMINAL).unwrap());
    connected
        .set_sizing(&terminal, ClientSizingOptions { enabled: true, exclusive: Some(false) })
        .unwrap();
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn opaque_nested_ids_omit_structural_ancestors_but_names_supply_the_current_chain() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let by_id = request(&mut reader);
        assert_eq!(
            by_id["params"],
            json!({"machine": "current", "session": SESSION, "terminal": TERMINAL})
        );
        success(&mut stream, &by_id, terminal_screen("id"));

        let by_name = request(&mut reader);
        assert_eq!(
            by_name["params"],
            json!({
                "machine": "current",
                "session": SESSION,
                "workspace": "current",
                "screen": "current",
                "pane": "current",
                "tab": "current",
                "terminal": "name:build"
            })
        );
        success(&mut stream, &by_name, terminal_screen("name"));
    });

    let client = connect(&path);
    let session = client.session(SessionId::parse(SESSION).unwrap());
    session.terminal(TerminalId::parse(TERMINAL).unwrap()).read_screen(ReadScreenOptions).unwrap();
    session.terminal(Selector::name("build")).read_screen(ReadScreenOptions).unwrap();
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn catalog_terminal_session_client_and_pairing_results_are_concrete() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let steps = [
            (
                "session.ping",
                json!({
                    "alive": true,
                    "cursor": {"generation": "g", "revision": "1"}
                }),
                false,
            ),
            ("session.reload_config", json!({"reloaded": true, "warnings": ["fixture"]}), true),
            ("session.shutdown", json!({"accepted": true}), true),
            (
                "session.terminal_defaults.update",
                json!({"cursor_blink": true, "palette": {"0": "#000000"}}),
                true,
            ),
            ("terminal.screen.read", terminal_screen("screen"), false),
            ("terminal.state.read", json!({"state_base64": "AP8=", "cols": 80, "rows": 24}), false),
            (
                "terminal.history.read",
                json!({
                    "start": "7",
                    "next": null,
                    "rows": [{
                        "row": 0,
                        "runs": [{"text": "history", "fg": null, "bg": null, "attrs": 0}]
                    }]
                }),
                false,
            ),
            ("terminal.wait", json!({"matched": true, "text": "ready"}), false),
            ("terminal.copy", json!({"mode": "screen", "text": "copied"}), false),
            (
                "terminal.process.get",
                json!({
                    "pid": 42,
                    "executable": "/bin/zsh",
                    "argv": ["/bin/zsh", "-l"],
                    "cwd": "/tmp",
                    "children": [43]
                }),
                false,
            ),
            (
                "terminal.viewer.resize",
                json!({
                    "accepted": true,
                    "size": {"cols": 100, "rows": 30},
                    "outcome": "applied"
                }),
                false,
            ),
            ("terminal.viewer.release", json!({"outcome": "applied"}), false),
            (
                "client.cell_pixels.set",
                json!({
                    "width_px": 9,
                    "height_px": 18,
                    "resized_terminals": [TERMINAL],
                    "failures": {}
                }),
                false,
            ),
            ("client.detach", json!({}), false),
            ("terminal.input.write", json!({}), true),
            (
                "pairing_request.resolve",
                json!({
                    "pairing_request": {
                        "id": PAIRING_REQUEST,
                        "session_id": SESSION,
                        "peer": "iPhone",
                        "code": "",
                        "expires_in_seconds": "60",
                        "status": "accepted"
                    }
                }),
                true,
            ),
        ];
        for (operation, value, mutation) in steps {
            let item = request(&mut reader);
            assert_eq!(item["operation"], operation);
            if operation == "pairing_request.resolve" {
                assert_eq!(item["params"]["decision"], "accept");
            }
            let result = if mutation { mutation_result(&item, value) } else { value };
            success(&mut stream, &item, result);
        }
    });

    let client = connect(&path);
    let session = client.session(SessionId::parse(SESSION).unwrap());
    let terminal = session.terminal(TerminalId::parse(TERMINAL).unwrap());
    assert!(session.ping().unwrap().alive);
    assert!(
        session.reload_config_with(MutationOptions::new("reload").unwrap()).unwrap().value.reloaded
    );
    assert!(
        session
            .shutdown_with(ShutdownOptions::default(), MutationOptions::new("shutdown").unwrap(),)
            .unwrap()
            .value
            .accepted
    );
    let defaults = session
        .update_terminal_defaults_with(
            TerminalDefaultsOptions {
                cursor_blink: Update::Set(true),
                ..TerminalDefaultsOptions::default()
            },
            MutationOptions::new("defaults").unwrap(),
        )
        .unwrap();
    assert_eq!(defaults.value.cursor_blink, Some(true));
    assert_eq!(terminal.read_screen(ReadScreenOptions).unwrap().text, "screen");
    assert_eq!(terminal.read_state().unwrap().state, vec![0, 255]);
    assert_eq!(
        terminal.read_history(ReadHistoryOptions::default()).unwrap().rows[0].runs[0].text,
        "history"
    );
    assert!(
        terminal
            .wait(WaitOptions { pattern: "ready".to_string(), timeout_ms: None })
            .unwrap()
            .matched
    );
    assert_eq!(terminal.copy(CopyOptions::default()).unwrap().text, "copied");
    assert_eq!(terminal.process().unwrap().children, vec![43]);
    assert_eq!(
        terminal.viewer_resize("terminal-lease", Size::new(100, 30).unwrap()).unwrap().size.cols,
        100
    );
    terminal.viewer_release("terminal-lease").unwrap();

    let connected = session.connected_client(cmux::ConnectedClientId::parse(CLIENT).unwrap());
    assert_eq!(
        connected
            .set_cell_pixels(CellPixelsOptions { width_px: 9, height_px: 18 })
            .unwrap()
            .resized_terminals[0]
            .as_str(),
        TERMINAL
    );
    connected.detach().unwrap();
    terminal.write_text_with("input", MutationOptions::new("write").unwrap()).unwrap();
    let resolution = session
        .pairing_request(cmux::PairingRequestId::parse(PAIRING_REQUEST).unwrap())
        .resolve_with(
            PairingResolveOptions { decision: PairingDecision::Accept },
            MutationOptions::new("pair").unwrap(),
        )
        .unwrap();
    assert_eq!(resolution.value.pairing_request.code.expose(), "");
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn dropping_handles_never_sends_delete_or_close() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        assert_eq!(reader.read_line(&mut line).unwrap(), 0);
    });

    let client = connect(&path);
    {
        let _workspace = client.current_session().workspace(Selector::name(""));
    }
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn creation_resolution_and_terminal_exit_wait_are_strict_typed_reads() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());

        let resolve = request(&mut reader);
        assert_eq!(resolve["operation"], "session.creation.resolve");
        assert_eq!(resolve["params"]["correlation_key"], "create-1");
        success(
            &mut stream,
            &resolve,
            json!({
                "correlation_key": "create-1",
                "state": "created",
                "recovery": "none",
                "created_path": {
                    "kind": "workspace",
                    "workspace_id": WORKSPACE_A
                },
                "generation": "g",
                "revision": "7"
            }),
        );

        let pending = request(&mut reader);
        assert_eq!(pending["operation"], "terminal.wait_exit");
        assert_eq!(pending["params"]["timeout_ms"], "0");
        success(
            &mut stream,
            &pending,
            json!({
                "state": "pending",
                "terminal_id": TERMINAL,
                "lifecycle": "running",
                "revision": "8"
            }),
        );

        let exited = request(&mut reader);
        assert_eq!(exited["operation"], "terminal.wait_exit");
        assert_eq!(exited["params"]["timeout_ms"], "250");
        success(
            &mut stream,
            &exited,
            json!({
                "state": "exited",
                "terminal_id": TERMINAL,
                "lifecycle": "exited",
                "outcome": {
                    "kind": "signal",
                    "signal": 15,
                    "core_dumped": false
                },
                "exited_at": "1000",
                "revision": "9"
            }),
        );
    });

    let client = connect(&path);
    let session = client.session(SessionId::parse(SESSION).unwrap());
    let resolution = session.creation().resolve("create-1").unwrap();
    assert_eq!(resolution.state, CreationState::Created);
    assert_eq!(resolution.recovery, CreationRecovery::None);
    assert_eq!(resolution.created_path.unwrap().workspace_id().as_str(), WORKSPACE_A);
    let terminal = session.terminal(TerminalId::parse(TERMINAL).unwrap());
    assert!(matches!(terminal.wait_exit(Some(0)).unwrap(), TerminalWaitExitResult::Pending(_)));
    match terminal.wait_exit(Some(250)).unwrap() {
        TerminalWaitExitResult::Exited(exited) => {
            assert_eq!(exited.exited_at, 1000);
            assert!(matches!(
                exited.outcome,
                TerminalExitOutcome::Signal { signal: 15, core_dumped: false }
            ));
        }
        other => panic!("unexpected wait result: {other:?}"),
    }
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn terminal_exit_unions_reject_cross_variant_fields_and_invalid_signals() {
    for value in [
        json!({
            "state": "exited",
            "terminal_id": TERMINAL,
            "lifecycle": "exited",
            "outcome": {"kind": "exit", "code": -1},
            "exited_at": "1",
            "revision": "2"
        }),
        json!({
            "state": "exited",
            "terminal_id": TERMINAL,
            "lifecycle": "exited",
            "outcome": {"kind": "unknown", "reason": "registry unavailable"},
            "exited_at": "1",
            "revision": "2"
        }),
    ] {
        serde_json::from_value::<TerminalWaitExitResult>(value).unwrap();
    }
    assert!(
        serde_json::from_value::<TerminalWaitExitResult>(json!({
            "state": "pending",
            "terminal_id": TERMINAL,
            "lifecycle": "exited",
            "revision": "2"
        }))
        .is_err()
    );
    assert!(
        serde_json::from_value::<TerminalWaitExitResult>(json!({
            "state": "exited",
            "terminal_id": TERMINAL,
            "lifecycle": "exited",
            "outcome": {"kind": "signal", "signal": 0, "core_dumped": false},
            "exited_at": "1",
            "revision": "2"
        }))
        .is_err()
    );
}

#[test]
fn terminal_snapshot_lifecycle_invariants_are_strict() {
    let running: TerminalSnapshot = serde_json::from_value(terminal_snapshot()).unwrap();
    assert_eq!(running.lifecycle, TerminalLifecycle::Running);

    let mut inconsistent_running = terminal_snapshot();
    inconsistent_running["running"] = json!(false);
    assert!(serde_json::from_value::<TerminalSnapshot>(inconsistent_running).is_err());

    let mut missing_exit = terminal_snapshot();
    missing_exit["running"] = json!(false);
    missing_exit["lifecycle"] = json!("exited");
    assert!(serde_json::from_value::<TerminalSnapshot>(missing_exit).is_err());

    let exited: TerminalSnapshot = serde_json::from_value(json!({
        "id": TERMINAL,
        "tab_ids": [],
        "title": "finished",
        "cols": 80,
        "rows": 24,
        "running": false,
        "lifecycle": "exited",
        "exit": {
            "outcome": {"kind": "exit", "code": 0},
            "exited_at": "1000",
            "revision": "9"
        }
    }))
    .unwrap();
    assert_eq!(exited.lifecycle, TerminalLifecycle::Exited);
    assert!(exited.exit.is_some());
}

#[test]
fn terminal_snapshot_accepts_protocol_one_tab_id_alias() {
    let mut attached = terminal_snapshot();
    attached.as_object_mut().unwrap().remove("tab_ids");
    attached["tab_id"] = json!(TAB);
    let attached: TerminalSnapshot = serde_json::from_value(attached).unwrap();
    assert_eq!(attached.tab_ids.len(), 1);
    assert_eq!(attached.tab_ids[0].as_str(), TAB);

    let mut detached = terminal_snapshot();
    detached.as_object_mut().unwrap().remove("tab_ids");
    detached["tab_id"] = Value::Null;
    let detached: TerminalSnapshot = serde_json::from_value(detached).unwrap();
    assert!(detached.tab_ids.is_empty());

    let mut legacy_alias = terminal_snapshot();
    legacy_alias["tab_id"] = json!(TAB);
    assert!(serde_json::from_value::<TerminalSnapshot>(legacy_alias).is_ok());

    let mut missing = terminal_snapshot();
    missing.as_object_mut().unwrap().remove("tab_ids");
    assert!(serde_json::from_value::<TerminalSnapshot>(missing).is_err());

    let mut inconsistent = terminal_snapshot();
    inconsistent["tab_id"] = json!("tab_11111111111111111111111111111111");
    assert!(serde_json::from_value::<TerminalSnapshot>(inconsistent).is_err());
}

#[test]
fn one_call_deadline_drops_the_stale_connection_and_reconnects() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (first, _) = listener.accept().unwrap();
        let mut first_reader = BufReader::new(first);
        let first_request = request(&mut first_reader);
        assert_eq!(first_request["operation"], "session.ping");

        let (mut second, _) = listener.accept().unwrap();
        let second_request = request(&mut BufReader::new(second.try_clone().unwrap()));
        assert_eq!(second_request["operation"], "session.ping");
        success(
            &mut second,
            &second_request,
            json!({
                "alive": true,
                "cursor": {"generation": "g", "revision": "1"}
            }),
        );
    });

    let client = connect(&path);
    let options = RequestOptions::new().with_timeout(Duration::from_millis(20)).unwrap();
    match client.with_request_options(options, || client.current_session().ping()) {
        Err(Error::Timeout(_)) => {}
        other => panic!("unexpected deadline result: {other:?}"),
    }
    assert!(client.current_session().ping().unwrap().alive);
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn timed_out_terminal_wait_cancels_once_and_reuses_its_connection() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());

        let wait = request(&mut reader);
        assert_eq!(wait["operation"], "terminal.wait");

        let cancel = request(&mut reader);
        assert_eq!(cancel["operation"], "request.cancel");
        assert_eq!(cancel["params"], json!({"request_id": wait["id"]}));
        assert!(cancel.get("idempotency_key").is_none());
        success(&mut stream, &cancel, json!({"canceled": true}));

        let ping = request(&mut reader);
        assert_eq!(ping["operation"], "session.ping");
        success(
            &mut stream,
            &ping,
            json!({
                "alive": true,
                "cursor": {"generation": "g", "revision": "1"}
            }),
        );
    });

    let client = connect(&path);
    let terminal = client.current_session().terminal(TerminalId::parse(TERMINAL).unwrap());
    let options = RequestOptions::new().with_timeout(Duration::from_millis(20)).unwrap();
    let error = client
        .with_request_options(options, || {
            terminal.wait(WaitOptions { pattern: "never".to_string(), timeout_ms: None })
        })
        .unwrap_err();
    assert!(matches!(error, Error::Timeout(_)));
    assert!(client.current_session().ping().unwrap().alive);

    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn terminal_wait_cancel_false_drains_the_completion_race_before_reuse() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());

        let wait = request(&mut reader);
        assert_eq!(wait["operation"], "terminal.wait");
        let cancel = request(&mut reader);
        assert_eq!(cancel["operation"], "request.cancel");
        assert_eq!(cancel["params"], json!({"request_id": wait["id"]}));

        success(&mut stream, &cancel, json!({"canceled": false}));
        thread::sleep(Duration::from_millis(10));
        success(&mut stream, &wait, json!({"matched": true, "text": "raced"}));

        let ping = request(&mut reader);
        assert_eq!(ping["operation"], "session.ping");
        success(
            &mut stream,
            &ping,
            json!({
                "alive": true,
                "cursor": {"generation": "g", "revision": "2"}
            }),
        );
    });

    let client = connect(&path);
    let terminal = client.current_session().terminal(TerminalId::parse(TERMINAL).unwrap());
    let options = RequestOptions::new().with_timeout(Duration::from_millis(20)).unwrap();
    let error = client
        .with_request_options(options, || {
            terminal.wait(WaitOptions { pattern: "raced".to_string(), timeout_ms: None })
        })
        .unwrap_err();
    assert!(matches!(error, Error::Timeout(_)));
    assert!(client.current_session().ping().unwrap().alive);

    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn terminal_wait_cancel_false_drains_response_first_before_reuse() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());

        let wait = request(&mut reader);
        let cancel = request(&mut reader);
        assert_eq!(cancel["operation"], "request.cancel");
        success(&mut stream, &wait, json!({"matched": true, "text": "raced"}));
        thread::sleep(Duration::from_millis(10));
        success(&mut stream, &cancel, json!({"canceled": false}));

        let ping = request(&mut reader);
        success(
            &mut stream,
            &ping,
            json!({
                "alive": true,
                "cursor": {"generation": "g", "revision": "2"}
            }),
        );
    });

    let client = connect(&path);
    let terminal = client.current_session().terminal(TerminalId::parse(TERMINAL).unwrap());
    let options = RequestOptions::new().with_timeout(Duration::from_millis(20)).unwrap();
    let error = client
        .with_request_options(options, || {
            terminal.wait(WaitOptions { pattern: "raced".to_string(), timeout_ms: None })
        })
        .unwrap_err();
    assert!(matches!(error, Error::Timeout(_)));
    assert!(client.current_session().ping().unwrap().alive);

    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn malformed_raced_wait_result_preserves_timeout_and_reconnects() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (mut first, _) = listener.accept().unwrap();
        let mut first_reader = BufReader::new(first.try_clone().unwrap());
        let wait = request(&mut first_reader);
        let cancel = request(&mut first_reader);
        success(&mut first, &cancel, json!({"canceled": false}));
        success(&mut first, &wait, json!({"matched": true}));
        assert_connection_closed_without_request(
            &mut first_reader,
            "malformed raced terminal.wait result",
        );

        let (mut second, _) = listener.accept().unwrap();
        let ping = request(&mut BufReader::new(second.try_clone().unwrap()));
        success(
            &mut second,
            &ping,
            json!({
                "alive": true,
                "cursor": {"generation": "g", "revision": "3"}
            }),
        );
    });

    let client = connect(&path);
    let terminal = client.current_session().terminal(TerminalId::parse(TERMINAL).unwrap());
    let options = RequestOptions::new().with_timeout(Duration::from_millis(20)).unwrap();
    let error = client
        .with_request_options(options, || {
            terminal.wait(WaitOptions { pattern: "never".to_string(), timeout_ms: None })
        })
        .unwrap_err();
    assert!(matches!(error, Error::Timeout(_)));
    assert!(client.current_session().ping().unwrap().alive);

    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn malformed_wait_cleanup_preserves_timeout_and_reconnects() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (mut first, _) = listener.accept().unwrap();
        let mut first_reader = BufReader::new(first.try_clone().unwrap());
        let wait = request(&mut first_reader);
        assert_eq!(wait["operation"], "terminal.wait");
        let cancel = request(&mut first_reader);
        assert_eq!(cancel["operation"], "request.cancel");
        success(&mut first, &cancel, json!({"canceled": true, "future": true}));
        assert_connection_closed_without_request(
            &mut first_reader,
            "malformed request.cancel cleanup",
        );

        let (mut second, _) = listener.accept().unwrap();
        let ping = request(&mut BufReader::new(second.try_clone().unwrap()));
        assert_eq!(ping["operation"], "session.ping");
        success(
            &mut second,
            &ping,
            json!({
                "alive": true,
                "cursor": {"generation": "g", "revision": "3"}
            }),
        );
    });

    let client = connect(&path);
    let terminal = client.current_session().terminal(TerminalId::parse(TERMINAL).unwrap());
    let options = RequestOptions::new().with_timeout(Duration::from_millis(20)).unwrap();
    let error = client
        .with_request_options(options, || {
            terminal.wait(WaitOptions { pattern: "never".to_string(), timeout_ms: None })
        })
        .unwrap_err();
    assert!(matches!(error, Error::Timeout(_)));
    assert!(client.current_session().ping().unwrap().alive);

    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn canceled_wait_exit_preserves_abort_and_predispatch_sends_nothing() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let (wait_seen_tx, wait_seen_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());

        let wait = request(&mut reader);
        assert_eq!(wait["operation"], "terminal.wait_exit");
        wait_seen_tx.send(()).unwrap();

        let cancel = request(&mut reader);
        assert_eq!(cancel["operation"], "request.cancel");
        assert_eq!(cancel["params"], json!({"request_id": wait["id"]}));
        success(&mut stream, &cancel, json!({"canceled": true}));

        let ping = request(&mut reader);
        assert_eq!(ping["operation"], "session.ping");
        success(
            &mut stream,
            &ping,
            json!({
                "alive": true,
                "cursor": {"generation": "g", "revision": "3"}
            }),
        );
    });

    let client = connect(&path);
    let cancellation = CancellationToken::new();
    let worker_client = client.clone();
    let worker_cancellation = cancellation.clone();
    let worker = thread::spawn(move || {
        worker_client.with_request_options(
            RequestOptions::new().with_cancellation(worker_cancellation),
            || {
                worker_client
                    .current_session()
                    .terminal(TerminalId::parse(TERMINAL).unwrap())
                    .wait_exit(None)
            },
        )
    });
    wait_seen_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    cancellation.cancel();
    assert!(matches!(worker.join().unwrap(), Err(Error::Cancelled(_))));

    let already_canceled = CancellationToken::new();
    already_canceled.cancel();
    let predispatch = client
        .with_request_options(RequestOptions::new().with_cancellation(already_canceled), || {
            client.current_session().terminal(TerminalId::parse(TERMINAL).unwrap()).wait_exit(None)
        });
    assert!(matches!(predispatch, Err(Error::Cancelled(_))));
    assert!(client.current_session().ping().unwrap().alive);

    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn cancellation_after_mutation_dispatch_preserves_the_exact_key() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let (seen_tx, seen_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream);
        let observed = request(&mut reader);
        seen_tx.send(observed).unwrap();
        release_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    });

    let client = connect(&path);
    let cancellation = CancellationToken::new();
    let worker_client = client.clone();
    let worker_cancellation = cancellation.clone();
    let worker = thread::spawn(move || {
        worker_client
            .current_session()
            .workspace(WorkspaceId::parse(WORKSPACE_A).unwrap())
            .rename_with(
                "renamed",
                MutationOptions::new("cancel-key").unwrap().with_cancellation(worker_cancellation),
            )
            .unwrap_err()
    });
    let observed = seen_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(observed["idempotency_key"], "cancel-key");
    cancellation.cancel();
    match worker.join().unwrap() {
        Error::MutationTransport { operation, idempotency_key, source } => {
            assert_eq!(operation, "workspace.rename");
            assert_eq!(idempotency_key, "cancel-key");
            assert!(matches!(*source, Error::Cancelled(_)));
        }
        other => panic!("unexpected cancellation error: {other:?}"),
    }
    release_tx.send(()).unwrap();
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn cancellation_before_dispatch_is_not_mutation_uncertainty() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        assert_eq!(reader.read_line(&mut line).unwrap(), 0);
    });

    let client = connect(&path);
    let cancellation = CancellationToken::new();
    cancellation.cancel();
    let error = client
        .current_session()
        .workspace(WorkspaceId::parse(WORKSPACE_A).unwrap())
        .rename_with(
            "renamed",
            MutationOptions::new("never-sent").unwrap().with_cancellation(cancellation),
        )
        .unwrap_err();
    assert!(matches!(error, Error::Cancelled(_)));
    client.close().unwrap();
    server.join().unwrap();
    std::fs::remove_file(path).unwrap();
}

#[test]
fn mutation_send_revalidates_public_option_fields_before_transport() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        line
    });

    let client = connect(&path);
    let error = client
        .current_session()
        .workspace(WorkspaceId::parse(WORKSPACE_A).unwrap())
        .rename_with(
            "renamed",
            MutationOptions {
                idempotency_key: " \u{00a0}\u{3000}".to_string(),
                expected_revision: None,
                request: RequestOptions::default(),
            },
        )
        .unwrap_err();
    assert!(matches!(error, Error::InvalidArgument(_)));
    client.close().unwrap();
    assert_eq!(server.join().unwrap(), "");
    std::fs::remove_file(path).unwrap();
}
