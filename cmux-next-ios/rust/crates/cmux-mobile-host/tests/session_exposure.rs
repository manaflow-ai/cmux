//! Service-level regressions for per-chat iPhone Remote Control exposure.
//!
//! These tests keep the real signaling, link and `services::acpmux` splice in
//! the loop. The ACP endpoint is a small WebSocket fake so the tests can make
//! an approval request arrive from the backend, then observe exactly what the
//! phone answer sends back (or that it is refused after exposure is revoked).

use std::sync::Arc;
use std::time::Duration;

use bytes::Bytes;
use cmux_mobile_host::config::{AcpmuxTarget, ServiceConfig};
use cmux_mobile_host::control::SessionExposure;
use cmux_mobile_host::host::{AnswerContext, IceSource, serve_signaling};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use cmux_mobile_link::{Channel, ChannelEvent, DialOptions, LinkConfig, SignalingClient, TransportKind};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::sync::{mpsc, watch};
use tokio::time::timeout;
use tokio_tungstenite::tungstenite::Message;

const SESSION: &str = "00000000-0000-7000-8000-000000000001";
const OTHER_SESSION: &str = "00000000-0000-7000-8000-000000000002";
const ALIAS: &str = "visible-chat";

struct Fixture {
    _server: FakeSignaling,
    phone: SignalingClient,
    mac_id: String,
    exposure: watch::Sender<SessionExposure>,
    backend: mpsc::UnboundedReceiver<Value>,
    _dirs: Vec<tempfile::TempDir>,
}

fn open_options() -> DialOptions {
    DialOptions { include_loopback: true, timeout: Duration::from_secs(20), ..DialOptions::default() }
}

fn state(blocked: &[&str]) -> SessionExposure {
    SessionExposure {
        available: true,
        configured: true,
        allowed: Default::default(),
        blocked: blocked.iter().map(|session| (*session).to_owned()).collect(),
    }
}

/// An ACP fake that resolves aliases on `_acpmux/info`, records client traffic,
/// and sends a pending approval after each forwarded prompt.
#[allow(clippy::result_large_err)] // tungstenite requires an unboxed HTTP response in its handshake callback
async fn fake_acpmux() -> (String, mpsc::UnboundedReceiver<Value>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("ws://{}/", listener.local_addr().unwrap());
    let (tx, rx) = mpsc::unbounded_channel();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            let tx = tx.clone();
            tokio::spawn(async move {
                let check = |request: &tokio_tungstenite::tungstenite::handshake::server::Request,
                             response: tokio_tungstenite::tungstenite::handshake::server::Response| {
                    let ok = request.headers().get("authorization").is_some_and(|value| value == "Bearer acp-token");
                    if ok {
                        Ok(response)
                    } else {
                        Err(tokio_tungstenite::tungstenite::handshake::server::ErrorResponse::new(None))
                    }
                };
                let Ok(socket) = tokio_tungstenite::accept_hdr_async(stream, check).await else { return };
                let (mut sink, mut source) = socket.split();
                while let Some(Ok(Message::Text(text))) = source.next().await {
                    let Ok(request) = serde_json::from_str::<Value>(&text) else { continue };
                    if request["method"] == "_acpmux/info" {
                        let answer = json!({
                            "jsonrpc": "2.0",
                            "id": request["id"],
                            "result": {"sessionId": SESSION},
                        });
                        let _ = sink.send(Message::Text(answer.to_string().into())).await;
                        continue;
                    }
                    if request["method"] == "_acpmux/handoff_get" {
                        let answer = json!({"jsonrpc":"2.0","id":request["id"],"result":{
                            "source":{"sessionId":OTHER_SESSION},"target":{"sessionId":SESSION}
                        }});
                        let _ = sink.send(Message::Text(answer.to_string().into())).await;
                        continue;
                    }
                    let _ = tx.send(request.clone());
                    if request["method"] == "session/prompt" {
                        let approval = json!({
                            "jsonrpc": "2.0",
                            "id": "approval-1",
                            "method": "session/request_permission",
                            "params": {"sessionId": SESSION, "options": []},
                        });
                        let _ = sink.send(Message::Text(approval.to_string().into())).await;
                    }
                }
            });
        }
    });
    (url, rx)
}

async fn fixture(initial: SessionExposure) -> Fixture {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let sockets = tempfile::tempdir().unwrap();
    let uploads = tempfile::tempdir().unwrap();
    let (acpmux_url, backend) = fake_acpmux().await;
    let services = ServiceConfig {
        chief_socket: None,
        tui_socket_dir: sockets.path().to_path_buf(),
        default_session: "main".into(),
        default_socket: None,
        file_roots: Vec::new(),
        acpmux: AcpmuxTarget::Fixed { url: acpmux_url, token: Some("acp-token".into()) },
        pairing: None,
        agent_tab_host: None,
        uploads_dir: uploads.path().to_path_buf(),
        browser: cmux_mobile_host::browser::BrowserConfig::default(),
        surface: cmux_mobile_host::surface::SurfaceConfig::default(),
    };
    let (exposure, session_exposure) = watch::channel(initial);
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    tokio::spawn(serve_signaling(
        mac,
        AnswerContext {
            owner_user_id: "alice".into(),
            services: Arc::new(services),
            ice: IceSource::Fixed(Vec::new()),
            include_loopback: true,
            exclude_cgnat: false,
            mailbox: None,
            session_exposure: Some(session_exposure),
        },
    ));
    let phone_id = uuid::Uuid::new_v4().to_string();
    let phone = SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
    Fixture { _server: server, phone, mac_id, exposure, backend, _dirs: vec![sockets, uploads] }
}

async fn connect(fixture: &Fixture) -> cmux_mobile_link::Connected {
    cmux_mobile_link::dial::connect(
        &fixture.phone,
        &fixture.mac_id,
        TransportKind::WireGuard,
        &open_options(),
        LinkConfig::default(),
    )
    .await
    .expect("dial")
}

async fn recv_json(channel: &mut Channel) -> Value {
    match timeout(Duration::from_secs(10), channel.recv()).await.expect("in time") {
        Some(ChannelEvent::Data(data)) => serde_json::from_slice(&data).expect("json frame"),
        other => panic!("unexpected channel event: {other:?}"),
    }
}

async fn recv_close(channel: &mut Channel) -> (String, String) {
    loop {
        match timeout(Duration::from_secs(10), channel.recv()).await.expect("in time") {
            Some(ChannelEvent::Data(_)) => continue,
            Some(ChannelEvent::Closed(info)) => return (info.code, info.reason),
            None => return ("none".into(), String::new()),
        }
    }
}

fn prompt(session: &str) -> Bytes {
    Bytes::from(
        json!({"jsonrpc":"2.0","id":"prompt-1","method":"session/prompt","params":{"sessionId":session,"prompt":"hello"}})
            .to_string(),
    )
}

fn approval_answer() -> Bytes {
    Bytes::from(json!({"jsonrpc":"2.0","id":"approval-1","result":{"approved":true}}).to_string())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn visible_chat_approval_answer_reaches_backend() {
    let mut fixture = fixture(state(&[])).await;
    let connected = connect(&fixture).await;
    let mut channel = connected.link.open("acpmux", json!({})).await.unwrap();
    channel.send(prompt(SESSION)).await.unwrap();
    assert_eq!(fixture.backend.recv().await.unwrap()["method"], "session/prompt");
    let request = recv_json(&mut channel).await;
    assert_eq!(request["id"], "approval-1");
    assert_eq!(request["params"]["sessionId"], SESSION);
    channel.send(approval_answer()).await.unwrap();
    let answer = fixture.backend.recv().await.unwrap();
    assert_eq!(answer["id"], "approval-1");
    assert_eq!(answer["result"]["approved"], true);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn named_alias_is_forwarded_as_the_resolved_canonical_session() {
    let mut fixture = fixture(state(&[])).await;
    let connected = connect(&fixture).await;
    let channel = connected.link.open("acpmux", json!({})).await.unwrap();
    channel.send(prompt(ALIAS)).await.unwrap();
    let forwarded = fixture.backend.recv().await.unwrap();
    assert_eq!(forwarded["method"], "session/prompt");
    assert_eq!(forwarded["params"]["sessionId"], SESSION);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn pending_approval_is_refused_after_exposure_is_disabled() {
    let mut fixture = fixture(state(&[])).await;
    let connected = connect(&fixture).await;
    let mut channel = connected.link.open("acpmux", json!({})).await.unwrap();
    channel.send(prompt(SESSION)).await.unwrap();
    assert_eq!(fixture.backend.recv().await.unwrap()["method"], "session/prompt");
    assert_eq!(recv_json(&mut channel).await["id"], "approval-1");
    fixture.exposure.send_replace(state(&[SESSION]));
    // Revocation may win the select at the same instant as this answer. In
    // either order the pending approval must be refused or the link closed;
    // it must never reach the backend.
    let _ = channel.send(approval_answer()).await;
    let result = timeout(Duration::from_secs(10), channel.recv()).await.expect("in time");
    match result {
        Some(ChannelEvent::Data(data)) => {
            let refusal: Value = serde_json::from_slice(&data).unwrap();
            assert_eq!(refusal["error"]["data"]["reason"], "remote_control.session_not_exposed");
        }
        Some(ChannelEvent::Closed(_)) => {}
        other => panic!("unexpected channel event: {other:?}"),
    }
    assert!(timeout(Duration::from_millis(200), fixture.backend.recv()).await.is_err());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn live_acpmux_connection_is_revoked_when_exposure_turns_off() {
    let mut fixture = fixture(state(&[])).await;
    let connected = connect(&fixture).await;
    let mut channel = connected.link.open("acpmux", json!({})).await.unwrap();
    channel.send(prompt(SESSION)).await.unwrap();
    assert_eq!(fixture.backend.recv().await.unwrap()["method"], "session/prompt");
    fixture.exposure.send_replace(state(&[SESSION]));
    let (code, _) = recv_close(&mut channel).await;
    assert_eq!(code, "eof");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn named_alias_is_resolved_to_a_blocked_canonical_session() {
    let mut fixture = fixture(state(&[SESSION])).await;
    let connected = connect(&fixture).await;
    let mut channel = connected.link.open("acpmux", json!({})).await.unwrap();
    channel.send(prompt(ALIAS)).await.unwrap();
    let refusal = recv_json(&mut channel).await;
    assert_eq!(refusal["error"]["data"]["reason"], "remote_control.session_not_exposed");
    assert!(timeout(Duration::from_millis(200), fixture.backend.recv()).await.is_err());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn ordinary_client_reply_id_cannot_authorize_an_approval() {
    let mut fixture = fixture(state(&[])).await;
    let connected = connect(&fixture).await;
    let mut channel = connected.link.open("acpmux", json!({})).await.unwrap();
    channel.send(prompt(OTHER_SESSION)).await.unwrap();
    assert_eq!(fixture.backend.recv().await.unwrap()["method"], "session/prompt");
    assert_eq!(recv_json(&mut channel).await["id"], "approval-1");
    channel
        .send(Bytes::from(json!({"jsonrpc":"2.0","id":"ordinary-1","result":{"ok":true}}).to_string()))
        .await
        .unwrap();
    let refusal = recv_json(&mut channel).await;
    assert_eq!(refusal["error"]["data"]["reason"], "remote_control.invalid_request");
    assert!(timeout(Duration::from_millis(200), fixture.backend.recv()).await.is_err());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn global_catalog_queries_still_reach_backend() {
    let mut fixture = fixture(state(&[])).await;
    let connected = connect(&fixture).await;
    let channel = connected.link.open("acpmux", json!({})).await.unwrap();
    for method in ["_acpmux/harnesses", "_acpmux/models"] {
        channel
            .send(Bytes::from(json!({"jsonrpc":"2.0","id":method,"method":method,"params":{}}).to_string()))
            .await
            .unwrap();
        let forwarded = timeout(Duration::from_secs(10), fixture.backend.recv()).await.unwrap().unwrap();
        assert_eq!(forwarded["method"], method);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn handoff_ids_resolve_both_sessions_before_forwarding() {
    let mut fixture = fixture(state(&[])).await;
    let connected = connect(&fixture).await;
    let channel = connected.link.open("acpmux", json!({})).await.unwrap();
    channel
        .send(Bytes::from(
            json!({"jsonrpc":"2.0","id":"start","method":"_acpmux/handoff_start",
        "params":{"handoffId":"handoff-1","revision":1}})
            .to_string(),
        ))
        .await
        .unwrap();
    let forwarded = timeout(Duration::from_secs(10), fixture.backend.recv()).await.unwrap().unwrap();
    assert_eq!(forwarded["method"], "_acpmux/handoff_start");
    assert_eq!(forwarded["params"]["handoffId"], "handoff-1");
    assert_eq!(forwarded["params"]["sessionId"], SESSION);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn handoff_cannot_use_a_blocked_source_capsule() {
    let mut fixture = fixture(state(&[OTHER_SESSION])).await;
    let connected = connect(&fixture).await;
    let mut channel = connected.link.open("acpmux", json!({})).await.unwrap();
    channel
        .send(Bytes::from(
            json!({"jsonrpc":"2.0","id":"start","method":"_acpmux/handoff_start",
        "params":{"handoffId":"handoff-1","revision":1}})
            .to_string(),
        ))
        .await
        .unwrap();
    let _ = recv_close(&mut channel).await;
    assert!(timeout(Duration::from_millis(200), fixture.backend.recv()).await.is_err());
}
