//! A Mac's local signaling hub (ultra-connectivity P7, `local.rs`).
//!
//! The same wire as the Worker's signaling socket (PROTOCOL.md "Signaling
//! WebSocket"), the subset a dial needs: `hello`, `signal` forwarding by `to`
//! with `from` stamped from the socket, text `ping` → `pong`. It serves one
//! Mac: the Mac's own [`SignalingClient`](crate::SignalingClient) connects
//! over loopback with the hub's secret, and phones on the LAN (or AWDL)
//! connect to it as they would to the Worker, so `dial::connect` and
//! `dial::answer` run unchanged with no cloud round trip and no internet.
//!
//! Who may signal the Mac is [`Admit`]'s call (supervised hostd: a device on
//! the pairing's trust list); what a link may do is still the `auth` channel's.
//! A phone may signal only the Mac; the Mac may signal any phone on the hub.
//!
//! Lockstep ([`HUB_VERSION`]): the hello says the hub's version, a phone's
//! URL its own; a `signal` is forwarded as it came (fields this hub does not
//! know included, `from` and `fromUserId` stamped), and a message type it
//! does not know is ignored, so phones and Macs newer than the hub still
//! talk through it.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex, PoisonError};

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};
use tokio_tungstenite::tungstenite::protocol::CloseFrame;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;

use crate::local::{HUB_VERSION, HUB_VERSION_PARAM, LOCAL_USER};
use crate::signaling::{APP_PING, APP_PONG};

/// Whether a phone with this device id may signal the Mac through the hub.
pub type Admit = Arc<dyn Fn(&str) -> bool + Send + Sync>;

/// A frame larger than this is refused: a signal is a few kilobytes.
const MAX_FRAME: usize = 64 * 1024;
/// At most this many sockets at once (one per phone; a LAN is small).
const MAX_SOCKETS: usize = 64;

struct Socket {
    out: mpsc::UnboundedSender<Message>,
}

struct State {
    mac: String,
    /// The `hubVersion` this hub's hello says ([`HUB_VERSION`]; 0, no field,
    /// is how tests stand in for a hub older than it).
    version: u32,
    secret: String,
    admit: Admit,
    sockets: HashMap<String, Socket>,
}

/// A running hub; dropping it stops accepting (live sockets end with their peers).
pub struct LocalHub {
    port: u16,
    secret: String,
    accept: tokio::task::JoinHandle<()>,
}

impl Drop for LocalHub {
    fn drop(&mut self) {
        self.accept.abort();
    }
}

impl LocalHub {
    /// Listen on `address` (port 0 picks one) for Mac `mac`'s hub.
    pub async fn bind(address: SocketAddr, mac: &str, admit: Admit) -> std::io::Result<Self> {
        Self::bind_speaking(address, mac, admit, HUB_VERSION).await
    }

    /// [`Self::bind`] whose hello says `version` (0: no `hubVersion`, as a
    /// hub before it); lockstep tests stand in for an older hub with it.
    #[doc(hidden)]
    pub async fn bind_speaking(
        address: SocketAddr,
        mac: &str,
        admit: Admit,
        version: u32,
    ) -> std::io::Result<Self> {
        let listener = TcpListener::bind(address).await?;
        let port = listener.local_addr()?.port();
        let mut bytes = [0u8; 16];
        getrandom::fill(&mut bytes).map_err(|e| std::io::Error::other(e.to_string()))?;
        let secret: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
        let state = Arc::new(Mutex::new(State {
            mac: mac.to_owned(),
            version,
            secret: secret.clone(),
            admit,
            sockets: HashMap::new(),
        }));
        let accept = tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else { continue };
                let _ = stream.set_nodelay(true);
                tokio::spawn(serve(stream, Arc::clone(&state)));
            }
        });
        Ok(Self { port, secret, accept })
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    /// The bearer the Mac's own socket presents (`SignalingClient::connect_local`).
    pub fn secret(&self) -> &str {
        &self.secret
    }

    /// The URL the Mac's own socket opens.
    pub fn loopback_url(&self) -> String {
        format!("ws://127.0.0.1:{}", self.port)
    }
}

fn lock(state: &Mutex<State>) -> std::sync::MutexGuard<'_, State> {
    state.lock().unwrap_or_else(PoisonError::into_inner)
}

fn text(value: Value) -> Message {
    Message::Text(value.to_string().into())
}

#[allow(clippy::result_large_err)] // tungstenite's handshake callback signature
async fn serve(stream: TcpStream, state: Arc<Mutex<State>>) {
    let (out_tx, mut out_rx) = mpsc::unbounded_channel::<Message>();
    let mut identity: Option<String> = None;
    let callback = |request: &Request, response: Response| -> Result<Response, ErrorResponse> {
        let token = request
            .headers()
            .get("authorization")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.strip_prefix("Bearer "))
            .unwrap_or_default();
        let query = |key: &str| {
            request.uri().query().and_then(|q| {
                q.split('&').find_map(|kv| kv.split_once('=').filter(|(k, _)| *k == key).map(|(_, v)| v))
            })
        };
        let device = query("deviceId").map(str::to_owned).filter(|d| !d.is_empty());
        // The phone's hub version (0: a phone before the field); nothing is
        // gated on it yet, the next version's additions will be.
        let peer_version: u32 = query(HUB_VERSION_PARAM).and_then(|v| v.parse().ok()).unwrap_or(0);
        let path_ok =
            request.uri().path().starts_with("/v1/teams/") && request.uri().path().ends_with("/signal");
        let mut state = lock(&state);
        let allowed = match &device {
            // Only the Mac's own process knows the secret.
            Some(d) if *d == state.mac => token == state.secret,
            Some(d) => (state.admit)(d),
            None => false,
        };
        if !(path_ok && allowed)
            || (state.sockets.len() >= MAX_SOCKETS
                && !device.as_ref().is_some_and(|d| state.sockets.contains_key(d)))
        {
            let mut refused = ErrorResponse::new(Some("unauthorized".into()));
            *refused.status_mut() = tokio_tungstenite::tungstenite::http::StatusCode::UNAUTHORIZED;
            return Err(refused);
        }
        let device = device.unwrap_or_default();
        let mac_online = state.sockets.contains_key(&state.mac) || device == state.mac;
        let macs = if device == state.mac {
            json!([])
        } else {
            json!([{"deviceId": state.mac, "name": "", "online": mac_online}])
        };
        let mut hello = json!({"type": "hello", "you": device, "macs": macs});
        if state.version != 0 {
            hello[HUB_VERSION_PARAM] = json!(state.version);
        }
        let _ = out_tx.send(text(hello));
        tracing::debug!(device, peer_version, "local hub socket");
        // One live socket per device, as the Worker does: a reconnect
        // replaces the old socket (4000 "replaced").
        if let Some(old) = state.sockets.insert(device.clone(), Socket { out: out_tx.clone() }) {
            let _ = old.out.send(Message::Close(Some(CloseFrame {
                code: CloseCode::Library(4000),
                reason: "replaced".into(),
            })));
        }
        identity = Some(device);
        Ok(response)
    };
    let config = tokio_tungstenite::tungstenite::protocol::WebSocketConfig::default()
        .max_message_size(Some(MAX_FRAME))
        .max_frame_size(Some(MAX_FRAME));
    let accepted = tokio_tungstenite::accept_hdr_async_with_config(stream, callback, Some(config)).await;
    let Some(device) = identity else { return };
    let Ok(socket) = accepted else {
        forget(&state, &device, &out_tx);
        return;
    };
    let (mut sink, mut source) = socket.split();
    tokio::spawn(async move {
        while let Some(message) = out_rx.recv().await {
            let close = matches!(message, Message::Close(_));
            if sink.send(message).await.is_err() || close {
                break;
            }
        }
        let _ = sink.close().await;
    });
    while let Some(Ok(message)) = source.next().await {
        let Message::Text(body) = message else {
            if matches!(message, Message::Close(_)) {
                break;
            }
            continue;
        };
        if body.as_str() == APP_PING {
            let _ = out_tx.send(Message::Text(APP_PONG.into()));
            continue;
        }
        let Ok(mut value) = serde_json::from_str::<Value>(&body) else { continue };
        if value["type"] != "signal" {
            continue;
        }
        let state = lock(&state);
        // A replaced socket's late frames are dropped, as the Worker does.
        if !state.sockets.get(&device).is_some_and(|s| s.out.same_channel(&out_tx)) {
            continue;
        }
        let to = value["to"].as_str().unwrap_or_default().to_owned();
        // A phone reaches only the Mac; the Mac answers anyone here.
        if device != state.mac && to != state.mac {
            let _ = out_tx.send(text(json!({"type":"error","code":"not_owner","message":"not your device"})));
            continue;
        }
        value["from"] = Value::String(device.clone());
        value["fromUserId"] = Value::String(LOCAL_USER.to_owned());
        match state.sockets.get(&to) {
            Some(target) => {
                let _ = target.out.send(text(value));
            }
            None => {
                let mut error = json!({"type":"error","code":"offline","message":"device is offline"});
                if let Some(session) = value["sessionId"].as_str() {
                    error["sessionId"] = Value::String(session.to_owned());
                }
                let _ = out_tx.send(text(error));
            }
        }
    }
    forget(&state, &device, &out_tx);
}

/// Drop `device`'s socket if it is still this one.
fn forget(state: &Mutex<State>, device: &str, out_tx: &mpsc::UnboundedSender<Message>) {
    let mut state = lock(state);
    if state.sockets.get(device).is_some_and(|s| s.out.same_channel(out_tx)) {
        state.sockets.remove(device);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::SignalingClient;
    use crate::signaling::SignalPayload;

    async fn hub(admit: Admit) -> LocalHub {
        LocalHub::bind("127.0.0.1:0".parse().unwrap(), "mac", admit).await.unwrap()
    }

    #[tokio::test]
    async fn forwards_between_phone_and_mac_with_no_worker() {
        let hub = hub(Arc::new(|d: &str| d == "phone")).await;
        let mac = SignalingClient::connect_local(&hub.loopback_url(), hub.secret(), "mac").await.unwrap();
        let addr: SocketAddr = format!("127.0.0.1:{}", hub.port()).parse().unwrap();
        let phone = crate::local::connect_hub(&[addr], "phone").await.unwrap();
        assert!(phone.is_local() && mac.is_local());
        // A wg-init opens a session on the Mac's side (a bye alone would not).
        let init: SignalPayload = serde_json::from_value(json!(
            {"kind":"wg-init","publicKey":"k","endpoints":["192.168.1.4:5"],"overlayIP":"10.77.0.2"}))
        .unwrap();
        phone.send_signal("mac", "s1", init).unwrap();
        let session = tokio::time::timeout(std::time::Duration::from_secs(5), mac.next_session())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(session.first.from, "phone");
        assert_eq!(session.first.from_user_id.as_deref(), Some(LOCAL_USER));
    }

    #[tokio::test]
    async fn refuses_strangers_and_a_mac_without_the_secret() {
        let hub = hub(Arc::new(|d: &str| d == "phone")).await;
        let addr: SocketAddr = format!("127.0.0.1:{}", hub.port()).parse().unwrap();
        assert!(crate::local::connect_hub(&[addr], "stranger").await.is_err());
        assert!(SignalingClient::connect_local(&hub.loopback_url(), "guess", "mac").await.is_err());
    }

    // Lockstep (P7 13f): old against new, both ways. "Old" is the wire as it
    // was before a field existed: no `hubVersion` in a phone's URL or a hub's
    // hello; "new" is this build.

    use std::time::Duration;
    use tokio_tungstenite::tungstenite::client::IntoClientRequest;

    type Raw = tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<TcpStream>>;

    /// A raw socket to the hub, opened as a client of another build would.
    async fn raw(hub: &LocalHub, token: &str, query: &str) -> Raw {
        let url = format!("{}/v1/teams/local/signal?{query}", hub.loopback_url());
        let mut request = url.into_client_request().unwrap();
        request.headers_mut().insert("authorization", format!("Bearer {token}").parse().unwrap());
        tokio_tungstenite::connect_async(request).await.unwrap().0
    }

    /// The next text frame, JSON or not.
    async fn next_text(socket: &mut Raw) -> String {
        loop {
            let message =
                tokio::time::timeout(Duration::from_secs(5), socket.next()).await.unwrap().unwrap().unwrap();
            if let Message::Text(text) = message {
                return text.as_str().to_owned();
            }
        }
    }

    async fn next_json(socket: &mut Raw) -> Value {
        serde_json::from_str(&next_text(socket).await).unwrap()
    }

    fn wg_init() -> SignalPayload {
        serde_json::from_value(json!(
            {"kind":"wg-init","publicKey":"k","endpoints":["192.168.1.4:5"],"overlayIP":"10.77.0.2"}))
        .unwrap()
    }

    /// A phone from before `hubVersion` (no `&hubVersion=`, and a hello
    /// parser that knows only `you` and `macs`) against this hub: admitted,
    /// reads the hello, signals the Mac.
    #[tokio::test]
    async fn lockstep_old_phone_against_new_hub() {
        #[derive(serde::Deserialize)]
        #[serde(tag = "type", rename_all = "lowercase")]
        enum OldMessage {
            Hello {
                you: String,
                #[serde(default)]
                macs: Vec<crate::signaling::MacPresence>,
            },
        }
        let hub = hub(Arc::new(|d: &str| d == "phone")).await;
        let mut mac = raw(&hub, hub.secret(), "deviceId=mac&hubVersion=1").await;
        let mac_hello = next_json(&mut mac).await;
        assert_eq!(mac_hello[HUB_VERSION_PARAM], json!(HUB_VERSION));
        let mut phone = raw(&hub, "local", "deviceId=phone").await;
        let hello = next_json(&mut phone).await;
        assert_eq!(hello[HUB_VERSION_PARAM], json!(HUB_VERSION));
        let OldMessage::Hello { you, macs } = serde_json::from_value(hello).unwrap();
        assert_eq!((you.as_str(), macs[0].device_id.as_str(), macs[0].online), ("phone", "mac", true));
        let signal = json!({"type":"signal","to":"mac","from":"","sessionId":"s1",
            "payload":{"kind":"bye","reason":"r"}});
        phone.send(Message::Text(signal.to_string().into())).await.unwrap();
        let forwarded = next_json(&mut mac).await;
        assert_eq!(
            (forwarded["from"].as_str(), forwarded["sessionId"].as_str()),
            (Some("phone"), Some("s1"))
        );
    }

    /// This phone against a hub from before `hubVersion` (its hello has
    /// none) and against this hub: both carry the dial; the phone reads 0
    /// from the old one and [`HUB_VERSION`] from this one.
    #[tokio::test]
    async fn lockstep_new_phone_against_old_and_new_hub() {
        for version in [0, HUB_VERSION] {
            let hub = LocalHub::bind_speaking(
                "127.0.0.1:0".parse().unwrap(),
                "mac",
                Arc::new(|d: &str| d == "phone"),
                version,
            )
            .await
            .unwrap();
            let mac = SignalingClient::connect_local(&hub.loopback_url(), hub.secret(), "mac").await.unwrap();
            let addr: SocketAddr = format!("127.0.0.1:{}", hub.port()).parse().unwrap();
            let phone = crate::local::connect_hub(&[addr], "phone").await.unwrap();
            phone.send_signal("mac", "s1", wg_init()).unwrap();
            let wait = Duration::from_secs(5);
            let session = tokio::time::timeout(wait, mac.next_session()).await.unwrap().unwrap();
            assert_eq!(session.first.from, "phone", "hub version {version}");
            // The Mac's signal back arrives after the hello on the phone's socket.
            mac.send_signal("phone", "s2", wg_init()).unwrap();
            tokio::time::timeout(wait, phone.next_session()).await.unwrap().unwrap();
            assert_eq!(phone.hub_version(), version);
            assert_eq!(mac.hub_version(), version);
        }
    }

    /// This phone against a Mac with no hub (an older Mac, or the hub off):
    /// the hub dial fails at once, well inside its wait, so the phone goes on
    /// to the Worker; an older Mac also has no ad, so there is no address.
    #[tokio::test]
    async fn lockstep_new_phone_against_old_mac_with_no_hub() {
        let closed = {
            let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            listener.local_addr().unwrap()
        };
        let started = std::time::Instant::now();
        assert!(crate::local::connect_hub(&[closed], "phone").await.is_err());
        assert!(crate::local::connect_hub(&[], "phone").await.is_err());
        assert!(started.elapsed() < crate::local::HUB_CONNECT_WAIT / 3, "{:?}", started.elapsed());
    }

    /// A newer phone's or Mac's messages through this hub: a message type it
    /// does not know is ignored (no error, the socket stays up); a `signal`
    /// is forwarded with every field it does not know, `from` and
    /// `fromUserId` stamped over whatever the sender wrote; and this build's
    /// parser reads the forwarded signal.
    #[tokio::test]
    async fn lockstep_hub_forwards_unknown_fields_and_ignores_unknown_types() {
        let hub = hub(Arc::new(|d: &str| d == "phone")).await;
        let mut mac = raw(&hub, hub.secret(), "deviceId=mac&hubVersion=1").await;
        next_json(&mut mac).await;
        let mut phone = raw(&hub, "local", "deviceId=phone&hubVersion=99&future=1").await;
        next_json(&mut phone).await;
        for unknown in [
            json!({"type":"future","x":1}),
            json!({"type":"link_stat","path":"wifi"}),
            json!({"type":"mailbox_ack","results":[]}),
        ] {
            phone.send(Message::Text(unknown.to_string().into())).await.unwrap();
        }
        let signal = json!({"type":"signal","to":"mac","from":"forged","fromUserId":"forged","sessionId":"s1",
            "trace":"t1","payload":{"kind":"wg-init","publicKey":"k","endpoints":[],"overlayIP":"10.77.0.2",
            "version":9,"future":{"a":1}}});
        phone.send(Message::Text(signal.to_string().into())).await.unwrap();
        let forwarded = next_json(&mut mac).await;
        assert_eq!(forwarded["trace"], "t1");
        assert_eq!(forwarded["payload"]["future"], json!({"a":1}));
        assert_eq!(
            (forwarded["from"].as_str(), forwarded["fromUserId"].as_str()),
            (Some("phone"), Some(LOCAL_USER))
        );
        let parsed: crate::signaling::SignalMessage = serde_json::from_value(forwarded).unwrap();
        assert!(matches!(
            parsed,
            crate::signaling::SignalMessage::Signal(ref e)
                if matches!(e.payload, SignalPayload::WgInit { version: 9, .. })
        ));
        // Nothing came back for the unknown types: the next frame is the pong.
        phone.send(Message::Text(APP_PING.into())).await.unwrap();
        assert_eq!(next_text(&mut phone).await, APP_PONG);
    }

    /// A phone with no local support against a Mac that runs a hub: it never
    /// browses and dials through the Worker as before; the Mac's hub socket
    /// beside its Worker socket takes nothing from it. (A second hub stands
    /// in for the Worker: it is the same wire.)
    #[tokio::test]
    async fn lockstep_old_phone_without_local_dials_a_new_mac_through_the_worker() {
        let worker = hub(Arc::new(|d: &str| d == "phone")).await;
        let local = hub(Arc::new(|d: &str| d == "phone")).await;
        let mac_worker =
            SignalingClient::connect(&worker.loopback_url(), worker.secret(), "local", "mac").await.unwrap();
        let mac_local =
            SignalingClient::connect_local(&local.loopback_url(), local.secret(), "mac").await.unwrap();
        assert!(!mac_worker.is_local() && mac_local.is_local());
        let phone =
            SignalingClient::connect(&worker.loopback_url(), "local", "local", "phone").await.unwrap();
        phone.send_signal("mac", "s1", wg_init()).unwrap();
        let session =
            tokio::time::timeout(Duration::from_secs(5), mac_worker.next_session()).await.unwrap().unwrap();
        assert_eq!(session.first.from, "phone");
        assert!(tokio::time::timeout(Duration::from_millis(300), mac_local.next_session()).await.is_err());
        assert_eq!(phone.hub_version(), HUB_VERSION, "the stand-in Worker is a hub");
    }
}
