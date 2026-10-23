//! The room on the signal Worker: a WebSocket per role, plus the room's ICE
//! servers (STUN, and TURN when the Worker has a relay key).

use std::time::Duration;

use anyhow::{Context, Result, bail};
use cmux_screen_proto::{IceAnswer, IceServer, Pairing, SECRET_HEADER, SignalMessage};
use futures_util::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::{Message, client::IntoClientRequest, http::HeaderValue};

/// An open room connection: `outbox` sends, `inbox` yields until it closes.
pub struct Room {
    pub outbox: mpsc::UnboundedSender<SignalMessage>,
    pub inbox: mpsc::UnboundedReceiver<SignalMessage>,
}

/// Keepalive: an idle WebSocket can be dropped by a NAT or proxy without
/// either end hearing about it; a ping that fails surfaces it.
const KEEPALIVE: Duration = Duration::from_secs(20);

pub async fn connect(pairing: &Pairing, role: &str) -> Result<Room> {
    let mut request = pairing.socket_url(role).into_client_request()?;
    request.headers_mut().insert(SECRET_HEADER, HeaderValue::from_str(&pairing.secret)?);
    let (socket, _) = tokio_tungstenite::connect_async(request).await.context("room connection")?;
    let (mut write, mut read) = socket.split();
    let (outbox, mut outgoing) = mpsc::unbounded_channel::<SignalMessage>();
    let (incoming, inbox) = mpsc::unbounded_channel();
    tokio::spawn(async move {
        let mut keepalive = tokio::time::interval(KEEPALIVE);
        keepalive.tick().await;
        loop {
            tokio::select! {
                message = outgoing.recv() => {
                    let Some(message) = message else { break };
                    let Ok(text) = serde_json::to_string(&message) else { continue };
                    if write.send(Message::text(text)).await.is_err() { break }
                }
                frame = read.next() => match frame {
                    Some(Ok(Message::Text(text))) => {
                        if let Ok(message) = serde_json::from_str::<SignalMessage>(&text)
                            && incoming.send(message).is_err() { break }
                    }
                    Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                    Some(Ok(_)) => {}
                },
                _ = keepalive.tick() => {
                    if write.send(Message::Ping(Vec::new().into())).await.is_err() { break }
                }
            }
        }
        let _ = write.close().await;
        // Dropping `incoming` ends the inbox: the room connection is gone.
    });
    Ok(Room { outbox, inbox })
}

/// The room's ICE servers.
pub async fn ice_servers(pairing: &Pairing) -> Result<Vec<IceServer>> {
    let url = pairing.room_url("ice", None);
    let secret = pairing.secret.clone();
    tokio::task::spawn_blocking(move || -> Result<Vec<IceServer>> {
        // A stalled request must not hold up the host (it answers offers in order).
        let agent: ureq::Agent = ureq::Agent::config_builder().timeout_global(Some(Duration::from_secs(10))).build().into();
        let mut response = agent.get(&url).header(SECRET_HEADER, &secret).call().context("ICE servers")?;
        if response.status() != 200 {
            bail!("ICE servers: HTTP {}", response.status());
        }
        let answer: IceAnswer = serde_json::from_str(&response.body_mut().read_to_string()?)?;
        Ok(answer.ice_servers)
    })
    .await?
}
