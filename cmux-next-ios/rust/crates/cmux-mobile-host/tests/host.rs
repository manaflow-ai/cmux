#![allow(clippy::result_large_err)] // tungstenite's handshake callback signature
//! cmux-mobile-host end to end over a local fake signaling server: admission, both
//! transports, and every service.

use std::sync::Arc;
use std::time::Duration;

use bytes::Bytes;
use cmux_mobile_host::config::{AcpmuxTarget, ServiceConfig};
use cmux_mobile_host::control::Event;
use cmux_mobile_host::host::{AnswerContext, IceSource, serve_signaling};
use cmux_mobile_host::pairing::{
    DeniedDevice, DeviceTrust, MacIdentity, Pairing, TrustedDevice, TunnelKeys, challenge_message,
    challenge_message_v2, mac_proof_message, mac_proof_message_v2,
};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use cmux_mobile_link::{
    Channel, ChannelEvent, Connected, DialError, DialOptions, LinkConfig, SignalingClient, TransportKind,
};
use futures_util::{SinkExt, StreamExt};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

#[path = "support/fake_rb_host.rs"]
mod fake_rb_host;
#[path = "support/fake_surface_source.rs"]
mod fake_surface_source;

struct Fixture {
    _server: FakeSignaling,
    _dirs: Vec<tempfile::TempDir>,
    phone: SignalingClient,
    phone_id: String,
    /// Pairing on: the app's `devices` line and the events hostd emitted.
    trust: Option<tokio::sync::watch::Sender<Option<DeviceTrust>>>,
    events: Option<tokio::sync::Mutex<tokio::sync::mpsc::UnboundedReceiver<Event>>>,
    mac_id: String,
    /// Pairing on: this Mac's identity key (`mac_identity`).
    mac_key: Option<String>,
    /// Pairing on: what machines did here (`activity.rs`).
    activity: Option<Arc<cmux_mobile_host::activity::Activity>>,
    root: std::path::PathBuf,
    outside: std::path::PathBuf,
    uploads: std::path::PathBuf,
    browser_launches: Arc<std::sync::atomic::AtomicUsize>,
    /// What hostd told the fake simulator surface sources (touches, text, keys).
    surface_inputs: fake_surface_source::Inputs,
    /// Every request line the fake daemon read.
    daemon_lines: Arc<std::sync::Mutex<Vec<serde_json::Value>>>,
}

fn options() -> DialOptions {
    DialOptions { include_loopback: true, timeout: Duration::from_secs(20), ..DialOptions::default() }
}

/// A stand-in cmux-tui session socket: answers each request line with
/// `{"id":..,"ok":true,"data":{"cmd":..}}`.
/// Every request line it read goes to the returned list, in order.
/// `browser_url`: the page the Mac's one browser tab shows (`list-workspaces`).
fn fake_daemon(dir: &std::path::Path, browser_url: String) -> Arc<std::sync::Mutex<Vec<serde_json::Value>>> {
    let listener = tokio::net::UnixListener::bind(dir.join("main.sock")).unwrap();
    let seen = Arc::new(std::sync::Mutex::new(Vec::new()));
    let recorded = Arc::clone(&seen);
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            let recorded = Arc::clone(&recorded);
            let browser_url = browser_url.clone();
            tokio::spawn(async move {
                let (read, mut write) = stream.into_split();
                let mut lines = BufReader::new(read).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    let request: serde_json::Value = serde_json::from_str(&line).unwrap();
                    recorded.lock().unwrap().push(request.clone());
                    // A scripted terminal: an attach gets its vt-state (40x8, a prompt), then
                    // `scripted` output lines, enough to scroll, then the socket stays open.
                    if request["cmd"] == "attach-surface"
                        && let Some(count) = request["scripted"].as_u64()
                    {
                        let answer = serde_json::json!({"id": request["id"], "ok": true, "data": {}});
                        write.write_all(format!("{answer}\n").as_bytes()).await.unwrap();
                        let surface = request["surface"].clone();
                        let state = serde_json::json!({"event": "vt-state", "surface": surface, "cols": 40,
                            "rows": 8, "data": b64(SCRIPTED_PROMPT)});
                        write.write_all(format!("{state}\n").as_bytes()).await.unwrap();
                        for i in 0..count {
                            let data = b64(scripted_line(i).as_bytes());
                            let event =
                                serde_json::json!({"event": "output", "surface": surface, "data": data});
                            write.write_all(format!("{event}\n").as_bytes()).await.unwrap();
                            tokio::time::sleep(Duration::from_millis(5)).await;
                        }
                        continue;
                    }
                    // A busy terminal: an attach streams output until the socket closes.
                    if request["cmd"] == "attach-surface" && request["busy"] == true {
                        let answer = serde_json::json!({"id": request["id"], "ok": true, "data": {}});
                        write.write_all(format!("{answer}\n").as_bytes()).await.unwrap();
                        let (mut out, mut lines_left) = (write, lines);
                        let surface = request["surface"].clone();
                        tokio::spawn(async move {
                            loop {
                                let event = serde_json::json!({"event": "output", "surface": surface, "data": "eA=="});
                                if out.write_all(format!("{event}\n").as_bytes()).await.is_err() {
                                    return;
                                }
                                tokio::task::yield_now().await;
                            }
                        });
                        while let Ok(Some(line)) = lines_left.next_line().await {
                            recorded.lock().unwrap().push(serde_json::from_str(&line).unwrap());
                        }
                        return;
                    }
                    let mut data =
                        serde_json::json!({"cmd": request["cmd"], "host": request["agent_session"]["host"]});
                    if request["cmd"] == "list-workspaces" {
                        data["workspaces"] = serde_json::json!([{"screens": [{"panes": [{"tabs": [
                            {"surface": 9, "kind": "browser", "url": browser_url},
                            {"surface": 12, "kind": "conversation", "conversation": {"page": "phone", "route": "sim:A"}},
                            {"surface": 13, "kind": "conversation", "conversation": {"page": "settings"}}]}]}]}]);
                    }
                    let answer = serde_json::json!({"id": request["id"], "ok": true, "data": data});
                    write.write_all(format!("{answer}\n").as_bytes()).await.unwrap();
                }
            });
        }
    });
    seen
}

/// A stand-in Chief owner: lists the Chief, an owner-and-agents chat and a
/// chat with a paired install; `subscribe` replies, then sends an event for
/// each and a terminal event.
fn fake_chief(dir: &std::path::Path) {
    let listener = tokio::net::UnixListener::bind(dir.join("chief.sock")).unwrap();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            tokio::spawn(async move {
                let (read, mut write) = stream.into_split();
                let mut lines = BufReader::new(read).lines();
                let human = serde_json::json!({"id": "user_local", "kind": "human", "display_name": "A"});
                let chief = serde_json::json!({"id": "agent_mux", "kind": "agent", "display_name": "Chief"});
                let remote = serde_json::json!({"id": "remote_ab", "kind": "human", "display_name": "P"});
                while let Ok(Some(line)) = lines.next_line().await {
                    let request: serde_json::Value = serde_json::from_str(&line).unwrap();
                    let mut out = Vec::new();
                    match request["cmd"].as_str() {
                        Some("conversation-list") => out.push(serde_json::json!({"id": request["id"], "ok": true, "data": {"conversations": [
                            {"id": "conv_CHIEF", "participants": [human, chief]},
                            {"id": "conv_REMOTE", "participants": [human, remote]},
                        ]}})),
                        Some("subscribe") => {
                            out.push(serde_json::json!({"id": request["id"], "ok": true, "data": {}}));
                            for conversation in ["conv_REMOTE", "conv_CHIEF"] {
                                out.push(serde_json::json!({"event": "conversation-typing", "conversation": conversation,
                                    "participant": "agent_mux", "on": true}));
                            }
                            out.push(serde_json::json!({"event": "terminal-registry-changed"}));
                        }
                        _ => out.push(serde_json::json!({"id": request["id"], "ok": true, "data": {"cmd": request["cmd"]}})),
                    }
                    for answer in out {
                        write.write_all(format!("{answer}\n").as_bytes()).await.unwrap();
                    }
                }
            });
        }
    });
}

/// A stand-in acpmux listener: requires the bearer token, echoes text.
async fn fake_acpmux() -> String {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("ws://{}/", listener.local_addr().unwrap());
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            tokio::spawn(async move {
                let check = |request: &tokio_tungstenite::tungstenite::handshake::server::Request,
                             response: tokio_tungstenite::tungstenite::handshake::server::Response| {
                    let ok = request.headers().get("authorization").is_some_and(|v| v == "Bearer acp-token");
                    if ok {
                        Ok(response)
                    } else {
                        Err(tokio_tungstenite::tungstenite::handshake::server::ErrorResponse::new(None))
                    }
                };
                let Ok(socket) = tokio_tungstenite::accept_hdr_async(stream, check).await else { return };
                let (mut sink, mut source) = socket.split();
                while let Some(Ok(message)) = source.next().await {
                    if let tokio_tungstenite::tungstenite::Message::Text(text) = message {
                        let reply = format!("{{\"echo\":{text}}}");
                        sink.send(tokio_tungstenite::tungstenite::Message::Text(reply.into())).await.unwrap();
                    }
                }
            });
        }
    });
    url
}

async fn fixture(fake: FakeOptions) -> Fixture {
    fixture_with(fake, false).await
}

async fn fixture_with(fake: FakeOptions, pairing: bool) -> Fixture {
    fixture_trust(fake, pairing, true).await
}

/// `loaded`: whether the app already sent its (empty) `devices` list.
async fn fixture_trust(fake: FakeOptions, pairing: bool, loaded: bool) -> Fixture {
    fixture_viewport(fake, pairing, loaded, None).await
}

/// `viewport_sync`: the host's viewport sync gate (`ServiceConfig::viewport_sync`).
async fn fixture_viewport(
    fake: FakeOptions,
    pairing: bool,
    loaded: bool,
    viewport_sync: Option<cmux_mobile_host::viewport_sync::SelectorConfig>,
) -> Fixture {
    let server = FakeSignaling::start(fake).await;
    let sockets = tempfile::tempdir().unwrap();
    let root = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    let uploads = tempfile::tempdir().unwrap();
    std::fs::write(root.path().join("notes.md"), "# hello\n").unwrap();
    std::fs::write(outside.path().join("secret"), "nope").unwrap();
    std::fs::write(root.path().join("shared page.html"), "<p>shared</p>").unwrap();
    std::fs::write(outside.path().join("mac page.html"), "<p>the Mac opened this</p>").unwrap();
    let daemon_lines = fake_daemon(sockets.path(), file_url(&outside.path().join("mac page.html")));
    fake_chief(sockets.path());
    let browser_launches = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let surface_inputs = fake_surface_source::Inputs::default();
    let services = ServiceConfig {
        chief_socket: Some(sockets.path().join("chief.sock")),
        tui_socket_dir: sockets.path().to_path_buf(),
        default_session: "main".into(),
        default_socket: None,
        file_roots: vec![root.path().to_path_buf()],
        acpmux: AcpmuxTarget::Fixed { url: fake_acpmux().await, token: Some("acp-token".into()) },
        pairing: None,
        agent_tab_host: Some("install:mac-test".into()),
        uploads_dir: uploads.path().to_path_buf(),
        browser: cmux_mobile_host::browser::BrowserConfig::new(
            Some(fake_rb_host::launcher(Arc::clone(&browser_launches))),
            4,
        ),
        surface: cmux_mobile_host::surface::SurfaceConfig::new(
            Some(fake_surface_source::launcher(Arc::clone(&surface_inputs))),
            4,
        ),
        viewport_sync,
    };
    let mut services = services;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let (mut trust, mut events, mut mac_key, mut activity) = (None, None, None, None);
    if pairing {
        let (trust_tx, trust_rx) = tokio::sync::watch::channel(loaded.then(DeviceTrust::default));
        let (events_tx, events_rx) = tokio::sync::mpsc::unbounded_channel();
        let identity = MacIdentity::generate().unwrap();
        mac_key = Some(identity.public_key().to_owned());
        services.pairing = Some(
            Pairing::new(
                mac_id.clone(),
                trust_rx,
                Arc::new(move |event| {
                    let _ = events_tx.send(event);
                }),
            )
            .with_identity(tokio::sync::watch::channel(Some(identity)).1)
            .with_activity({
                let log = Arc::new(cmux_mobile_host::activity::Activity::memory());
                activity = Some(Arc::clone(&log));
                log
            }),
        );
        trust = Some(trust_tx);
        events = Some(tokio::sync::Mutex::new(events_rx));
    }
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
            session_exposure: None,
        },
    ));
    let phone_id = uuid::Uuid::new_v4().to_string();
    let phone = SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
    Fixture {
        _server: server,
        phone,
        phone_id,
        trust,
        events,
        mac_id,
        mac_key,
        activity,
        root: root.path().to_path_buf(),
        outside: outside.path().to_path_buf(),
        uploads: uploads.path().to_path_buf(),
        browser_launches,
        surface_inputs,
        daemon_lines,
        _dirs: vec![sockets, root, outside, uploads],
    }
}

async fn connect(fixture: &Fixture, kind: TransportKind) -> Result<Connected, DialError> {
    connect_with(fixture, kind, &options()).await
}

async fn connect_with(
    fixture: &Fixture,
    kind: TransportKind,
    options: &DialOptions,
) -> Result<Connected, DialError> {
    cmux_mobile_link::dial::connect(&fixture.phone, &fixture.mac_id, kind, options, LinkConfig::default())
        .await
}

/// Everything the channel delivers until it closes, and the close code.
/// A `file:` URL as a browser spells it (spaces escaped).
fn file_url(path: &std::path::Path) -> String {
    format!("file://{}", path.display()).replace(' ', "%20")
}

/// The reason a channel closed with.
async fn close_reason(channel: &mut Channel) -> (String, String) {
    loop {
        match tokio::time::timeout(Duration::from_secs(10), channel.recv()).await.expect("in time") {
            Some(ChannelEvent::Data(_)) => {}
            Some(ChannelEvent::Closed(info)) => return (info.code, info.reason),
            None => return ("none".into(), String::new()),
        }
    }
}

/// One rb message from the phone, as a stream frame.
fn phone_rb(body: serde_json::Value) -> Bytes {
    let control = serde_json::json!({"t": "service", "service": "rb/1", "body": body});
    let mut out = Vec::new();
    cmux_rd_proto::encode_stream_frame(
        cmux_rd_proto::STREAM_CONTROL,
        &serde_json::to_vec(&control).unwrap(),
        &mut out,
    )
    .unwrap();
    Bytes::from(out)
}

async fn drain(channel: &mut Channel) -> (Vec<u8>, String) {
    drain_within(channel, Duration::from_secs(10)).await
}

/// `drain`, with a longer wait per message for replies that follow heavy disk work.
async fn drain_within(channel: &mut Channel, wait: Duration) -> (Vec<u8>, String) {
    let mut bytes = Vec::new();
    loop {
        match tokio::time::timeout(wait, channel.recv()).await.expect("in time") {
            Some(ChannelEvent::Data(data)) => bytes.extend_from_slice(&data),
            Some(ChannelEvent::Closed(info)) => return (bytes, info.code),
            None => return (bytes, "none".into()),
        }
    }
}

async fn next_line(channel: &mut Channel, buffer: &mut Vec<u8>) -> serde_json::Value {
    loop {
        if let Some(newline) = buffer.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = buffer.drain(..=newline).collect();
            return serde_json::from_slice(&line).unwrap();
        }
        match tokio::time::timeout(Duration::from_secs(10), channel.recv()).await.expect("in time") {
            Some(ChannelEvent::Data(data)) => buffer.extend_from_slice(&data),
            other => panic!("unexpected {other:?}"),
        }
    }
}

/// Reads rd stream-carrier frames off a channel.
#[derive(Default)]
struct RdReader(cmux_rd_proto::StreamDeframer);

impl RdReader {
    async fn next(&mut self, channel: &mut Channel) -> (u8, Vec<u8>) {
        loop {
            if let Some(frame) = self.0.next_frame().unwrap() {
                return frame;
            }
            match tokio::time::timeout(Duration::from_secs(10), channel.recv()).await.expect("in time") {
                Some(ChannelEvent::Data(data)) => self.0.extend(&data),
                other => panic!("unexpected {other:?}"),
            }
        }
    }

    /// The next control message, skipping datagrams.
    async fn control(&mut self, channel: &mut Channel) -> serde_json::Value {
        loop {
            let (kind, payload) = self.next(channel).await;
            if kind == cmux_rd_proto::STREAM_CONTROL {
                return serde_json::from_slice(&payload).unwrap();
            }
        }
    }

    async fn datagram(&mut self, channel: &mut Channel) -> Vec<u8> {
        loop {
            let (kind, payload) = self.next(channel).await;
            if kind == cmux_rd_proto::STREAM_DATAGRAM {
                return payload;
            }
        }
    }
}

/// `localhost`: a phone's native browser tab reaches a web server on this Mac's
/// loopback, one channel per connection, keep-alive requests and all; a port
/// with nothing listening and a bad port are refused with a reason.
async fn localhost_forward(link: &cmux_mobile_link::Link) {
    // A dev server on the Mac's loopback: answers each request on a kept-alive connection.
    let server = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = server.local_addr().unwrap().port();
    tokio::spawn(async move {
        let (stream, _) = server.accept().await.unwrap();
        let (read, mut write) = stream.into_split();
        let mut lines = BufReader::new(read).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if line.is_empty() {
                let body = "served on the Mac's loopback";
                let reply = format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{body}", body.len());
                write.write_all(reply.as_bytes()).await.unwrap();
            }
        }
    });
    // The port as the iPhone sends it (text), two requests on one connection.
    let mut channel = link.open("localhost", serde_json::json!({"port": port.to_string()})).await.unwrap();
    for _ in 0..2 {
        channel.send(Bytes::from_static(b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")).await.unwrap();
        let mut reply = Vec::new();
        while !reply.ends_with(b"loopback") {
            match channel.recv().await {
                Some(ChannelEvent::Data(bytes)) => reply.extend_from_slice(&bytes),
                other => panic!("the forwarded connection ended early: {other:?}"),
            }
        }
        assert!(reply.starts_with(b"HTTP/1.1 200 OK"), "{}", String::from_utf8_lossy(&reply));
    }
    channel.close("done", "").await;

    // Nothing listening: refused with a sentence the phone can show.
    let unused = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let closed = unused.local_addr().unwrap().port();
    drop(unused);
    let mut channel = link.open("localhost", serde_json::json!({"port": closed})).await.unwrap();
    assert_eq!(
        close_reason(&mut channel).await,
        ("unavailable".to_owned(), format!("Nothing is listening on port {closed} on this Mac."))
    );
    // The phone names a port only, never a host.
    let mut channel =
        link.open("localhost", serde_json::json!({"host": "10.0.0.2", "port": "0"})).await.unwrap();
    assert_eq!(close_reason(&mut channel).await.0, "bad_request");
}

async fn exercise_services(fixture: &Fixture, kind: TransportKind) {
    exercise_services_with(fixture, kind, &options()).await;
}

async fn exercise_services_with(fixture: &Fixture, kind: TransportKind, options: &DialOptions) {
    let connected = connect_with(fixture, kind, options).await.expect("dial");
    let link = &connected.link;

    // echo
    let mut echo = link.open("echo", serde_json::json!({})).await.unwrap();
    echo.send(Bytes::from_static(b"ping")).await.unwrap();
    assert_eq!(echo.recv().await, Some(ChannelEvent::Data(Bytes::from_static(b"ping"))));

    // version: what the Mac runs, so a phone can tell an outdated Mac.
    let mut version = link.open("version", serde_json::json!({})).await.unwrap();
    let (bytes, code) = drain(&mut version).await;
    assert_eq!(code, "eof");
    let value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(value["link"], 2);
    assert!(value["hostd"].is_string());
    // This fixture has a browser host and a simulator surface source: a phone
    // may offer browser tabs and stream phone tabs.
    assert_eq!(
        value["capabilities"],
        serde_json::json!([
            "removal-v1",
            "file-preview-v1",
            "localhost-forward-v1",
            "cloud-directory-v1",
            "cloud-acpmux-v1",
            "needs-you-v1",
            "appearance-v1",
            "pair-requests-v1",
            "phone-frames-v1",
            "tab-snapshots-v1",
            "mailbox-send-v1",
            "browser-stream-v1",
            "browser-video-track-v1",
            "surface-stream-v1",
            "cloud-desktop-v1"
        ])
    );

    localhost_forward(link).await;

    // daemon: allowed lines reach the socket, denied ones are answered locally,
    // and responses stay whole lines in order.
    let mut daemon = link.open("daemon", serde_json::json!({})).await.unwrap();
    daemon
        .send(Bytes::from_static(
            b"{\"id\":1,\"cmd\":\"identify\"}\n{\"id\":2,\"cmd\":\"new-tab\",\"argv\":[\"sh\"]}\n{\"id\":3,\"cmd\":\"run\"}\n{\"id\":4,",
        ))
        .await
        .unwrap();
    daemon.send(Bytes::from_static(b"\"cmd\":\"list-workspaces\"}\n")).await.unwrap();
    let mut buffer = Vec::new();
    let mut answers = Vec::new();
    for _ in 0..4 {
        answers.push(next_line(&mut daemon, &mut buffer).await);
    }
    answers.sort_by_key(|answer| answer["id"].as_i64());
    assert_eq!(answers[0]["data"]["cmd"], "identify");
    assert_eq!(answers[1]["error_code"], "forbidden");
    assert_eq!(answers[2]["error_code"], "forbidden");
    assert_eq!(answers[3]["data"]["cmd"], "list-workspaces");
    let mut bad_session = link.open("daemon", serde_json::json!({"session": "../etc"})).await.unwrap();
    assert_eq!(drain(&mut bad_session).await.1, "bad_request");

    // daemon never reaches the Chief owner's session.
    for session in ["cmux-chief-c39c6f72", "CMUX-CHIEF-c39c6f72", "chief"] {
        let mut owner = link.open("daemon", serde_json::json!({"session": session})).await.unwrap();
        assert_eq!(drain(&mut owner).await.1, "bad_request", "{session}");
    }

    // chief: scoped to the owner's agent conversations, both ways.
    let mut chief = link.open("chief", serde_json::json!({})).await.unwrap();
    chief
        .send(Bytes::from_static(
            b"{\"id\":\"c1\",\"cmd\":\"conversation-list\"}\n{\"id\":\"c2\",\"cmd\":\"conversation-snapshot\",\"conversation\":\"conv_REMOTE\",\"tail\":1}\n",
        ))
        .await
        .unwrap();
    let mut chief_buffer = Vec::new();
    let mut seen = Vec::new();
    for _ in 0..2 {
        seen.push(next_line(&mut chief, &mut chief_buffer).await);
    }
    let list = seen.iter().find(|v| v["id"] == "c1").expect("list reply");
    assert_eq!(list["data"]["conversations"].as_array().unwrap().len(), 1);
    assert_eq!(list["data"]["conversations"][0]["id"], "conv_CHIEF");
    let refused = seen.iter().find(|v| v["id"] == "c2").expect("refusal");
    assert_eq!(refused["error_code"], "forbidden");
    chief
        .send(Bytes::from_static(
            b"{\"id\":\"c3\",\"cmd\":\"conversation-snapshot\",\"conversation\":\"conv_CHIEF\",\"tail\":1}\n{\"id\":\"c4\",\"cmd\":\"subscribe\"}\n{\"id\":\"c5\",\"cmd\":\"conversation-agent-token\",\"participant\":\"agent_mux\"}\n",
        ))
        .await
        .unwrap();
    let mut rest = Vec::new();
    for _ in 0..4 {
        rest.push(next_line(&mut chief, &mut chief_buffer).await);
    }
    assert_eq!(rest.iter().find(|v| v["id"] == "c3").unwrap()["data"]["cmd"], "conversation-snapshot");
    assert_eq!(rest.iter().find(|v| v["id"] == "c5").unwrap()["error_code"], "forbidden");
    let events: Vec<_> = rest.iter().filter(|v| v.get("event").is_some()).collect();
    assert_eq!(events.len(), 1, "{rest:?}");
    assert_eq!(events[0]["conversation"], "conv_CHIEF");

    // file
    let mut file = link
        .open("file", serde_json::json!({"path": fixture.root.join("notes.md").to_str().unwrap()}))
        .await
        .unwrap();
    assert_eq!(drain(&mut file).await, (b"# hello\n".to_vec(), "eof".into()));
    let mut secret = link
        .open("file", serde_json::json!({"path": fixture.outside.join("secret").to_str().unwrap()}))
        .await
        .unwrap();
    assert_eq!(drain(&mut secret).await, (Vec::new(), "forbidden".into()));

    // Preview metadata precedes the same raw contents; the legacy service above
    // remains raw. Forbidden paths must not disclose even their file size.
    let mut preview = link
        .open("file-preview", serde_json::json!({"path": fixture.root.join("notes.md").to_str().unwrap()}))
        .await
        .unwrap();
    assert_eq!(json_frame(preview.recv().await), serde_json::json!({"size": 8}));
    assert_eq!(drain(&mut preview).await, (b"# hello\n".to_vec(), "eof".into()));
    let mut secret_preview = link
        .open("file-preview", serde_json::json!({"path": fixture.outside.join("secret").to_str().unwrap()}))
        .await
        .unwrap();
    assert_eq!(drain(&mut secret_preview).await, (Vec::new(), "forbidden".into()));
    let empty_path = fixture.root.join("empty-preview.bin");
    std::fs::write(&empty_path, []).unwrap();
    let mut empty_preview =
        link.open("file-preview", serde_json::json!({"path": empty_path.to_str().unwrap()})).await.unwrap();
    assert_eq!(json_frame(empty_preview.recv().await), serde_json::json!({"size": 0}));
    assert_eq!(drain(&mut empty_preview).await, (Vec::new(), "eof".into()));

    // acpmux: one data frame per WebSocket message.
    let mut acp = link.open("acpmux", serde_json::json!({})).await.unwrap();
    acp.send(Bytes::from_static(br#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)).await.unwrap();
    match acp.recv().await {
        Some(ChannelEvent::Data(data)) => {
            let value: serde_json::Value = serde_json::from_slice(&data).unwrap();
            assert_eq!(value["echo"]["method"], "initialize");
        }
        other => panic!("unexpected {other:?}"),
    }

    // acpmux: a message the link splits (over 256 KiB) arrives whole.
    // Use a global request: a prompt without a session is rejected by exposure policy.
    let big = format!(
        r#"{{"jsonrpc":"2.0","id":2,"method":"initialize","params":{{"data":"{}"}}}}"#,
        "a".repeat(600_000)
    );
    acp.send(Bytes::from(big.clone())).await.unwrap();
    let mut echoed = Vec::new();
    while serde_json::from_slice::<serde_json::Value>(&echoed).is_err() {
        match tokio::time::timeout(Duration::from_secs(10), acp.recv()).await.expect("in time") {
            Some(ChannelEvent::Data(data)) => echoed.extend_from_slice(&data),
            other => panic!("unexpected {other:?}"),
        }
    }
    let echoed: serde_json::Value = serde_json::from_slice(&echoed).unwrap();
    assert_eq!(echoed["echo"]["params"]["data"].as_str().map(str::len), Some(600_000));
    let expected: serde_json::Value = serde_json::from_str(&big).unwrap();
    assert!(echoed["echo"] == expected, "fragmented ACP payload changed");

    // daemon: a phone's agent tab gets this Mac's host.
    daemon
        .send(Bytes::from_static(
            b"{\"id\":9,\"cmd\":\"new-conversation-tab\",\"pane\":1,\"agent_session\":{\"harness\":\"claude\"}}\n",
        ))
        .await
        .unwrap();
    let answer = next_line(&mut daemon, &mut buffer).await;
    assert_eq!(answer["data"]["host"], "install:mac-test");

    // upload: the bytes land in a new file, the reply names it.
    let mut upload =
        link.open("upload", serde_json::json!({"name": "../photo.jpg", "size": 5})).await.unwrap();
    upload.send(Bytes::from_static(b"he")).await.unwrap();
    upload.send(Bytes::from_static(b"llo")).await.unwrap();
    let (reply, code) = drain(&mut upload).await;
    assert_eq!(code, "eof");
    let reply: serde_json::Value = serde_json::from_slice(&reply).unwrap();
    let path = std::path::PathBuf::from(reply["path"].as_str().unwrap());
    assert!(path.starts_with(&fixture.uploads), "{path:?}");
    assert_eq!(path.file_name().unwrap(), "photo.jpg");
    assert_eq!(std::fs::read(&path).unwrap(), b"hello");
    // Into a workspace folder: next to acpmux's attachments.
    let mut upload = link
        .open(
            "upload",
            serde_json::json!({"name": "notes.txt", "size": 2, "cwd": fixture.root.to_str().unwrap()}),
        )
        .await
        .unwrap();
    upload.send(Bytes::from_static(b"hi")).await.unwrap();
    let (reply, code) = drain(&mut upload).await;
    assert_eq!(code, "eof");
    let reply: serde_json::Value = serde_json::from_slice(&reply).unwrap();
    let path = std::path::PathBuf::from(reply["path"].as_str().unwrap());
    let root = std::fs::canonicalize(&fixture.root).unwrap();
    assert!(path.starts_with(root.join(".cmux/attachments")), "{path:?}");
    // A folder that is no tab's and outside the roots: refused.
    let mut outside = link
        .open("upload", serde_json::json!({"name": "x", "size": 1, "cwd": fixture.outside.to_str().unwrap()}))
        .await
        .unwrap();
    assert_eq!(drain(&mut outside).await.1, "forbidden");
    // browser: hostd sends the hello, the phone reads the host's carrier.
    let tab = format!("s{}", kind as u8);
    let mut first =
        link.open("browser", serde_json::json!({"tab": tab, "url": "https://example.com/"})).await.unwrap();
    let mut rd = RdReader::default();
    assert_eq!(rd.control(&mut first).await["t"], "welcome");
    assert_eq!(rd.control(&mut first).await["t"], "started");
    assert_eq!(rd.control(&mut first).await["body"]["t"], "rb.opened");
    assert_eq!(rd.control(&mut first).await["body"]["url"], "https://example.com/");
    // Video shards flow.
    rd.datagram(&mut first).await;
    // The phone's address bar: what the policy allows reaches the host (which
    // answers rb.page); the rest is refused with a sentence, never sent on.
    // Canonical, as hostd forwards a shared file at its resolved path.
    let shared = file_url(&std::fs::canonicalize(fixture.root.join("shared page.html")).unwrap());
    let not_shared = file_url(&fixture.outside.join("secret"));
    for (url, refused) in [
        (not_shared.as_str(), Some("This file isn't in a folder this Mac shares with your iPhone.")),
        ("file:///etc/passwd", Some("This file isn't in a folder this Mac shares with your iPhone.")),
        ("javascript:alert(1)", Some("Scripts can't run from your iPhone's address bar.")),
        ("chrome://settings", Some("Browser settings and internal pages can't open from your iPhone.")),
        (
            "zoommtg://zoom.us/join",
            Some("Links that open other apps on your Mac can't open from your iPhone."),
        ),
        ("data:text/html,<h1>hi</h1>", None),
        (shared.as_str(), None),
        ("https://example.org/", None),
    ] {
        first.send(phone_rb(serde_json::json!({"t": "rb.navigate", "url": url}))).await.unwrap();
        let body = rd.control(&mut first).await["body"].clone();
        match refused {
            Some(reason) => {
                assert_eq!(body["t"], "rb.navigate.refused", "{url}");
                assert_eq!(body["url"], url);
                assert_eq!(body["reason"], reason);
            }
            None => {
                assert_eq!(body["t"], "rb.page", "{url}");
                assert_eq!(body["url"], url);
            }
        }
    }
    // A link inside the page follows the same rules: the host's page to an
    // unshared file never reaches the phone, and the host goes back.
    first
        .send(phone_rb(serde_json::json!({"t": "rb.find", "query": format!("goto:{not_shared}"),
        "forward": true, "match_case": false, "next": false})))
        .await
        .unwrap();
    let body = rd.control(&mut first).await["body"].clone();
    assert_eq!(body["t"], "rb.navigate.refused");
    assert_eq!(body["url"], not_shared.as_str());
    let body = rd.control(&mut first).await["body"].clone();
    assert_eq!((body["t"].as_str(), body["url"].as_str()), (Some("rb.page"), Some("https://example.org/")));
    // A second viewer of the same tab takes the host over, and the page stays.
    let mut second = link.open("browser", serde_json::json!({"tab": tab})).await.unwrap();
    let mut rd2 = RdReader::default();
    assert_eq!(rd2.control(&mut second).await["t"], "welcome");
    rd2.control(&mut second).await;
    rd2.control(&mut second).await;
    assert_eq!(rd2.control(&mut second).await["body"]["url"], "https://example.org/");
    assert_eq!(drain(&mut first).await.1, "replaced");
    assert_eq!(fixture.browser_launches.load(std::sync::atomic::Ordering::SeqCst), 1);
    second.close("eof", "").await;
    let mut refused = link.open("browser", serde_json::json!({"tab": "x", "url": "file:///"})).await.unwrap();
    assert_eq!(
        close_reason(&mut refused).await,
        ("forbidden".into(), "This file isn't in a folder this Mac shares with your iPhone.".into())
    );
    // A page one of the Mac's own browser tabs shows opens wherever it is.
    let mac_page = file_url(&fixture.outside.join("mac page.html"));
    let mut mac_tab = link.open("browser", serde_json::json!({"tab": "s9", "url": mac_page})).await.unwrap();
    let mut rd3 = RdReader::default();
    assert_eq!(rd3.control(&mut mac_tab).await["t"], "welcome");
    rd3.control(&mut mac_tab).await;
    rd3.control(&mut mac_tab).await;
    // A new host of a file page starts blank, gets its file policy, then the page.
    assert_eq!(rd3.control(&mut mac_tab).await["body"]["url"], "about:blank");
    assert_eq!(rd3.control(&mut mac_tab).await["body"]["url"], mac_page.as_str());
    mac_tab.close("eof", "").await;
    let mut bad_tab = link.open("browser", serde_json::json!({"tab": "../x"})).await.unwrap();
    assert_eq!(drain(&mut bad_tab).await.1, "bad_request");

    // default deny
    let mut shell = link.open("shell", serde_json::json!({})).await.unwrap();
    assert_eq!(drain(&mut shell).await.1, "unknown_service");

    link.close("done");
}

/// `browser {"video": "track"}` on a link with a media lane: the page's
/// frames ride the lane (a WebRTC video track, or RTP inside the WireGuard
/// tunnel; hostd is the main stream's viewer), rb control stays on the
/// channel. A second tab takes the lane over and the first gets its video
/// on its channel again. Without the lane (an older phone) the same request
/// streams on the channel.
async fn browser_video(kind: TransportKind, phone_lane: bool) {
    let fixture = fixture(FakeOptions::default()).await;
    let phone = DialOptions { video_lane: phone_lane, ..options() };
    let connected =
        cmux_mobile_link::dial::connect(&fixture.phone, &fixture.mac_id, kind, &phone, LinkConfig::default())
            .await
            .expect("dial");
    let link = &connected.link;
    let lane = match link.media() {
        Some(cmux_mobile_link::media::MediaLane::In(input)) => Some(input),
        None => None,
        other => panic!("{other:?}"),
    };
    assert_eq!(lane.is_some(), phone_lane);
    if let Some(lane) = &lane {
        let carrier = if kind == TransportKind::WebRtc { "webrtc-track" } else { "wireguard-udp" };
        assert_eq!(lane.kind().name(), carrier);
    }
    let mut frames = match &lane {
        Some(lane) => Some(lane.subscribe().await),
        None => None,
    };
    let mut tab_a = link
        .open(
            "browser",
            serde_json::json!({"tab": "sA", "url": "https://example.com/", "video": "track", "video_tag": 0xa1}),
        )
        .await
        .unwrap();
    let mut rd = RdReader::default();
    assert_eq!(rd.control(&mut tab_a).await["t"], "welcome");
    assert_eq!(rd.control(&mut tab_a).await["t"], "started");
    assert_eq!(rd.control(&mut tab_a).await["body"]["t"], "rb.opened");
    let Some(frames) = frames.as_mut() else {
        // No lane: the shards come on the channel.
        let datagram = rd.datagram(&mut tab_a).await;
        let (header, _) = cmux_rd_proto::DatagramHeader::decode(&datagram).unwrap();
        assert_eq!(header.kind, cmux_rd_proto::DatagramKind::Video);
        link.close("done");
        return;
    };
    // Frames on the track, starting at a keyframe, in order.
    let mut got = Vec::new();
    while got.len() < 10 {
        let frame = tokio::time::timeout(Duration::from_secs(10), frames.frames.recv())
            .await
            .expect("frame")
            .unwrap();
        got.push(frame);
    }
    assert!(got[0].keyframe);
    assert!(got.iter().skip(1).any(|f| !f.keyframe));
    // Each lane frame carries tab A's tag, after its slices.
    for frame in &mut got {
        assert_eq!(cmux_mobile_link::media::tag::strip(&mut frame.access_unit), Some(0xa1));
    }
    assert!(cmux_mobile_link::media::h264::is_keyframe(&got[0].access_unit));
    // The channel carries no main-stream video meanwhile.
    let quiet = tokio::time::Instant::now() + Duration::from_millis(500);
    loop {
        let Ok(Some(event)) = tokio::time::timeout_at(quiet, tab_a.recv()).await else { break };
        if let ChannelEvent::Data(data) = event {
            rd.0.extend(&data);
            while let Some((kind, payload)) = rd.0.next_frame().unwrap() {
                if kind == cmux_rd_proto::STREAM_DATAGRAM {
                    let (header, _) = cmux_rd_proto::DatagramHeader::decode(&payload).unwrap();
                    assert!(!matches!(
                        header.kind,
                        cmux_rd_proto::DatagramKind::Video | cmux_rd_proto::DatagramKind::Fec
                    ));
                }
            }
        }
    }
    // Tab B takes the lane; tab A's video returns to its channel.
    let mut tab_b = link
        .open("browser", serde_json::json!({"tab": "sB", "video": "track", "video_tag": 0xb2}))
        .await
        .unwrap();
    let mut rd_b = RdReader::default();
    assert_eq!(rd_b.control(&mut tab_b).await["t"], "welcome");
    // The lane goes over to tab B: its frames carry B's tag, and A's stop.
    loop {
        let mut frame = tokio::time::timeout(Duration::from_secs(10), frames.frames.recv())
            .await
            .expect("a lane frame after the takeover")
            .unwrap();
        match cmux_mobile_link::media::tag::strip(&mut frame.access_unit) {
            Some(0xa1) => continue,
            Some(0xb2) => break,
            other => panic!("a lane frame tagged {other:?}"),
        }
    }
    loop {
        let datagram = rd.datagram(&mut tab_a).await;
        let (header, _) = cmux_rd_proto::DatagramHeader::decode(&datagram).unwrap();
        if header.kind == cmux_rd_proto::DatagramKind::Video {
            break;
        }
    }
    link.close("done");
}

/// A simulator surface streams like a browser tab: only a phone tab of
/// this Mac opens, its video rides the media lane with its tag, and the
/// lane goes to whichever of the browser tab and the surface is shown.
async fn surface_video(kind: TransportKind) {
    let fixture = fixture(FakeOptions::default()).await;
    let phone = DialOptions { video_lane: true, ..options() };
    let connected =
        cmux_mobile_link::dial::connect(&fixture.phone, &fixture.mac_id, kind, &phone, LinkConfig::default())
            .await
            .expect("dial");
    let link = &connected.link;
    let Some(cmux_mobile_link::media::MediaLane::In(lane)) = link.media() else { panic!("no media lane") };
    let mut frames = lane.subscribe().await;
    // Not a phone tab, not a tab of this Mac, not a tab key: refused before any source starts.
    for (tab, code) in
        [("s9", "forbidden"), ("s13", "forbidden"), ("s14", "forbidden"), ("../x", "bad_request")]
    {
        let mut channel = link.open("surface", serde_json::json!({"tab": tab})).await.unwrap();
        assert_eq!(close_reason(&mut channel).await.0, code, "{tab}");
    }
    assert!(fixture.surface_inputs.lock().unwrap().is_empty());
    // A browser tab holds the lane first.
    let mut page = link
        .open("browser", serde_json::json!({"tab": "sA", "url": "https://example.com/", "video": "track", "video_tag": 0xa1}))
        .await
        .unwrap();
    let mut rd_page = RdReader::default();
    assert_eq!(rd_page.control(&mut page).await["t"], "welcome");
    let mut sim = link
        .open("surface", serde_json::json!({"tab": "s12", "video": "track", "video_tag": 0x5e}))
        .await
        .unwrap();
    let mut rd = RdReader::default();
    let welcome = rd.control(&mut sim).await;
    assert_eq!(welcome["t"], "welcome");
    assert_eq!((welcome["width"].as_u64(), welcome["height"].as_u64()), (Some(390), Some(844)));
    assert_eq!(rd.control(&mut sim).await["t"], "started");
    sim.send(phone_rb(serde_json::json!({"t": "rb.open", "tab": "s12"}))).await.unwrap();
    assert_eq!(rd.control(&mut sim).await["body"]["t"], "rb.opened");
    // The surface took the lane: its frames carry its tag, starting at a keyframe.
    let first = loop {
        let mut frame = tokio::time::timeout(Duration::from_secs(10), frames.frames.recv())
            .await
            .expect("a surface frame on the lane")
            .unwrap();
        match cmux_mobile_link::media::tag::strip(&mut frame.access_unit) {
            Some(0xa1) => continue,
            Some(0x5e) => break frame,
            other => panic!("a lane frame tagged {other:?}"),
        }
    };
    assert!(first.keyframe && cmux_mobile_link::media::h264::is_keyframe(&first.access_unit));
    // The browser tab shown again takes the lane back; hiding the surface reaches the source.
    sim.send(phone_rb(serde_json::json!({"t": "rb.visibility", "visible": false}))).await.unwrap();
    page.send(phone_rb(serde_json::json!({"t": "rb.visibility", "visible": true}))).await.unwrap();
    loop {
        let mut frame = tokio::time::timeout(Duration::from_secs(10), frames.frames.recv())
            .await
            .expect("a page frame after the take-back")
            .unwrap();
        if cmux_mobile_link::media::tag::strip(&mut frame.access_unit) == Some(0xa1) {
            break;
        }
    }
    for _ in 0..200 {
        if fake_surface_source::has(&fixture.surface_inputs, "visible", "visible", &serde_json::json!(false))
        {
            break;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    assert!(fake_surface_source::has(
        &fixture.surface_inputs,
        "visible",
        "visible",
        &serde_json::json!(false)
    ));
    // A navigation on a surface never reaches its source.
    sim.send(phone_rb(serde_json::json!({"t": "rb.navigate", "url": "https://example.org/"}))).await.unwrap();
    // A second viewer of the same surface replaces the first.
    let _second = link.open("surface", serde_json::json!({"tab": "s12"})).await.unwrap();
    assert_eq!(close_reason(&mut sim).await.0, "replaced");
    assert!(
        !fixture.surface_inputs.lock().unwrap().iter().any(|line| line.to_string().contains("example.org"))
    );
    link.close("done");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn surface_video_rides_the_webrtc_track() {
    surface_video(TransportKind::WebRtc).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn surface_video_rides_rtp_inside_the_wireguard_tunnel() {
    surface_video(TransportKind::WireGuard).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn browser_video_rides_the_webrtc_track() {
    browser_video(TransportKind::WebRtc, true).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn browser_video_rides_rtp_inside_the_wireguard_tunnel() {
    browser_video(TransportKind::WireGuard, true).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn browser_video_stays_on_the_channel_for_an_older_phone_over_wireguard() {
    browser_video(TransportKind::WireGuard, false).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn services_over_webrtc() {
    let fixture = fixture(FakeOptions::default()).await;
    exercise_services(&fixture, TransportKind::WebRtc).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn services_over_wireguard() {
    let fixture = fixture(FakeOptions::default()).await;
    exercise_services(&fixture, TransportKind::WireGuard).await;
}

/// The phone's network blocks UDP: every service works over the phone's
/// TURN allocation over TLS (the backend relay that used to carry this is
/// retired).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn services_over_wireguard_turn_tls_with_udp_blocked() {
    let turn = cmux_mobile_link::testing::TestTurn::start().await;
    let fixture =
        fixture(FakeOptions { ice_servers: vec![turn.ice.clone()], ..FakeOptions::default() }).await;
    let phone = DialOptions {
        ice_servers: vec![turn.ice.clone()],
        block_udp: true,
        turn_tls_roots: Some(Arc::clone(&turn.roots)),
        ..options()
    };
    exercise_services_with(&fixture, TransportKind::WireGuard, &phone).await;
    assert!(turn.stream_connections() >= 1, "the phone never connected to TURN over TLS");
}

/// A phone attachment has no size cap (Leo, 2026-10-26: "WE NEED ARBITARRILY LARGE FILES
/// OF ANY TYPE"): a file just past the old 100 MiB default, streamed in chunks, is saved
/// whole. The test never holds the file in memory; it checks the saved length.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_upload_past_the_old_100_mib_cap_is_saved_whole() {
    const CHUNK: usize = 256 * 1024;
    let size: u64 = 100 * 1024 * 1024 + 1;
    let fixture = fixture(FakeOptions::default()).await;
    let connected = connect(&fixture, TransportKind::WireGuard).await.expect("dial");
    let mut upload =
        connected.link.open("upload", serde_json::json!({"name": "big.bin", "size": size})).await.unwrap();
    let chunk = Bytes::from(vec![0x5a_u8; CHUNK]);
    let mut sent: u64 = 0;
    while sent < size {
        let take = usize::try_from(size - sent).unwrap_or(CHUNK).min(CHUNK);
        if upload.send(chunk.slice(..take)).await.is_err() {
            break;
        }
        sent += take as u64;
    }
    // The host writes and syncs 100 MiB before it answers; a loaded CI runner can take well over 10 s.
    let (reply, code) = drain_within(&mut upload, Duration::from_secs(90)).await;
    assert_eq!(code, "eof", "{}", String::from_utf8_lossy(&reply));
    assert_eq!(sent, size);
    let reply: serde_json::Value = serde_json::from_slice(&reply).unwrap();
    assert_eq!(reply["size"].as_u64(), Some(size));
    let path = std::path::PathBuf::from(reply["path"].as_str().unwrap());
    assert!(path.starts_with(&fixture.uploads), "{path:?}");
    assert_eq!(std::fs::metadata(&path).unwrap().len(), size);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn dials_without_a_stamped_user_are_refused() {
    let fixture = fixture(FakeOptions { omit_from_user_id: true, ..FakeOptions::default() }).await;
    for kind in [TransportKind::WebRtc, TransportKind::WireGuard] {
        let error = connect(&fixture, kind).await.err().expect("refused");
        assert_eq!(error, DialError::Bye("not_admitted".into()));
    }
}

// ---- Pairing (src/pairing.rs) ----

struct PhoneKeys {
    identity: ring::signature::EcdsaKeyPair,
    identity_hex: String,
    approval_hex: String,
}

fn p256() -> ring::signature::EcdsaKeyPair {
    use ring::signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair};
    let rng = ring::rand::SystemRandom::new();
    let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
    EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8.as_ref(), &rng).unwrap()
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn phone_keys() -> PhoneKeys {
    use ring::signature::KeyPair;
    let identity = p256();
    let identity_hex = hex(identity.public_key().as_ref());
    PhoneKeys { identity, identity_hex, approval_hex: hex(p256().public_key().as_ref()) }
}

fn json_frame(event: Option<ChannelEvent>) -> serde_json::Value {
    match event {
        Some(ChannelEvent::Data(data)) => serde_json::from_slice(&data).unwrap(),
        other => panic!("unexpected {other:?}"),
    }
}

/// Opens `auth`, signs the challenge with `signer`, and returns the channel
/// after the signature went out.
async fn auth(
    link: &cmux_mobile_link::Link,
    fixture: &Fixture,
    keys: &PhoneKeys,
    signer: &ring::signature::EcdsaKeyPair,
    action: &str,
) -> Channel {
    auth_presenting(link, fixture, keys, signer, action, None).await
}

/// `auth`, with an older phone's `pairToken` (the retired Mac pairing code's pre-approval) sent
/// beside the signature when `pair_token` is set.
async fn auth_presenting(
    link: &cmux_mobile_link::Link,
    fixture: &Fixture,
    keys: &PhoneKeys,
    signer: &ring::signature::EcdsaKeyPair,
    action: &str,
    pair_token: Option<&str>,
) -> Channel {
    auth_as(link, fixture, keys, signer, action, pair_token, "").await
}

/// `auth` as a device of `kind` (`""` is a phone, as every phone app sends it).
async fn auth_as(
    link: &cmux_mobile_link::Link,
    fixture: &Fixture,
    keys: &PhoneKeys,
    signer: &ring::signature::EcdsaKeyPair,
    action: &str,
    pair_token: Option<&str>,
    kind: &str,
) -> Channel {
    let mut args = serde_json::json!({"identityKey": keys.identity_hex, "approvalKey": keys.approval_hex,
                                      "name": "Test iPhone", "action": action,
                                      "bundleId": "dev.cmux.mobile.test-tag"});
    if !kind.is_empty() {
        args["kind"] = serde_json::json!(kind);
        args["name"] = serde_json::json!("Studio");
    }
    let mut channel = link.open("auth", args).await.unwrap();
    let challenge = json_frame(channel.recv().await);
    assert_eq!(challenge["mac"], fixture.mac_id);
    let message = challenge_message(
        &fixture.mac_id,
        &fixture.phone_id,
        challenge["challenge"].as_str().unwrap(),
        &keys.identity_hex,
        &keys.approval_hex,
        action,
    );
    let signature = hex(signer.sign(&ring::rand::SystemRandom::new(), &message).unwrap().as_ref());
    let mut reply = serde_json::json!({"signature": signature});
    if let Some(token) = pair_token {
        reply["pairToken"] = serde_json::json!(token);
    }
    channel.send(Bytes::from(reply.to_string())).await.unwrap();
    channel
}

/// The Mac's pairing code is retired: an older phone that still sends a `pairToken` (well formed
/// or not) beside its signature is asked as every phone is, and the token never reaches the app.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_older_phones_pairing_code_token_is_ignored() {
    let fixture = fixture_with(FakeOptions::default(), true).await;
    let keys = phone_keys();
    let connected = connect(&fixture, TransportKind::WireGuard).await.expect("dial");

    let mut channel =
        auth_presenting(&connected.link, &fixture, &keys, &keys.identity, "pair", Some("no spaces allowed"))
            .await;
    assert_eq!(json_frame(channel.recv().await), serde_json::json!({"pending": true}));
    let request = fixture.events.as_ref().unwrap().lock().await.recv().await.unwrap();
    assert_eq!(
        request,
        Event::PairRequest {
            phone_device_id: fixture.phone_id.clone(),
            name: "Test iPhone".into(),
            identity_key: keys.identity_hex.clone(),
            approval_key: keys.approval_hex.clone(),
            registered_at_ms: None,
            bundle_id: Some("dev.cmux.mobile.test-tag".into()),
            kind: cmux_mobile_host::peer::PeerKind::Phone,
        }
    );
    // The person allowed it on the Mac: the phone is served.
    fixture.trust.as_ref().unwrap().send_replace(Some(trusting(&fixture, &keys)));
    assert_eq!(json_frame(channel.recv().await), serde_json::json!({"ok": true}));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_token_alone_never_reaches_a_service_and_the_mac_approves_each_phone() {
    let fixture = fixture_with(FakeOptions::default(), true).await;
    let keys = phone_keys();
    let connected = connect(&fixture, TransportKind::WireGuard).await.expect("dial");
    let link = &connected.link;

    // Before auth: every service is refused.
    for service in ["daemon", "acpmux", "file", "file-preview", "echo", "localhost"] {
        let mut channel = link.open(service, serde_json::json!({})).await.unwrap();
        assert_eq!(drain(&mut channel).await.1, "unpaired", "{service}");
    }

    // A signature by another key proves nothing and asks nobody.
    let mut forged = auth(link, &fixture, &keys, &p256(), "pair").await;
    assert_eq!(drain(&mut forged).await.1, "unpaired");

    // Unknown keys: hostd asks the app, the phone waits, the user allows.
    let mut channel = auth(link, &fixture, &keys, &keys.identity, "pair").await;
    assert_eq!(json_frame(channel.recv().await), serde_json::json!({"pending": true}));
    let request = fixture.events.as_ref().unwrap().lock().await.recv().await.unwrap();
    assert_eq!(
        request,
        Event::PairRequest {
            phone_device_id: fixture.phone_id.clone(),
            name: "Test iPhone".into(),
            identity_key: keys.identity_hex.clone(),
            approval_key: keys.approval_hex.clone(),
            registered_at_ms: None,
            bundle_id: Some("dev.cmux.mobile.test-tag".into()),
            kind: cmux_mobile_host::peer::PeerKind::Phone,
        }
    );
    fixture.trust.as_ref().unwrap().send_replace(Some(DeviceTrust {
        devices: vec![TrustedDevice {
            id: fixture.phone_id.clone(),
            identity_key: keys.identity_hex.clone(),
            approval_key: keys.approval_hex.clone(),
            ..Default::default()
        }],
        denied: vec![],
    }));
    assert_eq!(json_frame(channel.recv().await), serde_json::json!({"ok": true}));
    let mut echo = link.open("echo", serde_json::json!({})).await.unwrap();
    echo.send(Bytes::from_static(b"ping")).await.unwrap();
    assert_eq!(echo.recv().await, Some(ChannelEvent::Data(Bytes::from_static(b"ping"))));
    link.close("done");

    // The next link with the same keys passes at once; with a new approval
    // key it asks again.
    let connected = connect(&fixture, TransportKind::WebRtc).await.expect("dial");
    let mut channel = auth(&connected.link, &fixture, &keys, &keys.identity, "pair").await;
    assert_eq!(json_frame(channel.recv().await), serde_json::json!({"ok": true}));
    let rotated = PhoneKeys {
        approval_hex: hex(ring::signature::KeyPair::public_key(&p256()).as_ref()),
        ..phone_keys()
    };
    let rotated = PhoneKeys {
        identity: keys.identity,
        identity_hex: keys.identity_hex.clone(),
        approval_hex: rotated.approval_hex,
    };
    let mut channel = auth(&connected.link, &fixture, &rotated, &rotated.identity, "pair").await;
    assert_eq!(json_frame(channel.recv().await), serde_json::json!({"pending": true}));
    assert!(matches!(
        fixture.events.as_ref().unwrap().lock().await.recv().await,
        Some(Event::PairRequest { .. })
    ));

    // Unpair by the paired identity key: the app hears it.
    let mut channel =
        auth(&connected.link, &fixture, &keys_like(&rotated), &rotated.identity, "unpair").await;
    assert_eq!(json_frame(channel.recv().await), serde_json::json!({"ok": true}));
    assert_eq!(
        fixture.events.as_ref().unwrap().lock().await.recv().await,
        Some(Event::Unpaired { phone_device_id: fixture.phone_id.clone() })
    );
}

/// Another of the person's Macs pairs through the same `auth`, is asked about as a Mac (never
/// pre-approved by a pairing code, never matched by a phone's record), and then opens only what
/// the app granted it; a removed machine loses its link's services at the next open.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_mac_opens_only_what_this_mac_granted_it() {
    use cmux_mobile_host::peer::{Grant, PeerKind};
    let fixture = fixture_with(FakeOptions::default(), true).await;
    let phone = phone_keys();
    let keys = PhoneKeys { approval_hex: String::new(), ..phone };
    let connected = connect(&fixture, TransportKind::WireGuard).await.expect("dial");
    let link = &connected.link;

    // An unknown kind is refused before anything is asked.
    let mut odd = link
        .open("auth", serde_json::json!({"identityKey": keys.identity_hex, "kind": "server"}))
        .await
        .unwrap();
    assert_eq!(drain(&mut odd).await.1, "bad_request");

    // A phone's record for the same device and key does not admit it as a Mac.
    fixture.trust.as_ref().unwrap().send_replace(Some(DeviceTrust {
        devices: vec![TrustedDevice {
            id: fixture.phone_id.clone(),
            identity_key: keys.identity_hex.clone(),
            approval_key: String::new(),
            ..Default::default()
        }],
        denied: vec![],
    }));
    let token = "Zm9vYmFyLWJhel9xdXV4";
    let mut channel = auth_as(link, &fixture, &keys, &keys.identity, "pair", Some(token), "mac").await;
    assert_eq!(json_frame(channel.recv().await), serde_json::json!({"pending": true}));
    let request = fixture.events.as_ref().unwrap().lock().await.recv().await.unwrap();
    assert_eq!(
        request,
        Event::PairRequest {
            phone_device_id: fixture.phone_id.clone(),
            name: "Studio".into(),
            identity_key: keys.identity_hex.clone(),
            approval_key: String::new(),
            registered_at_ms: None,
            // A machine's bundle id is dropped.
            bundle_id: None,
            kind: PeerKind::Mac,
        }
    );
    // The app allows it as a Mac, granting nothing yet (the person chooses grants after).
    let granting = |grants: Vec<Grant>| DeviceTrust {
        devices: vec![TrustedDevice {
            id: fixture.phone_id.clone(),
            identity_key: keys.identity_hex.clone(),
            approval_key: String::new(),
            kind: PeerKind::Mac,
            grants,
        }],
        denied: vec![],
    };
    fixture.trust.as_ref().unwrap().send_replace(Some(granting(vec![])));
    assert_eq!(json_frame(channel.recv().await), serde_json::json!({"ok": true}));

    let mut machine = link.open("machine", serde_json::json!({})).await.unwrap();
    let described = json_frame(machine.recv().await);
    assert_eq!(described["grants"], serde_json::json!([]));
    assert!(described.get("os").is_some());
    let mut preview = link.open("file-preview", serde_json::json!({})).await.unwrap();
    assert_eq!(drain(&mut preview).await.1, "not_granted", "pairing alone reads no files");

    // Granted view, it still may not type or reach agents.
    fixture.trust.as_ref().unwrap().send_replace(Some(granting(vec![Grant::View])));
    let mut machine = link.open("machine", serde_json::json!({})).await.unwrap();
    assert_eq!(json_frame(machine.recv().await)["grants"], serde_json::json!(["view"]));
    for (service, code) in
        [("daemon", "not_granted"), ("acpmux", "not_granted"), ("cloud-acpmux", "not_offered")]
    {
        let mut refused = link.open(service, serde_json::json!({})).await.unwrap();
        assert_eq!(drain(&mut refused).await.1, code, "{service}");
    }

    // Granted control, the same link opens `daemon` at once (read at every open).
    fixture.trust.as_ref().unwrap().send_replace(Some(granting(vec![Grant::View, Grant::Control])));
    let mut echo = link.open("echo", serde_json::json!({})).await.unwrap();
    echo.send(Bytes::from_static(b"hi")).await.unwrap();
    assert_eq!(echo.recv().await, Some(ChannelEvent::Data(Bytes::from_static(b"hi"))));

    // Removed: nothing opens any more on the live link.
    fixture.trust.as_ref().unwrap().send_replace(Some(DeviceTrust::default()));
    let mut gone = link.open("machine", serde_json::json!({})).await.unwrap();
    assert_eq!(drain(&mut gone).await.1, "revoked");

    // Activity has every pairing attempt and every request, allowed or refused.
    let logged: Vec<(String, String)> = fixture
        .activity
        .as_ref()
        .unwrap()
        .recent()
        .into_iter()
        .map(|entry| (entry.service, entry.decision))
        .collect();
    let has = |service: &str, decision: &str| logged.contains(&(service.to_owned(), decision.to_owned()));
    assert!(has("auth", "allowed"), "{logged:?}");
    assert!(has("file-preview", "not_granted"), "{logged:?}");
    assert!(has("machine", "allowed"), "{logged:?}");
    assert!(has("machine", "revoked"), "{logged:?}");
}

fn keys_like(keys: &PhoneKeys) -> PhoneKeys {
    PhoneKeys {
        identity: p256(),
        identity_hex: keys.identity_hex.clone(),
        approval_hex: keys.approval_hex.clone(),
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_phone_the_user_refused_is_closed_denied() {
    let fixture = fixture_with(FakeOptions::default(), true).await;
    let keys = phone_keys();
    let connected = connect(&fixture, TransportKind::WireGuard).await.expect("dial");
    let mut channel = auth(&connected.link, &fixture, &keys, &keys.identity, "pair").await;
    assert_eq!(json_frame(channel.recv().await), serde_json::json!({"pending": true}));
    let _ = fixture.events.as_ref().unwrap().lock().await.recv().await;
    fixture.trust.as_ref().unwrap().send_replace(Some(DeviceTrust {
        devices: vec![],
        denied: vec![DeniedDevice { id: fixture.phone_id.clone(), identity_key: keys.identity_hex.clone() }],
    }));
    assert_eq!(drain(&mut channel).await.1, "denied");
    // The next try with the same key is refused at once, without asking.
    let mut again = auth(&connected.link, &fixture, &keys, &keys.identity, "pair").await;
    assert_eq!(drain(&mut again).await.1, "denied");
    assert!(fixture.events.as_ref().unwrap().lock().await.try_recv().is_err());
    let mut daemon = connected.link.open("daemon", serde_json::json!({})).await.unwrap();
    assert_eq!(drain(&mut daemon).await.1, "unpaired");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn channels_opened_after_auth_wait_for_it() {
    let fixture = fixture_with(FakeOptions::default(), true).await;
    let keys = phone_keys();
    let connected = connect(&fixture, TransportKind::WireGuard).await.expect("dial");
    let link = &connected.link;
    // The phone opens auth and, without waiting, its other channels.
    let mut channel = link
        .open(
            "auth",
            serde_json::json!({"identityKey": keys.identity_hex, "approvalKey": keys.approval_hex,
                               "name": "Test iPhone", "action": "pair"}),
        )
        .await
        .unwrap();
    let mut echo = link.open("echo", serde_json::json!({})).await.unwrap();
    echo.send(Bytes::from_static(b"early")).await.unwrap();
    let challenge = json_frame(channel.recv().await);
    let message = challenge_message(
        &fixture.mac_id,
        &fixture.phone_id,
        challenge["challenge"].as_str().unwrap(),
        &keys.identity_hex,
        &keys.approval_hex,
        "pair",
    );
    let signature = hex(keys.identity.sign(&ring::rand::SystemRandom::new(), &message).unwrap().as_ref());
    channel.send(Bytes::from(serde_json::json!({"signature": signature}).to_string())).await.unwrap();
    assert_eq!(json_frame(channel.recv().await), serde_json::json!({"pending": true}));
    let _ = fixture.events.as_ref().unwrap().lock().await.recv().await;
    fixture.trust.as_ref().unwrap().send_replace(Some(DeviceTrust {
        devices: vec![TrustedDevice {
            id: fixture.phone_id.clone(),
            identity_key: keys.identity_hex.clone(),
            approval_key: keys.approval_hex.clone(),
            ..Default::default()
        }],
        denied: vec![],
    }));
    assert_eq!(json_frame(channel.recv().await), serde_json::json!({"ok": true}));
    // The echo opened before approval is served once the phone is paired.
    assert_eq!(echo.recv().await, Some(ChannelEvent::Data(Bytes::from_static(b"early"))));

    // On a link whose auth is refused, a channel opened behind it is refused too.
    let other = connect(&fixture, TransportKind::WebRtc).await.expect("dial");
    let mut forged = other
        .link
        .open(
            "auth",
            serde_json::json!({"identityKey": keys.identity_hex, "approvalKey": keys.approval_hex,
                               "name": "Test iPhone", "action": "pair"}),
        )
        .await
        .unwrap();
    let mut daemon = other.link.open("daemon", serde_json::json!({})).await.unwrap();
    let challenge = json_frame(forged.recv().await);
    let message = challenge_message(
        &fixture.mac_id,
        &fixture.phone_id,
        challenge["challenge"].as_str().unwrap(),
        &keys.identity_hex,
        &keys.approval_hex,
        "pair",
    );
    let signature = hex(p256().sign(&ring::rand::SystemRandom::new(), &message).unwrap().as_ref());
    forged.send(Bytes::from(serde_json::json!({"signature": signature}).to_string())).await.unwrap();
    assert_eq!(drain(&mut forged).await.1, "unpaired");
    assert_eq!(drain(&mut daemon).await.1, "unpaired");
}

fn trusting(fixture: &Fixture, keys: &PhoneKeys) -> DeviceTrust {
    DeviceTrust {
        devices: vec![TrustedDevice {
            id: fixture.phone_id.clone(),
            identity_key: keys.identity_hex.clone(),
            approval_key: keys.approval_hex.clone(),
            ..Default::default()
        }],
        denied: vec![],
    }
}

fn open_auth_args(keys: &PhoneKeys) -> serde_json::Value {
    serde_json::json!({"identityKey": keys.identity_hex, "approvalKey": keys.approval_hex,
                       "name": "Test iPhone", "action": "pair"})
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_link_runs_one_auth_at_a_time() {
    let fixture = fixture_with(FakeOptions::default(), true).await;
    let keys = phone_keys();
    let connected = connect(&fixture, TransportKind::WireGuard).await.expect("dial");
    let mut first = connected.link.open("auth", open_auth_args(&keys)).await.unwrap();
    let _challenge = json_frame(first.recv().await);
    let mut second = connected.link.open("auth", open_auth_args(&phone_keys())).await.unwrap();
    assert_eq!(drain(&mut second).await.1, "busy");
    assert!(fixture.events.as_ref().unwrap().lock().await.try_recv().is_err());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn after_a_refusal_new_keys_for_that_phone_ask_nothing() {
    let fixture = fixture_with(FakeOptions::default(), true).await;
    let keys = phone_keys();
    let connected = connect(&fixture, TransportKind::WireGuard).await.expect("dial");
    let mut channel = auth(&connected.link, &fixture, &keys, &keys.identity, "pair").await;
    assert_eq!(json_frame(channel.recv().await), serde_json::json!({"pending": true}));
    let _ = fixture.events.as_ref().unwrap().lock().await.recv().await;
    fixture.trust.as_ref().unwrap().send_replace(Some(DeviceTrust {
        devices: vec![],
        denied: vec![DeniedDevice { id: fixture.phone_id.clone(), identity_key: keys.identity_hex.clone() }],
    }));
    assert_eq!(drain(&mut channel).await.1, "denied");
    // A fresh key pair from the same device id: refused, and the Mac is not asked.
    let fresh = phone_keys();
    let mut again = auth(&connected.link, &fixture, &fresh, &fresh.identity, "pair").await;
    assert_eq!(drain(&mut again).await.1, "rate_limited");
    assert!(fixture.events.as_ref().unwrap().lock().await.try_recv().is_err());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_paired_phone_is_not_asked_before_the_app_sends_its_devices() {
    let fixture = fixture_trust(FakeOptions::default(), true, false).await;
    let keys = phone_keys();
    let connected = connect(&fixture, TransportKind::WireGuard).await.expect("dial");
    let mut channel = auth(&connected.link, &fixture, &keys, &keys.identity, "pair").await;
    // The list arrives and names this phone: it passes without a prompt (an
    // early prompt would still be queued below).
    fixture.trust.as_ref().unwrap().send_replace(Some(trusting(&fixture, &keys)));
    assert_eq!(json_frame(channel.recv().await), serde_json::json!({"ok": true}));
    assert!(fixture.events.as_ref().unwrap().lock().await.try_recv().is_err());
}

// ---- Mac identity and signed Chief answers (#13742 gaps 1 and 2) ----

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_mac_proves_its_key_and_a_chief_answer_needs_the_phones_signature() {
    use ring::signature::KeyPair;
    let fixture = fixture_with(FakeOptions::default(), true).await;
    let approval = p256();
    let keys = PhoneKeys { approval_hex: hex(approval.public_key().as_ref()), ..phone_keys() };
    fixture.trust.as_ref().unwrap().send_replace(Some(trusting(&fixture, &keys)));
    let connected = connect(&fixture, TransportKind::WireGuard).await.expect("dial");
    let link = &connected.link;

    // auth with the phone's nonce: the challenge carries the Mac's key and its
    // signature over this phone, nonce and challenge.
    let phone_nonce = "pinnonce0123456789abcdef";
    let mut channel = link
        .open(
            "auth",
            serde_json::json!({"identityKey": keys.identity_hex, "approvalKey": keys.approval_hex,
                               "name": "Test iPhone", "action": "pair", "macNonce": phone_nonce}),
        )
        .await
        .unwrap();
    let challenge = json_frame(channel.recv().await);
    let nonce = challenge["challenge"].as_str().unwrap();
    assert_eq!(challenge["macKey"].as_str(), fixture.mac_key.as_deref());
    let proof = mac_proof_message(&fixture.mac_id, &fixture.phone_id, phone_nonce, nonce);
    let mac_key = fixture.mac_key.as_deref().unwrap();
    assert!(cmux_mobile_host::pairing::verify(mac_key, &proof, challenge["macSignature"].as_str().unwrap()));
    // The same proof does not hold for another phone nonce (no replay).
    let other = mac_proof_message(&fixture.mac_id, &fixture.phone_id, "othernonce0123456789", nonce);
    assert!(!cmux_mobile_host::pairing::verify(mac_key, &other, challenge["macSignature"].as_str().unwrap()));
    let message = challenge_message(
        &fixture.mac_id,
        &fixture.phone_id,
        nonce,
        &keys.identity_hex,
        &keys.approval_hex,
        "pair",
    );
    let signature = hex(keys.identity.sign(&ring::rand::SystemRandom::new(), &message).unwrap().as_ref());
    channel.send(Bytes::from(serde_json::json!({"signature": signature}).to_string())).await.unwrap();
    assert_eq!(json_frame(channel.recv().await), serde_json::json!({"ok": true}));

    // Chief: an unsigned answer is refused before it reaches the owner; the
    // phone's signed one passes, without its approval field.
    let mut chief = link.open("chief", serde_json::json!({})).await.unwrap();
    let mut buffer = Vec::new();
    chief.send(Bytes::from_static(b"{\"id\":\"l\",\"cmd\":\"conversation-list\"}\n")).await.unwrap();
    let list = next_line(&mut chief, &mut buffer).await;
    assert_eq!(list["id"], "l");
    let op = serde_json::json!({"kind": "question.answer", "message_id": "msg_Q", "part_index": 0,
                                "answer": {"selections": {"q": ["yes"]}}});
    let unsigned = serde_json::json!({"id": "a1", "cmd": "conversation-op", "conversation": "conv_CHIEF",
                                      "idempotency_key": "k1", "op": op});
    chief.send(Bytes::from(format!("{unsigned}\n"))).await.unwrap();
    let refused = next_line(&mut chief, &mut buffer).await;
    assert_eq!(refused["id"], "a1");
    assert_eq!(refused["error_code"], "forbidden", "{refused}");
    let expires = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() + 60;
    let digest = cmux_mobile_host::chief_answers::answer_digest(&op["answer"]);
    let signed_bytes = cmux_mobile_host::chief_answers::message(&cmux_mobile_host::chief_answers::Parts {
        mac: &fixture.mac_id,
        approver: &fixture.phone_id,
        conversation: "conv_CHIEF",
        message_id: "msg_Q",
        part_index: 0,
        nonce: "answernonce0123456789",
        expires_at: expires,
        answer: &digest,
    });
    let signature = hex(approval.sign(&ring::rand::SystemRandom::new(), &signed_bytes).unwrap().as_ref());
    let mut signed = unsigned.clone();
    signed["id"] = serde_json::json!("a2");
    signed["approval"] = serde_json::json!({"approver": fixture.phone_id, "nonce": "answernonce0123456789",
                                            "expiresAt": expires, "signature": signature});
    chief.send(Bytes::from(format!("{signed}\n"))).await.unwrap();
    let passed = next_line(&mut chief, &mut buffer).await;
    assert_eq!(passed["id"], "a2");
    assert_eq!(passed["data"]["cmd"], "conversation-op", "{passed}");
    // The same approval again is spent.
    signed["id"] = serde_json::json!("a3");
    chief.send(Bytes::from(format!("{signed}\n"))).await.unwrap();
    let replay = next_line(&mut chief, &mut buffer).await;
    assert_eq!(replay["error_code"], "forbidden", "{replay}");
}

/// A phone that closes its terminal channel on purpose (a tab it left, an
/// older phone that does not release first) gets its terminal sizes released
/// by the Mac before the daemon socket closes, so the daemon never takes the
/// close for a dropped link and holds the grid (PROTOCOL.md "Terminal size
/// claims").
/// A v2 `auth` (`proofVersion` 2) on a WireGuard link: the challenge says v2, and the Mac's
/// proof covers the tunnel's two static keys as both ends of the real tunnel see them.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_identity_proofs_cover_the_wireguard_keys() {
    let fixture = fixture_with(FakeOptions::default(), true).await;
    let keys = phone_keys();
    fixture.trust.as_ref().unwrap().send_replace(Some(trusting(&fixture, &keys)));
    let connected = connect(&fixture, TransportKind::WireGuard).await.expect("dial");
    let tunnel = connected.tunnel_keys.clone().expect("a WireGuard link has tunnel keys");
    assert_ne!(tunnel.dialer, tunnel.answerer);
    let phone_nonce = "pinnonce0123456789abcdef";
    let (mut channel, challenge) = open_v2(&connected.link, &keys, phone_nonce).await;
    assert_eq!(challenge["proofVersion"], "2");
    let nonce = challenge["challenge"].as_str().unwrap().to_owned();
    let mac_key = fixture.mac_key.as_deref().unwrap();
    let mac_signature = challenge["macSignature"].as_str().unwrap();
    // The proof holds over this phone's own tunnel keys (so the Mac's tunnel has the same ones),
    // and neither over v1's message nor over other keys.
    let proof = mac_proof_message_v2(&fixture.mac_id, &fixture.phone_id, phone_nonce, &nonce, &tunnel);
    assert!(cmux_mobile_host::pairing::verify(mac_key, &proof, mac_signature));
    let v1 = mac_proof_message(&fixture.mac_id, &fixture.phone_id, phone_nonce, &nonce);
    assert!(!cmux_mobile_host::pairing::verify(mac_key, &v1, mac_signature));
    let swapped = TunnelKeys { dialer: tunnel.answerer.clone(), answerer: tunnel.dialer.clone() };
    let other = mac_proof_message_v2(&fixture.mac_id, &fixture.phone_id, phone_nonce, &nonce, &swapped);
    assert!(!cmux_mobile_host::pairing::verify(mac_key, &other, mac_signature));
    sign_v2(&mut channel, &fixture, &keys, &nonce, &tunnel).await;
    assert_eq!(json_frame(channel.recv().await), serde_json::json!({"ok": true}));
}

/// A hub in the signaling path that ran its own tunnel to each side and relayed `auth` between
/// them: the phone's tunnel then has the hub's key as its answerer, the Mac's the hub's as its
/// dialer. The phone signs the keys it handshook with; the Mac, checking the keys it handshook
/// with, refuses, and its proof does not hold for the phone's keys either.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_relayed_auth_with_other_wireguard_keys_is_refused() {
    let fixture = fixture_with(FakeOptions::default(), true).await;
    let keys = phone_keys();
    fixture.trust.as_ref().unwrap().send_replace(Some(trusting(&fixture, &keys)));
    // The hub's tunnel to the Mac: the real link, whose dialer key is the hub's.
    let hub_to_mac = connect(&fixture, TransportKind::WireGuard).await.expect("dial");
    let mac_side = hub_to_mac.tunnel_keys.clone().unwrap();
    // The phone's tunnel to the hub: the phone's own key, and the hub's other key as answerer.
    let hub_key = |seed: u8| {
        use base64::Engine as _;
        base64::engine::general_purpose::STANDARD.encode([seed; 32])
    };
    let phone_side = TunnelKeys { dialer: hub_key(1), answerer: hub_key(2) };
    assert_ne!(phone_side, mac_side);
    let phone_nonce = "pinnonce0123456789abcdef";
    let (mut channel, challenge) = open_v2(&hub_to_mac.link, &keys, phone_nonce).await;
    let nonce = challenge["challenge"].as_str().unwrap().to_owned();
    // The phone checks the Mac's proof over its own tunnel's keys: it does not hold.
    let proof = mac_proof_message_v2(&fixture.mac_id, &fixture.phone_id, phone_nonce, &nonce, &phone_side);
    let mac_key = fixture.mac_key.as_deref().unwrap();
    assert!(!cmux_mobile_host::pairing::verify(mac_key, &proof, challenge["macSignature"].as_str().unwrap()));
    // Relayed anyway, the phone's signature over its keys is refused by the Mac.
    sign_v2(&mut channel, &fixture, &keys, &nonce, &phone_side).await;
    let (code, _) = close_reason(&mut channel).await;
    assert_eq!(code, "unpaired");
    // A v1 signature on a link that asked for v2 is refused too (no downgrade inside the Mac).
    let (mut channel, challenge) = open_v2(&hub_to_mac.link, &keys, phone_nonce).await;
    let nonce = challenge["challenge"].as_str().unwrap();
    let message = challenge_message(
        &fixture.mac_id,
        &fixture.phone_id,
        nonce,
        &keys.identity_hex,
        &keys.approval_hex,
        "pair",
    );
    let signature = hex(keys.identity.sign(&ring::rand::SystemRandom::new(), &message).unwrap().as_ref());
    channel.send(Bytes::from(serde_json::json!({"signature": signature}).to_string())).await.unwrap();
    let (code, _) = close_reason(&mut channel).await;
    assert_eq!(code, "unpaired");
}

/// Opens a v2 `auth` with the phone's nonce and returns the channel and its challenge.
async fn open_v2(
    link: &cmux_mobile_link::Link,
    keys: &PhoneKeys,
    phone_nonce: &str,
) -> (Channel, serde_json::Value) {
    let mut channel = link
        .open(
            "auth",
            serde_json::json!({"identityKey": keys.identity_hex, "approvalKey": keys.approval_hex,
                               "name": "Test iPhone", "action": "pair", "macNonce": phone_nonce,
                               "proofVersion": "2"}),
        )
        .await
        .unwrap();
    let challenge = json_frame(channel.recv().await);
    (channel, challenge)
}

/// Signs a v2 challenge over `tunnel` and sends the signature.
async fn sign_v2(
    channel: &mut Channel,
    fixture: &Fixture,
    keys: &PhoneKeys,
    nonce: &str,
    tunnel: &TunnelKeys,
) {
    let message = challenge_message_v2(
        &fixture.mac_id,
        &fixture.phone_id,
        nonce,
        &keys.identity_hex,
        &keys.approval_hex,
        "pair",
        tunnel,
    );
    let signature = hex(keys.identity.sign(&ring::rand::SystemRandom::new(), &message).unwrap().as_ref());
    channel.send(Bytes::from(serde_json::json!({"signature": signature}).to_string())).await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_terminal_channel_the_phone_closes_releases_its_sizes() {
    let fixture = fixture(FakeOptions::default()).await;
    let connected = connect(&fixture, TransportKind::WebRtc).await.expect("dial");
    let mut daemon = connected.link.open("daemon", serde_json::json!({})).await.unwrap();
    daemon
        .send(Bytes::from_static(
            b"{\"id\":1,\"cmd\":\"attach-surface\",\"surface\":7,\"cols\":53,\"rows\":42}\n{\"id\":2,\"cmd\":\"resize-surface\",\"surface\":9,\"cols\":53,\"rows\":42}\n",
        ))
        .await
        .unwrap();
    let mut buffer = Vec::new();
    for _ in 0..2 {
        next_line(&mut daemon, &mut buffer).await;
    }
    daemon.close("eof", "").await;
    let released = |lines: &[serde_json::Value]| {
        let mut surfaces = lines
            .iter()
            .filter(|line| line["cmd"] == "release-surface-size")
            .filter_map(|line| line["surface"].as_u64())
            .collect::<Vec<_>>();
        surfaces.sort_unstable();
        surfaces
    };
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    loop {
        let lines = fixture.daemon_lines.lock().unwrap().clone();
        if released(&lines) == [7, 9] {
            break;
        }
        assert!(std::time::Instant::now() < deadline, "no releases after the phone closed: {lines:?}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// The same on a busy terminal: output keeps coming while the phone closes,
/// so the Mac's send to the phone fails first; the release still goes out.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_busy_terminal_channel_the_phone_closes_still_releases_its_size() {
    let fixture = fixture(FakeOptions::default()).await;
    let connected = connect(&fixture, TransportKind::WebRtc).await.expect("dial");
    let mut daemon = connected.link.open("daemon", serde_json::json!({})).await.unwrap();
    daemon
        .send(Bytes::from_static(
            b"{\"id\":1,\"cmd\":\"attach-surface\",\"surface\":7,\"cols\":53,\"rows\":42,\"busy\":true}\n",
        ))
        .await
        .unwrap();
    let mut buffer = Vec::new();
    next_line(&mut daemon, &mut buffer).await;
    daemon.close("eof", "").await;
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    loop {
        let lines = fixture.daemon_lines.lock().unwrap().clone();
        if lines.iter().any(|line| line["cmd"] == "release-surface-size" && line["surface"] == 7) {
            break;
        }
        assert!(std::time::Instant::now() < deadline, "no release after a busy channel closed: {lines:?}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// A Mac file opened for preview has no size cap (Leo, 2026-10-26: "WE NEED ARBITARRILY
/// LARGE FILES OF ANY TYPE"): a sparse file past the old 64 MiB cap streams whole, and no
/// message the phone receives is larger than one link data chunk, so neither side holds
/// the file in memory. The test hashes as it reads and checks the length and SHA-256.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_file_past_the_old_64_mib_cap_streams_whole_in_bounded_chunks() {
    use sha2::{Digest, Sha256};
    use std::io::{Read, Seek, SeekFrom, Write};

    let size: u64 = (64 << 20) + (1 << 20) + 7;
    let fixture = fixture(FakeOptions::default()).await;
    let path = fixture.root.join("big.bin");
    {
        let mut file = std::fs::File::create(&path).unwrap();
        file.set_len(size).unwrap();
        // Marks at the start, across the old cap and at the end, so the hash sees order.
        for (offset, mark) in [(0, b"start".as_slice()), (64 << 20, b"cap"), (size - 3, b"end")] {
            file.seek(SeekFrom::Start(offset)).unwrap();
            file.write_all(mark).unwrap();
        }
    }
    let expected = {
        let mut hasher = Sha256::new();
        let mut file = std::fs::File::open(&path).unwrap();
        let mut buffer = vec![0u8; 1 << 20];
        loop {
            let read = file.read(&mut buffer).unwrap();
            if read == 0 {
                break;
            }
            hasher.update(&buffer[..read]);
        }
        hasher.finalize()
    };

    let connected = connect(&fixture, TransportKind::WireGuard).await.expect("dial");
    for service in ["file", "file-preview"] {
        let mut channel =
            connected.link.open(service, serde_json::json!({"path": path.to_str().unwrap()})).await.unwrap();
        if service == "file-preview" {
            assert_eq!(json_frame(channel.recv().await), serde_json::json!({"size": size}));
        }
        let mut hasher = Sha256::new();
        let (mut received, mut largest): (u64, usize) = (0, 0);
        let code = loop {
            match tokio::time::timeout(Duration::from_secs(30), channel.recv()).await.expect("in time") {
                Some(ChannelEvent::Data(data)) => {
                    largest = largest.max(data.len());
                    received += data.len() as u64;
                    hasher.update(&data);
                }
                Some(ChannelEvent::Closed(info)) => break format!("{} {}", info.code, info.reason),
                None => break "none".into(),
            }
        };
        assert_eq!(code.trim(), "eof", "the Mac refused or cut the file");
        assert_eq!(received, size);
        assert_eq!(hasher.finalize(), expected);
        assert!(
            largest <= cmux_mobile_link::link::DATA_CHUNK,
            "a message of {largest} bytes: the file must stream in chunks of at most {}",
            cmux_mobile_link::link::DATA_CHUNK
        );
    }
}

/// One `{"op":"traffic"}` request on the link socket and its answer line.
async fn traffic_over(path: &std::path::Path) -> serde_json::Value {
    let stream = tokio::net::UnixStream::connect(path).await.expect("link socket");
    let (read, mut write) = stream.into_split();
    write.write_all(b"{\"op\":\"traffic\"}\n").await.unwrap();
    let mut line = String::new();
    BufReader::new(read).read_line(&mut line).await.unwrap();
    serde_json::from_str(&line).unwrap()
}

/// `(in_bytes, out_bytes)` of one service row of a traffic answer.
fn traffic_row(answer: &serde_json::Value, service: &str) -> (u64, u64) {
    let row = answer["services"].as_array().unwrap().iter().find(|row| row["service"] == service).unwrap();
    (row["in_bytes"].as_u64().unwrap(), row["out_bytes"].as_u64().unwrap())
}

/// `cmux device traffic` end to end: a phone dials this host over WireGuard
/// through the fake signaling server and moves known bytes through `echo`;
/// the host's real link socket (`<session>.link.sock`, link_socket.rs) then
/// answers `{"op":"traffic"}` with them under `control`, both ways. With
/// CMUX_TRAFFIC_CLI naming a cmux-tui binary, the CLI's own
/// `device traffic --json` and table read the same socket. Other tests of
/// this binary share the process's counters, so the checks are lower bounds.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn device_traffic_reads_back_a_phones_bytes_over_the_link_socket() {
    use cmux_mobile_host::auth::{TokenSource, Tokens};
    use cmux_mobile_host::link_socket::{Dialer, serve, socket_path};
    let fixture = fixture(FakeOptions::default()).await;
    let dir = tempfile::tempdir().unwrap();
    let daemon_socket = dir.path().join("traffic.sock");
    let path = socket_path(&daemon_socket);
    let dialer = Arc::new(Dialer {
        device_id: "this-mac".into(),
        device_name: "This Mac".into(),
        base_url: "http://127.0.0.1:9".into(),
        tokens: Arc::new(Tokens::new(TokenSource::Access("unused".into()))),
        ice: IceSource::Fixed(Vec::new()),
        signaling: tokio::sync::watch::channel(None).1,
        identity: tokio::sync::watch::channel(None).1,
        activity: Arc::new(cmux_mobile_host::activity::Activity::memory()),
        links: Default::default(),
        build_space: None,
        pairing: None,
    });
    let server = tokio::spawn(serve(path.clone(), dialer));
    for _ in 0..200 {
        if path.exists() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let before = traffic_over(&path).await;
    assert_eq!(before["ok"], true, "{before}");
    assert_eq!(before["pid"], std::process::id(), "{before}");

    let connected = connect(&fixture, TransportKind::WireGuard).await.expect("dial");
    let mut echo = connected.link.open("echo", serde_json::json!({})).await.unwrap();
    const BYTES: usize = 300_000;
    echo.send(Bytes::from(vec![7u8; BYTES])).await.unwrap();
    let mut got = 0;
    while got < BYTES {
        match echo.recv().await {
            Some(ChannelEvent::Data(data)) => got += data.len(),
            other => panic!("echo ended early: {other:?}"),
        }
    }

    let after = traffic_over(&path).await;
    eprintln!("link socket {{\"op\":\"traffic\"}}: {after}");
    let (in_before, out_before) = traffic_row(&before, "control");
    let (in_after, out_after) = traffic_row(&after, "control");
    assert!(in_after - in_before >= BYTES as u64, "control IN grew {} < {BYTES}", in_after - in_before);
    assert!(out_after - out_before >= BYTES as u64, "control OUT grew {} < {BYTES}", out_after - out_before);
    let total_in = |a: &serde_json::Value| a["total"]["in_bytes"].as_u64().unwrap();
    assert!(total_in(&after) - total_in(&before) >= BYTES as u64, "{after}");

    if let Some(cli) = std::env::var_os("CMUX_TRAFFIC_CLI") {
        // As typed in a cmux terminal (the session socket from the environment),
        // and with --socket for the table.
        let json = tokio::process::Command::new(&cli)
            .args(["device", "traffic", "--json"])
            .env("CMUX_TUI_SOCKET", &daemon_socket)
            .output()
            .await
            .expect("cmux device traffic --json");
        let stdout = String::from_utf8_lossy(&json.stdout);
        eprintln!("cmux device traffic --json (rc {:?}): {stdout}", json.status.code());
        eprintln!("stderr: {}", String::from_utf8_lossy(&json.stderr));
        assert!(json.status.success());
        let answer: serde_json::Value = serde_json::from_str(stdout.trim()).unwrap();
        assert_eq!(answer["pid"], std::process::id());
        let (cli_in, cli_out) = traffic_row(&answer, "control");
        assert!(cli_in >= in_after && cli_out >= out_after, "{answer}");
        let table = tokio::process::Command::new(&cli)
            .arg("--socket")
            .arg(&daemon_socket)
            .args(["device", "traffic"])
            .output()
            .await
            .expect("cmux device traffic");
        let text = String::from_utf8_lossy(&table.stdout);
        eprintln!("cmux device traffic (rc {:?}):\n{text}", table.status.code());
        assert!(table.status.success());
        assert!(text.lines().any(|line| line.starts_with("control")), "{text}");
        assert!(text.lines().any(|line| line.starts_with("total")), "{text}");
    }
    server.abort();
}

// ---- Answering a pairing request from another paired device (src/pair_requests.rs) ----

/// `auth` as `device` (not the fixture's phone), signed by its own identity key.
async fn auth_device(
    link: &cmux_mobile_link::Link,
    fixture: &Fixture,
    device: &str,
    keys: &PhoneKeys,
) -> Channel {
    let mut channel = link.open("auth", open_auth_args(keys)).await.unwrap();
    let challenge = json_frame(channel.recv().await);
    let message = challenge_message(
        &fixture.mac_id,
        device,
        challenge["challenge"].as_str().unwrap(),
        &keys.identity_hex,
        &keys.approval_hex,
        "pair",
    );
    let signature = hex(keys.identity.sign(&ring::rand::SystemRandom::new(), &message).unwrap().as_ref());
    channel.send(Bytes::from(serde_json::json!({"signature": signature}).to_string())).await.unwrap();
    channel
}

/// One `pair-requests` request: its answer and the close code.
async fn pair_requests(
    link: &cmux_mobile_link::Link,
    args: serde_json::Value,
) -> (serde_json::Value, String) {
    let mut channel = link.open("pair-requests", args).await.unwrap();
    let (bytes, code) = drain(&mut channel).await;
    (serde_json::from_slice(&bytes).unwrap_or(serde_json::Value::Null), code)
}

/// Leo, 2026-11-22: "ok surely we dont need to be bottled this hard by a click". A probe phone of
/// the same account waits for its pairing; the person's phone, already paired with this Mac,
/// lists it and allows it over its own link, and the Mac pairs it with no gesture on the Mac. A
/// device of another account never reaches the Mac, a token alone opens nothing, and an answer
/// with nothing waiting says so.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_paired_device_of_the_same_account_approves_a_waiting_request() {
    let fixture = fixture_with(FakeOptions::default(), true).await;
    let trust = fixture.trust.as_ref().unwrap();
    let base_url = fixture._server.base_url.clone();

    // The person's phone, paired already.
    let leo = phone_keys();
    trust.send_replace(Some(trusting(&fixture, &leo)));
    let leo_link = connect(&fixture, TransportKind::WireGuard).await.expect("dial").link;
    let mut channel = auth(&leo_link, &fixture, &leo, &leo.identity, "pair").await;
    assert_eq!(json_frame(channel.recv().await), serde_json::json!({"ok": true}));

    // Nothing waits yet.
    let (answer, code) = pair_requests(&leo_link, serde_json::json!({"action": "list"})).await;
    assert_eq!((answer, code.as_str()), (serde_json::json!({"requests": []}), "eof"));
    let (_, code) = pair_requests(
        &leo_link,
        serde_json::json!({"action": "answer", "deviceId": "nobody", "fingerprint": "abcdef01", "allow": true}),
    )
    .await;
    assert_eq!(code, "no_waiting_request");

    // A probe phone of the same account asks to pair and waits.
    let probe_id = uuid::Uuid::new_v4().to_string();
    let probe_client = SignalingClient::connect(&base_url, "user:alice", "team", &probe_id).await.unwrap();
    let probe_link = cmux_mobile_link::dial::connect(
        &probe_client,
        &fixture.mac_id,
        TransportKind::WireGuard,
        &options(),
        LinkConfig::default(),
    )
    .await
    .expect("dial")
    .link;
    // Before its own `auth` passed, the probe opens nothing, this service included.
    let (_, code) = pair_requests(&probe_link, serde_json::json!({"action": "list"})).await;
    assert_eq!(code, "unpaired");
    let probe = phone_keys();
    let mut probe_auth = auth_device(&probe_link, &fixture, &probe_id, &probe).await;
    assert_eq!(json_frame(probe_auth.recv().await), serde_json::json!({"pending": true}));
    assert!(matches!(
        fixture.events.as_ref().unwrap().lock().await.recv().await,
        Some(Event::PairRequest { phone_device_id, .. }) if phone_device_id == probe_id
    ));

    // The person's phone lists it with the fingerprint the Mac's prompt shows, and allows it.
    let (answer, code) = pair_requests(&leo_link, serde_json::json!({"action": "list"})).await;
    assert_eq!(code, "eof");
    let listed = &answer["requests"][0];
    assert_eq!(listed["deviceId"], probe_id.as_str());
    assert_eq!(listed["kind"], "phone");
    let fingerprint = listed["fingerprint"].as_str().unwrap().to_owned();
    assert_eq!(fingerprint, cmux_mobile_host::pair_requests::fingerprint(&probe.approval_hex));
    let (answer, code) = pair_requests(
        &leo_link,
        serde_json::json!({"action": "answer", "deviceId": probe_id, "fingerprint": &fingerprint[..8], "allow": true}),
    )
    .await;
    assert_eq!((answer, code.as_str()), (serde_json::json!({"ok": true}), "eof"));
    assert_eq!(
        fixture.events.as_ref().unwrap().lock().await.recv().await,
        Some(Event::PairAnswer {
            phone_device_id: probe_id.clone(),
            identity_key: probe.identity_hex.clone(),
            approval_key: probe.approval_hex.clone(),
            allow: true,
            by_device_id: fixture.phone_id.clone(),
        })
    );
    // The app approves it as the person's Allow would: the probe's waiting `auth` passes.
    let mut both = trusting(&fixture, &leo);
    both.devices.push(TrustedDevice {
        id: probe_id.clone(),
        identity_key: probe.identity_hex.clone(),
        approval_key: probe.approval_hex.clone(),
        ..Default::default()
    });
    trust.send_replace(Some(both));
    assert_eq!(json_frame(probe_auth.recv().await), serde_json::json!({"ok": true}));

    // Once answered, nothing waits: a second answer is a clear error.
    let (_, code) = pair_requests(
        &leo_link,
        serde_json::json!({"action": "answer", "deviceId": probe_id, "fingerprint": fingerprint, "allow": true}),
    )
    .await;
    assert_eq!(code, "no_waiting_request");

    // A device of another account never gets a link to this Mac at all.
    let mallory =
        SignalingClient::connect(&base_url, "user:mallory", "team", &uuid::Uuid::new_v4().to_string())
            .await
            .unwrap();
    let quick = DialOptions { timeout: Duration::from_secs(5), ..options() };
    let refused = cmux_mobile_link::dial::connect(
        &mallory,
        &fixture.mac_id,
        TransportKind::WireGuard,
        &quick,
        LinkConfig::default(),
    )
    .await;
    assert!(refused.is_err(), "another account's device reached the Mac");
}

/// Every line the link socket answers to one request, until it ends.
async fn link_socket_lines(path: &std::path::Path, request: serde_json::Value) -> Vec<serde_json::Value> {
    let stream = tokio::net::UnixStream::connect(path).await.expect("link socket");
    let (read, mut write) = stream.into_split();
    write.write_all(format!("{request}\n").as_bytes()).await.unwrap();
    let mut lines = BufReader::new(read).lines();
    let mut out = Vec::new();
    while let Ok(Ok(Some(line))) = tokio::time::timeout(Duration::from_secs(60), lines.next_line()).await {
        out.push(serde_json::from_str(&line).unwrap_or_else(|_| panic!("not JSON: {line}")));
    }
    out
}

/// `cmux mobile pair-requests` end to end: another Mac of the same account, paired here as a
/// machine, reaches this Mac through its own hostd's link socket (link_socket.rs, as `cmux machine
/// NAME doctor` does), lists the probe phone waiting to pair and allows it; with `closeLine` each
/// refusal comes back as a last `{"error":CODE}` line (not a bare end). Without Control the
/// machine opens nothing; with CMUX_PAIR_REQUESTS_CLI naming a cmux-tui binary, the CLI's own
/// `mobile pair-requests list|allow` drive the same socket.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_paired_mac_lists_and_allows_a_waiting_request_over_its_link_socket() {
    use cmux_mobile_host::auth::{TokenSource, Tokens};
    use cmux_mobile_host::link_socket::{Dialer, serve, socket_path};
    use cmux_mobile_host::peer::{Grant, PeerKind};
    let fixture = fixture_with(FakeOptions::default(), true).await;
    let trust = fixture.trust.as_ref().unwrap();
    let base_url = fixture._server.base_url.clone();

    // The other Mac: its own hostd's dialer, paired here as a Mac.
    let studio_id = uuid::Uuid::new_v4().to_string();
    let studio_identity = MacIdentity::generate().unwrap();
    let studio_key = studio_identity.public_key().to_owned();
    let granting = |grants: Vec<Grant>| DeviceTrust {
        devices: vec![TrustedDevice {
            id: studio_id.clone(),
            identity_key: studio_key.clone(),
            approval_key: String::new(),
            kind: PeerKind::Mac,
            grants,
        }],
        denied: vec![],
    };
    trust.send_replace(Some(granting(vec![Grant::View])));
    let signaling = SignalingClient::connect(&base_url, "user:alice", "team", &studio_id).await.unwrap();
    let dir = tempfile::tempdir().unwrap();
    let daemon_socket = dir.path().join("studio.sock");
    let path = socket_path(&daemon_socket);
    let dialer = Arc::new(Dialer {
        device_id: studio_id.clone(),
        device_name: "Studio".into(),
        base_url: "http://127.0.0.1:9".into(),
        tokens: Arc::new(Tokens::new(TokenSource::Access("unused".into()))),
        ice: IceSource::Fixed(Vec::new()),
        signaling: tokio::sync::watch::channel(Some(signaling)).1,
        identity: tokio::sync::watch::channel(Some(studio_identity)).1,
        activity: Arc::new(cmux_mobile_host::activity::Activity::memory()),
        links: Default::default(),
        build_space: None,
        pairing: None,
    });
    let server = tokio::spawn(serve(path.clone(), dialer));
    for _ in 0..200 {
        if path.exists() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let open = |args: serde_json::Value| {
        serde_json::json!({"op": "open", "peer": fixture.mac_id, "service": "pair-requests",
                           "args": args, "closeLine": true})
    };

    // Paired with View only: refused, and the code reaches the socket.
    let lines = link_socket_lines(&path, open(serde_json::json!({"action": "list"}))).await;
    assert_eq!(lines.first().map(|l| l["ok"].clone()), Some(serde_json::json!(true)), "{lines:?}");
    assert_eq!(lines.last().unwrap()["error"], "not_granted", "{lines:?}");

    // With Control: nothing waits yet, and an answer says so.
    trust.send_replace(Some(granting(vec![Grant::View, Grant::Control])));
    let lines = link_socket_lines(&path, open(serde_json::json!({"action": "list"}))).await;
    assert_eq!(lines.get(1), Some(&serde_json::json!({"requests": []})), "{lines:?}");
    assert_eq!(lines.len(), 2, "a clean end adds no line: {lines:?}");
    let lines = link_socket_lines(
        &path,
        open(serde_json::json!({"action": "answer", "deviceId": "nobody", "fingerprint": "abcdef01", "allow": true})),
    )
    .await;
    assert_eq!(lines.last().unwrap()["error"], "no_waiting_request", "{lines:?}");

    // A probe phone of the same account asks to pair and waits.
    let probe_id = uuid::Uuid::new_v4().to_string();
    let probe_client = SignalingClient::connect(&base_url, "user:alice", "team", &probe_id).await.unwrap();
    let probe_link = cmux_mobile_link::dial::connect(
        &probe_client,
        &fixture.mac_id,
        TransportKind::WireGuard,
        &options(),
        LinkConfig::default(),
    )
    .await
    .expect("dial")
    .link;
    let probe = phone_keys();
    let mut probe_auth = auth_device(&probe_link, &fixture, &probe_id, &probe).await;
    assert_eq!(json_frame(probe_auth.recv().await), serde_json::json!({"pending": true}));
    assert!(matches!(
        fixture.events.as_ref().unwrap().lock().await.recv().await,
        Some(Event::PairRequest { phone_device_id, .. }) if phone_device_id == probe_id
    ));
    let fingerprint = cmux_mobile_host::pair_requests::fingerprint(&probe.approval_hex);

    // A wrong key is refused by name.
    let lines = link_socket_lines(
        &path,
        open(serde_json::json!({"action": "answer", "deviceId": probe_id, "fingerprint": "00000000", "allow": true})),
    )
    .await;
    assert_eq!(lines.last().unwrap()["error"], "fingerprint_mismatch", "{lines:?}");

    if let Some(cli) = std::env::var_os("CMUX_PAIR_REQUESTS_CLI") {
        let run = |args: Vec<String>| {
            let cli = cli.clone();
            let daemon_socket = daemon_socket.clone();
            async move {
                let out = tokio::process::Command::new(&cli)
                    .args(&args)
                    .env("CMUX_TUI_SOCKET", &daemon_socket)
                    .output()
                    .await
                    .expect("cmux mobile pair-requests");
                let (stdout, stderr) = (
                    String::from_utf8_lossy(&out.stdout).into_owned(),
                    String::from_utf8_lossy(&out.stderr).into_owned(),
                );
                eprintln!("cmux {} (rc {:?}):\n{stdout}{stderr}", args.join(" "), out.status.code());
                (out.status.code(), stdout, stderr)
            }
        };
        let words = |text: String| text.split_whitespace().map(str::to_owned).collect::<Vec<_>>();
        let (rc, stdout, _) =
            run(words(format!("mobile pair-requests list --mac {} --json", fixture.mac_id))).await;
        assert_eq!(rc, Some(0));
        let listed: serde_json::Value = serde_json::from_str(stdout.trim()).unwrap();
        assert_eq!(listed["requests"][0]["deviceId"], probe_id.as_str());
        let (rc, stdout, _) = run(words(format!("mobile pair-requests list --mac {}", fixture.mac_id))).await;
        assert_eq!(rc, Some(0));
        assert!(stdout.contains(&format!("allow {probe_id} --fingerprint {fingerprint}")), "{stdout}");
        let (rc, _, stderr) = run(words(format!(
            "mobile pair-requests allow {probe_id} --fingerprint 00000000 --mac {}",
            fixture.mac_id
        )))
        .await;
        assert_eq!(rc, Some(1));
        assert!(stderr.contains("pair-requests list"), "the refusal names a next step: {stderr}");
        let (rc, stdout, _) = run(words(format!(
            "mobile pair-requests allow {probe_id} --fingerprint {} --mac {}",
            &fingerprint[..8],
            fixture.mac_id
        )))
        .await;
        assert_eq!(rc, Some(0));
        assert!(stdout.contains("allowed"), "{stdout}");
    } else {
        // The Mac's list shows the probe with the fingerprint its prompt shows; Studio allows it.
        let lines = link_socket_lines(&path, open(serde_json::json!({"action": "list"}))).await;
        assert_eq!(lines[1]["requests"][0]["deviceId"], probe_id.as_str(), "{lines:?}");
        assert_eq!(lines[1]["requests"][0]["fingerprint"], fingerprint.as_str(), "{lines:?}");
        let lines = link_socket_lines(
            &path,
            open(serde_json::json!({"action": "answer", "deviceId": probe_id,
                                    "fingerprint": &fingerprint[..8], "allow": true})),
        )
        .await;
        assert_eq!(lines.get(1), Some(&serde_json::json!({"ok": true})), "{lines:?}");
    }
    assert_eq!(
        fixture.events.as_ref().unwrap().lock().await.recv().await,
        Some(Event::PairAnswer {
            phone_device_id: probe_id.clone(),
            identity_key: probe.identity_hex.clone(),
            approval_key: probe.approval_hex.clone(),
            allow: true,
            by_device_id: studio_id.clone(),
        })
    );
    server.abort();
}

/// `cmux mobile pair-requests` with no `--mac`, on the Mac the request waits on: the owner-only
/// link socket (`{"op":"pair-requests"}`, link_socket.rs) lists the waiting request and answers it
/// as the app's Allow would, with no link and no remote peer involved. The fingerprint is still
/// required and checked. With CMUX_PAIR_REQUESTS_CLI naming a cmux-tui binary, the CLI's own
/// `mobile pair-requests list|allow` (no `--mac`) drive the same socket.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn this_mac_lists_and_allows_its_own_waiting_request_over_its_link_socket() {
    use cmux_mobile_host::auth::{TokenSource, Tokens};
    use cmux_mobile_host::link_socket::{Dialer, serve, socket_path};
    use cmux_mobile_host::pair_requests::{WaitingRequest, fingerprint};
    let events = Arc::new(std::sync::Mutex::new(Vec::new()));
    let sink = Arc::clone(&events);
    let pairing = Pairing::new(
        "this-mac".into(),
        tokio::sync::watch::channel(None).1,
        Arc::new(move |event| sink.lock().unwrap().push(event)),
    );
    let waiting = Arc::clone(&pairing.waiting);
    let probe = phone_keys();
    let probe_id = uuid::Uuid::new_v4().to_string();
    let _held = waiting.hold(WaitingRequest {
        device_id: probe_id.clone(),
        name: "Probe iPhone".into(),
        kind: cmux_mobile_host::peer::PeerKind::Phone,
        identity_key: probe.identity_hex.clone(),
        approval_key: probe.approval_hex.clone(),
        since: std::time::Instant::now(),
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon_socket = dir.path().join("local.sock");
    let path = socket_path(&daemon_socket);
    let dialer = Arc::new(Dialer {
        device_id: "this-mac".into(),
        device_name: "This Mac".into(),
        base_url: "http://127.0.0.1:9".into(),
        tokens: Arc::new(Tokens::new(TokenSource::Access("unused".into()))),
        ice: IceSource::Fixed(Vec::new()),
        signaling: tokio::sync::watch::channel(None).1,
        identity: tokio::sync::watch::channel(None).1,
        activity: Arc::clone(&pairing.activity),
        links: Default::default(),
        build_space: None,
        pairing: Some(pairing),
    });
    let server = tokio::spawn(serve(path.clone(), dialer));
    for _ in 0..200 {
        if path.exists() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "the local path is owner-only");
    }
    let local = |args: serde_json::Value| serde_json::json!({"op": "pair-requests", "args": args});
    let fingerprint = fingerprint(&probe.approval_hex);

    let lines = link_socket_lines(&path, local(serde_json::json!({"action": "list"}))).await;
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert_eq!(lines[0]["requests"][0]["deviceId"], probe_id.as_str(), "{lines:?}");
    assert_eq!(lines[0]["requests"][0]["fingerprint"], fingerprint.as_str(), "{lines:?}");
    // A wrong key, or none, is refused as over a link.
    let lines = link_socket_lines(
        &path,
        local(serde_json::json!({"action": "answer", "deviceId": probe_id, "fingerprint": "00000000", "allow": true})),
    )
    .await;
    assert_eq!(lines[0]["error"], "fingerprint_mismatch", "{lines:?}");
    let lines = link_socket_lines(
        &path,
        local(serde_json::json!({"action": "answer", "deviceId": probe_id, "allow": true})),
    )
    .await;
    assert_eq!(lines[0]["error"], "bad_request", "{lines:?}");
    assert!(events.lock().unwrap().is_empty());

    if let Some(cli) = std::env::var_os("CMUX_PAIR_REQUESTS_CLI") {
        let run = |args: &str| {
            let out = std::process::Command::new(&cli)
                .args(args.split_whitespace())
                .env("CMUX_TUI_SOCKET", &daemon_socket)
                .output()
                .expect("cmux mobile pair-requests");
            let (stdout, stderr) = (
                String::from_utf8_lossy(&out.stdout).into_owned(),
                String::from_utf8_lossy(&out.stderr).into_owned(),
            );
            eprintln!("cmux {args} (rc {:?}):\n{stdout}{stderr}", out.status.code());
            (out.status.code(), stdout, stderr)
        };
        let (rc, stdout, _) = run("mobile pair-requests list");
        assert_eq!(rc, Some(0));
        assert!(stdout.contains(&format!("allow {probe_id} --fingerprint {fingerprint}\n")), "{stdout}");
        let (rc, _, stderr) = run(&format!("mobile pair-requests allow {probe_id} --fingerprint 00000000"));
        assert_eq!(rc, Some(1));
        assert!(stderr.contains("cmux mobile pair-requests list"), "{stderr}");
        let (rc, stdout, _) =
            run(&format!("mobile pair-requests allow {probe_id} --fingerprint {}", &fingerprint[..8]));
        assert_eq!(rc, Some(0));
        assert!(stdout.contains("allowed"), "{stdout}");
    } else {
        let lines = link_socket_lines(
            &path,
            local(serde_json::json!({"action": "answer", "deviceId": probe_id,
                                     "fingerprint": &fingerprint[..8], "allow": true})),
        )
        .await;
        assert_eq!(lines, vec![serde_json::json!({"ok": true})]);
    }
    assert_eq!(
        *events.lock().unwrap(),
        vec![Event::PairAnswer {
            phone_device_id: probe_id.clone(),
            identity_key: probe.identity_hex.clone(),
            approval_key: probe.approval_hex.clone(),
            allow: true,
            by_device_id: "this-mac".into(),
        }]
    );
    server.abort();
}

/// The scripted terminal's first screen and its `i`th output batch (`fake_daemon`).
const SCRIPTED_PROMPT: &[u8] = b"$ ";

fn scripted_line(i: u64) -> String {
    format!("line {i}\r\n")
}

fn b64(bytes: &[u8]) -> String {
    use base64::Engine as _;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn unb64(line: &serde_json::Value, field: &str) -> Vec<u8> {
    use base64::Engine as _;
    line[field]
        .as_str()
        .map_or_else(Vec::new, |data| base64::engine::general_purpose::STANDARD.decode(data).unwrap())
}

/// A screen's visible text, row by row (wide tails and blanks are "").
fn screen_text(screen: &cmux_terminal_projection::sync::ScreenState) -> String {
    (0..screen.rows)
        .map(|row| screen.row(row).iter().map(|cell| cell.text.as_str()).collect::<String>())
        .collect::<Vec<_>>()
        .join("\n")
}

fn history_text(term: &cmux_terminal_projection::Terminal) -> String {
    let rows =
        term.history.iter().map(|row| row.cells.iter().map(|&cell| term.cell_text(cell)).collect::<String>());
    rows.collect::<Vec<_>>().join("\n")
}

/// The phone's projection of one surface: `vt-state` resets it, `output` feeds it.
struct PhoneScreen {
    term: Option<cmux_terminal_projection::Terminal>,
    outputs: usize,
}

impl PhoneScreen {
    fn take(&mut self, line: &serde_json::Value) {
        match line["event"].as_str() {
            Some("vt-state") => {
                let cols = line["cols"].as_u64().unwrap() as usize;
                let rows = line["rows"].as_u64().unwrap() as usize;
                let mut term = cmux_terminal_projection::Terminal::new(
                    cols,
                    rows,
                    cmux_terminal_projection::DEFAULT_HISTORY_LIMIT,
                );
                for byte in unb64(line, "data").into_iter().chain(unb64(line, "pending")) {
                    term.advance(byte);
                }
                self.term = Some(term);
            }
            Some("output") => {
                self.outputs += 1;
                let term = self.term.as_mut().expect("an output after the vt-state");
                for byte in unb64(line, "data") {
                    term.advance(byte);
                }
            }
            _ => {}
        }
    }
}

/// The screen and scrollback the scripted terminal ends on (the host's model of it).
fn scripted_terminal(count: u64) -> cmux_terminal_projection::Terminal {
    let mut term =
        cmux_terminal_projection::Terminal::new(40, 8, cmux_terminal_projection::DEFAULT_HISTORY_LIMIT);
    let script = (0..count).flat_map(|i| scripted_line(i).into_bytes());
    for byte in SCRIPTED_PROMPT.iter().copied().chain(script) {
        term.advance(byte);
    }
    term
}

const SCRIPTED: u64 = 30;

fn scripted_attach() -> Bytes {
    let attach = serde_json::json!({"id": 1, "cmd": "attach-surface", "surface": 7, "cols": 40, "rows": 8,
        "scripted": SCRIPTED});
    Bytes::from(format!("{attach}\n"))
}

/// Viewport sync end to end over WireGuard (the datagram path forced): the phone's projection,
/// fed only `output`/`vt-state` lines from its wrapped receiver, ends on the host's screen,
/// injected outputs carried it, and the rows that scrolled off reached its scrollback.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn viewport_sync_brings_the_phone_to_the_hosts_screen_over_wireguard() {
    let selector = cmux_mobile_host::viewport_sync::SelectorConfig::datagram_first();
    let fixture = fixture_viewport(FakeOptions::default(), false, true, Some(selector)).await;
    let connected = connect(&fixture, TransportKind::WireGuard).await.expect("dial");
    assert!(connected.overlay.is_some(), "a WireGuard link rides an overlay");
    let daemon =
        connected.link.open("daemon", serde_json::json!({"pseq": true, "viewport_sync": 1})).await.unwrap();
    let (sender, receiver) = daemon.split();
    let mut phone =
        cmux_mobile_link::viewport::PhoneViewport::new(connected.overlay.as_ref(), true).wrap(receiver);
    sender.send(scripted_attach()).await.unwrap();
    let expected = scripted_terminal(SCRIPTED);
    let expected_screen = cmux_terminal_projection::sync::ScreenState::capture(&expected);
    let mut screen = PhoneScreen { term: None, outputs: 0 };
    let mut buffer = Vec::new();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(15);
    loop {
        let shown = screen.term.as_ref().map(cmux_terminal_projection::sync::ScreenState::capture);
        if let Some(shown) = &shown
            && shown.cells == expected_screen.cells
            && shown.cursor == expected_screen.cursor
        {
            break;
        }
        let event = tokio::time::timeout_at(deadline, phone.recv()).await;
        let data = match event {
            Ok(Some(ChannelEvent::Data(data))) => data,
            other => {
                let shown = shown.as_ref().map(screen_text).unwrap_or_default();
                let expected = screen_text(&expected_screen);
                panic!(
                    "the phone never showed the host's screen: {other:?}\nshown:\n{shown}\nexpected:\n{expected}"
                );
            }
        };
        buffer.extend_from_slice(&data);
        while let Some(newline) = buffer.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = buffer.drain(..=newline).collect();
            let line: serde_json::Value = serde_json::from_slice(&line).unwrap();
            let event = line["event"].as_str().unwrap_or_default();
            assert!(!event.starts_with("viewport-"), "the wrapper swallows viewport lines: {line}");
            screen.take(&line);
        }
    }
    // On the datagram path the host forwards no output line: every one the phone fed came from
    // the wrapper (its datagrams and the history lines).
    assert!(screen.outputs > 0, "an injected output");
    let history = history_text(screen.term.as_ref().unwrap());
    assert!(history.contains("$ line 0") && history.contains("line 20"), "the scrolled rows: {history:?}");
}

/// Reads `daemon`'s lines until `count` outputs passed; every line read, in order.
async fn read_outputs(daemon: &mut Channel, count: u64) -> Vec<serde_json::Value> {
    let mut buffer = Vec::new();
    let mut lines = Vec::new();
    let mut outputs = 0;
    while outputs < count {
        let line = next_line(daemon, &mut buffer).await;
        outputs += u64::from(line["event"] == "output");
        lines.push(line);
    }
    lines
}

/// An old phone (no args) on a host with the gate on: the plain stream, unstamped, and no
/// viewport line.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn viewport_sync_an_old_phone_gets_the_plain_stream() {
    let selector = cmux_mobile_host::viewport_sync::SelectorConfig::datagram_first();
    let fixture = fixture_viewport(FakeOptions::default(), false, true, Some(selector)).await;
    let connected = connect(&fixture, TransportKind::WireGuard).await.expect("dial");
    let mut daemon = connected.link.open("daemon", serde_json::json!({})).await.unwrap();
    daemon.send(scripted_attach()).await.unwrap();
    let lines = read_outputs(&mut daemon, SCRIPTED).await;
    assert!(
        lines.iter().all(|line| !line["event"].as_str().unwrap_or_default().starts_with("viewport-")),
        "{lines:?}"
    );
    assert!(lines.iter().all(|line| line.get("pseq").is_none()), "no pseq without the arg: {lines:?}");
    let outputs: Vec<Vec<u8>> =
        lines.iter().filter(|line| line["event"] == "output").map(|line| unb64(line, "data")).collect();
    assert_eq!(outputs, (0..SCRIPTED).map(|i| scripted_line(i).into_bytes()).collect::<Vec<_>>());
}

/// A new phone (both args) on a host with the gate off: the plain stream, stamped.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn viewport_sync_off_on_the_host_gives_the_plain_stream() {
    let fixture = fixture_viewport(FakeOptions::default(), false, true, None).await;
    let connected = connect(&fixture, TransportKind::WireGuard).await.expect("dial");
    let mut daemon =
        connected.link.open("daemon", serde_json::json!({"pseq": true, "viewport_sync": 1})).await.unwrap();
    daemon.send(scripted_attach()).await.unwrap();
    let lines = read_outputs(&mut daemon, SCRIPTED).await;
    assert!(
        lines.iter().all(|line| !line["event"].as_str().unwrap_or_default().starts_with("viewport-")),
        "{lines:?}"
    );
    let outputs: Vec<&serde_json::Value> = lines.iter().filter(|line| line["event"] == "output").collect();
    assert!(outputs.iter().all(|line| line["pseq"].is_u64()), "pseq with the arg: {outputs:?}");
    let bytes: Vec<Vec<u8>> = outputs.iter().map(|line| unb64(line, "data")).collect();
    assert_eq!(bytes, (0..SCRIPTED).map(|i| scripted_line(i).into_bytes()).collect::<Vec<_>>());
}
