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

/// Whether `transport.tailnetCarrier` is `direct-only` or `on` (RFD 0164 T5): the enroll reply
/// then carries this Mac's tailnet addresses. `CMUX_TAILNET_CARRIER` wins, as in the Mac daemon
/// (cmux-tui-util `user_settings::tailnet_carrier`); then cmux-next.json. Default off; off in
/// this crate's unit tests.
fn tailnet_carrier_on() -> bool {
    let env = |name: &str| std::env::var_os(name).filter(|value| !value.is_empty());
    if let Some(value) = env("CMUX_TAILNET_CARRIER") {
        return carrier_on(value.to_str());
    }
    if cfg!(test) {
        return false;
    }
    std::fs::read_to_string(next_config_path(env)).is_ok_and(|text| carrier_on_in_config(&text))
}

/// `direct-only` (or `direct_only`) and `on` are on; anything else, absent included, is off.
fn carrier_on(value: Option<&str>) -> bool {
    matches!(value.map(str::trim), Some("direct-only" | "direct_only" | "on"))
}

fn carrier_on_in_config(text: &str) -> bool {
    serde_json::from_str::<Value>(&cmux_json::strip_jsonc(text)).ok().is_some_and(|document| {
        carrier_on(document.pointer("/transport/tailnetCarrier").and_then(Value::as_str))
    })
}

/// The settings file, as `cmux_config::location::config_path_from` finds it:
/// `CMUX_NEXT_CONFIG_FILE` (a leading `~` is the home), else
/// `$HOME/.config/<cmux-next on macOS, cmux elsewhere>/cmux-next.json`.
fn next_config_path(env: impl Fn(&str) -> Option<std::ffi::OsString>) -> std::path::PathBuf {
    use std::path::PathBuf;
    if let Some(path) = env("CMUX_NEXT_CONFIG_FILE") {
        let path = PathBuf::from(path);
        if let Ok(rest) = path.strip_prefix("~")
            && let Some(home) = env("HOME")
        {
            return PathBuf::from(home).join(rest);
        }
        return path;
    }
    let dir = if cfg!(target_os = "macos") { "cmux-next" } else { "cmux" };
    PathBuf::from(env("HOME").unwrap_or_default()).join(".config").join(dir).join("cmux-next.json")
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
    let carrier = tailnet_carrier_on();
    let reply = host
        .enroll_hinting(&peer.device_id, &request, carrier)
        .await
        .map_err(|reason| Refusal::new("bad_request", reason))?;
    tracing::info!(
        phone = peer.device_id,
        tailnet = reply.tailnet.as_ref().map_or(0, |hint| hint.addresses.len()),
        "LAN direct path enrolled"
    );
    let body = serde_json::to_vec(&reply).map_err(|error| Refusal::new("internal", error.to_string()))?;
    let _ = sender.send(Bytes::from(body)).await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_carrier_setting_reads_like_the_mac_daemon() {
        assert!(!carrier_on(None), "absent is off");
        assert!(!carrier_on(Some("off")));
        assert!(!carrier_on(Some("bogus")), "unknown is off");
        assert!(carrier_on(Some("on")));
        assert!(carrier_on(Some(" direct-only ")));
        assert!(carrier_on(Some("direct_only")));
        assert!(!carrier_on_in_config("{}"));
        assert!(!carrier_on_in_config("not json"));
        assert!(!carrier_on_in_config(r#"{"transport": {"tailnetCarrier": "off"}}"#));
        assert!(carrier_on_in_config(
            "{\n  // chosen in Settings\n  \"transport\": {\"tailnetCarrier\": \"on\",},\n}"
        ));
    }

    #[test]
    fn the_settings_file_is_where_the_mac_app_keeps_it() {
        use std::ffi::OsString;
        let env = |pairs: &'static [(&'static str, &'static str)]| {
            move |name: &str| {
                pairs.iter().find(|(key, _)| *key == name).map(|(_, value)| OsString::from(value))
            }
        };
        assert_eq!(
            next_config_path(env(&[("CMUX_NEXT_CONFIG_FILE", "~/x.json"), ("HOME", "/h")])),
            std::path::PathBuf::from("/h/x.json")
        );
        let dir = if cfg!(target_os = "macos") { "cmux-next" } else { "cmux" };
        assert_eq!(
            next_config_path(env(&[("HOME", "/h")])),
            std::path::PathBuf::from(format!("/h/.config/{dir}/cmux-next.json"))
        );
    }
}
