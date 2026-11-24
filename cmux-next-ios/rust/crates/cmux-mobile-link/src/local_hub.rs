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

use crate::local::LOCAL_USER;
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
        let listener = TcpListener::bind(address).await?;
        let port = listener.local_addr()?.port();
        let mut bytes = [0u8; 16];
        getrandom::fill(&mut bytes).map_err(|e| std::io::Error::other(e.to_string()))?;
        let secret: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
        let state = Arc::new(Mutex::new(State {
            mac: mac.to_owned(),
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
        let device = request
            .uri()
            .query()
            .and_then(|q| q.split('&').find_map(|kv| kv.strip_prefix("deviceId=")))
            .map(str::to_owned)
            .filter(|d| !d.is_empty());
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
        let _ = out_tx.send(text(json!({"type": "hello", "you": device, "macs": macs})));
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
}
