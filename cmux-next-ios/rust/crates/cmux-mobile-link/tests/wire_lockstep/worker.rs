use std::collections::BTreeSet;
use std::time::Duration;

use cmux_mobile_link::signaling::{APP_PING, APP_PONG};
use cmux_mobile_link::{
    BuildSpace, DialError, DialOptions, LinkConfig, SignalingClient, TransportKind, dial,
};
use cmux_wire_lockstep::{Dir, OldPeer, Tap};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::handshake::server::{Request, Response};
use tokio_tungstenite::tungstenite::protocol::{CloseFrame, frame::coding::CloseCode};

use super::manifest;

// The Worker validates device and session IDs before forwarding a signal.
const PHONE: &str = "b21d7b3d-da51-4306-85be-035fe10c5eea";
const MAC: &str = "bb7fc319-eec9-4ec0-94b9-160eb1408d1b";
const OWNER: &str = "lockstep-owner";
const TEAM_HUB: &str = include_str!("../../../../../backend/src/team-hub.ts");

fn forwarded_kinds() -> Vec<String> {
    let declaration = TEAM_HUB.split_once("const SIGNAL_KINDS = new Set(").unwrap().1;
    let mut registry = serde_json::Deserializer::from_str(declaration).into_iter::<Vec<String>>();
    let kinds = registry.next().unwrap().expect("Worker signaling kind array");
    assert!(!kinds.is_empty());
    kinds
}

// The Worker has no separate registry for these codes: the literal arguments
// at its WebSocket close and signaling-error sends are the protocol vocabulary.
pub(super) fn control_names() -> BTreeSet<String> {
    // Worker admission and endpoint decoding are distinct: what it forwards is its own list.
    let mut names: BTreeSet<_> =
        forwarded_kinds().iter().map(|kind| format!("control:worker-forward/{kind}")).collect();
    for call in TEAM_HUB.split(".close(").skip(1) {
        let (code, _) = call.split_once(',').expect("Worker WebSocket close takes a code");
        let code: u16 = code.trim().parse().expect("expected literal Worker WebSocket close code");
        names.insert(format!("control:ws-close#{code}"));
    }
    for sender in ["this.error(ws,", "this.relayError(ws,"] {
        for call in TEAM_HUB.split(sender).skip(1) {
            let (code, _) = call.split_once(',').expect("Worker signaling error takes a code");
            if code.trim() == "code" {
                continue; // relayError forwards the same code to error
            }
            let code: String =
                serde_json::from_str(code).expect("expected literal Worker signaling error code");
            names.insert(format!("control:signal-error#{code}"));
        }
    }
    names
}

// tungstenite's handshake callback returns its own `ErrorResponse`; its size is not ours to change.
#[allow(clippy::result_large_err)]
async fn accept_worker(stream: TcpStream, tap: &Tap) -> WebSocketStream<TcpStream> {
    tokio_tungstenite::accept_hdr_async(stream, |request: &Request, response: Response| {
        for key in request.headers().keys() {
            // These are the WebSocket upgrade itself. Record every application header.
            if !matches!(
                key.as_str(),
                "host" | "connection" | "upgrade" | "sec-websocket-key" | "sec-websocket-version"
            ) {
                tap.record(Dir::Sent, format!("header:{key}"));
            }
        }
        Ok(response)
    })
    .await
    .unwrap()
}

fn observe_object(tap: &Tap, old: &OldPeer, dir: Dir, value: &Value) {
    let mut names = std::collections::BTreeSet::new();
    super::signals::collect(value, "", &mut names);
    if value["type"] == "signal" {
        names.insert(format!("control:worker-forward/{}", value["payload"]["kind"].as_str().unwrap()));
    }
    if value["type"] == "error" {
        names.insert(format!("control:signal-error#{}", value["code"].as_str().unwrap()));
    }
    for name in names {
        if dir == Dir::Received {
            assert!(old.knows(&name), "old Worker cannot send {name}");
        }
        tap.record(dir, name);
    }
}

async fn hello(socket: &mut WebSocketStream<TcpStream>, tap: &Tap, old: &OldPeer, you: &str) {
    let message = json!({"type":"hello","you":you,"macs":[{"deviceId": MAC, "online": true, "name":"Mac"}]});
    observe_object(tap, old, Dir::Received, &message);
    socket.send(Message::Text(message.to_string().into())).await.unwrap();
}

async fn next_packet(socket: &mut WebSocketStream<TcpStream>, tap: &Tap, old: &OldPeer) -> Value {
    loop {
        let message = socket.next().await.expect("signaling socket open").unwrap();
        match message {
            Message::Ping(_) => {
                tap.record(Dir::Sent, "control:websocket/ping");
                assert!(old.knows("control:websocket/pong"));
                tap.record(Dir::Received, "control:websocket/pong");
                // tungstenite queued the echo automatically.
                socket.flush().await.unwrap();
            }
            Message::Text(text) if text.as_str() == APP_PING => {
                tap.record(Dir::Sent, format!("control:signaling-text/{APP_PING}"));
                let pong = format!("control:signaling-text/{APP_PONG}");
                assert!(old.knows(&pong));
                tap.record(Dir::Received, pong);
                socket.send(Message::Text(APP_PONG.into())).await.unwrap();
            }
            Message::Text(text) => return serde_json::from_str(&text).unwrap(),
            other => panic!("unexpected signaling frame {other:?}"),
        }
    }
}

// Exercise both shipping dialers all the way through serialization and the
// Worker error reader. A session-scoped offline answer ends the dial before
// ICE or WireGuard needs an external peer. Inspect the actual final bye too.
async fn dial_against_worker(transport: TransportKind, offer: &str) -> Value {
    let head = manifest::manifest();
    let old = manifest::base();
    let tap = Tap::new();
    let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let worker = async {
        let (stream, _) = listener.accept().await.unwrap();
        let mut socket = accept_worker(stream, &tap).await;
        hello(&mut socket, &tap, &old, PHONE).await;
        let mut captured_offer = None;
        loop {
            let packet = next_packet(&mut socket, &tap, &old).await;
            observe_object(&tap, &old, Dir::Sent, &packet);
            let kind = packet["payload"]["kind"].as_str().unwrap();
            if kind == offer {
                assert_eq!(packet["from"], PHONE);
                assert_eq!(packet["to"], MAC);
                let session = packet["sessionId"].as_str().unwrap();
                let error = json!({"type":"error","code":"offline","message":"offline","sessionId":session});
                observe_object(&tap, &old, Dir::Received, &error);
                socket.send(Message::Text(error.to_string().into())).await.unwrap();
                captured_offer = Some(packet);
            } else if kind == "bye" {
                let offer = captured_offer.take().unwrap();
                assert_eq!(packet["sessionId"], offer["sessionId"]);
                break offer;
            }
        }
    };
    let phone = async {
        let space = BuildSpace::parse("dev:lockstep").unwrap();
        let client =
            SignalingClient::connect_in(&url, "test-token", "test-team", PHONE, Some(&space)).await.unwrap();
        let options = DialOptions { include_loopback: true, ..DialOptions::default() };
        let result = dial::connect(&client, MAC, transport, &options, LinkConfig::default()).await;
        assert!(matches!(result, Err(DialError::Refused { code, .. }) if code == "offline"));
        client
    };
    let (offer, client) = tokio::join!(worker, phone);
    client.close();
    tap.assert_lockstep(&head, &old);
    offer
}

// Keep the dialer's generated SDP / key. The old phone opens a fresh signaling
// session with just the original offer fields. End the harness when the real Mac
// answer is on the socket, before it needs a working ICE or tunnel data path.
async fn answer_old_phone(mut offer: Value, answer: &str) {
    let old = manifest::base();
    let tap = Tap::new();
    offer["fromUserId"] = json!(OWNER);
    offer["payload"]
        .as_object_mut()
        .unwrap()
        .retain(|key, _| matches!(key.as_str(), "kind" | "sdp" | "publicKey" | "endpoints" | "overlayIP"));
    let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let worker = async {
        let (stream, _) = listener.accept().await.unwrap();
        let mut socket = accept_worker(stream, &tap).await;
        hello(&mut socket, &tap, &old, MAC).await;
        observe_object(&tap, &old, Dir::Received, &offer);
        socket.send(Message::Text(offer.to_string().into())).await.unwrap();
        loop {
            let packet = next_packet(&mut socket, &tap, &old).await;
            observe_object(&tap, &old, Dir::Sent, &packet);
            assert_eq!(packet["sessionId"], offer["sessionId"]);
            if packet["payload"]["kind"] == answer {
                let close = CloseFrame { code: CloseCode::from(4002), reason: "removed".into() };
                let name = format!("control:ws-close#{}", u16::from(close.code));
                let close = old.knows(&name).then(|| {
                    tap.record(Dir::Received, name);
                    close
                });
                socket.send(Message::Close(close)).await.unwrap();
                break;
            }
        }
    };
    let mac = async {
        let client = SignalingClient::connect(&url, "test-token", "test-team", MAC).await.unwrap();
        let session = client.next_session().await.unwrap();
        assert!(cmux_mobile_host::host::admitted(&session.first, OWNER));
        let events = dial::SessionEvents {
            session_id: session.first.session_id.clone(),
            session: session.events,
            backend: client.events(),
        };
        let options = DialOptions { include_loopback: true, ..DialOptions::default() };
        let mut lifecycle = client.events();
        let disconnected = async {
            loop {
                if let cmux_mobile_link::signaling::SignalingEvent::Disconnected(reason) =
                    lifecycle.recv().await.unwrap()
                {
                    assert_eq!(
                        cmux_mobile_host::host::removed(&reason),
                        old.knows("control:ws-close#4002"),
                        "{reason}"
                    );
                    break;
                }
            }
        };
        tokio::pin!(disconnected);
        tokio::select! {
            () = &mut disconnected => {}
            _ = dial::answer(&client, session.first, events, &options, LinkConfig::default()) => disconnected.await,
        }
        client.close();
    };
    tokio::join!(worker, mac);
    tap.assert_lockstep(&manifest::manifest(), &old);
}

#[tokio::test]
async fn signaling_dial_against_base_worker() {
    tokio::time::timeout(Duration::from_secs(8), async {
        for (transport, offer, answer) in [
            (TransportKind::WebRtc, "webrtc-offer", "webrtc-answer"),
            (TransportKind::WireGuard, "wg-init", "wg-resp"),
        ] {
            answer_old_phone(dial_against_worker(transport, offer).await, answer).await;
        }
    })
    .await
    .expect("both transports exchange their offers, answers and dial refusals on loopback");
}

/// The 0.17 Worker forwards this signal to the other device on an existing session.
#[tokio::test]
async fn worker_wg_relay_reaches_the_peer() {
    use cmux_mobile_link::signaling::SessionEvent;
    use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};

    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac = SignalingClient::connect(&server.base_url, "user:owner", "team", MAC).await.unwrap();
    let session = uuid::Uuid::new_v4().to_string();
    let mut inbox = mac.subscribe(&session);
    for payload in [json!({"kind":"wg-relay"}), json!({"kind":"bye", "reason":"done"})] {
        let packet = json!({"type":"signal","to":MAC,"from":PHONE,"fromUserId":OWNER,"sessionId":session,"payload":payload});
        assert!(server.send_to_device(MAC, &packet));
    }
    // An ordered bye is the barrier: if it arrives first, the live reader discarded wg-relay.
    let Some(SessionEvent::Signal(first)) =
        tokio::time::timeout(Duration::from_secs(2), inbox.recv()).await.unwrap()
    else {
        panic!("expected a forwarded signal");
    };
    assert_eq!(
        serde_json::to_value(first.payload).unwrap()["kind"],
        "wg-relay",
        "Rust dropped the Worker's wg-relay before the following bye"
    );
}

// This is the admission registry used by the in-tree Worker on every forwarded
// signal: every kind it forwards, the link reads.
#[test]
fn worker_forwarded_payloads_are_known_to_the_link() {
    let kinds = forwarded_kinds();
    let worker: BTreeSet<_> = kinds.iter().map(String::as_str).collect();
    let rust = super::signals::payload_tags();
    assert_eq!(worker.difference(&rust).next(), None, "the link drops a Worker-forwarded payload kind");
    assert_eq!(rust.difference(&worker).next(), None, "the Worker refuses a Rust payload kind");
}
