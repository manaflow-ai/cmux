//! Same harness, with and without the wake event: the first signaling socket
//! silently blackholes, the replacement reaches the fake backend, then a phone
//! must complete a real WireGuard dial and echo. No sleep or real account needed.
use super::*;
use crate::auth::TokenSource;
use crate::config::AcpmuxTarget;
use bytes::Bytes;
use cmux_mobile_link::ChannelEvent;
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use futures_util::{SinkExt, StreamExt};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, watch};
use tokio_tungstenite::tungstenite::{
    Message, client::IntoClientRequest, handshake::derive_accept_key, protocol::Role,
};

// Own every test task, including on an assertion failure.
struct Tasks(Vec<tokio::task::JoinHandle<()>>);
impl Drop for Tasks {
    fn drop(&mut self) {
        for task in &self.0 {
            task.abort();
        }
    }
}

async fn recovery_sample(wake: bool) -> Duration {
    let backend = FakeSignaling::start(FakeOptions::default()).await;
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base_url = format!("http://{}", listener.local_addr().unwrap());
    let backend_url = backend.base_url.clone();
    let (connected, mut connections) = mpsc::unbounded_channel();
    let mut tasks = Tasks(Vec::new());
    tasks.0.push(tokio::spawn(async move {
        let mut children = tokio::task::JoinSet::new();
        let mut first_socket = true;
        while let Ok((mut stream, _)) = listener.accept().await {
            // Read just the HTTP headers. All requests in this rig are bounded.
            let mut head = Vec::new();
            while !head.ends_with(b"\r\n\r\n") {
                head.push(stream.read_u8().await.unwrap());
                assert!(head.len() < 16384);
            }
            let head_text = String::from_utf8(head.clone()).unwrap();
            if !head_text.to_ascii_lowercase().contains("upgrade: websocket") {
                let backend_url = backend_url.clone();
                children.spawn(async move {
                    let mut upstream = TcpStream::connect(backend_url.trim_start_matches("http://")).await.unwrap();
                    upstream.write_all(&head).await.unwrap();
                    let _ = tokio::io::copy_bidirectional(&mut stream, &mut upstream).await;
                });
                continue;
            }
            let dead = first_socket;
            first_socket = false;
            let connected = connected.clone();
            let backend_url = backend_url.clone();
            children.spawn(async move {
                let key = head_text.lines().find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("sec-websocket-key").then(|| value.trim())
                }).unwrap();
                let reply = format!("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {}\r\n\r\n", derive_accept_key(key.as_bytes()));
                stream.write_all(reply.as_bytes()).await.unwrap();
                let mut socket = tokio_tungstenite::WebSocketStream::from_raw_socket(stream, Role::Server, None).await;
                if dead {
                    socket.send(Message::Text(r#"{"type":"hello","you":"mac","macs":[]}"#.into())).await.unwrap();
                    connected.send(()).unwrap();
                    // Hold TCP open but never read or answer a ping, like a stale NAT mapping.
                    std::future::pending::<()>().await;
                    return;
                }
                let url = cmux_mobile_link::signaling::signal_url(&backend_url, "team", "mac").unwrap();
                let mut request = url.into_client_request().unwrap();
                request.headers_mut().insert("authorization", "Bearer user:owner".parse().unwrap());
                let (mut upstream, _) = tokio_tungstenite::connect_async(request).await.unwrap();
                connected.send(()).unwrap();
                loop {
                    tokio::select! {
                        Some(Ok(message)) = socket.next() => { if upstream.send(message).await.is_err() { break; } },
                        Some(Ok(message)) = upstream.next() => { if socket.send(message).await.is_err() { break; } },
                        else => break,
                    }
                }
            });
        }
    }));
    let dir = tempfile::tempdir().unwrap();
    let config = HostConfig {
        base_url,
        team_id: "team".into(),
        device_id: "mac".into(),
        device_name: "Test Mac".into(),
        host_uuid: None,
        machine_id_override: None,
        app_support: dir.path().into(),
        state_dir: dir.path().into(),
        tokens: TokenSource::Access("user:owner".into()),
        owner_user_id: Some("owner".into()),
        include_loopback: true,
        exclude_cgnat: true,
        services: ServiceConfig {
            tui_socket_dir: dir.path().into(),
            default_session: "main".into(),
            default_socket: None,
            file_roots: vec![],
            acpmux: AcpmuxTarget::Home(dir.path().into()),
            pairing: None,
            agent_tab_host: None,
            uploads_dir: dir.path().into(),
            chief_socket: None,
            browser: crate::browser::BrowserConfig::new(None, 1),
            surface: crate::surface::SurfaceConfig::new(None, 1),
        },
    };
    let (changes, receiver) = watch::channel(0);
    tasks.0.push(tokio::spawn(async move {
        run_with_changes(config, receiver).await.unwrap();
    }));
    let phone = SignalingClient::connect(&backend.base_url, "user:owner", "team", "phone").await.unwrap();
    connections.recv().await.unwrap();
    let started = std::time::Instant::now();
    if wake {
        changes.send_modify(|generation| *generation += 1);
    }
    // The backend records the replacement before this event; the phone can now dial it.
    connections.recv().await.unwrap();
    let connected = dial::connect(
        &phone,
        "mac",
        TransportKind::WireGuard,
        &DialOptions { include_loopback: true, timeout: Duration::from_secs(10), ..DialOptions::default() },
        LinkConfig::default(),
    )
    .await
    .unwrap();
    let mut echo = connected.link.open("echo", serde_json::json!({})).await.unwrap();
    echo.send(Bytes::from_static(b"awake")).await.unwrap();
    assert_eq!(echo.recv().await, Some(ChannelEvent::Data(Bytes::from_static(b"awake"))));
    let elapsed = started.elapsed();
    connected.link.close("test complete");
    phone.close();
    elapsed
}

#[tokio::test]
async fn wake_recovers_signaling_and_phone_dial() {
    let elapsed = tokio::time::timeout(Duration::from_secs(15), recovery_sample(true)).await.unwrap();
    println!("wake_to_phone_echo_after_ms={:.3}", elapsed.as_secs_f64() * 1000.0);
}

/// Fleet benchmark: one baseline and one fixed sample through the exact same rig.
#[tokio::test]
#[ignore = "45 second baseline; run explicitly for the PR Performance table"]
async fn wake_recovery_performance() {
    let before = tokio::time::timeout(Duration::from_secs(65), recovery_sample(false)).await.unwrap();
    let after = tokio::time::timeout(Duration::from_secs(15), recovery_sample(true)).await.unwrap();
    assert!(before >= cmux_mobile_link::signaling::KEEPALIVE_TIMEOUT);
    assert!(after < before / 2);
    println!(
        "wake_to_phone_echo before_ms={:.3} after_ms={:.3} delta_ms={:.3}",
        before.as_secs_f64() * 1000.0,
        after.as_secs_f64() * 1000.0,
        after.as_secs_f64() * 1000.0 - before.as_secs_f64() * 1000.0
    );
}
