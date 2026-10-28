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
    DeniedDevice, DeviceTrust, MacIdentity, Pairing, TrustedDevice, challenge_message, mac_proof_message,
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
        upload_max_bytes: 1024 * 1024,
        browser: cmux_mobile_host::browser::BrowserConfig::new(
            Some(fake_rb_host::launcher(Arc::clone(&browser_launches))),
            4,
        ),
        surface: cmux_mobile_host::surface::SurfaceConfig::new(
            Some(fake_surface_source::launcher(Arc::clone(&surface_inputs))),
            4,
        ),
    };
    let mut services = services;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let (mut trust, mut events, mut mac_key) = (None, None, None);
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
            .with_identity(tokio::sync::watch::channel(Some(identity)).1),
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
    let mut bytes = Vec::new();
    loop {
        match tokio::time::timeout(Duration::from_secs(10), channel.recv()).await.expect("in time") {
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
        serde_json::json!(["removal-v1", "browser-stream-v1", "browser-video-track-v1", "surface-stream-v1"])
    );

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
    let big = format!(
        r#"{{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{{"data":"{}"}}}}"#,
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
    // A folder that is no tab's and outside the roots, or too large: refused.
    let mut outside = link
        .open("upload", serde_json::json!({"name": "x", "size": 1, "cwd": fixture.outside.to_str().unwrap()}))
        .await
        .unwrap();
    assert_eq!(drain(&mut outside).await.1, "forbidden");
    let mut large =
        link.open("upload", serde_json::json!({"name": "x", "size": 2 * 1024 * 1024})).await.unwrap();
    assert_eq!(drain(&mut large).await.1, "too_large");
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

/// `auth`, with the pairing code's pre-approval sent beside the signature when `pair_token` is set.
async fn auth_presenting(
    link: &cmux_mobile_link::Link,
    fixture: &Fixture,
    keys: &PhoneKeys,
    signer: &ring::signature::EcdsaKeyPair,
    action: &str,
    pair_token: Option<&str>,
) -> Channel {
    let mut channel = link
        .open(
            "auth",
            serde_json::json!({"identityKey": keys.identity_hex, "approvalKey": keys.approval_hex,
                               "name": "Test iPhone", "action": action}),
        )
        .await
        .unwrap();
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

/// A pairing code's pre-approval rides with the signature to the app, which decides; hostd only
/// checks its shape, and a phone without one is asked exactly as before.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_scanned_pairing_code_reaches_the_app_with_the_request() {
    let fixture = fixture_with(FakeOptions::default(), true).await;
    let keys = phone_keys();
    let connected = connect(&fixture, TransportKind::WireGuard).await.expect("dial");
    let token = "Zm9vYmFyLWJhel9xdXV4";

    let mut bad =
        auth_presenting(&connected.link, &fixture, &keys, &keys.identity, "pair", Some("no spaces allowed"))
            .await;
    assert_eq!(drain(&mut bad).await.1, "bad_request");

    let mut channel =
        auth_presenting(&connected.link, &fixture, &keys, &keys.identity, "pair", Some(token)).await;
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
            pair_token: Some(token.into()),
        }
    );
    // The app allowed it (as it does for a live token): the phone is served.
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
    for service in ["daemon", "acpmux", "file", "echo"] {
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
            pair_token: None,
        }
    );
    fixture.trust.as_ref().unwrap().send_replace(Some(DeviceTrust {
        devices: vec![TrustedDevice {
            id: fixture.phone_id.clone(),
            identity_key: keys.identity_hex.clone(),
            approval_key: keys.approval_hex.clone(),
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
