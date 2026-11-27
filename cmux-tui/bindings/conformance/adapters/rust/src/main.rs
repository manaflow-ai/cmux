use cmux_sdk::{
    Client, Config, CreateScreenOptions, CreateWorkspaceOptions, CreatedPath, CreationRecovery,
    CreationResolution, CreationState, Cursor, Document, Error, EventStreamOptions, InitialContent,
    MutationOptions, RendererGrant, RunCommand, RunOptions, Selector, Session, SessionEvent,
    SessionEventStream, SessionId, StreamEndReason, TerminalExitOutcome, TerminalExitedLifecycle,
    TerminalId, TerminalPendingLifecycle, TerminalWaitExitResult, Workspace, WorkspaceId,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::io::{self, BufRead};
use std::time::Duration;

#[derive(Deserialize)]
struct Constants {
    session: String,
    workspace: String,
    revision: String,
    idempotency_key: String,
    correlation_key: String,
    name: String,
    terminal: String,
}

#[derive(Deserialize)]
struct Request {
    #[allow(dead_code)]
    contract_version: u32,
    id: String,
    op: String,
    socket_path: Option<String>,
    workspace_name: Option<String>,
    key_prefix: Option<String>,
    expected_stable_id: Option<String>,
    expected_duplicate_ids: Option<Vec<String>>,
    exit_shell: Option<String>,
    pending_timeout_ms: Option<String>,
    exit_timeout_ms: Option<String>,
    expected_created_path: Option<Value>,
    expected_correlation_key: Option<String>,
    timeout_ms: Option<String>,
    constants: Constants,
}

#[derive(Serialize)]
struct Response {
    contract_version: u32,
    id: String,
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    value: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<AdapterError>,
}

#[derive(Serialize)]
struct AdapterError {
    kind: &'static str,
    message: String,
}

fn main() {
    let line = match io::stdin().lock().lines().next() {
        Some(Ok(line)) => line,
        Some(Err(error)) => {
            write_error(String::new(), format!("cannot read adapter request: {error}"));
            return;
        }
        None => {
            write_error(String::new(), "adapter request is empty".to_string());
            return;
        }
    };
    let request: Request = match serde_json::from_str(&line) {
        Ok(request) => request,
        Err(error) => {
            write_error(String::new(), format!("invalid adapter request: {error}"));
            return;
        }
    };
    let id = request.id.clone();
    match dispatch(request) {
        Ok(value) => {
            write(Response { contract_version: 2, id, ok: true, value: Some(value), error: None })
        }
        Err(error) => write_error(id, error.to_string()),
    }
}

fn write_error(id: String, message: String) {
    write(Response {
        contract_version: 2,
        id,
        ok: false,
        value: None,
        error: Some(AdapterError { kind: "adapter", message }),
    });
}

fn write(response: Response) {
    match serde_json::to_string(&response) {
        Ok(encoded) => println!("{encoded}"),
        Err(error) => {
            eprintln!("cannot encode adapter response: {error}");
            std::process::exit(2);
        }
    }
}

fn dispatch(request: Request) -> Result<Value, Box<dyn std::error::Error>> {
    if request.op == "redaction" {
        return redaction();
    }
    let socket_path = request.socket_path.as_deref().ok_or("socket_path is required")?;
    let config = Config::from_socket_path(socket_path).with_timeout(Duration::from_secs(15));
    let client = Client::connect(config)?;
    let session = session(&client, &request.constants)?;
    let workspace = workspace(&session, &request.constants)?;
    let result = match request.op.as_str() {
        "read" => {
            let result = session.ping()?;
            json!({
                "alive": result.alive,
                "cursor": cursor_value(Some(&result.cursor)),
            })
        }
        "mutation-replay" => {
            let options = rename_options(&request.constants)?;
            let first = workspace.rename_with(request.constants.name.clone(), options.clone())?;
            let second = workspace.rename_with(request.constants.name.clone(), options)?;
            json!({
                "first": mutation_value(first),
                "second": mutation_value(second),
            })
        }
        "mutation-error" => {
            let error = workspace
                .rename_with(request.constants.name.clone(), rename_options(&request.constants)?)
                .expect_err("mutation unexpectedly succeeded");
            protocol_error(error)?
        }
        "creation-resolve" => creation_resolution_value(
            &session.creation().resolve(request.constants.correlation_key.clone())?,
        ),
        "creation-conflict" => {
            let result = session.create_workspace_with(
                CreateWorkspaceOptions {
                    name: Some(request.constants.name.clone()),
                    initial_content: InitialContent::Empty,
                    correlation_key: Some(request.constants.correlation_key.clone()),
                },
                MutationOptions::new(request.constants.idempotency_key.clone())?,
            );
            match result {
                Ok(_) => return Err("creation conflict unexpectedly succeeded".into()),
                Err(error) => protocol_error(error)?,
            }
        }
        "terminal-wait-exit" => {
            let timeout_ms = parse_decimal(
                request.timeout_ms.as_deref().ok_or("timeout_ms is required")?,
                "timeout_ms",
            )?;
            let terminal_id = TerminalId::parse(request.constants.terminal.clone())?;
            terminal_wait_exit_value(session.terminal(terminal_id).wait_exit(Some(timeout_ms))?)
        }
        "stream-unknown" => stream_unknown(session.events(EventStreamOptions::default())?)?,
        "stream-cancel" => stream_cancel(session.events(EventStreamOptions::default())?)?,
        "stream-overflow" => stream_overflow(&session)?,
        "live-setup" => {
            let name = request.workspace_name.as_deref().ok_or("workspace_name is required")?;
            let key_prefix = request.key_prefix.as_deref().ok_or("key_prefix is required")?;
            live_setup(&client, name, key_prefix)?
        }
        "live-creation-exit" => live_creation_exit(&client, &request)?,
        "live-exit-restart" => live_exit_restart(&client, &request)?,
        "live-restart" => {
            let name = request.workspace_name.as_deref().ok_or("workspace_name is required")?;
            let key_prefix = request.key_prefix.as_deref().ok_or("key_prefix is required")?;
            let stable_id =
                request.expected_stable_id.as_deref().ok_or("expected_stable_id is required")?;
            let duplicate_ids = request
                .expected_duplicate_ids
                .as_deref()
                .ok_or("expected_duplicate_ids is required")?;
            live_restart(&client, name, key_prefix, stable_id, duplicate_ids)?
        }
        other => return Err(format!("unknown adapter operation {other:?}").into()),
    };
    client.close()?;
    Ok(result)
}

fn session(client: &Client, constants: &Constants) -> cmux_sdk::Result<Session> {
    Ok(client.session(SessionId::parse(constants.session.clone())?))
}

fn workspace(session: &Session, constants: &Constants) -> cmux_sdk::Result<Workspace> {
    Ok(session.workspace(WorkspaceId::parse(constants.workspace.clone())?))
}

fn rename_options(constants: &Constants) -> cmux_sdk::Result<MutationOptions> {
    let revision = constants
        .revision
        .parse::<u64>()
        .map_err(|error| Error::InvalidArgument(error.to_string()))?;
    Ok(MutationOptions::new(constants.idempotency_key.clone())?.with_expected_revision(revision))
}

fn mutation_value(result: cmux_sdk::MutationResult<cmux_sdk::WorkspaceSnapshot>) -> Value {
    json!({
        "workspace_id": result.value.id.as_str(),
        "name": result.value.name,
        "generation": result.generation,
        "revision": result.revision.to_string(),
        "replayed": result.replayed,
    })
}

fn document_value(document: &Document) -> cmux_sdk::Result<Value> {
    document.deserialize()
}

fn cursor_value(cursor: Option<&Cursor>) -> Value {
    cursor.map_or(Value::Null, |cursor| {
        json!({
            "generation": cursor.generation,
            "revision": cursor.revision.to_string(),
        })
    })
}

fn protocol_error(error: Error) -> Result<Value, Box<dyn std::error::Error>> {
    match error {
        Error::Protocol { code, message, details, retryable } => Ok(json!({
            "code": code,
            "message": message,
            "details": details,
            "retryable": retryable,
        })),
        other => Err(other.into()),
    }
}

fn parse_decimal(value: &str, label: &str) -> Result<u64, Box<dyn std::error::Error>> {
    value.parse::<u64>().map_err(|error| format!("{label} is not a u64 decimal: {error}").into())
}

fn created_path_value(path: &CreatedPath) -> Value {
    match path {
        CreatedPath::Workspace { workspace_id } => json!({
            "kind": "workspace",
            "workspace_id": workspace_id.as_str(),
        }),
        CreatedPath::Terminal { workspace_id, screen_id, pane_id, tab_id, terminal_id } => json!({
            "kind": "terminal",
            "workspace_id": workspace_id.as_str(),
            "screen_id": screen_id.as_str(),
            "pane_id": pane_id.as_str(),
            "tab_id": tab_id.as_str(),
            "terminal_id": terminal_id.as_str(),
        }),
        CreatedPath::Browser { workspace_id, screen_id, pane_id, tab_id, browser_id } => json!({
            "kind": "browser",
            "workspace_id": workspace_id.as_str(),
            "screen_id": screen_id.as_str(),
            "pane_id": pane_id.as_str(),
            "tab_id": tab_id.as_str(),
            "browser_id": browser_id.as_str(),
        }),
    }
}

fn creation_state_name(state: CreationState) -> &'static str {
    match state {
        CreationState::Pending => "pending",
        CreationState::Created => "created",
        CreationState::NotApplied => "not_applied",
        CreationState::Indeterminate => "indeterminate",
    }
}

fn creation_recovery_name(recovery: CreationRecovery) -> &'static str {
    match recovery {
        CreationRecovery::RetrySameIdempotencyKey => "retry_same_idempotency_key",
        CreationRecovery::RetryNewIdempotencyKey => "retry_new_idempotency_key",
        CreationRecovery::Wait => "wait",
        CreationRecovery::None => "none",
        CreationRecovery::DoNotRetry => "do_not_retry",
    }
}

fn creation_resolution_value(resolution: &CreationResolution) -> Value {
    let mut value = serde_json::Map::new();
    value.insert("correlation_key".to_string(), json!(resolution.correlation_key));
    value.insert("state".to_string(), json!(creation_state_name(resolution.state)));
    value.insert("recovery".to_string(), json!(creation_recovery_name(resolution.recovery)));
    if let Some(operation) = &resolution.operation {
        value.insert("operation".to_string(), json!(operation));
    }
    if let Some(idempotency_key) = &resolution.idempotency_key {
        value.insert("idempotency_key".to_string(), json!(idempotency_key));
    }
    if let Some(path) = &resolution.created_path {
        value.insert("created_path".to_string(), created_path_value(path));
    }
    if let Some(generation) = &resolution.generation {
        value.insert("generation".to_string(), json!(generation));
    }
    if let Some(revision) = resolution.revision {
        value.insert("revision".to_string(), json!(revision.to_string()));
    }
    Value::Object(value)
}

fn pending_lifecycle_name(lifecycle: TerminalPendingLifecycle) -> &'static str {
    match lifecycle {
        TerminalPendingLifecycle::Launching => "launching",
        TerminalPendingLifecycle::Running => "running",
    }
}

fn exit_outcome_value(outcome: &TerminalExitOutcome) -> Value {
    match outcome {
        TerminalExitOutcome::Exit { code } => json!({
            "kind": "exit",
            "code": code,
        }),
        TerminalExitOutcome::Signal { signal, core_dumped } => json!({
            "kind": "signal",
            "signal": signal,
            "core_dumped": core_dumped,
        }),
        TerminalExitOutcome::Unknown { reason } => json!({
            "kind": "unknown",
            "reason": reason,
        }),
    }
}

fn terminal_wait_exit_value(result: TerminalWaitExitResult) -> Value {
    match result {
        TerminalWaitExitResult::Pending(value) => json!({
            "state": "pending",
            "terminal_id": value.terminal_id.as_str(),
            "lifecycle": pending_lifecycle_name(value.lifecycle),
            "revision": value.revision.to_string(),
        }),
        TerminalWaitExitResult::Exited(value) => {
            let lifecycle = match value.lifecycle {
                TerminalExitedLifecycle::Exited => "exited",
            };
            json!({
                "state": "exited",
                "terminal_id": value.terminal_id.as_str(),
                "lifecycle": lifecycle,
                "outcome": exit_outcome_value(&value.outcome),
                "exited_at": value.exited_at.to_string(),
                "revision": value.revision.to_string(),
            })
        }
    }
}

fn stream_unknown(mut stream: SessionEventStream) -> Result<Value, Box<dyn std::error::Error>> {
    let item = stream.recv()?.ok_or("session event stream ended before its item")?;
    let (kind, raw) = match item.value {
        SessionEvent::Unknown { kind, raw } => (kind, document_value(&raw)?),
        _ => return Err("session event was not the public Unknown variant".into()),
    };
    while stream.recv()?.is_some() {}
    let end = stream.end().ok_or("session event stream omitted terminal metadata")?;
    Ok(json!({
        "sequence": item.sequence.to_string(),
        "cursor": cursor_value(item.cursor.as_ref()),
        "kind": kind,
        "raw": raw,
        "end": end_reason(end.reason),
    }))
}

fn stream_cancel(mut stream: SessionEventStream) -> Result<Value, Box<dyn std::error::Error>> {
    stream.cancel()?;
    stream.cancel()?;
    let mut items_after_cancel = 0_u32;
    while stream.recv()?.is_some() {
        items_after_cancel += 1;
    }
    let end = stream.end().ok_or("canceled stream omitted terminal metadata")?;
    Ok(json!({
        "end": end_reason(end.reason),
        "items_after_cancel": items_after_cancel,
        "cancel_calls": 2,
    }))
}

fn stream_overflow(session: &Session) -> Result<Value, Box<dyn std::error::Error>> {
    let first = drain_end(session.events(EventStreamOptions::default())?)?;
    let mut second = session.events(EventStreamOptions::default())?;
    let item = second.recv()?.ok_or("second stream ended before its item")?;
    let second_kind = match item.value {
        SessionEvent::Unknown { kind, .. } => kind,
        _ => return Err("second stream item was not the public Unknown variant".into()),
    };
    while second.recv()?.is_some() {}
    let ping = session.ping()?;
    Ok(json!({
        "first_end": first,
        "second_kind": second_kind,
        "control_alive": ping.alive,
    }))
}

fn drain_end(mut stream: SessionEventStream) -> Result<&'static str, Box<dyn std::error::Error>> {
    loop {
        match stream.recv() {
            Ok(Some(_)) => {}
            Ok(None) => {
                let end = stream.end().ok_or("stream omitted terminal metadata")?;
                return Ok(end_reason(end.reason));
            }
            Err(Error::StreamEnded { reason, .. }) => {
                return match reason.as_str() {
                    "gap" => Ok("gap"),
                    "error" => Ok("error"),
                    other => Err(format!("unexpected stream end reason {other:?}").into()),
                };
            }
            Err(error) => return Err(error.into()),
        }
    }
}

fn end_reason(reason: StreamEndReason) -> &'static str {
    match reason {
        StreamEndReason::Completed => "completed",
        StreamEndReason::Canceled => "canceled",
        StreamEndReason::Closed => "closed",
        StreamEndReason::Gap => "gap",
        StreamEndReason::Error => "error",
    }
}

fn redaction() -> Result<Value, Box<dyn std::error::Error>> {
    const SPECIFIER: &str = "provider://conformance-secret";
    const TOKEN: &str = "renderer-conformance-secret";
    let specifier = RendererGrant::new(
        SPECIFIER,
        "unix:///tmp/renderer",
        TerminalId::parse("term_66666666666666666666666666666666")?,
        vec!["render".to_string()],
        1000,
    )?;
    let grant = RendererGrant::new(
        TOKEN,
        "unix:///tmp/renderer",
        TerminalId::parse("term_66666666666666666666666666666666")?,
        vec!["render".to_string()],
        1000,
    )?;
    Ok(json!({
        "specifier_redacted": !format!("{specifier:?}").contains(SPECIFIER),
        "renderer_token_redacted": !format!("{grant:?}").contains(TOKEN),
    }))
}

fn workspace_rows(
    session: &Session,
) -> Result<BTreeMap<String, String>, Box<dyn std::error::Error>> {
    let mut rows = BTreeMap::new();
    for workspace in session.workspaces()? {
        let snapshot = workspace.refresh()?;
        rows.insert(snapshot.id.as_str().to_string(), snapshot.name);
    }
    Ok(rows)
}

fn create_empty_workspace(
    session: &Session,
    name: &str,
    key: String,
) -> Result<Workspace, Box<dyn std::error::Error>> {
    Ok(session
        .create_workspace_with(
            CreateWorkspaceOptions {
                name: Some(name.to_string()),
                initial_content: InitialContent::Empty,
                correlation_key: None,
            },
            MutationOptions::new(key)?,
        )?
        .resource)
}

fn live_setup(
    client: &Client,
    name: &str,
    key_prefix: &str,
) -> Result<Value, Box<dyn std::error::Error>> {
    let session = client.current_session();
    let pinged = session.ping()?.alive;
    let stable = create_empty_workspace(&session, name, format!("{key_prefix}-stable-create"))?;
    let stable_id = stable.id().ok_or("created stable workspace lacks an exact ID")?.clone();
    let stable_renamed_name = format!("{name}-renamed");
    let renamed = stable.rename_with(
        stable_renamed_name.clone(),
        MutationOptions::new(format!("{key_prefix}-stable-rename"))?,
    )?;

    let duplicate_name = format!("{name}-duplicate");
    let mut duplicate_ids = Vec::with_capacity(2);
    for suffix in ["a", "b"] {
        let workspace = create_empty_workspace(
            &session,
            &duplicate_name,
            format!("{key_prefix}-duplicate-{suffix}"),
        )?;
        duplicate_ids
            .push(workspace.id().ok_or("created duplicate workspace lacks an exact ID")?.clone());
    }

    let (ambiguity_code, ambiguity_candidates) =
        match session.workspace(Selector::name(duplicate_name.clone())).rename_with(
            format!("{name}-must-not-apply"),
            MutationOptions::new(format!("{key_prefix}-ambiguous-rename"))?,
        ) {
            Err(Error::Protocol { code, details, .. }) => {
                let candidates = details
                    .get("candidates")
                    .and_then(Value::as_array)
                    .ok_or("selector ambiguity omitted candidates")?
                    .iter()
                    .map(|candidate| {
                        candidate
                            .as_str()
                            .map(str::to_string)
                            .ok_or("selector ambiguity candidate is not a string")
                    })
                    .collect::<Result<Vec<_>, _>>()?;
                (code, candidates)
            }
            Err(error) => return Err(error.into()),
            Ok(_) => return Err("duplicate workspace selector unexpectedly mutated".into()),
        };
    let expected_candidates = duplicate_ids
        .iter()
        .map(|identifier| identifier.as_str().to_string())
        .collect::<BTreeSet<_>>();
    let observed_candidates = ambiguity_candidates.iter().cloned().collect::<BTreeSet<_>>();
    let preserved_candidates = ambiguity_candidates.len() == duplicate_ids.len()
        && observed_candidates == expected_candidates;

    let rows = workspace_rows(&session)?;
    let no_mutation = duplicate_ids
        .iter()
        .all(|identifier| rows.get(identifier.as_str()) == Some(&duplicate_name))
        && !rows.values().any(|value| value == &format!("{name}-must-not-apply"));
    Ok(json!({
        "pinged": pinged,
        "stable_id": stable_id.as_str(),
        "stable_renamed": renamed.value.name == stable_renamed_name,
        "duplicate_ids": duplicate_ids.iter().map(|identifier| identifier.as_str()).collect::<Vec<_>>(),
        "ambiguity_code": ambiguity_code,
        "ambiguity_preserved_all_candidates": preserved_candidates,
        "no_mutation": no_mutation,
    }))
}

fn live_creation_exit(
    client: &Client,
    request: &Request,
) -> Result<Value, Box<dyn std::error::Error>> {
    let session = client.current_session();
    let stable_id = WorkspaceId::parse(
        request.expected_stable_id.as_deref().ok_or("expected_stable_id is required")?.to_string(),
    )?;
    let key_prefix = request.key_prefix.as_deref().ok_or("key_prefix is required")?;
    let exit_shell = request.exit_shell.as_deref().ok_or("exit_shell is required")?;
    let workspace = session.workspace(stable_id);

    let screen_created = workspace.create_screen_with(
        CreateScreenOptions::default(),
        MutationOptions::new(format!("{key_prefix}-runtime-screen"))?,
    )?;
    let screen_id =
        screen_created.value.screen_id().cloned().ok_or("screen.create omitted screen_id")?;
    let pane_id = screen_created.value.pane_id().cloned().ok_or("screen.create omitted pane_id")?;
    let pane = workspace.screen(screen_id).pane(pane_id);

    let correlation_key = format!("{key_prefix}-terminal-correlation");
    let run_options = RunOptions::command(RunCommand::shell(exit_shell)?)
        .correlation_key(correlation_key.clone())?;
    let run_result =
        pane.run_with(run_options, MutationOptions::new(format!("{key_prefix}-terminal-run"))?)?;
    let created_path = run_result.value.clone();
    let terminal = run_result.resource;

    let pending_timeout = parse_decimal(
        request.pending_timeout_ms.as_deref().ok_or("pending_timeout_ms is required")?,
        "pending_timeout_ms",
    )?;
    let (pending_terminal_id, pending_lifecycle) =
        match terminal.wait_exit(Some(pending_timeout))? {
            TerminalWaitExitResult::Pending(value) => {
                (value.terminal_id.as_str().to_string(), pending_lifecycle_name(value.lifecycle))
            }
            TerminalWaitExitResult::Exited(_) => {
                return Err("terminal exited before the pending observation".into());
            }
        };

    let resolution = session.creation().resolve(correlation_key.clone())?;
    if resolution.created_path.as_ref() != Some(&created_path) {
        return Err("creation resolution returned a different terminal path".into());
    }
    let creation_generation =
        resolution.generation.as_deref().ok_or("created resolution omitted generation")?;
    let creation_revision =
        resolution.revision.ok_or("created resolution omitted revision")?.to_string();

    let exit_timeout = parse_decimal(
        request.exit_timeout_ms.as_deref().ok_or("exit_timeout_ms is required")?,
        "exit_timeout_ms",
    )?;
    let exited = match terminal.wait_exit(Some(exit_timeout))? {
        TerminalWaitExitResult::Exited(value) => value,
        TerminalWaitExitResult::Pending(_) => {
            return Err("terminal remained pending after the exit timeout".into());
        }
    };
    let exit_lifecycle = match exited.lifecycle {
        TerminalExitedLifecycle::Exited => "exited",
    };
    let exit_code = match exited.outcome {
        TerminalExitOutcome::Exit { code } => code,
        TerminalExitOutcome::Signal { .. } | TerminalExitOutcome::Unknown { .. } => {
            return Err("terminal did not return an exit-code outcome".into());
        }
    };

    Ok(json!({
        "correlation_key": correlation_key,
        "created_path": created_path_value(&created_path),
        "pending_terminal_id": pending_terminal_id,
        "pending_state": "pending",
        "pending_lifecycle": pending_lifecycle,
        "creation_state": creation_state_name(resolution.state),
        "creation_recovery": creation_recovery_name(resolution.recovery),
        "creation_generation": creation_generation,
        "creation_revision": creation_revision,
        "exit_state": "exited",
        "exit_terminal_id": exited.terminal_id.as_str(),
        "exit_lifecycle": exit_lifecycle,
        "exit_kind": "exit",
        "exit_code": exit_code,
        "exited_at": exited.exited_at.to_string(),
        "exit_revision": exited.revision.to_string(),
    }))
}

fn live_exit_restart(
    client: &Client,
    request: &Request,
) -> Result<Value, Box<dyn std::error::Error>> {
    let session = client.current_session();
    let correlation_key = request
        .expected_correlation_key
        .as_deref()
        .ok_or("expected_correlation_key is required")?;
    let resolution = session.creation().resolve(correlation_key.to_string())?;
    let created_path =
        resolution.created_path.as_ref().ok_or("created resolution omitted created_path")?;
    let normalized_path = created_path_value(created_path);
    let expected_path =
        request.expected_created_path.as_ref().ok_or("expected_created_path is required")?;
    if &normalized_path != expected_path {
        return Err("durable creation path differs from the first process".into());
    }
    let terminal_id = expected_path
        .get("terminal_id")
        .and_then(Value::as_str)
        .ok_or("expected_created_path.terminal_id must be a string")?;
    let timeout_ms = parse_decimal(
        request.exit_timeout_ms.as_deref().ok_or("exit_timeout_ms is required")?,
        "exit_timeout_ms",
    )?;
    let exited = match session
        .terminal(TerminalId::parse(terminal_id.to_string())?)
        .wait_exit(Some(timeout_ms))?
    {
        TerminalWaitExitResult::Exited(value) => value,
        TerminalWaitExitResult::Pending(_) => {
            return Err("durable terminal exit remained pending".into());
        }
    };
    let exit_lifecycle = match exited.lifecycle {
        TerminalExitedLifecycle::Exited => "exited",
    };
    let exit_code = match exited.outcome {
        TerminalExitOutcome::Exit { code } => code,
        TerminalExitOutcome::Signal { .. } | TerminalExitOutcome::Unknown { .. } => {
            return Err("durable terminal outcome was not an exit code".into());
        }
    };
    let generation =
        resolution.generation.as_deref().ok_or("created resolution omitted generation")?;
    let revision = resolution.revision.ok_or("created resolution omitted revision")?;

    Ok(json!({
        "correlation_key": resolution.correlation_key,
        "created_path": normalized_path,
        "creation_state": creation_state_name(resolution.state),
        "creation_recovery": creation_recovery_name(resolution.recovery),
        "creation_generation": generation,
        "creation_revision": revision.to_string(),
        "exit_state": "exited",
        "exit_terminal_id": exited.terminal_id.as_str(),
        "exit_lifecycle": exit_lifecycle,
        "exit_kind": "exit",
        "exit_code": exit_code,
        "exited_at": exited.exited_at.to_string(),
        "exit_revision": exited.revision.to_string(),
    }))
}

fn live_restart(
    client: &Client,
    name: &str,
    key_prefix: &str,
    expected_stable_id: &str,
    expected_duplicate_ids: &[String],
) -> Result<Value, Box<dyn std::error::Error>> {
    if expected_duplicate_ids.len() != 2 {
        return Err("expected_duplicate_ids must contain two IDs".into());
    }
    let stable_id = WorkspaceId::parse(expected_stable_id.to_string())?;
    let duplicate_ids = expected_duplicate_ids
        .iter()
        .cloned()
        .map(WorkspaceId::parse)
        .collect::<cmux_sdk::Result<Vec<_>>>()?;
    let session = client.current_session();
    let rows = workspace_rows(&session)?;
    let expected_ids = std::iter::once(&stable_id).chain(duplicate_ids.iter()).collect::<Vec<_>>();
    let same_ids = expected_ids.iter().all(|identifier| rows.contains_key(identifier.as_str()));
    let stable_name_preserved = rows.get(stable_id.as_str()) == Some(&format!("{name}-renamed"));
    let duplicate_name = format!("{name}-duplicate");
    let duplicates_preserved = duplicate_ids
        .iter()
        .all(|identifier| rows.get(identifier.as_str()) == Some(&duplicate_name));

    session
        .workspace(stable_id.clone())
        .close_with(MutationOptions::new(format!("{key_prefix}-close-stable"))?)?;
    for (suffix, identifier) in ["a", "b"].iter().zip(duplicate_ids.iter()) {
        session
            .workspace(identifier.clone())
            .close_with(MutationOptions::new(format!("{key_prefix}-close-{suffix}"))?)?;
    }
    let remaining = workspace_rows(&session)?;
    let disappeared =
        expected_ids.iter().all(|identifier| !remaining.contains_key(identifier.as_str()));
    Ok(json!({
        "same_ids": same_ids,
        "stable_name_preserved": stable_name_preserved,
        "duplicates_preserved": duplicates_preserved,
        "closed": true,
        "disappeared": disappeared,
    }))
}
