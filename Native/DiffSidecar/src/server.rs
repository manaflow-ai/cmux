use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use axum::body::Body;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Path as AxumPath, Query, State};
use axum::http::header::{
    CACHE_CONTROL, CONNECTION, CONTENT_LENGTH, CONTENT_TYPE, LOCATION, REFERRER_POLICY,
};
use axum::http::{HeaderMap, HeaderValue, Method, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{any, get, post};
use axum::{Json, Router};
use futures_util::StreamExt;
use notify::{RecursiveMode, Watcher};
use serde::Serialize;
use tokio::io::AsyncWriteExt;
use tokio::process::Command;
use tokio_util::io::ReaderStream;

use crate::manifest::{AllowedFile, Manifest, split_resource_path, valid_token};
use crate::protocol::{
    BranchListResult, DiffCommand, DiffRequest, DiffResponse, DiffResult, NavigationResult,
    handshake,
};
use crate::{HTTP_PROTOCOL_VERSION, PROTOCOL_VERSION, health_response};

#[derive(Clone)]
pub struct ServerConfig {
    pub root: PathBuf,
    pub cmux_executable: PathBuf,
    pub executable_path: PathBuf,
}

#[derive(Clone)]
struct AppState {
    config: Arc<ServerConfig>,
    client: reqwest::Client,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ServerStateFile<'a> {
    port: u16,
    pid: u32,
    root_path: &'a str,
    protocol_version: &'a str,
    executable_path: &'a str,
}

/// Runs the loopback sidecar until the listener exits.
///
/// # Errors
///
/// Returns an error when root validation, listener setup, state persistence, or serving fails.
pub async fn run(config: ServerConfig) -> Result<(), String> {
    validate_root(&config.root).await?;
    let listener = tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
        .await
        .map_err(|error| error.to_string())?;
    let port = listener
        .local_addr()
        .map_err(|error| error.to_string())?
        .port();
    write_state_file(&config, port).await?;

    let state = AppState {
        config: Arc::new(config),
        client: reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::limited(5))
            .timeout(Duration::from_secs(120))
            .build()
            .map_err(|error| error.to_string())?,
    };
    let app = Router::new()
        .route("/__cmux_diff_viewer_healthz", get(health))
        .route("/__cmux_diff_rpc", post(rpc))
        .route("/__cmux_diff_ws", get(websocket))
        .route("/__cmux_diff_viewer_refs", get(branch_refs))
        .route("/__cmux_diff_viewer_branch", get(branch_change))
        .route(
            "/__cmux_diff_viewer_wait/{*resource}",
            get(wait_for_resource),
        )
        .route("/{*resource}", any(resource))
        .with_state(state);

    let mut stdout = tokio::io::stdout();
    stdout
        .write_all(format!("{port}\n").as_bytes())
        .await
        .map_err(|error| error.to_string())?;
    stdout.flush().await.map_err(|error| error.to_string())?;
    axum::serve(listener, app)
        .await
        .map_err(|error| error.to_string())
}

async fn validate_root(root: &Path) -> Result<(), String> {
    let metadata = tokio::fs::metadata(root)
        .await
        .map_err(|error| error.to_string())?;
    if !metadata.is_dir() {
        return Err("diff root is not a directory".to_owned());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;

        if metadata.uid() != rustix::process::geteuid().as_raw() {
            return Err("diff root is not owned by the current user".to_owned());
        }
        if metadata.mode() & 0o777 != 0o700 {
            return Err("diff root permissions must be 0700".to_owned());
        }
    }
    Ok(())
}

async fn write_state_file(config: &ServerConfig, port: u16) -> Result<(), String> {
    let root = config.root.to_string_lossy();
    let executable = config.executable_path.to_string_lossy();
    let state = ServerStateFile {
        port,
        pid: std::process::id(),
        root_path: &root,
        protocol_version: HTTP_PROTOCOL_VERSION,
        executable_path: &executable,
    };
    let path = config.root.join(".server.json");
    let temporary = config
        .root
        .join(format!(".server-{}.tmp", std::process::id()));
    let bytes = serde_json::to_vec_pretty(&state).map_err(|error| error.to_string())?;
    tokio::fs::write(&temporary, bytes)
        .await
        .map_err(|error| error.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        tokio::fs::set_permissions(&temporary, std::fs::Permissions::from_mode(0o600))
            .await
            .map_err(|error| error.to_string())?;
    }
    tokio::fs::rename(temporary, path)
        .await
        .map_err(|error| error.to_string())
}

async fn health(method: Method) -> Response {
    text_response(
        StatusCode::OK,
        "text/plain; charset=utf-8",
        health_response().into_bytes(),
        method == Method::HEAD,
    )
}

async fn rpc(
    State(state): State<AppState>,
    Json(request): Json<DiffRequest>,
) -> Json<DiffResponse> {
    Json(handle_protocol_request(request, Some(&state)).await)
}

async fn websocket(State(state): State<AppState>, ws: WebSocketUpgrade) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_websocket(socket, state))
}

async fn handle_websocket(mut socket: WebSocket, state: AppState) {
    while let Some(Ok(message)) = socket.next().await {
        match message {
            Message::Text(text) => {
                let response = match serde_json::from_str::<DiffRequest>(&text) {
                    Ok(request) => handle_protocol_request(request, Some(&state)).await,
                    Err(_) => {
                        DiffResponse::failure(String::new(), "invalidRequest", "Invalid request")
                    }
                };
                let Ok(encoded) = serde_json::to_string(&response) else {
                    break;
                };
                if socket.send(Message::Text(encoded.into())).await.is_err() {
                    break;
                }
            }
            Message::Close(_) => break,
            Message::Ping(data) => {
                if socket.send(Message::Pong(data)).await.is_err() {
                    break;
                }
            }
            Message::Binary(_) | Message::Pong(_) => {}
        }
    }
}

async fn handle_protocol_request(request: DiffRequest, state: Option<&AppState>) -> DiffResponse {
    if request.version != PROTOCOL_VERSION {
        return DiffResponse::failure(
            request.id,
            "unsupportedVersion",
            "Unsupported protocol version",
        );
    }
    match request.command {
        DiffCommand::ProtocolHandshake => handshake(request.id),
        DiffCommand::BranchList(params) => {
            let Some(state) = state else {
                return DiffResponse::failure(request.id, "hostUnavailable", "Host unavailable");
            };
            match load_branch_refs(
                state,
                &params.repo_root,
                &params.capability_token,
                params.selected_base.as_deref(),
            )
            .await
            {
                Ok(value) => DiffResponse::success(request.id, DiffResult::Branches(value)),
                Err(()) => {
                    DiffResponse::failure(request.id, "branchListFailed", "Could not load branches")
                }
            }
        }
        DiffCommand::BranchChange(params) => {
            let Some(state) = state else {
                return DiffResponse::failure(request.id, "hostUnavailable", "Host unavailable");
            };
            match change_branch(
                state,
                &params.group_id,
                &params.repo_root,
                &params.base_ref,
                &params.capability_token,
            )
            .await
            {
                Ok(url) => DiffResponse::success(
                    request.id,
                    DiffResult::Navigation(NavigationResult { url }),
                ),
                Err(()) => DiffResponse::failure(
                    request.id,
                    "branchChangeFailed",
                    "Could not change diff base",
                ),
            }
        }
        _ => DiffResponse::failure(
            request.id,
            "unsupportedMethod",
            "This protocol method is not enabled by the current host",
        ),
    }
}

async fn branch_refs(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let Some(repo) = query.get("repo") else {
        return not_found(false);
    };
    let Some(token) = query.get("token").filter(|value| valid_token(value)) else {
        return not_found(false);
    };
    match load_branch_refs(&state, repo, token, query.get("base").map(String::as_str)).await {
        Ok(value) => match serde_json::to_vec(&value) {
            Ok(body) => text_response(
                StatusCode::OK,
                "application/json; charset=utf-8",
                body,
                false,
            ),
            Err(_) => not_found(false),
        },
        Err(()) => not_found(false),
    }
}

async fn load_branch_refs(
    state: &AppState,
    repo: &str,
    token: &str,
    base: Option<&str>,
) -> Result<BranchListResult, ()> {
    if !valid_token(token) {
        return Err(());
    }
    let mut command = Command::new(&state.config.cmux_executable);
    command
        .arg("__diff-viewer-refs")
        .arg("--repo")
        .arg(repo)
        .arg("--token")
        .arg(token)
        .stdin(Stdio::null())
        .stderr(Stdio::null());
    if let Some(base) = base {
        command.arg("--base").arg(base);
    }
    match command.output().await {
        Ok(output) if output.status.success() => {
            serde_json::from_slice(&output.stdout).map_err(|_| ())
        }
        _ => Err(()),
    }
}

async fn branch_change(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let (Some(group), Some(repo), Some(base), Some(token)) = (
        query.get("group"),
        query.get("repo"),
        query.get("base"),
        query.get("token").filter(|value| valid_token(value)),
    ) else {
        return not_found(false);
    };
    match change_branch(&state, group, repo, base, token).await {
        Ok(location) => redirect_response(&location),
        Err(()) => not_found(false),
    }
}

async fn change_branch(
    state: &AppState,
    group: &str,
    repo: &str,
    base: &str,
    token: &str,
) -> Result<String, ()> {
    if !valid_token(token) {
        return Err(());
    }
    let output = Command::new(&state.config.cmux_executable)
        .arg("__diff-viewer-branch")
        .arg("--group")
        .arg(group)
        .arg("--repo")
        .arg(repo)
        .arg("--base")
        .arg(base)
        .arg("--token")
        .arg(token)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .await;
    let Ok(output) = output else { return Err(()) };
    if !output.status.success() {
        return Err(());
    }
    let scheme_url = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    let Some(path) = scheme_url.strip_prefix(&format!("cmux-diff-viewer://{token}/")) else {
        return Err(());
    };
    Ok(format!(
        "http://127.0.0.1:{}/{token}/{path}#cmux-diff-viewer",
        server_port(state).await
    ))
}

async fn server_port(state: &AppState) -> u16 {
    let path = state.config.root.join(".server.json");
    let Ok(bytes) = tokio::fs::read(path).await else {
        return 0;
    };
    serde_json::from_slice::<serde_json::Value>(&bytes)
        .ok()
        .and_then(|value| value.get("port")?.as_u64())
        .and_then(|port| u16::try_from(port).ok())
        .unwrap_or(0)
}

async fn wait_for_resource(
    State(state): State<AppState>,
    AxumPath(resource_path): AxumPath<String>,
    method: Method,
) -> Response {
    let Some((_, file)) = resolve_allowed_file(&state, &resource_path).await else {
        return not_found(method == Method::HEAD);
    };
    let Ok(path) = file.canonical_local_path(&state.config.root).await else {
        return not_found(method == Method::HEAD);
    };
    let timeout = replacement_timeout();
    let watched = path.clone();
    let ready = tokio::task::spawn_blocking(move || wait_until_replaced(&watched, timeout))
        .await
        .unwrap_or(false);
    if !ready {
        return text_response(
            StatusCode::GATEWAY_TIMEOUT,
            "text/plain; charset=utf-8",
            b"504 Gateway Timeout\n".to_vec(),
            method == Method::HEAD,
        );
    }
    resource_response(&state, file, method == Method::HEAD).await
}

fn replacement_timeout() -> Duration {
    let seconds = std::env::var("CMUX_DIFF_VIEWER_WAIT_TIMEOUT_SECONDS")
        .ok()
        .and_then(|value| value.parse::<f64>().ok())
        .filter(|value| value.is_finite())
        .unwrap_or(120.0)
        .clamp(0.05, 600.0);
    Duration::from_secs_f64(seconds)
}

fn wait_until_replaced(path: &Path, timeout: Duration) -> bool {
    if !file_is_pending(path) {
        return true;
    }
    let (sender, receiver) = std::sync::mpsc::channel();
    let Ok(mut watcher) = notify::recommended_watcher(move |event| {
        let _ = sender.send(event);
    }) else {
        return false;
    };
    if watcher.watch(path, RecursiveMode::NonRecursive).is_err() {
        return false;
    }
    let deadline = std::time::Instant::now() + timeout;
    while file_is_pending(path) {
        let Some(remaining) = deadline.checked_duration_since(std::time::Instant::now()) else {
            return false;
        };
        if receiver.recv_timeout(remaining).is_err() {
            return false;
        }
    }
    true
}

fn file_is_pending(path: &Path) -> bool {
    let Ok(file) = std::fs::File::open(path) else {
        return false;
    };
    let mut bytes = Vec::with_capacity(8192);
    if std::io::Read::take(file, 8192)
        .read_to_end(&mut bytes)
        .is_err()
    {
        return false;
    }
    String::from_utf8_lossy(&bytes).contains("data-cmux-diff-pending=\"true\"")
}

async fn resource(
    State(state): State<AppState>,
    AxumPath(resource_path): AxumPath<String>,
    method: Method,
) -> Response {
    if method != Method::GET && method != Method::HEAD {
        return text_response(
            StatusCode::METHOD_NOT_ALLOWED,
            "text/plain; charset=utf-8",
            b"405 Method Not Allowed\n".to_vec(),
            false,
        );
    }
    let Some((_, file)) = resolve_allowed_file(&state, &resource_path).await else {
        return not_found(method == Method::HEAD);
    };
    resource_response(&state, file, method == Method::HEAD).await
}

async fn resolve_allowed_file(
    state: &AppState,
    resource_path: &str,
) -> Option<(String, AllowedFile)> {
    let normalized = format!("/{}", resource_path.trim_start_matches('/'));
    let (token, request_path) = split_resource_path(&normalized)?;
    let manifest = Manifest::load(&state.config.root, token).await.ok()?;
    let file = manifest.files_by_path().ok()?.remove(&request_path)?;
    Some((token.to_owned(), file))
}

async fn resource_response(state: &AppState, file: AllowedFile, head: bool) -> Response {
    if let Some(remote_url) = &file.remote_url {
        return remote_response(state, remote_url, head).await;
    }
    let Ok(path) = file.canonical_local_path(&state.config.root).await else {
        return not_found(head);
    };
    let Ok(metadata) = tokio::fs::metadata(&path).await else {
        return not_found(head);
    };
    let mut headers = base_headers();
    set_header(&mut headers, CONTENT_TYPE, content_type(&file.mime_type));
    set_header(&mut headers, CONTENT_LENGTH, metadata.len().to_string());
    if head {
        return (StatusCode::OK, headers, Body::empty()).into_response();
    }
    let Ok(open_file) = tokio::fs::File::open(path).await else {
        return not_found(false);
    };
    let body = Body::from_stream(ReaderStream::new(open_file));
    (StatusCode::OK, headers, body).into_response()
}

async fn remote_response(state: &AppState, raw_url: &str, head: bool) -> Response {
    let Ok(url) = reqwest::Url::parse(raw_url) else {
        return not_found(head);
    };
    if url.scheme() != "https"
        || url.host_str() != Some("github.com")
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return not_found(head);
    }
    if head {
        let mut headers = base_headers();
        set_header(&mut headers, CONTENT_TYPE, content_type("text/x-diff"));
        return (StatusCode::OK, headers, Body::empty()).into_response();
    }
    let Ok(response) = state.client.get(url).send().await else {
        return bad_gateway();
    };
    if !response.status().is_success() {
        return bad_gateway();
    }
    let mut headers = base_headers();
    set_header(&mut headers, CONTENT_TYPE, content_type("text/x-diff"));
    let body = Body::from_stream(
        response
            .bytes_stream()
            .map(|result| result.map_err(std::io::Error::other)),
    );
    (StatusCode::OK, headers, body).into_response()
}

fn base_headers() -> HeaderMap {
    let mut headers = HeaderMap::new();
    set_header(&mut headers, CACHE_CONTROL, "no-store");
    set_header(&mut headers, CONNECTION, "close");
    set_header(&mut headers, "cross-origin-resource-policy", "same-origin");
    set_header(&mut headers, "x-content-type-options", "nosniff");
    set_header(&mut headers, REFERRER_POLICY, "no-referrer");
    set_header(&mut headers, "origin-agent-cluster", "?1");
    headers
}

fn text_response(
    status: StatusCode,
    content_type_value: &str,
    body: Vec<u8>,
    head: bool,
) -> Response {
    let mut headers = base_headers();
    set_header(&mut headers, CONTENT_TYPE, content_type_value);
    set_header(&mut headers, CONTENT_LENGTH, body.len().to_string());
    let response_body = if head {
        Body::empty()
    } else {
        Body::from(body)
    };
    (status, headers, response_body).into_response()
}

fn redirect_response(location: &str) -> Response {
    let mut headers = base_headers();
    set_header(&mut headers, LOCATION, location);
    set_header(&mut headers, CONTENT_TYPE, "text/plain; charset=utf-8");
    (StatusCode::FOUND, headers, Body::from("302 Found\n")).into_response()
}

fn not_found(head: bool) -> Response {
    text_response(
        StatusCode::NOT_FOUND,
        "text/plain; charset=utf-8",
        b"404 Not Found\n".to_vec(),
        head,
    )
}

fn bad_gateway() -> Response {
    text_response(
        StatusCode::BAD_GATEWAY,
        "text/plain; charset=utf-8",
        b"502 Bad Gateway\n".to_vec(),
        false,
    )
}

fn content_type(mime_type: &str) -> &str {
    match mime_type {
        "text/html" => "text/html; charset=utf-8",
        "text/javascript" => "text/javascript; charset=utf-8",
        "text/x-diff" => "text/x-diff; charset=utf-8",
        _ => "application/octet-stream",
    }
}

fn set_header(
    headers: &mut HeaderMap,
    name: impl axum::http::header::IntoHeaderName,
    value: impl AsRef<str>,
) {
    if let Ok(value) = HeaderValue::from_str(value.as_ref()) {
        headers.insert(name, value);
    }
}

/// Writes one protocol handshake response as JSON to standard output.
///
/// # Errors
///
/// Returns an error when serialization or standard-output writes fail.
pub async fn write_handshake_to_stdout() -> Result<(), String> {
    let request = DiffRequest {
        id: "handshake".to_owned(),
        version: PROTOCOL_VERSION,
        command: DiffCommand::ProtocolHandshake,
    };
    let response = handle_protocol_request(request, None).await;
    let bytes = serde_json::to_vec(&response).map_err(|error| error.to_string())?;
    let mut stdout = tokio::io::stdout();
    stdout
        .write_all(&bytes)
        .await
        .map_err(|error| error.to_string())?;
    stdout
        .write_all(b"\n")
        .await
        .map_err(|error| error.to_string())?;
    stdout.flush().await.map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use crate::PROTOCOL_VERSION;
    use crate::protocol::{DiffCommand, DiffRequest, DiffResult};

    use super::handle_protocol_request;

    #[tokio::test]
    async fn handshake_reports_transport_capabilities() {
        let response = handle_protocol_request(
            DiffRequest {
                id: "test".to_owned(),
                version: PROTOCOL_VERSION,
                command: DiffCommand::ProtocolHandshake,
            },
            None,
        )
        .await;
        let Some(DiffResult::Handshake(handshake)) = response.result else {
            panic!("expected handshake result");
        };
        assert!(
            handshake
                .capabilities
                .contains(&"transport.webkit".to_owned())
        );
        assert!(
            handshake
                .capabilities
                .contains(&"transport.websocket".to_owned())
        );
    }
}
