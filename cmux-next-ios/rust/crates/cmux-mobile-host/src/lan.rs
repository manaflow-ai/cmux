//! The Mac's side of the LAN direct path (`cmux_mobile_link::lan`): one
//! WireGuard mesh on UDP 7421 that every enrolled phone may reach on this
//! Mac's network, with no signaling, token or ICE, so it works with the
//! internet down.
//!
//! - It starts beside the signaling loop and outlives it (`host.rs`).
//! - A phone enrolls through the `lan` service, which `services::serve` runs
//!   only past the pairing gate: the phone's Secure Enclave key was proven on
//!   this link first. Its LAN key is stored with its device id
//!   (`<state>/lan-phones.json`); the Mac's key is `<state>/lan.key`.
//! - A link accepted on the mesh is served exactly like an answered one
//!   (`host::serve_link`): `auth` runs on it again before any other service.
//! - Removing the phone (Settings > Mobile > Remove) removes its mesh peer.
//! - `CMUX_MOBILE_LAN=0` keeps the mesh off.

use std::sync::{Arc, OnceLock};

use bytes::Bytes;
use cmux_mobile_link::lan::{self, LanEnrollRequest, LanHost, LanIdentity};
use cmux_mobile_link::link::ChannelSender;
use cmux_mobile_link::{LinkConfig, Timeline, TransportKind};
use serde_json::Value;

use crate::config::ServiceConfig;
use crate::services::{Peer, Refusal};

/// The service a phone opens to enroll ([`lan::LAN_SERVICE`]).
pub const SERVICE: &str = lan::LAN_SERVICE;
/// `version`'s capability while the mesh runs.
pub const CAPABILITY: &str = "lan-direct-v1";

static HOST: OnceLock<Arc<LanHost>> = OnceLock::new();

/// Whether this Mac's LAN mesh is running.
pub fn running() -> bool {
    HOST.get().is_some()
}

/// Off in this crate's unit tests: they run the host (`host_recovery_tests`), and a real mesh
/// would bind UDP 7421, write `lan.key` to the user's state dir and, being process-global, add
/// its capability to every other test's `version`.
fn enabled() -> bool {
    !cfg!(test) && std::env::var("CMUX_MOBILE_LAN").map_or(true, |v| v.trim() != "0")
}

/// Start the mesh and serve the links it accepts; `None` when it is off or
/// its socket could not be had (logged; the relayed paths are unaffected).
pub async fn start(
    services: Arc<ServiceConfig>,
    include_loopback: bool,
    session_exposure: Option<tokio::sync::watch::Receiver<crate::control::SessionExposure>>,
) -> Option<tokio::task::JoinHandle<()>> {
    if !enabled() {
        return None;
    }
    let host = match HOST.get() {
        Some(host) => Arc::clone(host),
        None => {
            let state = crate::config::default_state_dir();
            let identity = match LanIdentity::load_or_create(&state.join("lan.key")) {
                Ok(identity) => identity,
                Err(error) => {
                    tracing::warn!(%error, "LAN key unavailable; LAN direct path off");
                    return None;
                }
            };
            let port = std::env::var("CMUX_MOBILE_LAN_PORT")
                .ok()
                .and_then(|v| v.trim().parse().ok())
                .unwrap_or(lan::LAN_PORT);
            match LanHost::start(identity, port, Some(state.join("lan-phones.json")), include_loopback).await
            {
                Ok(host) => {
                    tracing::info!(port = host.port(), key = host.public_b64(), "LAN direct path listening");
                    let host = Arc::new(host);
                    let _ = HOST.set(Arc::clone(&host));
                    Arc::clone(HOST.get().unwrap_or(&host))
                }
                Err(error) => {
                    tracing::warn!(%error, "LAN mesh did not start; LAN direct path off");
                    return None;
                }
            }
        }
    };
    let removals = Arc::clone(&host);
    let mut drops = crate::control::drops();
    tokio::spawn(async move {
        loop {
            match drops.recv().await {
                Ok(id) => removals.remove(&id).await,
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
                Err(_) => return,
            }
        }
    });
    Some(tokio::spawn(async move {
        while let Some(accepted) = host.accept().await {
            let timeline = Timeline::new();
            timeline.mark("lan_accepted");
            let (device_id, connected) = lan::answer(accepted, LinkConfig::default());
            let peer = Peer {
                device_id,
                session_id: connected.session_id.clone(),
                video: None,
                session_exposure: session_exposure.clone(),
                // serve_link fills both from the link.
                route: None,
                path: None,
                // A LAN link rides no WireGuard overlay, so it has no viewport sync port.
                viewport: None,
            };
            tracing::info!(phone = peer.device_id, session_id = peer.session_id, "LAN link up");
            tokio::spawn(crate::host::serve_link(
                connected,
                TransportKind::WireGuard,
                peer,
                timeline,
                Arc::clone(&services),
            ));
        }
    }))
}

/// The `lan` service: enroll this link's phone (`args`: `{phoneKey}`) and
/// reply with what it keeps ([`lan::LanEnrollReply`]).
pub(crate) async fn enroll(peer: &Peer, args: &Value, sender: &ChannelSender) -> Result<(), Refusal> {
    let Some(host) = HOST.get() else {
        return Err(Refusal::new("unavailable", "this Mac's LAN direct path is off"));
    };
    let request: LanEnrollRequest = serde_json::from_value(args.clone())
        .map_err(|error| Refusal::new("bad_request", format!("lan args: {error}")))?;
    let reply =
        host.enroll(&peer.device_id, &request).await.map_err(|reason| Refusal::new("bad_request", reason))?;
    tracing::info!(phone = peer.device_id, "LAN direct path enrolled");
    let body = serde_json::to_vec(&reply).map_err(|error| Refusal::new("internal", error.to_string()))?;
    let _ = sender.send(Bytes::from(body)).await;
    Ok(())
}
