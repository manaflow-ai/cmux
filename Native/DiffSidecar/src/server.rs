use std::collections::HashMap;
use std::fs::OpenOptions;
#[cfg(feature = "http-server")]
use std::io::Read;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::{Duration, SystemTime};

#[cfg(feature = "http-server")]
use axum::body::Body;
#[cfg(feature = "http-server")]
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
#[cfg(feature = "http-server")]
use axum::extract::{Path as AxumPath, Query, State};
#[cfg(feature = "http-server")]
use axum::http::header::{
    CACHE_CONTROL, CONNECTION, CONTENT_ENCODING, CONTENT_LENGTH, CONTENT_TYPE, HOST, LOCATION,
    ORIGIN, REFERRER_POLICY,
};
#[cfg(feature = "http-server")]
use axum::http::{HeaderMap, HeaderValue, Method, StatusCode};
#[cfg(feature = "http-server")]
use axum::response::{IntoResponse, Response};
#[cfg(feature = "http-server")]
use axum::routing::{any, get, post};
#[cfg(feature = "http-server")]
use axum::{Json, Router};
use fs2::FileExt;
#[cfg(feature = "http-server")]
use futures_util::StreamExt;
#[cfg(feature = "http-server")]
use notify::{RecursiveMode, Watcher};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::process::Command;
use tokio::sync::{RwLock, Semaphore};
#[cfg(feature = "http-server")]
use tokio_util::io::ReaderStream;

use crate::PROTOCOL_VERSION;
use crate::manifest::{
    AllowedFile, Manifest, split_resource_path, valid_request_path, valid_token,
};
use crate::protocol::{
    BranchListResult, DiffCommand, DiffRequest, DiffResourceRef, DiffResponse, DiffResult,
    DiffSource, NavigationResult, OpenSessionRequest, SessionOpened, SessionRequest, handshake,
};
#[cfg(feature = "http-server")]
use crate::{HTTP_PROTOCOL_VERSION, health_response};

#[derive(Clone)]
pub struct ServerConfig {
    pub root: PathBuf,
    pub cmux_executable: PathBuf,
    pub executable_path: PathBuf,
}

#[derive(Clone)]
struct AppState {
    config: Arc<ServerConfig>,
    #[cfg(feature = "http-server")]
    client: Option<reqwest::Client>,
    port: u16,
    manifests: Arc<RwLock<HashMap<String, CachedManifest>>>,
    child_processes: Arc<Semaphore>,
}

#[derive(Clone)]
struct CachedManifest {
    fingerprint: ManifestFingerprint,
    files: Arc<HashMap<String, AllowedFile>>,
}

#[derive(Clone, Copy, Eq, PartialEq)]
struct ManifestFingerprint {
    byte_length: u64,
    modified: Option<SystemTime>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BranchSessionAuthorization {
    token: String,
    #[serde(rename = "groupID")]
    group_id: String,
    allowed_repo_roots: Vec<String>,
}

const MAX_CACHED_MANIFESTS: usize = 64;
const MAX_RPC_REQUEST_BYTES: usize = 1024 * 1024;
const MAX_RPC_RESPONSE_BYTES: usize = 32 * 1024 * 1024;
const RPC_STDIN_READ_TIMEOUT: Duration = Duration::from_secs(10);
// The caller-supplied ID cannot be trusted until the complete envelope parses.
const UNTRUSTED_RPC_REQUEST_ID: &str = "__cmux_untrusted_request__";
const MAX_CONCURRENT_CHILD_PROCESSES: usize = 4;
const BRANCH_LIST_CHILD_TIMEOUT: Duration = Duration::from_secs(30);
const SESSION_GIT_TIMEOUT: Duration = Duration::from_secs(60);
const SESSION_OPEN_TIMEOUT: Duration = Duration::from_secs(120);
const MAX_SESSION_PATCH_BYTES: u64 = 512 * 1024 * 1024;
const ORPHAN_SESSION_TEMP_MIN_AGE: Duration = Duration::from_secs(2 * 60);
const ORPHAN_SESSION_FINAL_MIN_AGE: Duration = Duration::from_secs(24 * 60 * 60);
const MAX_ORPHAN_SCAN_ENTRIES: usize = 4096;
const MAX_ORPHAN_REMOVALS: usize = 64;
const MAX_TEMP_INDEX_ENTRIES: usize = 4096;

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct SessionOwner {
    session_id: String,
    capability_token: String,
}
// Branch regeneration runs Git commands with 60-second deadlines, then writes
// the page, patch, assets, and manifest. Keep the outer safety deadline above
// that complete contract while still releasing a stuck child eventually.
const BRANCH_CHANGE_CHILD_TIMEOUT: Duration = Duration::from_secs(120);

#[cfg(feature = "http-server")]
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
#[cfg(feature = "http-server")]
pub async fn run(config: ServerConfig) -> Result<(), String> {
    validate_root(&config.root).await?;
    prune_orphaned_session_temp_files(
        &config.root,
        ORPHAN_SESSION_TEMP_MIN_AGE,
        ORPHAN_SESSION_FINAL_MIN_AGE,
        MAX_ORPHAN_SCAN_ENTRIES,
    )
    .await;
    // Ring keeps the mandatory sidecar build self-contained. Reqwest's default
    // AWS-LC provider adds an undeclared CMake prerequisite to every Xcode build.
    let _ = rustls::crypto::ring::default_provider().install_default();
    let listener = tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
        .await
        .map_err(|error| error.to_string())?;
    let port = listener
        .local_addr()
        .map_err(|error| error.to_string())?
        .port();
    write_state_file(&config, port).await?;

    let state = app_state(config, port)?;
    let app = router(state);

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

#[cfg(feature = "http-server")]
fn app_state(config: ServerConfig, port: u16) -> Result<AppState, String> {
    Ok(AppState {
        config: Arc::new(config),
        #[cfg(feature = "http-server")]
        client: if port == 0 {
            None
        } else {
            Some(
                reqwest::Client::builder()
                    .redirect(reqwest::redirect::Policy::limited(5))
                    .timeout(Duration::from_secs(120))
                    .build()
                    .map_err(|error| error.to_string())?,
            )
        },
        port,
        manifests: Arc::new(RwLock::new(HashMap::new())),
        child_processes: Arc::new(Semaphore::new(MAX_CONCURRENT_CHILD_PROCESSES)),
    })
}

#[cfg(not(feature = "http-server"))]
fn app_state(config: ServerConfig, port: u16) -> AppState {
    AppState {
        config: Arc::new(config),
        port,
        manifests: Arc::new(RwLock::new(HashMap::new())),
        child_processes: Arc::new(Semaphore::new(MAX_CONCURRENT_CHILD_PROCESSES)),
    }
}

/// Handles one typed request from standard input and writes one response to
/// standard output. This is the native `WebKit` transport boundary: it performs
/// no bind, connect, or listen operation.
///
/// # Errors
///
/// Returns an error when the secure root, request envelope, or stdio operation
/// is invalid.
pub async fn run_rpc(config: ServerConfig) -> Result<(), String> {
    validate_root(&config.root).await?;
    prune_orphaned_session_temp_files(
        &config.root,
        ORPHAN_SESSION_TEMP_MIN_AGE,
        ORPHAN_SESSION_FINAL_MIN_AGE,
        MAX_ORPHAN_SCAN_ENTRIES,
    )
    .await;
    #[cfg(unix)]
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        .map_err(|error| error.to_string())?;
    #[cfg(unix)]
    tokio::select! {
        result = run_rpc_request(config) => result,
        _ = terminate.recv() => Err("RPC request was cancelled".to_owned()),
    }
    #[cfg(not(unix))]
    run_rpc_request(config).await
}

async fn run_rpc_request(config: ServerConfig) -> Result<(), String> {
    let response = match read_rpc_request(tokio::io::stdin(), RPC_STDIN_READ_TIMEOUT).await? {
        RpcRequestRead::Request(request) => {
            #[cfg(feature = "http-server")]
            let state = app_state(config, 0)?;
            #[cfg(not(feature = "http-server"))]
            let state = app_state(config, 0);
            handle_protocol_request(request, Some(&state)).await
        }
        RpcRequestRead::Rejected(response) => response,
    };
    write_rpc_response(&response).await
}

enum RpcRequestRead {
    Request(DiffRequest),
    Rejected(DiffResponse),
}

async fn read_rpc_request<R>(reader: R, timeout: Duration) -> Result<RpcRequestRead, String>
where
    R: tokio::io::AsyncRead + Unpin,
{
    let mut input = Vec::new();
    let mut limited_reader = reader.take((MAX_RPC_REQUEST_BYTES + 1) as u64);
    let read = limited_reader.read_to_end(&mut input);
    match tokio::time::timeout(timeout, read).await {
        Err(_) => {
            return Ok(RpcRequestRead::Rejected(DiffResponse::failure(
                UNTRUSTED_RPC_REQUEST_ID.to_owned(),
                "requestTimeout",
                "Timed out waiting for a complete RPC request",
            )));
        }
        Ok(Err(error)) => return Err(error.to_string()),
        Ok(Ok(_)) => {}
    }
    if input.len() > MAX_RPC_REQUEST_BYTES {
        return Ok(RpcRequestRead::Rejected(DiffResponse::failure(
            UNTRUSTED_RPC_REQUEST_ID.to_owned(),
            "requestTooLarge",
            "RPC request exceeds 1 MiB",
        )));
    }
    match serde_json::from_slice(&input) {
        Ok(request) => Ok(RpcRequestRead::Request(request)),
        Err(error) => Ok(RpcRequestRead::Rejected(DiffResponse::failure(
            UNTRUSTED_RPC_REQUEST_ID.to_owned(),
            "invalidRequest",
            &format!("Invalid RPC request: {error}"),
        ))),
    }
}

async fn write_rpc_response(response: &DiffResponse) -> Result<(), String> {
    let bytes = serde_json::to_vec(&response).map_err(|error| error.to_string())?;
    if bytes.len() > MAX_RPC_RESPONSE_BYTES {
        return Err("response exceeds 32 MiB".to_owned());
    }
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

#[cfg(feature = "http-server")]
fn router(state: AppState) -> Router {
    Router::new()
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
        .with_state(state)
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

#[cfg(feature = "http-server")]
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

#[cfg(feature = "http-server")]
async fn health(method: Method) -> Response {
    text_response(
        StatusCode::OK,
        "text/plain; charset=utf-8",
        health_response().into_bytes(),
        method == Method::HEAD,
    )
}

#[cfg(feature = "http-server")]
async fn rpc(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<DiffRequest>,
) -> Response {
    if !trusted_browser_request(&headers, state.port) {
        return not_found(false);
    }
    Json(handle_protocol_request(request, Some(&state)).await).into_response()
}

#[cfg(feature = "http-server")]
async fn websocket(
    State(state): State<AppState>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> Response {
    if !trusted_browser_request(&headers, state.port) {
        return not_found(false);
    }
    ws.on_upgrade(move |socket| handle_websocket(socket, state))
        .into_response()
}

#[cfg(feature = "http-server")]
async fn handle_websocket(mut socket: WebSocket, state: AppState) {
    while let Some(Ok(message)) = socket.next().await {
        match message {
            Message::Text(text) => {
                let Ok(request) = serde_json::from_str::<DiffRequest>(&text) else {
                    // A malformed frame has no trustworthy request id, so a
                    // response cannot be correlated with a pending call.
                    // Closing rejects every pending client promise instead
                    // of leaving one hung forever.
                    let _ = socket.send(Message::Close(None)).await;
                    break;
                };
                let response = handle_protocol_request(request, Some(&state)).await;
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
        DiffCommand::SessionOpen(params) => {
            let Some(state) = state else {
                return DiffResponse::failure(request.id, "hostUnavailable", "Host unavailable");
            };
            match tokio::time::timeout(SESSION_OPEN_TIMEOUT, open_session(state, params)).await {
                Ok(Ok(value)) => {
                    DiffResponse::success(request.id, DiffResult::SessionOpened(value))
                }
                Ok(Err(SessionOpenError::Unauthorized)) => DiffResponse::failure(
                    request.id,
                    "notAllowed",
                    "Diff session is not authorized",
                ),
                Ok(Err(SessionOpenError::Empty)) => {
                    DiffResponse::failure(request.id, "emptyDiff", "No changes to diff")
                }
                Err(_) | Ok(Err(SessionOpenError::Failed)) => DiffResponse::failure(
                    request.id,
                    "sessionOpenFailed",
                    "Could not generate the diff",
                ),
            }
        }
        DiffCommand::SessionClose(params) => {
            let Some(state) = state else {
                return DiffResponse::failure(request.id, "hostUnavailable", "Host unavailable");
            };
            if close_session(state, &params).await {
                DiffResponse::success(request.id, DiffResult::SessionClosed)
            } else {
                DiffResponse::failure(request.id, "notAllowed", "Diff session is not authorized")
            }
        }
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
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SessionOpenError {
    Unauthorized,
    Empty,
    Failed,
}

#[allow(clippy::too_many_lines)]
async fn open_session(
    state: &AppState,
    params: OpenSessionRequest,
) -> Result<SessionOpened, SessionOpenError> {
    if !valid_token(&params.capability_token) {
        return Err(SessionOpenError::Unauthorized);
    }
    if let DiffSource::Patch { path } = &params.source {
        let request_path = if path.starts_with('/') {
            path.clone()
        } else {
            format!("/{path}")
        };
        let (_, resource) =
            resolve_allowed_file(state, &format!("{}{request_path}", params.capability_token))
                .await
                .ok_or(SessionOpenError::Unauthorized)?;
        let length = if resource.remote_url.is_none() {
            tokio::fs::metadata(&resource.file_path)
                .await
                .ok()
                .map(|metadata| metadata.len())
        } else {
            None
        };
        return Ok(SessionOpened {
            session_id: uuid::Uuid::new_v4().to_string(),
            patch: DiffResourceRef {
                id: resource_url(state, &params.capability_token, &request_path),
                media_type: "text/x-diff".to_owned(),
                byte_length: length,
                revision: 1,
            },
            source: params.source,
        });
    }
    let _permit = state
        .child_processes
        .try_acquire()
        .map_err(|_| SessionOpenError::Failed)?;

    let repo = match &params.source {
        DiffSource::Unstaged { repo_root }
        | DiffSource::Staged { repo_root }
        | DiffSource::Branch { repo_root, .. } => repo_root,
        DiffSource::Patch { .. } => unreachable!(),
    };
    if !authorize_repo_for_token(state, &params.capability_token, repo).await {
        return Err(SessionOpenError::Unauthorized);
    }
    let canonical_repo = tokio::fs::canonicalize(repo)
        .await
        .map_err(|_| SessionOpenError::Unauthorized)?;
    let session_id = match params.session_id {
        Some(session_id) if uuid::Uuid::parse_str(&session_id).is_ok() => session_id,
        Some(_) => return Err(SessionOpenError::Unauthorized),
        None => uuid::Uuid::new_v4().to_string(),
    };
    let file_name = format!("diff-session-{session_id}.patch");
    let request_path = format!("/{file_name}");
    let final_path = state.config.root.join(&file_name);
    let temporary_path = state.config.root.join(format!(".{file_name}.tmp"));
    let owner_path =
        reserve_session_owner(&state.config.root, &session_id, &params.capability_token)
            .map_err(|_| SessionOpenError::Failed)?;
    reserve_session_temp(&state.config.root, &temporary_path)
        .inspect_err(|_| {
            let _ = std::fs::remove_file(&owner_path);
        })
        .map_err(|_| SessionOpenError::Failed)?;
    let mut temporary_file = TemporaryPatchFile::new(
        state.config.root.clone(),
        temporary_path.clone(),
        owner_path,
    );

    let source = resolve_session_source(state, params.source, &canonical_repo).await?;
    run_git_patch(&source, &canonical_repo, &temporary_path).await?;
    rename_owned_session_temp(&state.config.root, &temporary_path, &final_path)
        .map_err(|_| SessionOpenError::Failed)?;
    temporary_file.retarget(final_path.clone());
    let metadata = tokio::fs::metadata(&final_path)
        .await
        .map_err(|_| SessionOpenError::Failed)?;
    if metadata.len() == 0 {
        let _ = tokio::fs::remove_file(&final_path).await;
        return Err(SessionOpenError::Empty);
    }
    if metadata.len() > MAX_SESSION_PATCH_BYTES {
        let _ = tokio::fs::remove_file(&final_path).await;
        return Err(SessionOpenError::Failed);
    }
    let allowed = AllowedFile {
        request_path: request_path.clone(),
        file_path: final_path.to_string_lossy().into_owned(),
        mime_type: "text/x-diff".to_owned(),
        remote_url: None,
    };
    if append_manifest_file(&state.config.root, &params.capability_token, allowed).is_err() {
        let _ = tokio::fs::remove_file(&final_path).await;
        return Err(SessionOpenError::Failed);
    }
    temporary_file.disarm();

    Ok(SessionOpened {
        session_id,
        patch: DiffResourceRef {
            id: resource_url(state, &params.capability_token, &request_path),
            media_type: "text/x-diff".to_owned(),
            byte_length: Some(metadata.len()),
            revision: 1,
        },
        source,
    })
}

struct TemporaryPatchFile {
    root: PathBuf,
    path: PathBuf,
    owner_path: PathBuf,
    armed: bool,
}

impl TemporaryPatchFile {
    fn new(root: PathBuf, path: PathBuf, owner_path: PathBuf) -> Self {
        Self {
            root,
            path,
            owner_path,
            armed: true,
        }
    }

    fn disarm(&mut self) {
        self.armed = false;
    }

    fn retarget(&mut self, path: PathBuf) {
        self.path = path;
    }
}

impl Drop for TemporaryPatchFile {
    fn drop(&mut self) {
        if self.armed {
            remove_owned_patch_sync(&self.root, &self.path);
            let _ = std::fs::remove_file(&self.owner_path);
        }
    }
}

fn remove_owned_patch_sync(root: &Path, path: &Path) {
    match std::fs::remove_file(path) {
        Ok(()) => {
            let _ = unregister_session_temp(root, path);
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let _ = unregister_session_temp(root, path);
        }
        Err(_) => {}
    }
}

async fn resolve_session_source(
    state: &AppState,
    source: DiffSource,
    repo: &Path,
) -> Result<DiffSource, SessionOpenError> {
    let DiffSource::Branch {
        repo_root,
        base_ref: None,
    } = source
    else {
        return Ok(source);
    };
    let output = tokio::time::timeout(
        SESSION_GIT_TIMEOUT,
        Command::new(&state.config.cmux_executable)
            .arg("__diff-viewer-refs")
            .arg("--repo")
            .arg(repo)
            .arg("--suggested-only")
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .output(),
    )
    .await
    .map_err(|_| SessionOpenError::Failed)?
    .map_err(|_| SessionOpenError::Failed)?;
    if !output.status.success() || output.stdout.len() > 4096 {
        return Err(SessionOpenError::Failed);
    }
    let resolved: BranchListResult =
        serde_json::from_slice(&output.stdout).map_err(|_| SessionOpenError::Failed)?;
    let base_ref = resolved
        .groups
        .iter()
        .find(|group| group.id == "suggested")
        .and_then(|group| group.rows.first())
        .or_else(|| resolved.groups.iter().find_map(|group| group.rows.first()))
        .map(|row| row.r#ref.clone())
        .filter(|value| !value.is_empty())
        .ok_or(SessionOpenError::Failed)?;
    Ok(DiffSource::Branch {
        repo_root,
        base_ref: Some(base_ref),
    })
}

async fn run_git_patch(
    source: &DiffSource,
    repo: &Path,
    output_path: &Path,
) -> Result<(), SessionOpenError> {
    run_git_patch_with_limit(source, repo, output_path, MAX_SESSION_PATCH_BYTES).await
}

async fn run_git_patch_with_limit(
    source: &DiffSource,
    repo: &Path,
    output_path: &Path,
    max_patch_bytes: u64,
) -> Result<(), SessionOpenError> {
    let mut arguments = vec![
        "-C".to_owned(),
        repo.to_string_lossy().into_owned(),
        "diff".to_owned(),
        "--no-ext-diff".to_owned(),
        "--no-color".to_owned(),
        "--binary".to_owned(),
    ];
    match source {
        DiffSource::Unstaged { .. } => arguments.push("--".to_owned()),
        DiffSource::Staged { .. } => {
            arguments.push("--cached".to_owned());
            arguments.push("--".to_owned());
        }
        DiffSource::Branch {
            base_ref: Some(base_ref),
            ..
        } => {
            let base_commit = git_single_line(
                repo,
                &[
                    "rev-parse",
                    "--verify",
                    "--end-of-options",
                    &format!("{base_ref}^{{commit}}"),
                ],
            )
            .await?;
            let merge_base = git_single_line(repo, &["merge-base", "HEAD", &base_commit]).await?;
            arguments.push(merge_base);
            arguments.push("--".to_owned());
        }
        DiffSource::Branch { base_ref: None, .. } | DiffSource::Patch { .. } => {
            return Err(SessionOpenError::Failed);
        }
    }

    let mut command = Command::new("/usr/bin/git");
    command
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let mut child = command.spawn().map_err(|_| SessionOpenError::Failed)?;
    let Some(mut stdout) = child.stdout.take() else {
        let _ = child.kill().await;
        let _ = tokio::fs::remove_file(output_path).await;
        return Err(SessionOpenError::Failed);
    };
    let result = tokio::time::timeout(SESSION_GIT_TIMEOUT, async {
        let mut output = tokio::fs::File::create(output_path)
            .await
            .map_err(|_| SessionOpenError::Failed)?;
        let mut bytes_written = 0_u64;
        let mut buffer = vec![0_u8; 64 * 1024];
        loop {
            let read = stdout
                .read(&mut buffer)
                .await
                .map_err(|_| SessionOpenError::Failed)?;
            if read == 0 {
                break;
            }
            let next_size = bytes_written
                .checked_add(read as u64)
                .ok_or(SessionOpenError::Failed)?;
            if next_size > max_patch_bytes {
                return Err(SessionOpenError::Failed);
            }
            output
                .write_all(&buffer[..read])
                .await
                .map_err(|_| SessionOpenError::Failed)?;
            bytes_written = next_size;
        }
        output.flush().await.map_err(|_| SessionOpenError::Failed)?;
        let status = child.wait().await.map_err(|_| SessionOpenError::Failed)?;
        if status.success() {
            Ok(())
        } else {
            Err(SessionOpenError::Failed)
        }
    })
    .await;
    if !matches!(result, Ok(Ok(()))) {
        let _ = child.kill().await;
        let _ = child.wait().await;
        let _ = tokio::fs::remove_file(output_path).await;
        return Err(SessionOpenError::Failed);
    }
    Ok(())
}

async fn git_single_line(repo: &Path, arguments: &[&str]) -> Result<String, SessionOpenError> {
    let mut command = Command::new("/usr/bin/git");
    command
        .arg("-C")
        .arg(repo)
        .args(arguments)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let output = tokio::time::timeout(SESSION_GIT_TIMEOUT, command.output())
        .await
        .map_err(|_| SessionOpenError::Failed)?
        .map_err(|_| SessionOpenError::Failed)?;
    if !output.status.success() || output.stdout.len() > 4096 {
        return Err(SessionOpenError::Failed);
    }
    let line = String::from_utf8(output.stdout)
        .map_err(|_| SessionOpenError::Failed)?
        .trim()
        .to_owned();
    if line.is_empty() || line.contains(['\r', '\n']) {
        return Err(SessionOpenError::Failed);
    }
    Ok(line)
}

fn append_manifest_file(root: &Path, token: &str, file: AllowedFile) -> Result<(), String> {
    // Keep publication synchronous so cancellation cannot detach a blocking
    // task that commits after the patch ownership guard has deleted its file.
    mutate_manifest(root, token, |manifest| {
        manifest
            .files
            .retain(|entry| entry.request_path != file.request_path);
        manifest.files.push(file);
        Ok(())
    })
}

async fn prune_orphaned_session_temp_files(
    root: &Path,
    temporary_minimum_age: Duration,
    final_minimum_age: Duration,
    scan_limit: usize,
) {
    let root = root.to_owned();
    let _ = tokio::task::spawn_blocking(move || {
        reconcile_session_owners(&root, temporary_minimum_age, scan_limit);
        mutate_temp_index(&root, |entries| {
            let take = scan_limit.min(MAX_ORPHAN_REMOVALS).min(entries.len());
            let mut rotated = entries.drain(..take).collect::<Vec<_>>();
            rotated.retain(|name| {
                let path = root.join(name);
                let Ok(metadata) = std::fs::metadata(&path) else {
                    return false;
                };
                let minimum_age = if name.starts_with('.') {
                    temporary_minimum_age
                } else {
                    final_minimum_age
                };
                let old_enough = metadata
                    .modified()
                    .ok()
                    .and_then(|modified| SystemTime::now().duration_since(modified).ok())
                    .is_some_and(|age| age >= minimum_age);
                if old_enough {
                    if !name.starts_with('.') && final_patch_is_manifest_owned(&root, &path) {
                        return true;
                    }
                    if !name.starts_with('.')
                        && remove_abandoned_session_manifest_entry(&root, name).is_err()
                    {
                        return true;
                    }
                    match std::fs::remove_file(path) {
                        Ok(()) => {
                            remove_session_owner_for_name(&root, name);
                            false
                        }
                        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                            remove_session_owner_for_name(&root, name);
                            false
                        }
                        Err(_) => true,
                    }
                } else {
                    true
                }
            });
            entries.extend(rotated);
            Ok(())
        })
    })
    .await;
}

fn reconcile_session_owners(root: &Path, minimum_age: Duration, scan_limit: usize) {
    let Ok(entries) = std::fs::read_dir(session_owner_directory(root)) else {
        return;
    };
    for entry in entries.flatten().take(scan_limit) {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        let Some(session_id) = name
            .strip_prefix("diff-session-")
            .and_then(|value| value.strip_suffix(".owner.json"))
            .filter(|value| uuid::Uuid::parse_str(value).is_ok())
        else {
            continue;
        };
        let temporary_name = format!(".diff-session-{session_id}.patch.tmp");
        let final_name = format!("diff-session-{session_id}.patch");
        let owned_name = if root.join(&final_name).exists() {
            Some(final_name)
        } else if root.join(&temporary_name).exists() {
            Some(temporary_name)
        } else {
            None
        };
        if let Some(owned_name) = owned_name {
            let _ = mutate_temp_index(root, |indexed| {
                indexed.retain(|value| session_temp_id(value) != Some(session_id));
                if indexed.len() >= MAX_TEMP_INDEX_ENTRIES {
                    return Err("temp index full".to_owned());
                }
                indexed.push(owned_name);
                Ok(())
            });
        } else {
            let old_enough = entry
                .metadata()
                .ok()
                .and_then(|metadata| metadata.modified().ok())
                .and_then(|modified| SystemTime::now().duration_since(modified).ok())
                .is_some_and(|age| age >= minimum_age);
            if old_enough {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }
}

fn remove_session_owner_for_name(root: &Path, name: &str) {
    if let Some(session_id) = session_temp_id(name) {
        let _ = std::fs::remove_file(session_owner_path(root, session_id));
    }
}

fn remove_abandoned_session_manifest_entry(root: &Path, name: &str) -> Result<(), String> {
    let session_id = session_temp_id(name).ok_or("invalid session patch")?;
    let owner_bytes = match std::fs::read(session_owner_path(root, session_id)) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.to_string()),
    };
    let owner: SessionOwner =
        serde_json::from_slice(&owner_bytes).map_err(|error| error.to_string())?;
    if owner.session_id != session_id || !valid_token(&owner.capability_token) {
        return Err("invalid session owner".to_owned());
    }
    let request_path = format!("/diff-session-{session_id}.patch");
    mutate_manifest(root, &owner.capability_token, |manifest| {
        manifest
            .files
            .retain(|file| file.request_path != request_path);
        Ok(())
    })
}

fn final_patch_is_manifest_owned(root: &Path, patch_path: &Path) -> bool {
    let Ok(entries) = std::fs::read_dir(root) else {
        return true;
    };
    let mut manifest_count = 0;
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        let Some(token) = name
            .strip_prefix(".manifest-")
            .and_then(|value| value.strip_suffix(".json"))
            .filter(|token| valid_token(token))
        else {
            continue;
        };
        manifest_count += 1;
        if manifest_count > MAX_ORPHAN_SCAN_ENTRIES {
            return true;
        }
        let Ok(bytes) = std::fs::read(entry.path()) else {
            return true;
        };
        if bytes.len() > MAX_RPC_REQUEST_BYTES {
            return true;
        }
        let Ok(manifest) = serde_json::from_slice::<Manifest>(&bytes) else {
            return true;
        };
        if manifest.token != token {
            return true;
        }
        if manifest
            .files
            .iter()
            .any(|file| file.remote_url.is_none() && Path::new(&file.file_path) == patch_path)
        {
            return session_lease_is_active(root, token);
        }
    }
    false
}

fn session_lease_is_active(root: &Path, token: &str) -> bool {
    let Ok(lock) = OpenOptions::new()
        .read(true)
        .write(true)
        .open(root.join(format!(".session-lease-{token}.lock")))
    else {
        return false;
    };
    match lock.try_lock_exclusive() {
        Ok(()) => {
            let _ = FileExt::unlock(&lock);
            false
        }
        Err(error) => error.kind() == std::io::ErrorKind::WouldBlock,
    }
}

fn valid_session_temp_name(name: &str) -> bool {
    session_temp_id(name).is_some()
}

fn session_temp_id(name: &str) -> Option<&str> {
    name.strip_prefix(".diff-session-")
        .and_then(|value| value.strip_suffix(".patch.tmp"))
        .filter(|session_id| uuid::Uuid::parse_str(session_id).is_ok())
        .or_else(|| {
            name.strip_prefix("diff-session-")
                .and_then(|value| value.strip_suffix(".patch"))
                .filter(|session_id| uuid::Uuid::parse_str(session_id).is_ok())
        })
}

fn session_owner_path(root: &Path, session_id: &str) -> PathBuf {
    session_owner_directory(root).join(format!("diff-session-{session_id}.owner.json"))
}

fn session_owner_directory(root: &Path) -> PathBuf {
    root.join(".diff-session-owners")
}

fn reserve_session_owner(root: &Path, session_id: &str, token: &str) -> Result<PathBuf, String> {
    let directory = session_owner_directory(root);
    std::fs::create_dir_all(&directory).map_err(|error| error.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700))
            .map_err(|error| error.to_string())?;
    }
    let path = session_owner_path(root, session_id);
    let owner = SessionOwner {
        session_id: session_id.to_owned(),
        capability_token: token.to_owned(),
    };
    let bytes = serde_json::to_vec(&owner).map_err(|error| error.to_string())?;
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&path)
        .map_err(|error| error.to_string())?;
    if let Err(error) = file.write_all(&bytes).and_then(|()| file.sync_all()) {
        let _ = std::fs::remove_file(&path);
        return Err(error.to_string());
    }
    Ok(path)
}

#[cfg(test)]
fn register_session_temp(root: &Path, path: &Path) -> Result<(), String> {
    let name = path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or("invalid temp name")?;
    if !valid_session_temp_name(name) {
        return Err("invalid temp name".to_owned());
    }
    let session_id = session_temp_id(name).ok_or("invalid temp name")?;
    mutate_temp_index(root, |entries| {
        if entries.len() >= MAX_TEMP_INDEX_ENTRIES {
            return Err("temp index full".to_owned());
        }
        if entries
            .iter()
            .any(|entry| session_temp_id(entry) == Some(session_id))
        {
            return Err("session id already reserved".to_owned());
        }
        entries.push(name.to_owned());
        Ok(())
    })
}

fn reserve_session_temp(root: &Path, path: &Path) -> Result<(), String> {
    let name = path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or("invalid temp name")?;
    let session_id = session_temp_id(name).ok_or("invalid temp name")?;
    let mut created = false;
    let result = mutate_temp_index(root, |entries| {
        if entries.len() >= MAX_TEMP_INDEX_ENTRIES
            || entries
                .iter()
                .any(|entry| session_temp_id(entry) == Some(session_id))
        {
            return Err("session id already reserved".to_owned());
        }
        OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(path)
            .map_err(|error| error.to_string())?;
        created = true;
        entries.push(name.to_owned());
        Ok(())
    });
    if result.is_err() && created {
        let _ = std::fs::remove_file(path);
    }
    result
}

fn unregister_session_temp(root: &Path, path: &Path) -> Result<(), String> {
    let name = path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or("invalid temp name")?;
    mutate_temp_index(root, |entries| {
        entries.retain(|entry| entry != name);
        Ok(())
    })
}

fn rename_owned_session_temp(root: &Path, old_path: &Path, new_path: &Path) -> Result<(), String> {
    let old_name = old_path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or("invalid temp name")?;
    let new_name = new_path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or("invalid final name")?;
    if !valid_session_temp_name(old_name) || !valid_session_temp_name(new_name) {
        return Err("invalid owned patch name".to_owned());
    }
    mutate_temp_index(root, |entries| {
        let Some(entry) = entries.iter_mut().find(|entry| entry.as_str() == old_name) else {
            return Err("temp ownership missing".to_owned());
        };
        std::fs::rename(old_path, new_path).map_err(|error| error.to_string())?;
        new_name.clone_into(entry);
        Ok(())
    })
}

fn mutate_temp_index<T>(
    root: &Path,
    update: impl FnOnce(&mut Vec<String>) -> Result<T, String>,
) -> Result<T, String> {
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(root.join(".diff-session-temp-index.lock"))
        .map_err(|error| error.to_string())?;
    FileExt::lock_exclusive(&lock).map_err(|error| error.to_string())?;
    let index_path = root.join(".diff-session-temp-index");
    let contents = std::fs::read_to_string(&index_path).unwrap_or_default();
    let mut entries: Vec<String> = contents
        .lines()
        .filter(|name| valid_session_temp_name(name))
        .take(MAX_TEMP_INDEX_ENTRIES)
        .map(str::to_owned)
        .collect();
    let value = update(&mut entries)?;
    let temporary = root.join(format!(
        ".diff-session-temp-index-{}.tmp",
        uuid::Uuid::new_v4()
    ));
    if let Err(error) = std::fs::write(&temporary, entries.join("\n")) {
        let _ = std::fs::remove_file(&temporary);
        return Err(error.to_string());
    }
    if let Err(error) = std::fs::rename(&temporary, index_path) {
        let _ = std::fs::remove_file(&temporary);
        return Err(error.to_string());
    }
    Ok(value)
}

async fn close_session(state: &AppState, params: &SessionRequest) -> bool {
    if !valid_token(&params.capability_token)
        || uuid::Uuid::parse_str(&params.session_id).is_err()
        || !has_session_token(state, &params.capability_token).await
    {
        return false;
    }
    let request_path = format!("/diff-session-{}.patch", params.session_id);
    let file_path = state.config.root.join(request_path.trim_start_matches('/'));
    let transaction = mutate_manifest(&state.config.root, &params.capability_token, |manifest| {
        let owned = manifest.files.iter().any(|entry| {
            entry.request_path == request_path
                && entry.remote_url.is_none()
                && Path::new(&entry.file_path) == file_path
        });
        manifest
            .files
            .retain(|entry| entry.request_path != request_path);
        Ok(owned)
    });
    let Ok(owned) = transaction else { return false };
    if !owned {
        return true;
    }
    match std::fs::remove_file(&file_path) {
        Ok(()) => {
            let _ = unregister_session_temp(&state.config.root, &file_path);
            remove_session_owner_for_name(
                &state.config.root,
                file_path
                    .file_name()
                    .and_then(|value| value.to_str())
                    .unwrap_or(""),
            );
            true
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let _ = unregister_session_temp(&state.config.root, &file_path);
            remove_session_owner_for_name(
                &state.config.root,
                file_path
                    .file_name()
                    .and_then(|value| value.to_str())
                    .unwrap_or(""),
            );
            true
        }
        // The manifest commit is the logical close. Retain index ownership so
        // bounded cleanup can retry a transient filesystem deletion failure.
        Err(_) => {
            if let Ok(file) = OpenOptions::new().write(true).open(&file_path) {
                let _ = file.set_modified(SystemTime::UNIX_EPOCH);
            }
            remove_owned_patch_sync(&state.config.root, &file_path);
            true
        }
    }
}

fn mutate_manifest<T>(
    root: &Path,
    token: &str,
    update: impl FnOnce(&mut Manifest) -> Result<T, String>,
) -> Result<T, String> {
    let lock_path = root.join(format!(".manifest-{token}.lock"));
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(lock_path)
        .map_err(|error| error.to_string())?;
    FileExt::lock_exclusive(&lock).map_err(|error| error.to_string())?;
    let manifest_path = root.join(format!(".manifest-{token}.json"));
    let bytes = std::fs::read(&manifest_path).map_err(|error| error.to_string())?;
    let mut manifest: Manifest =
        serde_json::from_slice(&bytes).map_err(|error| error.to_string())?;
    if manifest.token != token {
        return Err("manifest token mismatch".to_owned());
    }
    manifest.files_by_path()?;
    let value = update(&mut manifest)?;
    if manifest.files.is_empty() || manifest.files.len() > 4096 {
        return Err("invalid manifest size".to_owned());
    }
    manifest.files_by_path()?;
    let temporary = root.join(format!(".manifest-{token}-{}.tmp", uuid::Uuid::new_v4()));
    if let Err(error) = std::fs::write(
        &temporary,
        serde_json::to_vec_pretty(&manifest).map_err(|error| error.to_string())?,
    ) {
        let _ = std::fs::remove_file(&temporary);
        return Err(error.to_string());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if let Err(error) =
            std::fs::set_permissions(&temporary, std::fs::Permissions::from_mode(0o600))
        {
            let _ = std::fs::remove_file(&temporary);
            return Err(error.to_string());
        }
    }
    if let Err(error) = std::fs::rename(&temporary, manifest_path) {
        let _ = std::fs::remove_file(&temporary);
        return Err(error.to_string());
    }
    Ok(value)
}

async fn has_session_token(state: &AppState, token: &str) -> bool {
    let Ok(mut entries) = tokio::fs::read_dir(&state.config.root).await else {
        return false;
    };
    while let Ok(Some(entry)) = entries.next_entry().await {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if !name.starts_with(".branch-session-") || !name.ends_with(".json") {
            continue;
        }
        let Ok(bytes) = tokio::fs::read(entry.path()).await else {
            continue;
        };
        if serde_json::from_slice::<BranchSessionAuthorization>(&bytes)
            .is_ok_and(|session| session.token == token)
        {
            return true;
        }
    }
    false
}

fn resource_url(state: &AppState, token: &str, request_path: &str) -> String {
    if state.port == 0 {
        format!("cmux-diff-viewer://{token}{request_path}")
    } else {
        format!("http://127.0.0.1:{}/{token}{request_path}", state.port)
    }
}

#[cfg(feature = "http-server")]
async fn branch_refs(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if !trusted_browser_request(&headers, state.port) {
        return not_found(false);
    }
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
    if !authorize_repo_for_token(state, token, repo).await {
        return Err(());
    }
    let Ok(_permit) = state.child_processes.try_acquire() else {
        return Err(());
    };
    let mut command = Command::new(&state.config.cmux_executable);
    command
        .arg("__diff-viewer-refs")
        .arg("--repo")
        .arg(repo)
        .arg("--token")
        .arg(token)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    if let Some(base) = base {
        command.arg("--base").arg(base);
    }
    match tokio::time::timeout(BRANCH_LIST_CHILD_TIMEOUT, command.output()).await {
        Ok(Ok(output)) if output.status.success() => {
            serde_json::from_slice(&output.stdout).map_err(|_| ())
        }
        _ => Err(()),
    }
}

#[cfg(feature = "http-server")]
async fn branch_change(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if !trusted_browser_request(&headers, state.port) {
        return not_found(false);
    }
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
    if !authorize_branch_change(state, token, group, repo).await {
        return Err(());
    }
    let Ok(_permit) = state.child_processes.try_acquire() else {
        return Err(());
    };
    let mut command = Command::new(&state.config.cmux_executable);
    command
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
        .kill_on_drop(true);
    let Ok(Ok(output)) = tokio::time::timeout(BRANCH_CHANGE_CHILD_TIMEOUT, command.output()).await
    else {
        return Err(());
    };
    if !output.status.success() {
        return Err(());
    }
    let scheme_url = String::from_utf8_lossy(&output.stdout);
    let scheme_url = scheme_url.trim();
    let authority = format!("cmux-diff-viewer://{token}");
    let Some(path) = scheme_url.strip_prefix(&authority) else {
        return Err(());
    };
    if path.contains(['?', '#', '%']) || !valid_request_path(path) {
        return Err(());
    }
    let resource_path = format!("{token}{path}");
    if resolve_allowed_file(state, &resource_path).await.is_none() {
        return Err(());
    }
    if state.port == 0 {
        Ok(scheme_url.to_owned())
    } else {
        Ok(format!(
            "http://127.0.0.1:{}/{token}{}#cmux-diff-viewer",
            server_port(state),
            path
        ))
    }
}

fn server_port(state: &AppState) -> u16 {
    state.port
}

#[cfg(feature = "http-server")]
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

#[cfg(feature = "http-server")]
fn replacement_timeout() -> Duration {
    let seconds = std::env::var("CMUX_DIFF_VIEWER_WAIT_TIMEOUT_SECONDS")
        .ok()
        .and_then(|value| value.parse::<f64>().ok())
        .filter(|value| value.is_finite())
        .unwrap_or(120.0)
        .clamp(0.05, 600.0);
    Duration::from_secs_f64(seconds)
}

#[cfg(feature = "http-server")]
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

#[cfg(feature = "http-server")]
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

#[cfg(feature = "http-server")]
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
    let path = state.config.root.join(format!(".manifest-{token}.json"));
    let metadata = tokio::fs::metadata(path).await.ok()?;
    let fingerprint = ManifestFingerprint {
        byte_length: metadata.len(),
        modified: metadata.modified().ok(),
    };
    if let Some(cached) = state.manifests.read().await.get(token)
        && cached.fingerprint == fingerprint
    {
        let file = cached.files.get(&request_path)?.clone();
        return Some((token.to_owned(), file));
    }

    let manifest = Manifest::load(&state.config.root, token).await.ok()?;
    let files = Arc::new(manifest.files_by_path().ok()?);
    let file = files.get(&request_path)?.clone();
    let mut manifests = state.manifests.write().await;
    if manifests.len() >= MAX_CACHED_MANIFESTS && !manifests.contains_key(token) {
        manifests.clear();
    }
    manifests.insert(token.to_owned(), CachedManifest { fingerprint, files });
    Some((token.to_owned(), file))
}

#[cfg(feature = "http-server")]
fn trusted_browser_request(headers: &HeaderMap, port: u16) -> bool {
    let expected_host = format!("127.0.0.1:{port}");
    let expected_origin = format!("http://127.0.0.1:{port}");
    let host_matches = headers
        .get(HOST)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|host| host == expected_host);
    host_matches
        && (headers
            .get(ORIGIN)
            .and_then(|value| value.to_str().ok())
            .is_some_and(|origin| origin == expected_origin)
            || headers
                .get("sec-fetch-site")
                .and_then(|value| value.to_str().ok())
                .is_some_and(|site| site.eq_ignore_ascii_case("same-origin")))
}

async fn authorize_repo_for_token(state: &AppState, token: &str, repo: &str) -> bool {
    if !valid_token(token) {
        return false;
    }
    let Ok(canonical_repo) = tokio::fs::canonicalize(repo).await else {
        return false;
    };
    let Ok(mut entries) = tokio::fs::read_dir(&state.config.root).await else {
        return false;
    };
    while let Ok(Some(entry)) = entries.next_entry().await {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if !name.starts_with(".branch-session-") || !name.ends_with(".json") {
            continue;
        }
        let Ok(session) = read_branch_session(&entry.path()).await else {
            continue;
        };
        if session.token == token && session_allows_repo(&session, &canonical_repo).await {
            return true;
        }
    }
    false
}

async fn authorize_branch_change(state: &AppState, token: &str, group: &str, repo: &str) -> bool {
    if !valid_token(token) || !valid_group_id(group) {
        return false;
    }
    let Ok(canonical_repo) = tokio::fs::canonicalize(repo).await else {
        return false;
    };
    let path = state
        .config
        .root
        .join(format!(".branch-session-{group}.json"));
    let Ok(session) = read_branch_session(&path).await else {
        return false;
    };
    session.token == token
        && session.group_id == group
        && session_allows_repo(&session, &canonical_repo).await
}

fn valid_group_id(value: &str) -> bool {
    (1..=64).contains(&value.chars().count())
        && value
            .chars()
            .all(|character| character.is_alphanumeric() || character == '-')
}

async fn read_branch_session(path: &Path) -> Result<BranchSessionAuthorization, ()> {
    let bytes = tokio::fs::read(path).await.map_err(|_| ())?;
    if bytes.len() > 1024 * 1024 {
        return Err(());
    }
    serde_json::from_slice(&bytes).map_err(|_| ())
}

async fn session_allows_repo(session: &BranchSessionAuthorization, canonical_repo: &Path) -> bool {
    for allowed in &session.allowed_repo_roots {
        if tokio::fs::canonicalize(allowed)
            .await
            .is_ok_and(|path| path == canonical_repo)
        {
            return true;
        }
    }
    false
}

#[cfg(feature = "http-server")]
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
    if path
        .extension()
        .is_some_and(|extension| extension == "deflate")
    {
        set_header(&mut headers, CONTENT_ENCODING, "deflate");
    }
    if head {
        return (StatusCode::OK, headers, Body::empty()).into_response();
    }
    let Ok(open_file) = tokio::fs::File::open(path).await else {
        return not_found(false);
    };
    let body = Body::from_stream(ReaderStream::new(open_file));
    (StatusCode::OK, headers, body).into_response()
}

#[cfg(feature = "http-server")]
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
    let Some(client) = &state.client else {
        return bad_gateway();
    };
    let Ok(response) = client.get(url).send().await else {
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

#[cfg(feature = "http-server")]
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

#[cfg(feature = "http-server")]
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

#[cfg(feature = "http-server")]
fn redirect_response(location: &str) -> Response {
    let mut headers = base_headers();
    set_header(&mut headers, LOCATION, location);
    set_header(&mut headers, CONTENT_TYPE, "text/plain; charset=utf-8");
    (StatusCode::FOUND, headers, Body::from("302 Found\n")).into_response()
}

#[cfg(feature = "http-server")]
fn not_found(head: bool) -> Response {
    text_response(
        StatusCode::NOT_FOUND,
        "text/plain; charset=utf-8",
        b"404 Not Found\n".to_vec(),
        head,
    )
}

#[cfg(feature = "http-server")]
fn bad_gateway() -> Response {
    text_response(
        StatusCode::BAD_GATEWAY,
        "text/plain; charset=utf-8",
        b"502 Bad Gateway\n".to_vec(),
        false,
    )
}

#[cfg(feature = "http-server")]
fn content_type(mime_type: &str) -> &str {
    match mime_type {
        "text/html" => "text/html; charset=utf-8",
        "text/javascript" => "text/javascript; charset=utf-8",
        "text/x-diff" => "text/x-diff; charset=utf-8",
        _ => "application/octet-stream",
    }
}

#[cfg(feature = "http-server")]
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
    use std::process::Command;
    use std::time::Duration;

    use tokio::io::AsyncWriteExt;

    use crate::PROTOCOL_VERSION;
    use crate::protocol::{DiffCommand, DiffRequest, DiffResult};

    use super::{
        AllowedFile, DiffSource, FileExt, Manifest, OpenOptions, RpcRequestRead, SessionOpenError,
        TemporaryPatchFile, UNTRUSTED_RPC_REQUEST_ID, handle_protocol_request,
        prune_orphaned_session_temp_files, read_rpc_request, register_session_temp,
        reserve_session_owner, run_git_patch_with_limit, valid_group_id,
    };

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
        #[cfg(feature = "http-server")]
        assert!(
            handshake
                .capabilities
                .contains(&"transport.websocket".to_owned())
        );
        #[cfg(not(feature = "http-server"))]
        assert!(
            !handshake
                .capabilities
                .contains(&"transport.websocket".to_owned())
        );
    }

    #[test]
    fn branch_group_ids_match_cli_validation() {
        assert!(valid_group_id("a"));
        assert!(valid_group_id(&"a".repeat(64)));
        assert!(!valid_group_id(""));
        assert!(!valid_group_id(&"a".repeat(65)));
        assert!(!valid_group_id("../group"));
    }

    #[test]
    fn temporary_patch_guard_follows_rename_until_registration() {
        let root = std::env::temp_dir().join(format!(
            "cmux-diff-sidecar-rename-guard-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&root).expect("create root");
        let temporary = root.join(".diff-session-test.patch.tmp");
        let final_path = root.join("diff-session-test.patch");
        std::fs::write(&temporary, b"private diff").expect("write temporary patch");

        {
            let mut guard =
                TemporaryPatchFile::new(root.clone(), temporary.clone(), root.join("owner.json"));
            std::fs::rename(&temporary, &final_path).expect("rename patch");
            guard.retarget(final_path.clone());
        }

        assert!(!temporary.exists());
        assert!(!final_path.exists());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn session_ids_are_reserved_across_temporary_and_final_names() {
        let root = std::env::temp_dir().join(format!(
            "cmux-diff-sidecar-reservation-test-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&root).expect("create root");
        let session_id = uuid::Uuid::new_v4();
        let temporary = root.join(format!(".diff-session-{session_id}.patch.tmp"));
        let final_path = root.join(format!("diff-session-{session_id}.patch"));

        register_session_temp(&root, &temporary).expect("reserve session id");
        assert!(register_session_temp(&root, &temporary).is_err());
        assert!(register_session_temp(&root, &final_path).is_err());

        let _ = std::fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn startup_prunes_only_orphaned_session_temp_files() {
        let root = std::env::temp_dir().join(format!(
            "cmux-diff-sidecar-orphan-test-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&root).expect("create root");
        let orphans: Vec<_> = (0..4)
            .map(|_| root.join(format!(".diff-session-{}.patch.tmp", uuid::Uuid::new_v4())))
            .collect();
        let final_orphan = root.join(format!("diff-session-{}.patch", uuid::Uuid::new_v4()));
        let active_final = root.join(format!("diff-session-{}.patch", uuid::Uuid::new_v4()));
        let active_token = "a".repeat(64);
        let unrelated = root.join(".diff-session-invalid.patch.tmp");
        for orphan in &orphans {
            std::fs::write(orphan, b"private diff").expect("write orphan");
            register_session_temp(&root, orphan).expect("register orphan");
        }
        std::fs::write(&final_orphan, b"private final diff").expect("write final orphan");
        register_session_temp(&root, &final_orphan).expect("register final orphan");
        std::fs::write(&active_final, b"active private diff").expect("write active patch");
        register_session_temp(&root, &active_final).expect("register active patch");
        let active_manifest = Manifest {
            token: active_token.clone(),
            files: vec![AllowedFile {
                request_path: format!("/{}", active_final.file_name().unwrap().to_string_lossy()),
                file_path: active_final.to_string_lossy().into_owned(),
                mime_type: "text/x-diff".to_owned(),
                remote_url: None,
            }],
        };
        std::fs::write(
            root.join(format!(".manifest-{active_token}.json")),
            serde_json::to_vec(&active_manifest).expect("encode active manifest"),
        )
        .expect("write active manifest");
        let active_lease = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(root.join(format!(".session-lease-{active_token}.lock")))
            .expect("open active lease");
        FileExt::lock_shared(&active_lease).expect("hold active lease");
        std::fs::write(&unrelated, b"keep").expect("write unrelated file");

        for _ in 0..6 {
            prune_orphaned_session_temp_files(&root, Duration::ZERO, Duration::ZERO, 2).await;
        }

        assert!(orphans.iter().all(|orphan| !orphan.exists()));
        assert!(!final_orphan.exists());
        assert!(active_final.exists());
        FileExt::unlock(&active_lease).expect("release active lease");
        prune_orphaned_session_temp_files(&root, Duration::ZERO, Duration::ZERO, 16).await;
        assert!(!active_final.exists());
        assert!(unrelated.exists());
        let _ = std::fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn owner_descriptor_recovers_rename_crash_and_repairs_manifest() {
        let root = std::env::temp_dir().join(format!(
            "cmux-diff-sidecar-owner-recovery-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&root).expect("create root");
        let session_id = uuid::Uuid::new_v4().to_string();
        let token = "b".repeat(64);
        let temporary = root.join(format!(".diff-session-{session_id}.patch.tmp"));
        let final_path = root.join(format!("diff-session-{session_id}.patch"));
        reserve_session_owner(&root, &session_id, &token).expect("reserve owner");
        register_session_temp(&root, &temporary).expect("index temporary name");
        std::fs::write(&final_path, b"private diff after rename").expect("write final patch");
        let page = root.join("index.html");
        std::fs::write(&page, b"page").expect("write page");
        let manifest = Manifest {
            token: token.clone(),
            files: vec![
                AllowedFile {
                    request_path: "/index.html".to_owned(),
                    file_path: page.to_string_lossy().into_owned(),
                    mime_type: "text/html".to_owned(),
                    remote_url: None,
                },
                AllowedFile {
                    request_path: format!("/diff-session-{session_id}.patch"),
                    file_path: final_path.to_string_lossy().into_owned(),
                    mime_type: "text/x-diff".to_owned(),
                    remote_url: None,
                },
            ],
        };
        std::fs::write(
            root.join(format!(".manifest-{token}.json")),
            serde_json::to_vec(&manifest).expect("encode manifest"),
        )
        .expect("write manifest");

        prune_orphaned_session_temp_files(&root, Duration::ZERO, Duration::ZERO, 64).await;

        assert!(!final_path.exists());
        assert!(!super::session_owner_path(&root, &session_id).exists());
        let repaired: Manifest = serde_json::from_slice(
            &std::fs::read(root.join(format!(".manifest-{token}.json")))
                .expect("read repaired manifest"),
        )
        .expect("decode repaired manifest");
        assert_eq!(repaired.files.len(), 1);
        assert_eq!(repaired.files[0].request_path, "/index.html");
        let _ = std::fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn stdio_request_read_has_an_internal_deadline() {
        let (mut writer, reader) = tokio::io::duplex(64);
        writer.write_all(b"{").await.expect("write partial request");

        let read = read_rpc_request(reader, Duration::from_millis(10))
            .await
            .expect("read timeout response");
        let RpcRequestRead::Rejected(response) = read else {
            panic!("expected rejected request");
        };
        assert_eq!(response.id, UNTRUSTED_RPC_REQUEST_ID);
        assert_eq!(
            response.error.as_ref().map(|error| error.code.as_str()),
            Some("requestTimeout")
        );
    }

    #[tokio::test]
    async fn git_patch_limit_removes_partial_output() {
        let root = std::env::temp_dir().join(format!(
            "cmux-diff-sidecar-size-limit-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        let repo = root.join("repo");
        std::fs::create_dir_all(&repo).expect("create repo");
        let run_git = |arguments: &[&str]| {
            let output = Command::new("/usr/bin/git")
                .arg("-C")
                .arg(&repo)
                .args(arguments)
                .output()
                .expect("run git");
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
        };
        run_git(&["init"]);
        run_git(&["config", "user.name", "cmux tests"]);
        run_git(&["config", "user.email", "cmux@example.invalid"]);
        std::fs::write(repo.join("large.txt"), "before\n").expect("write initial file");
        run_git(&["add", "large.txt"]);
        run_git(&["commit", "-m", "initial"]);
        std::fs::write(
            repo.join("large.txt"),
            format!("{}\n", "x".repeat(8 * 1024)),
        )
        .expect("write large diff");
        let patch_path = root.join("too-large.patch");

        let result = run_git_patch_with_limit(
            &DiffSource::Unstaged {
                repo_root: repo.to_string_lossy().into_owned(),
            },
            &repo,
            &patch_path,
            1024,
        )
        .await;

        assert_eq!(result, Err(SessionOpenError::Failed));
        assert!(!patch_path.exists());
        let _ = std::fs::remove_dir_all(root);
    }
}
