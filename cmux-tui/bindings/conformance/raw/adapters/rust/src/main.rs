//! Protocol-10 conformance adapter for the public Rust SDK.

use cmux_sdk::raw::{
    AttachBuilder, BrowserBackRequest, COMMANDS, Client as CmuxClient, ClientConfig,
    CloseWorkspaceRequest, CreateTerminalRequest, EVENTS, Error as CmuxError, Event,
    MarkWorkspacesProviderManagedRequest, Optional, PairingResponseRequest, Pane, PingRequest,
    RenameWorkspaceRequest, SetClientInfoRequest, SubscriptionBuilder, TabKind, WaitForRequest,
};
use serde::Deserialize;
use serde_json::{Map, Value, json};
use std::io::{self, Read};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

#[derive(Debug, Deserialize)]
struct Request {
    id: Value,
    op: String,
    #[serde(default)]
    socket_path: String,
    #[serde(default)]
    timeout_ms: u64,
    #[serde(default)]
    max_frame_bytes: usize,
    #[serde(default)]
    max_buffered_events: usize,
    #[serde(default)]
    stream: String,
    #[serde(default)]
    surface: String,
    #[serde(default)]
    events: usize,
    #[serde(default)]
    close_after_ms: u64,
    #[serde(default)]
    deadline_ms: u64,
    #[serde(default)]
    authority: String,
    #[serde(default)]
    marker: String,
    #[serde(default)]
    workspace_name: String,
    #[serde(default)]
    renamed_name: String,
    #[serde(default)]
    presence: String,
}

fn main() {
    let mut input = String::new();
    if let Err(error) = io::stdin().read_to_string(&mut input) {
        eprintln!("{error}");
        std::process::exit(2);
    }
    let request: Request = match serde_json::from_str(input.trim()) {
        Ok(request) => request,
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(2);
        }
    };
    let mut response = Map::new();
    response.insert("contract_version".into(), Value::from(1));
    response.insert("id".into(), request.id.clone());
    match dispatch(&request) {
        Ok(value) => {
            response.insert("ok".into(), Value::Bool(true));
            response.insert("value".into(), value);
        }
        Err(error) => {
            response.insert("ok".into(), Value::Bool(false));
            response.insert(
                "error".into(),
                json!({"kind": classify(&error), "message": error.to_string()}),
            );
        }
    }
    println!("{}", Value::Object(response));
}

fn dispatch(request: &Request) -> Result<Value, CmuxError> {
    match request.op.as_str() {
        "metadata" => Ok(metadata()),
        "identify" => identify(request),
        "nullable-literal" => nullable_literal(request),
        "optional-non-null-response" => optional_non_null_response(request),
        "optional-nullable-request" => optional_nullable_request(request),
        "stream" => run_stream(request),
        "required-nullable-event" => required_nullable_event(request),
        "optional-non-null-event" => optional_non_null_event(request),
        "close-pending-stream" => close_pending_stream(request),
        "authority" => authority(request),
        "authority-denied" => authority_denied(request),
        "real-flow" => real_flow(request),
        operation => {
            Err(CmuxError::InvalidArgument(format!("unknown adapter operation {operation:?}")))
        }
    }
}

fn metadata() -> Value {
    json!({
        "commands": COMMANDS.iter().map(|item| json!({
            "name": item.name,
            "authority": item.authority,
            "stream": item.stream.map(|stream| stream.kind),
        })).collect::<Vec<_>>(),
        "events": EVENTS.iter().map(|item| json!({
            "name": item.name,
            "streams": item.streams,
        })).collect::<Vec<_>>(),
    })
}

fn config(request: &Request) -> ClientConfig {
    let timeout_ms = if request.timeout_ms == 0 { 1_000 } else { request.timeout_ms };
    ClientConfig::from_socket_path(&request.socket_path)
        .with_timeout(Duration::from_millis(timeout_ms))
        .with_max_frame_bytes(if request.max_frame_bytes == 0 {
            16 * 1024 * 1024
        } else {
            request.max_frame_bytes
        })
        .with_max_queued_events(if request.max_buffered_events == 0 {
            256
        } else {
            request.max_buffered_events
        })
}

fn identify(request: &Request) -> Result<Value, CmuxError> {
    let mut client = CmuxClient::connect(config(request))?;
    let value = client.identify_server()?;
    Ok(json!({
        "app": value.app,
        "protocol": value.protocol,
        "workspace_revision": value.workspace_revision.to_string(),
        "terminal_revision": value.terminal_revision.to_string(),
    }))
}

fn nullable_literal(request: &Request) -> Result<Value, CmuxError> {
    let mut client = CmuxClient::connect(config(request))?;
    let placement = client.create_terminal(CreateTerminalRequest {
        key: Optional::Value("workspace-key".into()),
        ..CreateTerminalRequest::default()
    })?;
    Ok(json!({"lifecycle": placement.lifecycle}))
}

fn optional_non_null_response(request: &Request) -> Result<Value, CmuxError> {
    let mut client = CmuxClient::connect(config(request))?;
    let value = client.identify_server()?;
    Ok(json!({"present": value.capabilities.is_some()}))
}

fn optional_nullable_request(request: &Request) -> Result<Value, CmuxError> {
    let name = match request.presence.as_str() {
        "omitted" => Optional::Missing,
        "null" => Optional::Null,
        "value" => Optional::Value("conformance-client".into()),
        presence => {
            return Err(CmuxError::InvalidArgument(format!("unknown presence {presence:?}")));
        }
    };
    let mut client = CmuxClient::connect(config(request))?;
    client.set_client_info(SetClientInfoRequest {
        capabilities: Optional::Missing,
        kind: Optional::Missing,
        name,
    })?;
    Ok(json!({"presence": request.presence}))
}

fn surface(request: &Request) -> Result<u64, CmuxError> {
    request
        .surface
        .parse()
        .or(if request.surface.is_empty() { Ok(7) } else { Err(()) })
        .map_err(|()| CmuxError::InvalidArgument("surface is not uint64".into()))
}

fn open_stream(
    client: &mut CmuxClient,
    request: &Request,
) -> Result<cmux_sdk::raw::Stream, CmuxError> {
    match request.stream.as_str() {
        "subscribe-coarse" => SubscriptionBuilder::coarse().open(client),
        "subscribe-deltas" => SubscriptionBuilder::deltas().open(client),
        "attach-byte" => AttachBuilder::bytes(surface(request)?).open(client),
        "attach-render" => AttachBuilder::render(surface(request)?).open(client),
        "attach-browser" => AttachBuilder::browser(surface(request)?).open(client),
        stream => Err(CmuxError::InvalidArgument(format!("unknown stream {stream:?}"))),
    }
}

fn run_stream(request: &Request) -> Result<Value, CmuxError> {
    let mut client = CmuxClient::connect(config(request))?;
    let mut stream = open_stream(&mut client, request)?;
    let mut events = Vec::new();
    let mut terminal = false;
    for _ in 0..request.events.max(1) {
        let timeout_ms = if request.timeout_ms == 0 { 1_000 } else { request.timeout_ms };
        match stream.recv_timeout(Duration::from_millis(timeout_ms)) {
            Ok(event) => {
                terminal = matches!(event, Event::Overflow(_) | Event::Detached(_));
                events.push(event_value(event));
            }
            Err(CmuxError::Closed) if terminal => break,
            Err(error) => return Err(error),
        }
    }
    Ok(json!({"events": events, "terminal": terminal}))
}

fn required_nullable_event(request: &Request) -> Result<Value, CmuxError> {
    let mut client = CmuxClient::connect(config(request))?;
    let mut stream = open_stream(&mut client, request)?;
    let timeout_ms = if request.timeout_ms == 0 { 1_000 } else { request.timeout_ms };
    match stream.recv_timeout(Duration::from_millis(timeout_ms))? {
        Event::ClientChanged(event) => Ok(json!({"name": event.name.into_option()})),
        Event::Unknown(unknown) if unknown.name.as_deref() == Some("client-changed") => {
            Err(CmuxError::Decode(
                unknown
                    .decode_error
                    .unwrap_or_else(|| "client-changed event failed typed decoding".into()),
            ))
        }
        event => Err(CmuxError::Decode(format!(
            "expected client-changed event, received {:?}",
            event.wire_name()
        ))),
    }
}

fn optional_non_null_event(request: &Request) -> Result<Value, CmuxError> {
    let mut client = CmuxClient::connect(config(request))?;
    let mut stream = open_stream(&mut client, request)?;
    let timeout_ms = if request.timeout_ms == 0 { 1_000 } else { request.timeout_ms };
    match stream.recv_timeout(Duration::from_millis(timeout_ms))? {
        Event::Output(event) => Ok(json!({"present": event.colors.is_some()})),
        event => Err(CmuxError::Decode(format!(
            "expected output event, received {:?}",
            event.wire_name()
        ))),
    }
}

fn event_value(event: Event) -> Value {
    match event {
        Event::Unknown(unknown) => json!({
            "event": unknown.name,
            "unknown": true,
            "raw": normalize_value(unknown.raw, None),
        }),
        Event::Empty(_) => json!({"event": "empty"}),
        Event::TreeChanged(_) => json!({"event": "tree-changed"}),
        Event::Output(value) => json!({
            "event": "output",
            "surface": value.surface.to_string(),
            "data": value.data,
        }),
        Event::Detached(value) => json!({
            "event": "detached",
            "surface": value.surface.to_string(),
        }),
        Event::Overflow(value) => {
            let mut result = json!({
                "event": "overflow",
                "error": value.error,
            });
            if let Value::Object(fields) = &mut result {
                if let Some(scope) = value.scope {
                    fields.insert("scope".into(), Value::String(scope));
                }
                if let Some(surface) = value.surface {
                    fields.insert("surface".into(), Value::String(surface.to_string()));
                }
            }
            result
        }
        Event::BrowserState(value) => json!({
            "event": "browser-state",
            "surface": value.surface.to_string(),
            "cols": value.cols,
            "rows": value.rows,
            "url": value.url,
            "title": value.title,
            "status": match value.status {
                cmux_sdk::raw::BrowserStateEventStatus::Starting => "starting",
                cmux_sdk::raw::BrowserStateEventStatus::Live => "live",
                cmux_sdk::raw::BrowserStateEventStatus::Failed => "failed",
            },
            "frames_stalled": value.frames_stalled,
        }),
        other => json!({"event": other.wire_name()}),
    }
}

fn normalize_value(value: Value, key: Option<&str>) -> Value {
    match value {
        Value::Object(fields) => Value::Object(
            fields
                .into_iter()
                .map(|(name, value)| {
                    let normalized = normalize_value(value, Some(&name));
                    (name, normalized)
                })
                .collect(),
        ),
        Value::Array(items) => {
            Value::Array(items.into_iter().map(|item| normalize_value(item, None)).collect())
        }
        Value::Number(number) if key.is_some_and(is_uint64_key) => {
            Value::String(number.to_string())
        }
        other => other,
    }
}

fn is_uint64_key(key: &str) -> bool {
    matches!(
        key,
        "client"
            | "index"
            | "offset"
            | "pane"
            | "pane_revision"
            | "projection_revision"
            | "request"
            | "screen"
            | "seq"
            | "surface"
            | "terminal_revision"
            | "timeout_ms"
            | "workspace"
            | "workspace_revision"
    ) || key.ends_with("_revision")
}

fn close_pending_stream(request: &Request) -> Result<Value, CmuxError> {
    let mut client = CmuxClient::connect(config(request))?;
    let mut stream = open_stream(&mut client, request)?;
    let closer = stream.closer();
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || {
        let _ = stream.recv();
        let _ = sender.send(());
    });
    thread::sleep(Duration::from_millis(request.close_after_ms.max(1)));
    closer.close();
    let unblocked =
        receiver.recv_timeout(Duration::from_millis(request.deadline_ms.max(1))).is_ok();
    Ok(json!({"unblocked": unblocked}))
}

fn authority(request: &Request) -> Result<Value, CmuxError> {
    let provider_authority = request.authority == "provider-authority";
    let mut client =
        CmuxClient::connect(config(request).with_provider_authority(provider_authority))?;
    let command = match request.authority.as_str() {
        "control" => {
            client.ping(PingRequest::default())?;
            "ping"
        }
        "frontend" => {
            client.browser_back(BrowserBackRequest { surface: 7 })?;
            "browser-back"
        }
        "local-admin" => {
            client.pairing_response(PairingResponseRequest { request: 1, approve: false })?;
            "pairing-response"
        }
        "provider-authority" => {
            client.identify_server()?;
            client.mark_workspaces_provider_managed(MarkWorkspacesProviderManagedRequest {
                authority: "conformance-authority".into(),
            })?;
            "mark-workspaces-provider-managed"
        }
        authority => {
            return Err(CmuxError::InvalidArgument(format!("unknown authority {authority:?}")));
        }
    };
    Ok(json!({"command": command}))
}

fn authority_denied(request: &Request) -> Result<Value, CmuxError> {
    let mut client = CmuxClient::connect(config(request))?;
    match client.mark_workspaces_provider_managed(MarkWorkspacesProviderManagedRequest {
        authority: "conformance-authority".into(),
    }) {
        Err(CmuxError::AuthorityDenied { .. }) => Ok(json!({"denied": true})),
        Err(error) => Err(error),
        Ok(_) => Err(CmuxError::InvalidArgument(
            "default client allowed provider-authority command".into(),
        )),
    }
}

fn real_flow(request: &Request) -> Result<Value, CmuxError> {
    let mut client = CmuxClient::connect(config(request))?;
    let identity = client.identify_server()?;
    let mut stream = SubscriptionBuilder::deltas().open(&mut client)?;
    let marker = default_string(&request.marker, "cmux-sdk-conformance-marker");
    let workspace_name = default_string(&request.workspace_name, "sdk-conformance-workspace");
    let renamed_name = default_string(&request.renamed_name, "sdk-conformance-renamed");
    let created = client.new_workspace_simple(Some(workspace_name), Some((80, 24)))?;
    let surface = created.surface;

    let result = (|| {
        client.send_text(surface, format!("printf '{marker}\\n'\r"))?;
        let waited = client.wait_for(WaitForRequest {
            pattern: marker.to_owned(),
            surface,
            timeout_ms: 5_000,
        })?;
        let screen = client.read_surface(surface)?;
        let tree = client.workspace_tree()?;
        let (workspace, terminal_created) = find_surface(&tree, surface).ok_or_else(|| {
            CmuxError::InvalidArgument(format!("created surface {surface} is absent from the tree"))
        })?;

        let renamed_result = client.rename_workspace(RenameWorkspaceRequest {
            expected_generation: Optional::Missing,
            expected_revision: Optional::Missing,
            key: Optional::Missing,
            mutation_id: Optional::Missing,
            name: renamed_name.to_owned(),
            origin: Optional::Missing,
            workspace: Optional::Value(workspace),
        })?;
        let renamed_tree = client.workspace_tree()?;
        let renamed = renamed_result.workspace == workspace
            && renamed_tree
                .workspaces
                .iter()
                .any(|item| item.id == workspace && item.name == renamed_name);

        let closed_result = client.close_workspace(CloseWorkspaceRequest {
            workspace: Optional::Value(workspace),
            ..CloseWorkspaceRequest::default()
        })?;
        let remaining = client.workspace_tree()?;
        let disappeared = remaining.workspaces.iter().all(|item| item.id != workspace);

        let required = ["workspace-added", "workspace-renamed", "workspace-closed"];
        let mut observed: Vec<String> = Vec::new();
        while observed.len() < 64
            && !required.iter().all(|name| observed.iter().any(|item| item == name))
        {
            let timeout_ms = request.timeout_ms.max(1);
            let event = stream.recv_timeout(Duration::from_millis(timeout_ms))?;
            if let Some(name) = event.wire_name() {
                observed.push(name.to_owned());
            }
        }
        let positions = required
            .iter()
            .map(|name| observed.iter().position(|item| item == name))
            .collect::<Vec<_>>();
        let stream_ordered = positions.iter().all(Option::is_some)
            && positions
                .windows(2)
                .all(|pair| pair[0].is_some_and(|left| pair[1].is_some_and(|right| left < right)));

        Ok(json!({
            "identified": identity.protocol == 12,
            "workspace_created": workspace > 0,
            "terminal_created": terminal_created,
            "marker_sent": true,
            "wait_matched": waited.matched,
            "read_contains_marker": screen.text.contains(marker),
            "stream_ordered": stream_ordered,
            "renamed": renamed,
            "closed": closed_result.workspace == workspace,
            "disappeared": disappeared,
            "observed_events": observed,
        }))
    })();

    stream.close();
    result
}

fn find_surface(tree: &cmux_sdk::raw::Tree, surface: u64) -> Option<(u64, bool)> {
    for workspace in &tree.workspaces {
        for screen in &workspace.screens {
            for pane in &screen.panes {
                let Pane::LivePane(live) = pane else {
                    continue;
                };
                if let Some(tab) = live.tabs.iter().find(|tab| tab.surface == surface) {
                    return Some((workspace.id, tab.kind == TabKind::Pty && !tab.dead));
                }
            }
        }
    }
    None
}

fn default_string<'a>(value: &'a str, fallback: &'a str) -> &'a str {
    if value.is_empty() { fallback } else { value }
}

fn classify(error: &CmuxError) -> &'static str {
    match error {
        CmuxError::Timeout(_) => "timeout",
        CmuxError::FrameTooLarge { .. } | CmuxError::QueueOverflow { .. } => "limit",
        CmuxError::Command { .. } => "command",
        CmuxError::Decode(_)
        | CmuxError::ProtocolVersion { .. }
        | CmuxError::MissingCapability { .. } => "decode",
        CmuxError::Connection(message) if message.to_ascii_lowercase().contains("utf-8") => {
            "decode"
        }
        _ => "transport",
    }
}
