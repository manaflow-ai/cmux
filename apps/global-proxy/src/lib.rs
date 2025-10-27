use std::{net::SocketAddr, sync::Arc};

use bytes::Bytes;
use futures_util::{SinkExt, StreamExt};
use http::{
    HeaderMap, Method, Request, Response, StatusCode, Uri, Version,
    header::{self, HeaderValue},
    uri::Scheme,
};
use hyper::{
    Body, Client, body,
    client::HttpConnector,
    server::conn::AddrStream,
    service::{make_service_fn, service_fn},
};
use hyper_rustls::HttpsConnectorBuilder;
use hyper_tungstenite::{HyperWebsocket, is_upgrade_request};
use lol_html::{HtmlRewriter, Settings, element, html_content::ContentType};
use tokio::{sync::oneshot, task::JoinHandle};
use tokio_tungstenite::{connect_async, tungstenite::client::IntoClientRequest};
use tracing::error;

use chrono::Utc;
use serde_json::{Value, json};

type HttpClient = Client<hyper_rustls::HttpsConnector<HttpConnector>, Body>;

const VERSION: &str = env!("CARGO_PKG_VERSION");
const GIT_COMMIT: &str = match option_env!("GIT_COMMIT") {
    Some(commit) => commit,
    None => "unknown",
};

const CSP_FRAME_ANCESTORS_PORT_39378: &str = "frame-ancestors 'self' https://cmux.local http://cmux.local https://www.cmux.sh https://cmux.sh https://www.cmux.dev https://cmux.dev http://localhost:5173;";

#[derive(Clone, Debug)]
pub struct ProxyConfig {
    pub bind_addr: SocketAddr,
    pub backend_host: String,
    pub backend_scheme: Scheme,
    pub morph_domain_suffix: Option<String>,
    pub workspace_domain_suffix: Option<String>,
}

impl Default for ProxyConfig {
    fn default() -> Self {
        Self {
            bind_addr: SocketAddr::from(([0, 0, 0, 0], 8080)),
            backend_host: "127.0.0.1".to_string(),
            backend_scheme: Scheme::HTTP,
            morph_domain_suffix: None,
            workspace_domain_suffix: None,
        }
    }
}

pub struct ProxyHandle {
    pub addr: SocketAddr,
    shutdown: Option<oneshot::Sender<()>>,
    task: JoinHandle<()>,
}

impl ProxyHandle {
    pub async fn shutdown(mut self) {
        if let Some(tx) = self.shutdown.take() {
            let _ = tx.send(());
        }
        let _ = self.task.await;
    }
}

#[derive(thiserror::Error, Debug)]
pub enum ProxyError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("hyper error: {0}")]
    Hyper(#[from] hyper::Error),
}

struct AppState {
    client: HttpClient,
    backend_host: String,
    backend_scheme: Scheme,
    morph_domain_suffix: Option<String>,
    workspace_domain_suffix: Option<String>,
}

pub async fn spawn_proxy(config: ProxyConfig) -> Result<ProxyHandle, ProxyError> {
    let listener = std::net::TcpListener::bind(config.bind_addr)?;
    listener.set_nonblocking(true)?;
    let local_addr = listener.local_addr()?;

    let https = HttpsConnectorBuilder::new()
        .with_webpki_roots()
        .https_or_http()
        .enable_http1()
        .build();
    let client: HttpClient = Client::builder().build(https);

    let state = Arc::new(AppState {
        client,
        backend_host: config.backend_host,
        backend_scheme: config.backend_scheme,
        morph_domain_suffix: config.morph_domain_suffix,
        workspace_domain_suffix: config.workspace_domain_suffix,
    });

    let make_svc = make_service_fn(move |_conn: &AddrStream| {
        let state = state.clone();
        async move {
            Ok::<_, hyper::Error>(service_fn(move |req| {
                let state = state.clone();
                async move { Ok::<_, hyper::Error>(handle_request(state, req).await) }
            }))
        }
    });

    let server = hyper::Server::from_tcp(listener)?.serve(make_svc);
    let (shutdown_tx, shutdown_rx) = oneshot::channel();
    let graceful = server.with_graceful_shutdown(async move {
        let _ = shutdown_rx.await;
    });
    let task = tokio::spawn(async move {
        if let Err(err) = graceful.await {
            error!(%err, "proxy server error");
        }
    });

    Ok(ProxyHandle {
        addr: local_addr,
        shutdown: Some(shutdown_tx),
        task,
    })
}

async fn handle_request(state: Arc<AppState>, req: Request<Body>) -> Response<Body> {
    if req.uri().path() == "/health" {
        return json_response(
            StatusCode::OK,
            json!({
                "status": "healthy",
                "timestamp": Utc::now().to_rfc3339(),
            }),
        );
    }

    let host = match extract_host(&req) {
        Some(host) => host,
        None => {
            return text_response(
                StatusCode::BAD_REQUEST,
                "Missing host header for proxied request",
            );
        }
    };

    if req.uri().path() == "/version" {
        match parse_cmux_host(&host) {
            Some((Some(_), _)) => {
                // Requests to subdomains must be proxied; fall through.
            }
            _ => {
                return json_response(
                    StatusCode::OK,
                    json!({
                        "version": VERSION,
                        "git_commit": GIT_COMMIT,
                    }),
                );
            }
        }
    }

    if let Some((subdomain, _domain)) = parse_cmux_host(&host) {
        if subdomain.is_none() {
            return text_response(StatusCode::OK, "cmux!");
        }

        if req.uri().path() == "/proxy-sw.js" {
            return service_worker_response();
        }

        match parse_route(subdomain.unwrap()) {
            Route::Port(route) => {
                if is_loop_header(&req) {
                    return text_response(StatusCode::LOOP_DETECTED, "Loop detected in proxy");
                }

                if route.port == 39_378 && *req.method() == Method::OPTIONS {
                    return Response::builder()
                        .status(StatusCode::NO_CONTENT)
                        .body(Body::empty())
                        .unwrap();
                }

                let target = if let Some(suffix) = state.morph_domain_suffix.clone() {
                    let host = format!("port-{}-morphvm-{}{}", route.port, route.morph_id, suffix);
                    Target::Absolute {
                        scheme: Scheme::HTTPS,
                        host,
                        port: None,
                    }
                } else {
                    Target::BackendPort(route.port)
                };

                let (strip_cors_headers, frame_ancestors) = if route.skip_service_worker {
                    (true, Some(CSP_FRAME_ANCESTORS_PORT_39378))
                } else {
                    (false, None)
                };

                return forward_request(
                    state,
                    req,
                    target,
                    ProxyBehavior {
                        skip_service_worker: route.skip_service_worker,
                        add_cors: false,
                        strip_cors_headers,
                        workspace_header: None,
                        port_header: None,
                        frame_ancestors,
                    },
                )
                .await;
            }
            Route::Cmux(route) => {
                if is_loop_header(&req) {
                    return text_response(StatusCode::LOOP_DETECTED, "Loop detected in proxy");
                }

                let is_vscode_route = route.port == 39_378;

                if *req.method() == Method::OPTIONS {
                    if is_vscode_route {
                        return Response::builder()
                            .status(StatusCode::NO_CONTENT)
                            .body(Body::empty())
                            .unwrap();
                    }
                    return cors_response(StatusCode::NO_CONTENT);
                }

                let target = if let Some(suffix) = state.morph_domain_suffix.clone() {
                    let host = format!("port-39379-morphvm-{}{}", route.morph_id, suffix);
                    Target::Absolute {
                        scheme: Scheme::HTTPS,
                        host,
                        port: None,
                    }
                } else {
                    Target::BackendPort(route.port)
                };

                return forward_request(
                    state,
                    req,
                    target,
                    ProxyBehavior {
                        skip_service_worker: true,
                        add_cors: !is_vscode_route,
                        strip_cors_headers: is_vscode_route,
                        workspace_header: route.workspace_header,
                        port_header: Some(route.port.to_string()),
                        frame_ancestors: None,
                    },
                )
                .await;
            }
            Route::Workspace(route) => {
                if is_loop_header(&req) {
                    return text_response(StatusCode::LOOP_DETECTED, "Loop detected in proxy");
                }

                let target = if let Some(suffix) = state.workspace_domain_suffix.clone() {
                    let host = format!("{}{}", route.vm_slug, suffix);
                    Target::Absolute {
                        scheme: Scheme::HTTPS,
                        host,
                        port: None,
                    }
                } else {
                    Target::BackendPort(route.port)
                };

                return forward_request(
                    state,
                    req,
                    target,
                    ProxyBehavior {
                        skip_service_worker: false,
                        add_cors: false,
                        strip_cors_headers: false,
                        workspace_header: Some(route.workspace),
                        port_header: Some(route.port.to_string()),
                        frame_ancestors: None,
                    },
                )
                .await;
            }
            Route::Invalid(resp) => return resp,
        }
    }

    text_response(StatusCode::BAD_GATEWAY, "Not a cmux domain")
}

#[derive(Clone)]
enum Target {
    BackendPort(u16),
    Absolute {
        scheme: Scheme,
        host: String,
        port: Option<u16>,
    },
}

#[derive(Clone)]
struct ProxyBehavior {
    skip_service_worker: bool,
    add_cors: bool,
    strip_cors_headers: bool,
    workspace_header: Option<String>,
    port_header: Option<String>,
    frame_ancestors: Option<&'static str>,
}

async fn forward_request(
    state: Arc<AppState>,
    mut req: Request<Body>,
    target: Target,
    behavior: ProxyBehavior,
) -> Response<Body> {
    if is_upgrade_request(&req) {
        return handle_websocket(state, req, target, behavior).await;
    }

    let (scheme, host, port_opt) = match target {
        Target::BackendPort(port) => (
            state.backend_scheme.clone(),
            state.backend_host.clone(),
            Some(port),
        ),
        Target::Absolute { scheme, host, port } => (scheme, host, port),
    };

    let authority = match port_opt {
        Some(port) => format!("{}:{}", host, port),
        None => host,
    };

    let path_and_query = req
        .uri()
        .path_and_query()
        .map(|pq| pq.as_str())
        .unwrap_or("/");
    let target_uri =
        match format!("{}://{}{}", scheme.as_str(), authority, path_and_query).parse::<Uri>() {
            Ok(uri) => uri,
            Err(_) => {
                return text_response(StatusCode::BAD_GATEWAY, "Failed to build upstream URI");
            }
        };

    *req.uri_mut() = target_uri;

    if let Ok(value) = HeaderValue::from_str(&authority) {
        req.headers_mut().insert(header::HOST, value);
    }

    req.headers_mut()
        .insert("X-Cmux-Proxied", HeaderValue::from_static("true"));

    if let Some(port_hdr) = behavior.port_header.as_ref() {
        if let Ok(value) = HeaderValue::from_str(port_hdr) {
            req.headers_mut().insert("X-Cmux-Port-Internal", value);
        }
    } else {
        req.headers_mut().remove("X-Cmux-Port-Internal");
    }

    if let Some(value) = behavior.workspace_header.as_ref() {
        if let Ok(value) = HeaderValue::from_str(value) {
            req.headers_mut().insert("X-Cmux-Workspace-Internal", value);
        }
    } else {
        req.headers_mut().remove("X-Cmux-Workspace-Internal");
    }

    let original_method = req.method().clone();
    let head_fallback_context = if original_method == Method::HEAD {
        Some(HeadFallbackContext {
            headers: req.headers().clone(),
            uri: req.uri().clone(),
            version: req.version(),
        })
    } else {
        None
    };

    let response = match state.client.request(req).await {
        Ok(resp) => resp,
        Err(_) => return text_response(StatusCode::BAD_GATEWAY, "Upstream fetch failed"),
    };

    if original_method == Method::HEAD
        && matches!(
            response.status(),
            StatusCode::METHOD_NOT_ALLOWED | StatusCode::NOT_IMPLEMENTED
        )
    {
        if let Some(context) = head_fallback_context {
            if let Some(fallback) =
                handle_head_method_not_allowed(state, context, behavior.clone()).await
            {
                return fallback;
            }
        }
    }

    transform_response(response, behavior).await
}

/// Captures enough of the original HEAD request to retry with GET when the
/// upstream does not implement HEAD (e.g. OpenVSCode static assets).
struct HeadFallbackContext {
    headers: HeaderMap,
    uri: Uri,
    version: Version,
}

async fn handle_head_method_not_allowed(
    state: Arc<AppState>,
    context: HeadFallbackContext,
    behavior: ProxyBehavior,
) -> Option<Response<Body>> {
    let mut get_request = Request::builder()
        .method(Method::GET)
        .uri(context.uri)
        .version(context.version)
        .body(Body::empty())
        .ok()?;

    *get_request.headers_mut() = context.headers;
    get_request.headers_mut().remove(header::CONTENT_LENGTH);

    match state.client.request(get_request).await {
        Ok(resp) => match transform_head_response_from_get(resp, behavior).await {
            Ok(head_response) => Some(head_response),
            Err(_) => None,
        },
        Err(_) => None,
    }
}

async fn transform_head_response_from_get(
    response: Response<Body>,
    behavior: ProxyBehavior,
) -> Result<Response<Body>, hyper::Error> {
    let transformed_response = transform_response(response, behavior.clone()).await;
    let status = transformed_response.status();
    let version = transformed_response.version();
    let headers = transformed_response.headers().clone();

    // Drain the transformed body so we can surface an accurate Content-Length
    // header that matches the rewritten GET response.
    let body_bytes = body::to_bytes(transformed_response.into_body()).await?;
    let body_len = body_bytes.len();

    Ok(build_head_response(
        status,
        version,
        &headers,
        &behavior,
        Some(body_len),
        true,
    ))
}

fn build_head_response(
    status: StatusCode,
    version: Version,
    headers: &HeaderMap,
    behavior: &ProxyBehavior,
    body_len: Option<usize>,
    force_cors_headers: bool,
) -> Response<Body> {
    let mut builder = Response::builder().status(status).version(version);
    // Start from the upstream headers, then strip only the payload metadata we
    // are about to recompute so things like content-encoding remain intact.
    let mut new_headers = sanitize_headers(headers, false);
    new_headers.remove(header::CONTENT_LENGTH);
    new_headers.remove(header::TRANSFER_ENCODING);
    strip_csp_headers(&mut new_headers);
    if behavior.strip_cors_headers {
        strip_cors_headers(&mut new_headers);
    } else if behavior.add_cors {
        add_cors_headers(&mut new_headers);
    }
    if force_cors_headers && !behavior.strip_cors_headers {
        add_cors_headers(&mut new_headers);
    }
    if let Some(frame_ancestors) = behavior.frame_ancestors {
        if let Ok(value) = HeaderValue::from_str(frame_ancestors) {
            new_headers.insert("content-security-policy", value);
        }
    }
    if let Some(len) = body_len {
        if let Ok(value) = HeaderValue::from_str(&len.to_string()) {
            new_headers.insert(header::CONTENT_LENGTH, value);
        }
    }
    let headers_mut = builder.headers_mut().unwrap();
    for (name, value) in new_headers.iter() {
        headers_mut.insert(name, value.clone());
    }
    builder.body(Body::empty()).unwrap()
}

async fn handle_websocket(
    state: Arc<AppState>,
    req: Request<Body>,
    target: Target,
    behavior: ProxyBehavior,
) -> Response<Body> {
    let (scheme, host, port_opt) = match target {
        Target::BackendPort(port) => (
            state.backend_scheme.clone(),
            state.backend_host.clone(),
            Some(port),
        ),
        Target::Absolute { scheme, host, port } => (scheme, host, port),
    };

    let authority = match port_opt {
        Some(port) => format!("{}:{}", host, port),
        None => host,
    };

    let path_and_query = req
        .uri()
        .path_and_query()
        .map(|pq| pq.as_str())
        .unwrap_or("/");
    let ws_scheme = match scheme.as_str() {
        "https" | "wss" => "wss",
        _ => "ws",
    };
    let backend_url = format!("{}://{}{}", ws_scheme, authority, path_and_query);

    let headers_to_forward = collect_forward_headers(req.headers(), &behavior);

    match hyper_tungstenite::upgrade(req, None) {
        Ok((response, websocket)) => {
            tokio::spawn(async move {
                if let Err(err) = pump_websocket(websocket, backend_url, headers_to_forward).await {
                    error!(%err, "websocket proxy error");
                }
            });
            response
        }
        Err(err) => {
            error!(%err, "failed to upgrade connection");
            text_response(
                StatusCode::INTERNAL_SERVER_ERROR,
                "Failed to upgrade WebSocket connection",
            )
        }
    }
}

fn collect_forward_headers(
    original: &http::HeaderMap,
    behavior: &ProxyBehavior,
) -> http::HeaderMap {
    let mut headers = http::HeaderMap::new();
    if let Some(port) = &behavior.port_header {
        if let Ok(value) = HeaderValue::from_str(port) {
            headers.insert("X-Cmux-Port-Internal", value);
        }
    }
    if let Some(workspace) = behavior.workspace_header.as_ref() {
        if let Ok(value) = HeaderValue::from_str(workspace) {
            headers.insert("X-Cmux-Workspace-Internal", value);
        }
    } else if let Some(workspace) = derive_workspace_scope_from_headers(original) {
        if let Ok(value) = HeaderValue::from_str(&workspace) {
            headers.insert("X-Cmux-Workspace-Internal", value);
        }
    }
    headers.insert("X-Cmux-Proxied", HeaderValue::from_static("true"));

    if let Some(value) = original.get(header::USER_AGENT) {
        headers.insert(header::USER_AGENT, value.clone());
    }
    headers
}

fn derive_workspace_scope_from_headers(headers: &HeaderMap) -> Option<String> {
    let host = headers
        .get("x-forwarded-host")
        .and_then(|value| value.to_str().ok())
        .or_else(|| {
            headers
                .get(header::HOST)
                .and_then(|value| value.to_str().ok())
        })
        .map(normalize_host)?;

    let (subdomain_opt, _) = parse_cmux_host(&host)?;
    let subdomain = subdomain_opt?;
    scope_from_cmux_subdomain(&subdomain)
}

fn scope_from_cmux_subdomain(subdomain: &str) -> Option<String> {
    let rest = subdomain.strip_prefix("cmux-")?;
    let segments: Vec<&str> = rest.split('-').collect();
    if segments.len() < 2 {
        return None;
    }

    let port_segment = segments.last()?;
    if port_segment.parse::<u16>().ok().is_none() {
        return None;
    }

    let scope_segments = &segments[1..segments.len() - 1];
    if scope_segments.is_empty()
        || (scope_segments.len() == 1 && scope_segments[0].eq_ignore_ascii_case("base"))
    {
        None
    } else {
        Some(scope_segments.join("-"))
    }
}

async fn pump_websocket(
    websocket: HyperWebsocket,
    backend_url: String,
    headers: http::HeaderMap,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client_ws = websocket.await?;

    let mut request = backend_url.into_client_request()?;
    if let Some(host) = request.uri().host() {
        let host_header = if let Some(port) = request.uri().port_u16() {
            format!("{}:{}", host, port)
        } else {
            host.to_string()
        };
        request
            .headers_mut()
            .insert(header::HOST, HeaderValue::from_str(&host_header)?);
    }

    for (name, value) in headers.iter() {
        request.headers_mut().insert(name.clone(), value.clone());
    }

    let (backend_ws, _) = connect_async(request).await?;

    let (mut client_sink, mut client_stream) = client_ws.split();
    let (mut backend_sink, mut backend_stream) = backend_ws.split();

    let to_backend = async {
        while let Some(msg) = client_stream.next().await {
            match msg {
                Ok(message) => {
                    backend_sink.send(message).await?;
                }
                Err(err) => {
                    backend_sink.close().await?;
                    return Err(err);
                }
            }
        }
        backend_sink.close().await?;
        Ok::<(), hyper_tungstenite::tungstenite::Error>(())
    };

    let to_client = async {
        while let Some(msg) = backend_stream.next().await {
            match msg {
                Ok(message) => {
                    client_sink.send(message).await?;
                }
                Err(err) => {
                    client_sink.close().await?;
                    return Err(err);
                }
            }
        }
        client_sink.close().await?;
        Ok::<(), hyper_tungstenite::tungstenite::Error>(())
    };

    tokio::select! {
        res = to_backend => { res?; }
        res = to_client => { res?; }
    }

    Ok(())
}

async fn transform_response(response: Response<Body>, behavior: ProxyBehavior) -> Response<Body> {
    let status = response.status();
    let version = response.version();
    let headers = response.headers().clone();

    let content_type = headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");

    if content_type.contains("text/html") {
        match body::to_bytes(response.into_body()).await {
            Ok(bytes) => match rewrite_html(bytes, behavior.skip_service_worker) {
                Ok(body) => {
                    let mut builder = Response::builder().status(status).version(version);
                    let mut new_headers =
                        sanitize_headers(&headers, /* strip_payload_headers */ true);
                    strip_csp_headers(&mut new_headers);
                    if behavior.strip_cors_headers {
                        strip_cors_headers(&mut new_headers);
                    } else if behavior.add_cors {
                        add_cors_headers(&mut new_headers);
                    }
                    if let Some(frame_ancestors) = behavior.frame_ancestors {
                        if let Ok(value) = HeaderValue::from_str(frame_ancestors) {
                            new_headers.insert("content-security-policy", value);
                        }
                    }
                    new_headers.insert(
                        header::CONTENT_LENGTH,
                        HeaderValue::from_str(&body.len().to_string()).unwrap(),
                    );
                    let headers_mut = builder.headers_mut().unwrap();
                    for (name, value) in new_headers.iter() {
                        headers_mut.insert(name, value.clone());
                    }
                    builder.body(Body::from(body)).unwrap()
                }
                Err(_) => text_response(StatusCode::INTERNAL_SERVER_ERROR, "HTML rewrite failed"),
            },
            Err(_) => text_response(StatusCode::BAD_GATEWAY, "Failed to read upstream body"),
        }
    } else {
        let mut builder = Response::builder().status(status).version(version);
        let mut new_headers = sanitize_headers(&headers, /* strip_payload_headers */ false);
        strip_csp_headers(&mut new_headers);
        if behavior.strip_cors_headers {
            strip_cors_headers(&mut new_headers);
        } else if behavior.add_cors {
            add_cors_headers(&mut new_headers);
        }
        if let Some(frame_ancestors) = behavior.frame_ancestors {
            if let Ok(value) = HeaderValue::from_str(frame_ancestors) {
                new_headers.insert("content-security-policy", value);
            }
        }
        let headers_mut = builder.headers_mut().unwrap();
        for (name, value) in new_headers.iter() {
            headers_mut.insert(name, value.clone());
        }
        builder.body(response.into_body()).unwrap()
    }
}

fn sanitize_headers(headers: &HeaderMap, strip_payload_headers: bool) -> HeaderMap {
    let ignored_payload_headers = [
        "content-length",
        "content-encoding",
        "transfer-encoding",
        "content-md5",
        "content-digest",
        "etag",
    ];

    let mut out = HeaderMap::new();
    for (name, value) in headers.iter() {
        if strip_payload_headers && ignored_payload_headers.contains(&name.as_str()) {
            continue;
        }
        out.insert(name.clone(), value.clone());
    }
    out
}

fn strip_csp_headers(headers: &mut HeaderMap) {
    headers.remove("content-security-policy");
    headers.remove("content-security-policy-report-only");
    headers.remove("x-frame-options");
    headers.remove("frame-options");
}

fn add_cors_headers(headers: &mut HeaderMap) {
    headers.insert("access-control-allow-origin", HeaderValue::from_static("*"));
    headers.insert(
        "access-control-allow-methods",
        HeaderValue::from_static("GET, POST, PUT, DELETE, PATCH, OPTIONS, HEAD"),
    );
    headers.insert(
        "access-control-allow-headers",
        HeaderValue::from_static("*"),
    );
    headers.insert(
        "access-control-expose-headers",
        HeaderValue::from_static("*"),
    );
    headers.insert(
        "access-control-allow-credentials",
        HeaderValue::from_static("true"),
    );
    headers.insert("access-control-max-age", HeaderValue::from_static("86400"));
}

fn strip_cors_headers(headers: &mut HeaderMap) {
    const CORS_HEADER_NAMES: &[&str] = &[
        "access-control-allow-origin",
        "access-control-allow-methods",
        "access-control-allow-headers",
        "access-control-expose-headers",
        "access-control-allow-credentials",
        "access-control-max-age",
        "access-control-allow-private-network",
    ];

    for name in CORS_HEADER_NAMES {
        headers.remove(*name);
    }
}

fn rewrite_html(
    bytes: Bytes,
    skip_service_worker: bool,
) -> Result<Vec<u8>, lol_html::errors::RewritingError> {
    let mut output = Vec::with_capacity(bytes.len());

    let mut rewriter = HtmlRewriter::new(
        Settings {
            element_content_handlers: vec![
                element!("head", move |el| {
                    el.prepend(HEAD_SCRIPT, ContentType::Html);
                    if !skip_service_worker {
                        el.prepend(SERVICE_WORKER_SCRIPT, ContentType::Html);
                    }
                    Ok(())
                }),
                element!("meta", |el| {
                    if let Some(value) = el.get_attribute("http-equiv") {
                        if value.eq_ignore_ascii_case("content-security-policy") {
                            el.remove();
                        }
                    }
                    Ok(())
                }),
            ],
            ..Settings::default()
        },
        |c: &[u8]| output.extend_from_slice(c),
    );

    rewriter.write(&bytes)?;
    rewriter.end()?;
    Ok(output)
}

fn parse_route(subdomain: String) -> Route {
    if let Some(rest) = subdomain.strip_prefix("port-") {
        let segments: Vec<&str> = rest.split('-').collect();
        if segments.len() < 2 {
            return Route::Invalid(text_response(
                StatusCode::BAD_REQUEST,
                "Invalid cmux proxy subdomain",
            ));
        }

        let port = match segments[0].parse::<u16>() {
            Ok(port) => port,
            Err(_) => {
                return Route::Invalid(text_response(
                    StatusCode::BAD_REQUEST,
                    "Invalid cmux proxy subdomain",
                ));
            }
        };

        let morph_id = segments[1..].join("-");
        if morph_id.is_empty() {
            return Route::Invalid(text_response(
                StatusCode::BAD_REQUEST,
                "Invalid cmux proxy subdomain",
            ));
        }

        return Route::Port(PortRoute {
            port,
            morph_id,
            skip_service_worker: port == 39_378,
        });
    }

    if let Some(rest) = subdomain.strip_prefix("cmux-") {
        let segments: Vec<&str> = rest.split('-').collect();
        if segments.len() < 2 {
            return Route::Invalid(text_response(
                StatusCode::BAD_REQUEST,
                "Invalid cmux proxy subdomain",
            ));
        }
        let morph_id = segments[0];
        if morph_id.is_empty() {
            return Route::Invalid(text_response(
                StatusCode::BAD_REQUEST,
                "Missing morph id in cmux proxy subdomain",
            ));
        }
        let port_segment = match segments.last() {
            Some(seg) => *seg,
            None => {
                return Route::Invalid(text_response(
                    StatusCode::BAD_REQUEST,
                    "Invalid cmux proxy subdomain",
                ));
            }
        };
        let port = match port_segment.parse::<u16>() {
            Ok(port) => port,
            Err(_) => {
                return Route::Invalid(text_response(
                    StatusCode::BAD_REQUEST,
                    "Invalid port in cmux proxy subdomain",
                ));
            }
        };
        let scope_segments = &segments[1..segments.len() - 1];
        let workspace_header = if scope_segments.is_empty()
            || (scope_segments.len() == 1 && scope_segments[0].eq_ignore_ascii_case("base"))
        {
            None
        } else {
            Some(scope_segments.join("-"))
        };
        return Route::Cmux(CmuxRoute {
            port,
            workspace_header,
            morph_id: morph_id.to_string(),
        });
    }

    let parts: Vec<&str> = subdomain.split('-').collect();
    if parts.len() < 3 {
        return Route::Invalid(text_response(
            StatusCode::BAD_REQUEST,
            "Invalid cmux subdomain",
        ));
    }

    let port_segment = parts[parts.len() - 2];
    let workspace_parts = &parts[..parts.len() - 2];
    let vm_slug = parts.last().unwrap();

    if workspace_parts.is_empty() {
        return Route::Invalid(text_response(
            StatusCode::BAD_REQUEST,
            "Invalid cmux subdomain",
        ));
    }

    let workspace = workspace_parts.join("-");

    let port = match port_segment.parse::<u16>() {
        Ok(port) => port,
        Err(_) => {
            return Route::Invalid(text_response(
                StatusCode::BAD_REQUEST,
                "Invalid port in subdomain",
            ));
        }
    };

    if vm_slug.is_empty() {
        return Route::Invalid(text_response(
            StatusCode::BAD_REQUEST,
            "Invalid cmux subdomain",
        ));
    }

    Route::Workspace(WorkspaceRoute {
        workspace,
        port,
        vm_slug: vm_slug.to_string(),
    })
}

struct PortRoute {
    port: u16,
    morph_id: String,
    skip_service_worker: bool,
}

struct CmuxRoute {
    port: u16,
    workspace_header: Option<String>,
    morph_id: String,
}

struct WorkspaceRoute {
    workspace: String,
    port: u16,
    vm_slug: String,
}

enum Route {
    Port(PortRoute),
    Cmux(CmuxRoute),
    Workspace(WorkspaceRoute),
    Invalid(Response<Body>),
}

fn is_loop_header(req: &Request<Body>) -> bool {
    req.headers()
        .get("X-Cmux-Proxied")
        .and_then(|v| v.to_str().ok())
        .map(|v| v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

fn cors_response(status: StatusCode) -> Response<Body> {
    let mut headers = HeaderMap::new();
    add_cors_headers(&mut headers);
    let mut builder = Response::builder().status(status);
    let headers_mut = builder.headers_mut().unwrap();
    for (name, value) in headers.iter() {
        headers_mut.insert(name, value.clone());
    }
    builder.body(Body::empty()).unwrap()
}

fn text_response(status: StatusCode, body: &str) -> Response<Body> {
    Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, "text/plain; charset=utf-8")
        .body(Body::from(body.to_string()))
        .unwrap()
}

fn json_response(status: StatusCode, value: Value) -> Response<Body> {
    Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(value.to_string()))
        .unwrap()
}

fn extract_host(req: &Request<Body>) -> Option<String> {
    let headers = req.headers();
    if let Some(forwarded) = headers
        .get("x-forwarded-host")
        .and_then(|value| value.to_str().ok())
    {
        return Some(normalize_host(forwarded));
    }

    headers
        .get(header::HOST)
        .and_then(|value| value.to_str().ok())
        .map(normalize_host)
}

fn normalize_host(value: &str) -> String {
    let mut host = value.to_ascii_lowercase();
    if let Some(idx) = host.rfind(':') {
        if host[idx + 1..].chars().all(|c| c.is_ascii_digit()) {
            host.truncate(idx);
        }
    }
    host
}

fn parse_cmux_host(host: &str) -> Option<(Option<String>, String)> {
    if host == "cmux.sh" || host == "cmux.local" {
        return Some((None, "cmux.sh".to_string()));
    }
    if let Some(prefix) = host.strip_suffix(".cmux.sh") {
        let subdomain = if prefix.is_empty() {
            None
        } else {
            Some(prefix.to_string())
        };
        return Some((subdomain, "cmux.sh".to_string()));
    }

    if host == "cmux.localhost" {
        return Some((None, "cmux.localhost".to_string()));
    }
    if let Some(prefix) = host.strip_suffix(".cmux.localhost") {
        let subdomain = if prefix.is_empty() {
            None
        } else {
            Some(prefix.to_string())
        };
        return Some((subdomain, "cmux.localhost".to_string()));
    }

    if host == "cmux.app" {
        return Some((None, "cmux.app".to_string()));
    }
    if let Some(prefix) = host.strip_suffix(".cmux.app") {
        let subdomain = if prefix.is_empty() {
            None
        } else {
            Some(prefix.to_string())
        };
        return Some((subdomain, "cmux.app".to_string()));
    }
    None
}

const HEAD_SCRIPT: &str = r#"<script data-cmux-injected="true">
window.__cmuxLocation = window.location;
</script>"#;

const SERVICE_WORKER_SCRIPT: &str = r#"<script data-cmux-injected="true">
// __CMUX_NO_REWRITE__
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('/proxy-sw.js', { scope: '/' }).catch(console.error);
}
</script>"#;

const SERVICE_WORKER_JS: &str = r#"self.addEventListener('install', (event) => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(clients.claim());
});

function isLoopbackHostname(hostname) {
  if (!hostname) {
    return false;
  }
  if (hostname === 'localhost' || hostname === '0.0.0.0') {
    return true;
  }
  if (hostname === '::1' || hostname === '[::1]' || hostname === '::') {
    return true;
  }
  return /^127(?:\.\d{1,3}){3}$/.test(hostname);
}

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  if (isLoopbackHostname(url.hostname) && url.port) {
    const currentHost = self.location.hostname;
    const firstDot = currentHost.indexOf('.');
    if (firstDot === -1) {
      return;
    }
    const firstLabel = currentHost.slice(0, firstDot);
    const morphIdMatch = firstLabel.match(/^port-\d+-(.*)$/);
    if (!morphIdMatch) {
      return;
    }
    const domain = currentHost.slice(firstDot + 1);
    if (!domain) {
      return;
    }
    const morphId = morphIdMatch[1];
    const redirectUrl = `https://port-${url.port}-${morphId}.${domain}${url.pathname}${url.search}`;
    event.respondWith(fetch(redirectUrl, { redirect: 'follow' }));
    return;
  }
});
"#;

fn service_worker_response() -> Response<Body> {
    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "application/javascript")
        .header(header::CACHE_CONTROL, "no-cache")
        .body(Body::from(SERVICE_WORKER_JS))
        .unwrap()
}
