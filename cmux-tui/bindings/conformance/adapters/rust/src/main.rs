use cmux_client::{
    Client, Config, CreateWorkspaceOptions, Cursor, Document, Error, EventStreamOptions,
    InitialContent, MachineConnectOptions, MutationOptions, RendererGrant, Session, SessionEvent,
    SessionEventStream, SessionId, StreamEndReason, TerminalId, Workspace, WorkspaceId,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::io::{self, BufRead};
use std::time::Duration;

#[derive(Deserialize)]
struct Constants {
    session: String,
    workspace: String,
    generation: String,
    revision: String,
    idempotency_key: String,
    name: String,
}

#[derive(Deserialize)]
struct Request {
    #[allow(dead_code)]
    contract_version: u32,
    id: String,
    op: String,
    socket_path: Option<String>,
    workspace_name: Option<String>,
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
            let fields = document_value(&session.ping()?)?;
            json!({
                "alive": fields["alive"],
                "cursor": fields["cursor"],
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
        "stream-unknown" => stream_unknown(session.events(EventStreamOptions::default())?)?,
        "stream-cancel" => stream_cancel(session.events(EventStreamOptions::default())?)?,
        "stream-overflow" => stream_overflow(&session)?,
        "live-flow" => {
            let name = request.workspace_name.as_deref().ok_or("workspace_name is required")?;
            live_flow(&client, name)?
        }
        other => return Err(format!("unknown adapter operation {other:?}").into()),
    };
    client.close()?;
    Ok(result)
}

fn session(client: &Client, constants: &Constants) -> cmux_client::Result<Session> {
    Ok(client.session(SessionId::parse(constants.session.clone())?))
}

fn workspace(session: &Session, constants: &Constants) -> cmux_client::Result<Workspace> {
    Ok(session.workspace(WorkspaceId::parse(constants.workspace.clone())?))
}

fn rename_options(constants: &Constants) -> cmux_client::Result<MutationOptions> {
    let revision = constants
        .revision
        .parse::<u64>()
        .map_err(|error| Error::InvalidArgument(error.to_string()))?;
    Ok(MutationOptions::new(constants.idempotency_key.clone())?.with_expected_revision(revision))
}

fn mutation_value(result: cmux_client::MutationResult<cmux_client::WorkspaceSnapshot>) -> Value {
    json!({
        "workspace_id": result.value.id.as_str(),
        "name": result.value.name,
        "generation": result.generation,
        "revision": result.revision.to_string(),
        "replayed": result.replayed,
    })
}

fn document_value(document: &Document) -> cmux_client::Result<Value> {
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
    let fields = document_value(&session.ping()?)?;
    Ok(json!({
        "first_end": first,
        "second_kind": second_kind,
        "control_alive": fields["alive"],
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
    let connect = MachineConnectOptions::new(SPECIFIER)?;
    let grant = RendererGrant::new(
        TOKEN,
        "unix:///tmp/renderer",
        TerminalId::parse("term_66666666666666666666666666666666")?,
        vec!["render".to_string()],
        1000,
    )?;
    Ok(json!({
        "specifier_redacted": !format!("{connect:?}").contains(SPECIFIER),
        "renderer_token_redacted": !format!("{grant:?}").contains(TOKEN),
    }))
}

fn live_flow(client: &Client, name: &str) -> Result<Value, Box<dyn std::error::Error>> {
    let session = client.current_session();
    let pinged = document_value(&session.ping()?)?["alive"].as_bool().unwrap_or(false);
    let created = session.create_workspace_with(
        CreateWorkspaceOptions {
            name: Some(name.to_string()),
            initial_content: InitialContent::Empty,
        },
        MutationOptions::new("live-create")?,
    )?;
    let workspace = created.resource;
    let created_id = workspace.id().ok_or("created workspace handle lacks an exact ID")?.clone();
    let renamed =
        workspace.rename_with(format!("{name}-renamed"), MutationOptions::new("live-rename")?)?;
    let listed = session.workspaces()?.iter().any(|candidate| candidate.id() == Some(&created_id));
    workspace.close_with(MutationOptions::new("live-close")?)?;
    let disappeared =
        session.workspaces()?.iter().all(|candidate| candidate.id() != Some(&created_id));
    Ok(json!({
        "pinged": pinged,
        "created": true,
        "renamed": renamed.value.name.as_deref() == Some(&format!("{name}-renamed")),
        "listed": listed,
        "closed": true,
        "disappeared": disappeared,
    }))
}
