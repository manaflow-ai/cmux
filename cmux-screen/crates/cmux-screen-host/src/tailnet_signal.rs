//! Signaling over the tailnet: the host's own tsnet node listens on one
//! tailnet port; each connection is a viewer. The peer is identified by a
//! Tailscale WhoIs on its address and checked with [`Access`] before the
//! WebSocket handshake, so an unknown device never reaches the signaling
//! code. The messages are the Worker room's (`SignalMessage`), so a viewer
//! runs the same state machine on both paths.
//!
//! The link is plain WebSocket inside WireGuard: the tailnet encrypts it and
//! authenticates the peer's node key; the SDP (with its DTLS fingerprint)
//! therefore arrives unmodified from the identified device.
//!
//! WhoIs names the device, not the program on it. A web page the owner opens
//! could reach this port as the owner, so any handshake that carries a
//! browser `Origin` header is refused. Other programs of the owner on the
//! owner's own devices are trusted, as with Rex and Tailscale SSH; the host's
//! consent prompt (remote-desktop.md 11) is the next gate.
//!
//! Media: the host's tsnet node also runs a TURN-over-TCP relay
//! (`cmux_tailnet::relay`, port 4181 by default). Each admitted link gets its
//! own credentials, bound to that link's device, in an `ice` message before
//! `hello`; the viewer's libwebrtc then has a tailnet relay candidate even
//! when the host has no OS tailnet interface. The credentials (and every
//! allocation made with them) end when the link and the session it started
//! have both ended.

use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use cmux_screen_proto::{IceServer, SignalMessage};
use cmux_tailnet::relay::{Log, TurnGrant, TurnRelay};
use cmux_tailnet::{Access, Decision, Node};
use futures_util::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};
use tokio_tungstenite::tungstenite::http::StatusCode;

use crate::log;

/// The default tailnet port for screen signaling.
pub const DEFAULT_PORT: u16 = 4180;

pub struct TailnetSignal {
    pub node: Arc<Node>,
    pub access: Access,
    pub port: u16,
    /// The tailnet port of the TURN relay for media; None: no relay (media
    /// then needs an OS tailnet interface, the LAN, or the room's TURN).
    pub relay_port: Option<u16>,
}

/// A message from one signaling source, with where to answer.
pub(crate) struct Incoming {
    pub source: Source,
    pub message: SignalMessage,
}

#[derive(Clone)]
pub(crate) enum Source {
    /// The Worker room (fallback). Answers go to the room's current connection.
    Worker,
    /// One identified tailnet viewer. `turn` is its relay credential: the link
    /// and the session each hold it, and the relay drops it with the last one.
    Tailnet { id: u64, principal: String, reply: mpsc::UnboundedSender<SignalMessage>, turn: Option<Arc<TurnGrant>> },
}

impl Source {
    pub(crate) fn same(&self, other: &Source) -> bool {
        match (self, other) {
            (Source::Worker, Source::Worker) => true,
            (Source::Tailnet { id: a, .. }, Source::Tailnet { id: b, .. }) => a == b,
            _ => false,
        }
    }

    pub(crate) fn describe(&self) -> String {
        match self {
            Source::Worker => "room".into(),
            Source::Tailnet { principal, .. } => format!("tailnet {principal}"),
        }
    }
}

/// Keepalive for an idle signaling link (same as the room's).
const KEEPALIVE: Duration = Duration::from_secs(20);
/// An admitted peer that does not finish the WebSocket handshake in time is dropped.
const HANDSHAKE_DEADLINE: Duration = Duration::from_secs(10);

/// Listens on the tailnet and feeds every admitted viewer's messages to `incoming`.
pub(crate) fn serve(signal: TailnetSignal, incoming: mpsc::UnboundedSender<Incoming>) -> Result<()> {
    let listener = signal.node.listen_tcp(signal.port).context("tailnet listen")?;
    let runtime = tokio::runtime::Handle::current();
    let relay = signal.relay_port.and_then(|port| {
        let relay_log: Log = Arc::new(|line: &str| log(line));
        match TurnRelay::serve(signal.node.clone(), signal.access.clone(), port, runtime.clone(), relay_log) {
            Ok(relay) => {
                log(format!("media relay (TURN over TCP) on tailnet port {port}"));
                Some(relay)
            }
            Err(error) => {
                log(format!("media relay failed: {error}; tailnet viewers get no relay"));
                None
            }
        }
    });
    std::thread::Builder::new().name("tailnet-accept".into()).spawn(move || {
        let mut next_id = 1u64;
        loop {
            let (stream, remote) = match listener.accept() {
                Ok(accepted) => accepted,
                Err(error) if error.0 == "listener closed" => {
                    log("tailnet listener closed; tailnet viewers can no longer connect");
                    return;
                }
                Err(error) => {
                    log(format!("tailnet accept: {error}"));
                    continue;
                }
            };
            let decision = signal
                .node
                .whois(&remote)
                .and_then(|peer| Ok((signal.access.check(&signal.node.status()?, &peer), peer)));
            let (principal, peer_node) = match decision {
                Ok((Decision::Allow { principal, why }, peer)) => {
                    log(format!("tailnet viewer {remote} ({principal}): allowed, {why}"));
                    (principal, peer.node.map(|node| node.stable_id).filter(|id| !id.is_empty()))
                }
                Ok((Decision::Deny { principal, why }, _)) => {
                    log(format!("tailnet viewer {remote} ({principal}): refused, {why}"));
                    continue;
                }
                Err(error) => {
                    log(format!("tailnet viewer {remote}: refused, no identity ({error})"));
                    continue;
                }
            };
            let id = next_id;
            next_id += 1;
            // Relay credentials only for a device the relay can identify again (its WhoIs node).
            let turn = match (&relay, peer_node) {
                (Some(relay), Some(peer_node)) => match (relay.ice_url(&signal.node), relay.grant(Some(peer_node))) {
                    (Some(url), Ok(grant)) => Some((grant, url)),
                    (_, Err(error)) => {
                        log(format!("media relay credentials: {error}"));
                        None
                    }
                    (None, _) => None,
                },
                _ => None,
            };
            let incoming = incoming.clone();
            runtime.spawn(async move {
                if let Err(error) = viewer(stream, id, principal.clone(), turn, incoming).await {
                    log(format!("tailnet viewer {principal}: {error:#}"));
                }
            });
        }
    })?;
    Ok(())
}

async fn viewer(
    stream: UnixStream,
    id: u64,
    principal: String,
    turn: Option<(Arc<TurnGrant>, String)>,
    incoming: mpsc::UnboundedSender<Incoming>,
) -> Result<()> {
    stream.set_nonblocking(true)?;
    let stream = tokio::net::UnixStream::from_std(stream)?;
    // tungstenite's handshake callback must return its own (large) ErrorResponse.
    #[allow(clippy::result_large_err)]
    let refuse_browsers = |request: &Request, response: Response| {
        if request.headers().contains_key("origin") {
            let mut refusal = ErrorResponse::new(Some("browser pages may not open screen signaling".into()));
            *refusal.status_mut() = StatusCode::FORBIDDEN;
            return Err(refusal);
        }
        Ok(response)
    };
    let socket = tokio::time::timeout(HANDSHAKE_DEADLINE, tokio_tungstenite::accept_hdr_async(stream, refuse_browsers))
        .await
        .context("signaling handshake timed out")?
        .context("signaling handshake")?;
    let (mut write, mut read) = socket.split();
    let (reply, mut outgoing) = mpsc::unbounded_channel::<SignalMessage>();
    let ice = turn.as_ref().map(|(grant, url)| SignalMessage {
        kind: "ice".into(),
        ice_servers: Some(vec![IceServer {
            urls: vec![url.clone()],
            username: Some(grant.username().to_owned()),
            credential: Some(grant.password().to_owned()),
        }]),
        ..SignalMessage::default()
    });
    let source = Source::Tailnet { id, principal, reply, turn: turn.map(|(grant, _)| grant) };
    let pumped = async {
        // Before `hello`: a viewer creates its peer connection (and gathers) on `hello`.
        if let Some(ice) = &ice {
            write.send(Message::text(serde_json::to_string(ice)?)).await?;
        }
        let hello = SignalMessage { kind: "hello".into(), role: Some("viewer".into()), peer: Some(true), ..SignalMessage::default() };
        write.send(Message::text(serde_json::to_string(&hello)?)).await?;
        let mut keepalive = tokio::time::interval(KEEPALIVE);
        keepalive.tick().await;
        loop {
            tokio::select! {
                message = outgoing.recv() => {
                    let Some(message) = message else { break };
                    write.send(Message::text(serde_json::to_string(&message)?)).await?;
                }
                frame = read.next() => match frame {
                    Some(Ok(Message::Text(text))) => {
                        let Ok(message) = serde_json::from_str::<SignalMessage>(&text) else { continue };
                        if incoming.send(Incoming { source: source.clone(), message }).is_err() { break }
                    }
                    Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                    Some(Ok(_)) => {}
                },
                _ = keepalive.tick() => write.send(Message::Ping(Vec::new().into())).await?,
            }
        }
        anyhow::Ok(())
    }
    .await;
    // However the link ended, the host hears that this viewer left.
    let _ = incoming.send(Incoming { source, message: SignalMessage::new("peer-left") });
    pumped
}
