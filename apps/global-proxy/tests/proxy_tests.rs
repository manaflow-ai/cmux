use std::{
    net::{Ipv4Addr, SocketAddr},
    sync::{Arc, Mutex},
    time::Duration,
};

use futures_util::{SinkExt, StreamExt};
use global_proxy::{ProxyConfig, spawn_proxy};
use hyper::{
    Body, Method as HyperMethod, Request, Response, Server, StatusCode,
    header::HeaderValue,
    service::{make_service_fn, service_fn},
};
use reqwest::Method;
use tokio::{sync::oneshot, task::JoinHandle};
use tokio_tungstenite::tungstenite::{
    Message,
    client::IntoClientRequest,
    handshake::server::{Request as WsHandshakeRequest, Response as WsHandshakeResponse},
};

struct TestProxy {
    addr: SocketAddr,
    handle: Option<global_proxy::ProxyHandle>,
    client: reqwest::Client,
}

impl TestProxy {
    async fn spawn() -> Self {
        let config = ProxyConfig {
            bind_addr: SocketAddr::from((Ipv4Addr::LOCALHOST, 0)),
            backend_host: "127.0.0.1".to_string(),
            ..Default::default()
        };

        let handle = spawn_proxy(config).await.expect("failed to start proxy");

        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(5))
            .build()
            .expect("client");

        Self {
            addr: handle.addr,
            handle: Some(handle),
            client,
        }
    }

    fn url(&self, path: &str) -> String {
        format!("http://{}{}", self.addr, path)
    }

    async fn request(
        &self,
        method: Method,
        host: &str,
        path: &str,
        headers: &[(&str, &str)],
    ) -> reqwest::Response {
        let mut request = self.client.request(method, self.url(path));
        request = request.header("Host", host);
        for (name, value) in headers {
            request = request.header(*name, *value);
        }
        request.send().await.expect("request")
    }

    async fn shutdown(mut self) {
        if let Some(handle) = self.handle.take() {
            handle.shutdown().await;
        }
    }
}

struct TestHttpBackend {
    addr: SocketAddr,
    shutdown: Option<oneshot::Sender<()>>,
    task: JoinHandle<()>,
}

impl TestHttpBackend {
    async fn serve(
        handler: Arc<dyn Fn(Request<Body>) -> Response<Body> + Send + Sync + 'static>,
    ) -> Self {
        let listener = std::net::TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)))
            .expect("bind backend");
        listener.set_nonblocking(true).expect("set nonblocking");
        let addr = listener.local_addr().expect("local addr");

        let make_svc = make_service_fn(move |_conn| {
            let handler = handler.clone();
            async move {
                Ok::<_, hyper::Error>(service_fn(move |req: Request<Body>| {
                    let handler = handler.clone();
                    async move { Ok::<_, hyper::Error>((handler)(req)) }
                }))
            }
        });

        let server = Server::from_tcp(listener)
            .expect("server from tcp")
            .serve(make_svc);
        let (tx, rx) = oneshot::channel();
        let task = tokio::spawn(async move {
            let server = server.with_graceful_shutdown(async {
                let _ = rx.await;
            });
            if let Err(err) = server.await {
                eprintln!("backend server error: {err}");
            }
        });

        Self {
            addr,
            shutdown: Some(tx),
            task,
        }
    }

    async fn serve_on_port(
        port: u16,
        handler: Arc<dyn Fn(Request<Body>) -> Response<Body> + Send + Sync + 'static>,
    ) -> Self {
        let listener = std::net::TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, port)))
            .expect("bind backend on port");
        listener.set_nonblocking(true).expect("set nonblocking");
        let addr = listener.local_addr().expect("local addr");

        let make_svc = make_service_fn(move |_conn| {
            let handler = handler.clone();
            async move {
                Ok::<_, hyper::Error>(service_fn(move |req: Request<Body>| {
                    let handler = handler.clone();
                    async move { Ok::<_, hyper::Error>((handler)(req)) }
                }))
            }
        });

        let server = Server::from_tcp(listener)
            .expect("server from tcp")
            .serve(make_svc);
        let (tx, rx) = oneshot::channel();
        let task = tokio::spawn(async move {
            let server = server.with_graceful_shutdown(async {
                let _ = rx.await;
            });
            if let Err(err) = server.await {
                eprintln!("backend server error: {err}");
            }
        });

        Self {
            addr,
            shutdown: Some(tx),
            task,
        }
    }

    fn port(&self) -> u16 {
        self.addr.port()
    }

    async fn shutdown(mut self) {
        if let Some(tx) = self.shutdown.take() {
            let _ = tx.send(());
        }
        let _ = self.task.await;
    }
}

struct TestWsBackend {
    addr: SocketAddr,
    shutdown: Option<oneshot::Sender<()>>,
    task: JoinHandle<()>,
}

impl TestWsBackend {
    async fn spawn_echo() -> Self {
        let listener = tokio::net::TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)))
            .await
            .expect("ws bind");
        let addr = listener.local_addr().expect("ws addr");
        let (tx, mut rx) = oneshot::channel();

        let task = tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = &mut rx => break,
                    accept = listener.accept() => {
                        match accept {
                            Ok((stream, _)) => {
                                tokio::spawn(async move {
                                    match tokio_tungstenite::accept_async(stream).await {
                                        Ok(mut ws) => {
                                            while let Some(msg) = ws.next().await {
                                                match msg {
                                                    Ok(Message::Text(text)) => {
                                                        if ws.send(Message::Text(text)).await.is_err() {
                                                            break;
                                                        }
                                                    }
                                                    Ok(Message::Binary(bin)) => {
                                                        if ws.send(Message::Binary(bin)).await.is_err() {
                                                            break;
                                                        }
                                                    }
                                                    Ok(Message::Ping(data)) => {
                                                        let _ = ws.send(Message::Pong(data)).await;
                                                    }
                                                    Ok(Message::Pong(_)) => {}
                                                    Ok(Message::Frame(frame)) => {
                                                        if ws.send(Message::Frame(frame)).await.is_err() {
                                                            break;
                                                        }
                                                    }
                                                    Ok(Message::Close(frame)) => {
                                                        let _ = ws.close(frame).await;
                                                        break;
                                                    }
                                                    Err(_) => break,
                                                }
                                            }
                                        }
                                        Err(err) => eprintln!("ws accept error: {err}"),
                                    }
                                });
                            }
                            Err(err) => {
                                eprintln!("ws accept error: {err}");
                                break;
                            }
                        }
                    }
                }
            }
        });

        Self {
            addr,
            shutdown: Some(tx),
            task,
        }
    }

    async fn spawn_with_handshake(protocol: Option<&str>, extensions: Option<&str>) -> Self {
        let listener = tokio::net::TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)))
            .await
            .expect("ws bind");
        let addr = listener.local_addr().expect("ws addr");
        let (tx, mut rx) = oneshot::channel();
        let protocol_value =
            protocol.map(|value| HeaderValue::from_str(value).expect("protocol header"));
        let extensions_value =
            extensions.map(|value| HeaderValue::from_str(value).expect("extensions header"));

        let task = tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = &mut rx => break,
                    accept = listener.accept() => {
                        match accept {
                            Ok((stream, _)) => {
                                let protocol_value = protocol_value.clone();
                                let extensions_value = extensions_value.clone();
                                tokio::spawn(async move {
                                    match tokio_tungstenite::accept_hdr_async(stream, move |_req: &WsHandshakeRequest, mut response: WsHandshakeResponse| {
                                        if let Some(value) = protocol_value.clone() {
                                            response.headers_mut().append("Sec-WebSocket-Protocol", value);
                                        }
                                        if let Some(value) = extensions_value.clone() {
                                            response.headers_mut().append("Sec-WebSocket-Extensions", value);
                                        }
                                        Ok(response)
                                    }).await {
                                        Ok(mut ws) => {
                                            while let Some(msg) = ws.next().await {
                                                match msg {
                                                    Ok(Message::Text(text)) => {
                                                        if ws.send(Message::Text(text)).await.is_err() {
                                                            break;
                                                        }
                                                    }
                                                    Ok(Message::Binary(bin)) => {
                                                        if ws.send(Message::Binary(bin)).await.is_err() {
                                                            break;
                                                        }
                                                    }
                                                    Ok(Message::Ping(data)) => {
                                                        let _ = ws.send(Message::Pong(data)).await;
                                                    }
                                                    Ok(Message::Pong(_)) => {}
                                                    Ok(Message::Frame(frame)) => {
                                                        if ws.send(Message::Frame(frame)).await.is_err() {
                                                            break;
                                                        }
                                                    }
                                                    Ok(Message::Close(frame)) => {
                                                        let _ = ws.close(frame).await;
                                                        break;
                                                    }
                                                    Err(_) => break,
                                                }
                                            }
                                        }
                                        Err(err) => eprintln!("ws accept error: {err}"),
                                    }
                                });
                            }
                            Err(err) => {
                                eprintln!("ws accept error: {err}");
                                break;
                            }
                        }
                    }
                }
            }
        });

        Self {
            addr,
            shutdown: Some(tx),
            task,
        }
    }

    async fn spawn_capture_workspace_header()
    -> (Self, tokio::sync::oneshot::Receiver<Option<String>>) {
        let listener = tokio::net::TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)))
            .await
            .expect("ws bind");
        let addr = listener.local_addr().expect("ws addr");
        let (shutdown_tx, mut shutdown_rx) = oneshot::channel();
        let (header_tx, header_rx) = oneshot::channel();
        let header_sender = Arc::new(Mutex::new(Some(header_tx)));

        let task = tokio::spawn({
            let header_sender = header_sender.clone();
            async move {
                loop {
                    tokio::select! {
                        _ = &mut shutdown_rx => break,
                        accept = listener.accept() => {
                            match accept {
                                Ok((stream, _)) => {
                                    let header_sender = header_sender.clone();
                                    tokio::spawn(async move {
                                        match tokio_tungstenite::accept_hdr_async(stream, move |req: &WsHandshakeRequest, response| {
                                            if let Some(sender) = header_sender.lock().expect("lock header sender").take() {
                                                let value = req
                                                    .headers()
                                                    .get("X-Cmux-Workspace-Internal")
                                                    .and_then(|v| v.to_str().ok())
                                                    .map(|v| v.to_string());
                                                let _ = sender.send(value);
                                            }
                                            Ok(response)
                                        }).await {
                                            Ok(mut ws) => {
                                                while let Some(msg) = ws.next().await {
                                                    match msg {
                                                        Ok(Message::Text(text)) => {
                                                            if ws.send(Message::Text(text)).await.is_err() {
                                                                break;
                                                            }
                                                        }
                                                        Ok(Message::Binary(bin)) => {
                                                            if ws.send(Message::Binary(bin)).await.is_err() {
                                                                break;
                                                            }
                                                        }
                                                        Ok(Message::Ping(data)) => {
                                                            let _ = ws.send(Message::Pong(data)).await;
                                                        }
                                                        Ok(Message::Pong(_)) => {}
                                                        Ok(Message::Frame(frame)) => {
                                                            if ws.send(Message::Frame(frame)).await.is_err() {
                                                                break;
                                                            }
                                                        }
                                                        Ok(Message::Close(frame)) => {
                                                            let _ = ws.close(frame).await;
                                                            break;
                                                        }
                                                        Err(_) => break,
                                                    }
                                                }
                                            }
                                            Err(err) => eprintln!("ws accept error: {err}"),
                                        }
                                    });
                                }
                                Err(err) => {
                                    eprintln!("ws accept error: {err}");
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        });

        (
            Self {
                addr,
                shutdown: Some(shutdown_tx),
                task,
            },
            header_rx,
        )
    }

    fn port(&self) -> u16 {
        self.addr.port()
    }

    async fn shutdown(mut self) {
        if let Some(tx) = self.shutdown.take() {
            let _ = tx.send(());
        }
        let _ = self.task.await;
    }
}

#[tokio::test]
async fn health_check() {
    let proxy = TestProxy::spawn().await;

    let response = proxy
        .request(Method::GET, "localhost", "/health", &[])
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let json: serde_json::Value = response.json().await.expect("json");
    assert_eq!(json["status"], "healthy");

    proxy.shutdown().await;
}

#[tokio::test]
async fn version_endpoint_reports_package_version() {
    let proxy = TestProxy::spawn().await;

    let response = proxy
        .request(Method::GET, "localhost", "/version", &[])
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let json: serde_json::Value = response.json().await.expect("json");
    assert_eq!(json["version"], env!("CARGO_PKG_VERSION"));

    proxy.shutdown().await;
}

#[tokio::test]
async fn version_path_with_cmux_subdomain_is_forwarded() {
    let backend = TestHttpBackend::serve(Arc::new(|_req| {
        Response::builder()
            .status(StatusCode::IM_A_TEAPOT)
            .body(Body::from("proxy"))
            .unwrap()
    }))
    .await;

    let proxy = TestProxy::spawn().await;
    let host = format!("cmux-demo-{}.cmux.sh", backend.port());

    let response = proxy.request(Method::GET, &host, "/version", &[]).await;
    assert_eq!(response.status(), StatusCode::IM_A_TEAPOT);
    assert_eq!(response.text().await.expect("body"), "proxy");

    proxy.shutdown().await;
    backend.shutdown().await;
}

#[tokio::test]
async fn apex_returns_greeting() {
    let proxy = TestProxy::spawn().await;

    let response = proxy.request(Method::GET, "cmux.sh", "/", &[]).await;
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response.text().await.expect("text"), "cmux!");

    proxy.shutdown().await;
}

#[tokio::test]
async fn service_worker_route() {
    let proxy = TestProxy::spawn().await;

    let response = proxy
        .request(Method::GET, "port-8080-test.cmux.sh", "/proxy-sw.js", &[])
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response
            .headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok()),
        Some("application/javascript")
    );
    let body = response.text().await.expect("body");
    assert!(body.contains("addEventListener"));
    assert!(body.contains("isLoopbackHostname"));

    proxy.shutdown().await;
}

#[tokio::test]
async fn port_options_preflight() {
    let proxy = TestProxy::spawn().await;

    let response = proxy
        .request(Method::OPTIONS, "port-39378-test.cmux.sh", "/", &[])
        .await;
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    assert!(
        response
            .headers()
            .get("access-control-allow-origin")
            .is_none()
    );

    let cmux_response = proxy
        .request(Method::OPTIONS, "cmux-test-base-39378.cmux.sh", "/", &[])
        .await;
    assert_eq!(cmux_response.status(), StatusCode::NO_CONTENT);
    assert!(
        cmux_response
            .headers()
            .get("access-control-allow-origin")
            .is_none()
    );

    proxy.shutdown().await;
}

#[tokio::test]
async fn port_loop_detection() {
    let proxy = TestProxy::spawn().await;

    let response = proxy
        .request(
            Method::GET,
            "port-8080-test.cmux.sh",
            "/",
            &[("X-Cmux-Proxied", "true")],
        )
        .await;
    assert_eq!(response.status(), StatusCode::LOOP_DETECTED);
    assert_eq!(
        response.text().await.expect("text"),
        "Loop detected in proxy"
    );

    proxy.shutdown().await;
}

#[tokio::test]
async fn port_head_request_passes_validation() {
    let proxy = TestProxy::spawn().await;

    let response = proxy
        .request(Method::HEAD, "port-8080-j2z9smmu.cmux.sh", "/test", &[])
        .await;
    assert_ne!(response.status(), StatusCode::BAD_REQUEST);
    assert_ne!(response.status(), StatusCode::LOOP_DETECTED);

    proxy.shutdown().await;
}

#[tokio::test]
async fn cmux_subdomain_validation() {
    let proxy = TestProxy::spawn().await;

    let invalid = proxy
        .request(Method::GET, "cmux-test.cmux.sh", "/", &[])
        .await;
    assert_eq!(invalid.status(), StatusCode::BAD_REQUEST);
    assert_eq!(
        invalid.text().await.expect("text"),
        "Invalid cmux proxy subdomain"
    );

    let invalid_port = proxy
        .request(Method::GET, "cmux-test-abc.cmux.sh", "/", &[])
        .await;
    assert_eq!(invalid_port.status(), StatusCode::BAD_REQUEST);
    assert_eq!(
        invalid_port.text().await.expect("text"),
        "Invalid port in cmux proxy subdomain"
    );

    proxy.shutdown().await;
}

#[tokio::test]
async fn cmux_head_request_validation() {
    let proxy = TestProxy::spawn().await;

    let response = proxy
        .request(Method::HEAD, "cmux-j2z9smmu-8080.cmux.sh", "/test", &[])
        .await;
    assert_ne!(response.status(), StatusCode::BAD_REQUEST);
    assert_ne!(response.status(), StatusCode::LOOP_DETECTED);

    proxy.shutdown().await;
}

#[tokio::test]
async fn cmux_domain_header_with_port_is_parsed() {
    let proxy = TestProxy::spawn().await;

    let response = proxy
        .request(
            Method::HEAD,
            "cmux-uopbmezr-39378.cmux.localhost:8090",
            "/",
            &[],
        )
        .await;
    assert_ne!(response.status(), StatusCode::BAD_REQUEST);
    assert_ne!(response.status(), StatusCode::LOOP_DETECTED);

    proxy.shutdown().await;
}

#[tokio::test]
async fn cmux_base_scope_validation() {
    let proxy = TestProxy::spawn().await;

    let response = proxy
        .request(Method::HEAD, "cmux-test-base-8080.cmux.sh", "/", &[])
        .await;
    assert_ne!(response.status(), StatusCode::BAD_REQUEST);

    proxy.shutdown().await;
}

#[tokio::test]
async fn cmux_loop_detection() {
    let proxy = TestProxy::spawn().await;

    let response = proxy
        .request(
            Method::GET,
            "cmux-test-8080.cmux.sh",
            "/",
            &[("X-Cmux-Proxied", "true")],
        )
        .await;
    assert_eq!(response.status(), StatusCode::LOOP_DETECTED);
    assert_eq!(
        response.text().await.expect("text"),
        "Loop detected in proxy"
    );

    proxy.shutdown().await;
}

#[tokio::test]
async fn workspace_subdomain_validation() {
    let proxy = TestProxy::spawn().await;

    let invalid = proxy
        .request(Method::GET, "test-8080.cmux.sh", "/", &[])
        .await;
    assert_eq!(invalid.status(), StatusCode::BAD_REQUEST);
    assert_eq!(
        invalid.text().await.expect("text"),
        "Invalid cmux subdomain"
    );

    let invalid_port = proxy
        .request(Method::GET, "workspace-abc-vmslug.cmux.sh", "/", &[])
        .await;
    assert_eq!(invalid_port.status(), StatusCode::BAD_REQUEST);
    assert_eq!(
        invalid_port.text().await.expect("text"),
        "Invalid port in subdomain"
    );

    proxy.shutdown().await;
}

#[tokio::test]
async fn workspace_head_validation() {
    let proxy = TestProxy::spawn().await;

    let response = proxy
        .request(
            Method::HEAD,
            "my-workspace-8080-vmslug.cmux.sh",
            "/test",
            &[],
        )
        .await;
    assert_ne!(response.status(), StatusCode::BAD_REQUEST);
    assert_ne!(response.status(), StatusCode::LOOP_DETECTED);

    proxy.shutdown().await;
}

#[tokio::test]
async fn workspace_loop_detection() {
    let proxy = TestProxy::spawn().await;

    let response = proxy
        .request(
            Method::GET,
            "workspace-8080-vmslug.cmux.sh",
            "/",
            &[("X-Cmux-Proxied", "true")],
        )
        .await;
    assert_eq!(response.status(), StatusCode::LOOP_DETECTED);
    assert_eq!(
        response.text().await.expect("text"),
        "Loop detected in proxy"
    );

    proxy.shutdown().await;
}

#[tokio::test]
async fn html_responses_inject_scripts() {
    let backend = TestHttpBackend::serve(Arc::new(|_req| {
        Response::builder()
            .status(StatusCode::OK)
            .header("content-type", "text/html")
            .body(Body::from(
                "<html><head><title>Demo</title></head><body>Hello</body></html>",
            ))
            .unwrap()
    }))
    .await;

    let proxy = TestProxy::spawn().await;
    let host = format!("port-{}-test.cmux.sh", backend.port());

    let response = proxy.request(Method::GET, &host, "/", &[]).await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = response.text().await.expect("body");
    assert!(
        body.contains("window.__cmuxLocation"),
        "missing location script"
    );
    assert!(
        body.contains("navigator.serviceWorker.register"),
        "missing service worker script"
    );

    proxy.shutdown().await;
    backend.shutdown().await;
}

#[tokio::test]
async fn html_with_unsupported_encoding_skips_rewrite() {
    static HTML_BODY: &str = "<!DOCTYPE html><html><head><title>Encoded</title></head><body>Encoded Content</body></html>";
    let backend = TestHttpBackend::serve(Arc::new(|_req| {
        Response::builder()
            .status(StatusCode::OK)
            .header("content-type", "text/html; charset=utf-8")
            .header("content-encoding", "compress")
            .body(Body::from(HTML_BODY))
            .unwrap()
    }))
    .await;

    let proxy = TestProxy::spawn().await;
    let host = format!("port-{}-test.cmux.sh", backend.port());

    let response = proxy.request(Method::GET, &host, "/", &[]).await;
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response
            .headers()
            .get("content-encoding")
            .and_then(|value| value.to_str().ok()),
        Some("compress")
    );
    let body = response.text().await.expect("body");
    assert!(
        !body.contains("window.__cmuxLocation"),
        "unsupported encodings should not be rewritten"
    );
    assert!(body.contains("Encoded Content"));

    proxy.shutdown().await;
    backend.shutdown().await;
}

#[tokio::test]
async fn html_responses_skip_service_worker_for_cmux_route() {
    let backend = TestHttpBackend::serve(Arc::new(|_req| {
        Response::builder()
            .status(StatusCode::OK)
            .header("content-type", "text/html")
            .body(Body::from(
                "<html><head><title>Demo</title></head><body>Hello</body></html>",
            ))
            .unwrap()
    }))
    .await;

    let proxy = TestProxy::spawn().await;
    let host = format!("cmux-demo-{}.cmux.sh", backend.port());

    let response = proxy.request(Method::GET, &host, "/", &[]).await;
    assert_eq!(response.status(), StatusCode::OK);
    let body = response.text().await.expect("body");
    assert!(body.contains("window.__cmuxLocation"));
    assert!(
        !body.contains("navigator.serviceWorker.register"),
        "service worker script should be skipped"
    );

    proxy.shutdown().await;
    backend.shutdown().await;
}

#[tokio::test]
async fn port_39378_strips_cors_and_applies_csp() {
    let handler = Arc::new(|req: Request<Body>| {
        if req.method() == HyperMethod::HEAD {
            Response::builder()
                .status(StatusCode::METHOD_NOT_ALLOWED)
                .body(Body::empty())
                .unwrap()
        } else {
            Response::builder()
                .status(StatusCode::OK)
                .header("content-type", "text/html")
                .header("content-security-policy", "frame-ancestors 'none';")
                .header("access-control-allow-origin", "https://upstream.example")
                .header("access-control-allow-methods", "GET, OPTIONS")
                .header("access-control-allow-headers", "X-Test")
                .header("access-control-allow-credentials", "true")
                .body(Body::from("<html><head></head><body>ok</body></html>"))
                .unwrap()
        }
    });

    let backend = TestHttpBackend::serve_on_port(39_378, handler).await;
    let proxy = TestProxy::spawn().await;

    let response = proxy
        .request(
            Method::GET,
            "port-39378-test.cmux.localhost",
            "/",
            &[("Origin", "https://cmux.dev")],
        )
        .await;

    assert_eq!(response.status(), StatusCode::OK);
    let headers = response.headers();
    assert!(headers.get("access-control-allow-origin").is_none());
    assert!(headers.get("access-control-allow-methods").is_none());
    assert!(headers.get("access-control-allow-headers").is_none());
    assert!(headers.get("access-control-allow-credentials").is_none());
    assert!(headers.get("access-control-expose-headers").is_none());
    assert!(headers.get("access-control-max-age").is_none());
    assert_eq!(
        headers
            .get("content-security-policy")
            .and_then(|v| v.to_str().ok()),
        Some(
            "frame-ancestors 'self' https://cmux.local http://cmux.local https://www.cmux.sh https://cmux.sh https://www.cmux.dev https://cmux.dev http://localhost:9775;",
        )
    );
    assert!(headers.get("x-frame-options").is_none());

    let cmux_response = proxy
        .request(
            Method::GET,
            "cmux-test-base-39378.cmux.sh",
            "/",
            &[("Origin", "https://cmux.dev")],
        )
        .await;
    assert_eq!(cmux_response.status(), StatusCode::OK);
    let cmux_headers = cmux_response.headers();
    for name in [
        "access-control-allow-origin",
        "access-control-allow-methods",
        "access-control-allow-headers",
        "access-control-allow-credentials",
        "access-control-expose-headers",
        "access-control-max-age",
    ] {
        assert!(
            cmux_headers.get(name).is_none(),
            "expected header {} to be stripped",
            name
        );
    }
    assert!(
        cmux_headers.get("content-security-policy").is_none(),
        "CSP should remain stripped for cmux host"
    );

    let cmux_localhost_response = proxy
        .request(Method::GET, "cmux-test-base-39378.cmux.localhost", "/", &[])
        .await;
    assert_eq!(cmux_localhost_response.status(), StatusCode::OK);
    for name in [
        "access-control-allow-origin",
        "access-control-allow-methods",
        "access-control-allow-headers",
        "access-control-allow-credentials",
        "access-control-expose-headers",
        "access-control-max-age",
    ] {
        assert!(
            cmux_localhost_response.headers().get(name).is_none(),
            "expected header {} to be stripped",
            name
        );
    }
    assert!(
        cmux_localhost_response
            .headers()
            .get("content-security-policy")
            .is_none(),
        "CSP should remain stripped for cmux .localhost host"
    );

    let response_localhost = proxy
        .request(
            Method::GET,
            "port-39378-test.cmux.localhost",
            "/",
            &[("Origin", "http://localhost:9775")],
        )
        .await;
    assert_eq!(response_localhost.status(), StatusCode::OK);
    for name in [
        "access-control-allow-origin",
        "access-control-allow-methods",
        "access-control-allow-headers",
        "access-control-allow-credentials",
        "access-control-expose-headers",
        "access-control-max-age",
    ] {
        assert!(
            response_localhost.headers().get(name).is_none(),
            "expected header {} to be stripped",
            name
        );
    }

    let cmux_local_response = proxy
        .request(
            Method::GET,
            "cmux-test-base-39378.cmux.sh",
            "/",
            &[("Origin", "http://localhost:9775")],
        )
        .await;
    assert_eq!(cmux_local_response.status(), StatusCode::OK);
    for name in [
        "access-control-allow-origin",
        "access-control-allow-methods",
        "access-control-allow-headers",
        "access-control-allow-credentials",
        "access-control-expose-headers",
        "access-control-max-age",
    ] {
        assert!(
            cmux_local_response.headers().get(name).is_none(),
            "expected header {} to be stripped",
            name
        );
    }

    let head_response = proxy
        .request(
            Method::HEAD,
            "port-39378-test.cmux.localhost",
            "/",
            &[("Origin", "https://cmux.dev")],
        )
        .await;
    assert_eq!(head_response.status(), StatusCode::OK);
    for name in [
        "access-control-allow-origin",
        "access-control-allow-methods",
        "access-control-allow-headers",
        "access-control-allow-credentials",
        "access-control-expose-headers",
        "access-control-max-age",
    ] {
        assert!(
            head_response.headers().get(name).is_none(),
            "expected header {} to be stripped",
            name
        );
    }
    assert_eq!(
        head_response
            .headers()
            .get("content-security-policy")
            .and_then(|v| v.to_str().ok()),
        Some(
            "frame-ancestors 'self' https://cmux.local http://cmux.local https://www.cmux.sh https://cmux.sh https://www.cmux.dev https://cmux.dev http://localhost:9775;"
        )
    );

    let head_cmux_response = proxy
        .request(
            Method::HEAD,
            "cmux-test-base-39378.cmux.sh",
            "/",
            &[("Origin", "https://cmux.dev")],
        )
        .await;
    assert_eq!(head_cmux_response.status(), StatusCode::OK);
    for name in [
        "access-control-allow-origin",
        "access-control-allow-methods",
        "access-control-allow-headers",
        "access-control-allow-credentials",
        "access-control-expose-headers",
        "access-control-max-age",
    ] {
        assert!(
            head_cmux_response.headers().get(name).is_none(),
            "expected header {} to be stripped",
            name
        );
    }
    assert!(
        head_cmux_response
            .headers()
            .get("content-security-policy")
            .is_none()
    );

    proxy.shutdown().await;
    backend.shutdown().await;
}

#[tokio::test]
async fn head_method_not_allowed_falls_back_to_get_with_length() {
    let seen_methods: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
    let handler_methods = seen_methods.clone();

    let handler = Arc::new(move |req: Request<Body>| {
        handler_methods
            .lock()
            .unwrap()
            .push(req.method().to_string());

        if req.method() == HyperMethod::HEAD {
            Response::builder()
                .status(StatusCode::METHOD_NOT_ALLOWED)
                .body(Body::empty())
                .unwrap()
        } else {
            Response::builder()
                .status(StatusCode::OK)
                .header("content-type", "text/plain")
                .body(Body::from("hello"))
                .unwrap()
        }
    });

    let backend = TestHttpBackend::serve(handler).await;
    let proxy = TestProxy::spawn().await;
    let host = format!("port-{}-test.cmux.localhost", backend.port());

    let response = proxy.request(Method::HEAD, &host, "/asset.js", &[]).await;
    assert_eq!(response.status(), StatusCode::OK);

    let headers = response.headers();
    assert_eq!(
        headers.get("content-length").and_then(|v| v.to_str().ok()),
        Some("5")
    );
    assert_eq!(
        headers.get("content-type").and_then(|v| v.to_str().ok()),
        Some("text/plain")
    );
    assert!(headers.get("transfer-encoding").is_none());

    let methods = seen_methods.lock().unwrap().clone();
    assert_eq!(methods, vec!["HEAD", "GET"]);

    proxy.shutdown().await;
    backend.shutdown().await;
}

#[tokio::test]
async fn websocket_proxy_for_cmux_route_forwards_workspace_header() {
    let (backend, header_rx) = TestWsBackend::spawn_capture_workspace_header().await;
    let proxy = TestProxy::spawn().await;

    let host = format!("cmux-demo-feature-{}.cmux.sh", backend.port());

    let url = format!("ws://{}{}", proxy.addr, "/ws");
    let mut request = url.into_client_request().expect("request");
    request
        .headers_mut()
        .insert("Host", host.parse().expect("host header"));
    let (mut ws, _) = tokio_tungstenite::connect_async(request)
        .await
        .expect("connect through proxy");

    let captured_workspace = header_rx.await.expect("header captured");
    assert_eq!(captured_workspace.as_deref(), Some("feature"));

    ws.send(Message::Text("scope".into())).await.expect("send");
    let reply = ws.next().await.expect("reply").expect("message");
    assert_eq!(reply.into_text().unwrap(), "scope");
    ws.close(None).await.unwrap();

    proxy.shutdown().await;
    backend.shutdown().await;
}

#[tokio::test]
async fn websocket_proxy_for_port_route() {
    let backend = TestWsBackend::spawn_echo().await;
    let proxy = TestProxy::spawn().await;

    let host = format!("port-{}-test.cmux.sh", backend.port());

    let url = format!("ws://{}{}", proxy.addr, "/ws");
    let mut request = url.into_client_request().expect("request");
    request
        .headers_mut()
        .insert("Host", host.parse().expect("host header"));
    let (mut ws, _) = tokio_tungstenite::connect_async(request)
        .await
        .expect("connect through proxy");

    ws.send(Message::Text("hello".into())).await.expect("send");
    let reply = ws.next().await.expect("reply").expect("message");
    assert_eq!(reply.into_text().unwrap(), "hello");

    ws.close(None).await.unwrap();

    proxy.shutdown().await;
    backend.shutdown().await;
}

#[tokio::test]
async fn websocket_proxy_for_cmux_route() {
    let backend = TestWsBackend::spawn_echo().await;
    let proxy = TestProxy::spawn().await;

    let host = format!("cmux-demo-feature-{}.cmux.sh", backend.port());

    let url = format!("ws://{}{}", proxy.addr, "/ws");
    let mut request = url.into_client_request().expect("request");
    request
        .headers_mut()
        .insert("Host", host.parse().expect("host header"));
    let (mut ws, _) = tokio_tungstenite::connect_async(request)
        .await
        .expect("connect through proxy");

    ws.send(Message::Text("cmux".into())).await.expect("send");
    let reply = ws.next().await.expect("reply").expect("message");
    assert_eq!(reply.into_text().unwrap(), "cmux");
    ws.close(None).await.unwrap();

    proxy.shutdown().await;
    backend.shutdown().await;
}

#[tokio::test]
async fn websocket_subprotocol_matches_backend_choice() {
    let backend = TestWsBackend::spawn_with_handshake(Some("vite-hmr"), None).await;
    let proxy = TestProxy::spawn().await;
    let host = format!("cmux-demo-feature-{}.cmux.sh", backend.port());

    let url = format!("ws://{}{}", proxy.addr, "/ws");
    let mut request = url.into_client_request().expect("request");
    request
        .headers_mut()
        .insert("Host", host.parse().expect("host header"));
    request.headers_mut().insert(
        "Sec-WebSocket-Protocol",
        HeaderValue::from_str("foo, vite-hmr").unwrap(),
    );

    let (mut ws, response) = tokio_tungstenite::connect_async(request)
        .await
        .expect("connect through proxy");
    let protocol = response
        .headers()
        .get("sec-websocket-protocol")
        .and_then(|value| value.to_str().ok());
    assert_eq!(protocol, Some("vite-hmr"));

    ws.send(Message::Text("subprotocol".into()))
        .await
        .expect("send");
    let reply = ws.next().await.expect("reply").expect("message");
    assert_eq!(reply.into_text().unwrap(), "subprotocol");
    ws.close(None).await.unwrap();

    proxy.shutdown().await;
    backend.shutdown().await;
}

#[tokio::test]
async fn websocket_extensions_are_forwarded() {
    let backend = TestWsBackend::spawn_with_handshake(None, Some("permessage-deflate")).await;
    let proxy = TestProxy::spawn().await;
    let host = format!("cmux-demo-feature-{}.cmux.sh", backend.port());

    let url = format!("ws://{}{}", proxy.addr, "/ws");
    let mut request = url.into_client_request().expect("request");
    request
        .headers_mut()
        .insert("Host", host.parse().expect("host header"));
    request.headers_mut().insert(
        "Sec-WebSocket-Extensions",
        HeaderValue::from_static("permessage-deflate"),
    );

    let (mut ws, response) = tokio_tungstenite::connect_async(request)
        .await
        .expect("connect through proxy");
    let extensions = response
        .headers()
        .get("sec-websocket-extensions")
        .and_then(|value| value.to_str().ok());
    assert_eq!(extensions, Some("permessage-deflate"));

    ws.send(Message::Text("extensions".into()))
        .await
        .expect("send");
    let reply = ws.next().await.expect("reply").expect("message");
    assert_eq!(reply.into_text().unwrap(), "extensions");
    ws.close(None).await.unwrap();

    proxy.shutdown().await;
    backend.shutdown().await;
}
