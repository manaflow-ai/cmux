use cmux::{
    ClientMetadataOptions, ClientSizingOptions, Config, Error, EventStreamOptions, InitialContent,
    LabelOptions, MachineConnectOptions, MutationOptions, ProviderActionId, ProviderActionOptions,
    ReadScreenOptions, RendererGrantOptions, RunCommand, Selector, SessionEvent, SessionId,
    StreamEndReason, TerminalId, Update, WorkspaceId,
};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
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
const CLIENT: &str = "client_00000000000000000000000000000009";
const PROVIDER_SCOPE: &str = "provider_scope_0000000000000000000000000000000a";
const PROVIDER_ACTION: &str = "provider_action_0000000000000000000000000000000b";

static NEXT_SOCKET: AtomicU64 = AtomicU64::new(1);

fn socket_path() -> PathBuf {
    std::env::temp_dir().join(format!(
        "cmux-resource-rust-test-{}-{}.sock",
        std::process::id(),
        NEXT_SOCKET.fetch_add(1, Ordering::Relaxed)
    ))
}

fn request(reader: &mut BufReader<UnixStream>) -> Value {
    let mut line = String::new();
    assert_ne!(reader.read_line(&mut line).unwrap(), 0);
    let value: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(value["protocol"], "cmux.protocol/1");
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
            "protocol": "cmux.protocol/1",
            "type": "response",
            "id": request["id"],
            "ok": true,
            "result": result,
        })
    )
    .unwrap();
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
                "initial_content": "empty"
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
            cmux::CreateWorkspaceOptions {
                name: Some(String::new()),
                initial_content: InitialContent::Empty,
            },
            MutationOptions::new("create-key").unwrap(),
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
    assert_eq!(renamed.value.name.as_deref(), Some("renamed"));
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
            success(
                &mut stream,
                &rename,
                mutation_result(&rename, json!({"id": SCREEN, "name": expected})),
            );
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
                "protocol": "cmux.protocol/1",
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
                "protocol": "cmux.protocol/1",
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
fn streams_are_typed_and_cancel_uses_the_same_scoped_connection() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (control, _) = listener.accept().unwrap();
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let open = request(&mut reader);
        assert_eq!(open["operation"], "session.events");
        let stream_id = open["params"]["stream_id"].as_str().unwrap().to_string();
        success(&mut stream, &open, json!({"stream_id": stream_id}));
        writeln!(
            stream,
            "{}",
            json!({
                "protocol": "cmux.protocol/1",
                "type": "stream_item",
                "stream_id": stream_id,
                "sequence": "18446744073709551615",
                "cursor": {
                    "generation": "g",
                    "revision": "18446744073709551615"
                },
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
                "protocol": "cmux.protocol/1",
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
    let item = events.recv().unwrap().unwrap();
    assert_eq!(item.sequence, u64::MAX);
    assert_eq!(item.cursor.as_ref().unwrap().generation, "g");
    assert_eq!(item.cursor.as_ref().unwrap().revision, u64::MAX);
    assert!(matches!(item.value, SessionEvent::Unknown { .. }));
    events.cancel().unwrap();
    events.cancel().unwrap();
    assert!(events.recv().unwrap().is_none());
    assert_eq!(events.end().unwrap().reason, StreamEndReason::Canceled);
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
                "protocol": "cmux.protocol/1",
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
                "protocol": "cmux.protocol/1",
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
                "protocol": "cmux.protocol/1",
                "type": "stream_end",
                "stream_id": stream_id,
                "reason": reason
            });
            if let Some(recovery) = recovery {
                end["recovery"] = json!(recovery);
            }
            writeln!(stream, "{end}").unwrap();

            stream.set_read_timeout(Some(Duration::from_millis(200))).unwrap();
            let mut possible_cancel = String::new();
            match reader.read_line(&mut possible_cancel) {
                Ok(0) => {}
                Ok(_) => panic!("{reason} stream sent cancel after stream_end: {possible_cancel}"),
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
fn provider_machine_operations_are_scope_first_and_redacted() {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());

        let create = request(&mut reader);
        assert_eq!(create["operation"], "machine.create");
        assert_eq!(create["params"], json!({"provider_scope": PROVIDER_SCOPE}));
        success(
            &mut stream,
            &create,
            mutation_result(
                &create,
                json!({"id": MACHINE, "connection": "local", "deleted": false}),
            ),
        );

        let connect = request(&mut reader);
        assert_eq!(connect["operation"], "machine.connect_external");
        assert_eq!(
            connect["params"],
            json!({
                "provider_scope": PROVIDER_SCOPE,
                "specifier": "ssh://user:secret@host"
            })
        );
        success(
            &mut stream,
            &connect,
            mutation_result(
                &connect,
                json!({"id": MACHINE, "connection": "external", "deleted": false}),
            ),
        );

        let action = request(&mut reader);
        assert_eq!(action["operation"], "provider_action.invoke");
        assert_eq!(
            action["params"],
            json!({
                "machine": MACHINE,
                "provider_scope": PROVIDER_SCOPE,
                "provider_action": PROVIDER_ACTION,
                "parameters": {
                    "region": "west",
                    "replicas": 3
                }
            })
        );
        success(&mut stream, &action, mutation_result(&action, json!({"accepted": true})));

        let mark = request(&mut reader);
        assert_eq!(mark["operation"], "provider_workspace.mark");
        assert_eq!(
            mark["params"],
            json!({
                "machine": MACHINE,
                "provider_scope": PROVIDER_SCOPE,
                "session": SESSION,
                "workspace": WORKSPACE_A,
                "managed": true,
                "expected_revision": "20"
            })
        );
        success(
            &mut stream,
            &mark,
            mutation_result(
                &mark,
                json!({
                    "id": WORKSPACE_A,
                    "session_id": SESSION,
                    "name": "managed",
                    "index": 0,
                    "focused": true
                }),
            ),
        );

        let rename = request(&mut reader);
        assert_eq!(rename["operation"], "provider_workspace.rename");
        assert_eq!(rename["params"]["name"], "provider-renamed");
        success(
            &mut stream,
            &rename,
            mutation_result(
                &rename,
                json!({
                    "id": WORKSPACE_A,
                    "session_id": SESSION,
                    "name": "provider-renamed",
                    "index": 0,
                    "focused": true
                }),
            ),
        );

        let close = request(&mut reader);
        assert_eq!(close["operation"], "provider_workspace.close");
        success(&mut stream, &close, mutation_result(&close, json!({})));
    });

    let client = connect(&path);
    let provider = client.provider_scope(cmux::ProviderScopeId::parse(PROVIDER_SCOPE).unwrap());
    provider.create_machine().unwrap();
    let options = MachineConnectOptions::new("ssh://user:secret@host").unwrap();
    assert!(!format!("{options:?}").contains("secret"));
    provider.connect_external_machine(options).unwrap();
    let scoped_provider = client
        .machine(cmux::MachineId::parse(MACHINE).unwrap())
        .provider_scope(cmux::ProviderScopeId::parse(PROVIDER_SCOPE).unwrap());
    scoped_provider
        .action(ProviderActionId::parse(PROVIDER_ACTION).unwrap())
        .invoke(
            ProviderActionOptions::new().parameter("region", "west").parameter("replicas", 3_i32),
        )
        .unwrap();
    let workspace = client
        .session(SessionId::parse(SESSION).unwrap())
        .workspace(WorkspaceId::parse(WORKSPACE_A).unwrap());
    let marked = scoped_provider
        .mark_workspace_with(
            &workspace,
            true,
            MutationOptions::new("provider-mark").unwrap().with_expected_revision(20),
        )
        .unwrap();
    assert_eq!(marked.value.id.as_str(), WORKSPACE_A);
    scoped_provider.rename_workspace(&workspace, "provider-renamed").unwrap();
    scoped_provider.close_workspace(&workspace).unwrap();
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
        success(&mut stream, &metadata, json!({"id": CLIENT}));

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
        success(&mut stream, &sizing, json!({"id": CLIENT}));
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
        success(&mut stream, &by_id, json!({"text": "id"}));

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
        success(&mut stream, &by_name, json!({"text": "name"}));
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
