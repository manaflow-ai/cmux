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

use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use cmux_screen_proto::SignalMessage;
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
    /// One identified tailnet viewer.
    Tailnet { id: u64, principal: String, reply: mpsc::UnboundedSender<SignalMessage> },
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
                .and_then(|peer| Ok(signal.access.check(&signal.node.status()?, &peer)));
            let principal = match decision {
                Ok(Decision::Allow { principal, why }) => {
                    log(format!("tailnet viewer {remote} ({principal}): allowed, {why}"));
                    principal
                }
                Ok(Decision::Deny { principal, why }) => {
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
            let incoming = incoming.clone();
            runtime.spawn(async move {
                if let Err(error) = viewer(stream, id, principal.clone(), incoming).await {
                    log(format!("tailnet viewer {principal}: {error:#}"));
                }
            });
        }
    })?;
    Ok(())
}

async fn viewer(stream: UnixStream, id: u64, principal: String, incoming: mpsc::UnboundedSender<Incoming>) -> Result<()> {
    stream.set_nonblocking(true)?;
    let stream = tokio::net::UnixStream::from_std(stream)?;
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
    let source = Source::Tailnet { id, principal, reply };
    let pumped = async {
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
