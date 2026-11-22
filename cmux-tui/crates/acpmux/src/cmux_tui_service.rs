//! The cmux-tui remote daemon over the hub carrier: `cmux remote exec|cp|connect --via-machine M`
//! reaches machine M's cmux-tui remote daemon through this person's own carrier, with no
//! inbound port and no ssh. Leo, 2026-11-14: "cant our cmux-wg and whatever sorta connect vms
//! to this mac and vice versa? our version of remote".
//!
//! - Dialing side: the CLI connects to this daemon's unix socket and its first line is
//!   `_acpmux/remote.pipe` `{machine, port}` (`rpc::method::MUX_REMOTE_PIPE`). The daemon
//!   dials M's carrier circuit naming the [`CircuitService::CmuxTui`] service
//!   (`HubCarrier::dial_service`), answers one JSON-RPC line, and from then on the socket
//!   carries the circuit's bytes both ways. The CLI speaks the remote protocol over it
//!   (WebSocket upgrade, Noise, device enrollment), as over TCP.
//! - Serving side: [`ConfiguredGate`] lets a circuit through only to the loopback address the
//!   owner named (`remoteDaemon`, `acpmux config --set remote_daemon=127.0.0.1:PORT`), only for
//!   that port, and on a joined machine only while its "control" consent is granted
//!   (`cli/machine_consent.rs`, the gate on anything that reaches a joined Mac from elsewhere).
//!   Without both, no circuit reaches it.
//!
//! What grants what: the carrier's Noise handshake proves the dialer is one of this person's
//! live machines (the platform's `peers`), nothing more. Running commands still takes a device
//! the remote daemon enrolled (`cmux remote enroll`): the daemon listens on loopback without
//! `--remote-ws-trusted-carrier`, so a circuit is an untrusted network connection to it.

use std::net::SocketAddr;
use std::sync::{Arc, Weak};

use async_trait::async_trait;
use serde_json::{Value, json};
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt};

use crate::hub::Hub;
use crate::hub_carrier::{CircuitService, CmuxTuiGate, ServiceRefusal};
use crate::rpc::{Message, RpcError};

/// The serving gate of a daemon: its config's `remoteDaemon` and the machine's consent.
pub struct ConfiguredGate {
    hub: Weak<Hub>,
}

impl ConfiguredGate {
    pub fn new(hub: &Arc<Hub>) -> Self {
        Self { hub: Arc::downgrade(hub) }
    }
}

#[async_trait]
impl CmuxTuiGate for ConfiguredGate {
    async fn admit(&self, port: u16) -> Result<SocketAddr, ServiceRefusal> {
        let hub =
            self.hub.upgrade().ok_or_else(|| ServiceRefusal::new("service.off", "stopping"))?;
        let configured = hub.config.read().await.remote_daemon.clone();
        let consent =
            tokio::task::spawn_blocking(|| crate::cli::cloud_join::consent_status_for(&json!({})))
                .await
                .unwrap_or_else(|_| json!({"consentRequired": true}));
        let admitted = admit(configured.as_deref(), &consent, port);
        if admitted.as_ref().is_err_and(|r| r.reason == crate::cli::cloud_join::CONSENT_REQUIRED) {
            // The app's consent settings show that something asked (`lastRefusal`).
            let _ = tokio::task::spawn_blocking(|| {
                crate::cli::cloud_join::record_consent_refusal("control")
            })
            .await;
        }
        admitted
    }
}

/// Whether a circuit that asked for `port` reaches `configured` (`remoteDaemon`), given the
/// machine's consent status (`_acpmux/machine_consent_get`'s answer for a use from elsewhere).
pub fn admit(
    configured: Option<&str>,
    consent: &Value,
    port: u16,
) -> Result<SocketAddr, ServiceRefusal> {
    let Some(configured) = configured else {
        return Err(ServiceRefusal::new(
            "service.off",
            "this machine serves no cmux-tui remote daemon to its other machines; its owner sets \
             one with `acpmux config --set remote_daemon=127.0.0.1:PORT`",
        ));
    };
    let address = crate::config::loopback_daemon_address(configured)
        .map_err(|e| ServiceRefusal::new("service.misconfigured", format!("{e:#}")))?;
    let required = consent.get("consentRequired").and_then(Value::as_bool) != Some(false);
    let granted = consent.pointer("/consent/control").and_then(Value::as_str) == Some("granted");
    if required && !granted {
        return Err(ServiceRefusal::new(
            crate::cli::cloud_join::CONSENT_REQUIRED,
            "this machine's owner has not granted control from elsewhere",
        ));
    }
    if address.port() != port {
        return Err(ServiceRefusal::new(
            "service.port",
            format!("this machine serves its cmux-tui remote daemon on port {}", address.port()),
        ));
    }
    Ok(address)
}

/// The machine a pipe dials: its hub `daemonId` (its node key, standard base64), given as
/// `daemonId`, or by `machine`: a peer whose config names its WireGuard key, a route the carrier
/// was given, a key itself, or the name the hub lists the machine by (`acpmux machine ls`, the
/// address book's host). This machine's own key is refused: the hub carries only between two of
/// the person's machines, and its daemon is on loopback here.
async fn pipe_target(hub: &Hub, params: &Value) -> Result<(String, u16), RpcError> {
    let text = |key: &str| params.get(key).and_then(Value::as_str).filter(|v| !v.is_empty());
    let port = params
        .get("port")
        .and_then(Value::as_u64)
        .and_then(|p| u16::try_from(p).ok())
        .filter(|p| *p != 0)
        .ok_or_else(|| {
            RpcError::invalid_params("port is required (the remote daemon's loopback port)")
        })?;
    let carrier = hub.hub_carrier.get();
    let daemon = match (text("daemonId"), text("machine")) {
        (Some(key), _) => Some(key.to_owned()),
        (None, Some(machine)) => {
            let configured = hub
                .config
                .read()
                .await
                .peers
                .get(machine)
                .and_then(|peer| peer.wireguard.as_ref().map(|wg| wg.public_key.clone()));
            configured
                .or_else(|| carrier.as_ref().and_then(|c| c.route(machine)))
                .or_else(|| is_key(machine).then(|| machine.to_owned()))
                .or_else(|| book_key(&hub.mesh_book_machines(), machine))
                // A hub-connected machine by the name `acpmux machine ls` shows: the address
                // book's `(daemonId, host)` rows of this person's other machines.
                .or_else(|| book_machine(&hub.mesh_book_machines(), machine))
        }
        (None, None) => {
            return Err(RpcError::invalid_params("machine is required"));
        }
    };
    let daemon = daemon.ok_or_else(|| {
        RpcError::invalid_params(
            "no hub route to that machine: name a peer whose config names its WireGuard key, or \
             the machine's node key (`acpmux machine status --json` there, `wgPublicKey`), or \
             a machine name `acpmux machine ls` shows with via hub",
        )
        .with_data(json!({"reason": "machine.unknown"}))
    })?;
    if carrier.as_ref().is_some_and(|c| c.public_key() == daemon) {
        return Err(RpcError::invalid_params(format!(
            "that is this machine: the hub carries only between two of your machines; reach this \
             machine's daemon at ws://127.0.0.1:{port} without --via-machine"
        ))
        .with_data(json!({"reason": "machine.self"})));
    }
    Ok((daemon, port))
}

/// The `daemonId` of the one machine the hub's address book lists as `name` (its host, any
/// case), among `machines` (`(daemonId, host)`). None when no machine or more than one has it.
fn book_key(machines: &[(String, String)], name: &str) -> Option<String> {
    let mut found = machines.iter().filter(|(_, host)| host.eq_ignore_ascii_case(name));
    let (key, _) = found.next()?;
    found.next().is_none().then(|| key.clone())
}

/// The hub `daemonId` of the machine the address book lists as `name` (its host name, matched
/// exactly, else without case). None when no machine has that name, or two machines do and the
/// name cannot say which: the caller then names the key.
pub(crate) fn book_machine(machines: &[(String, String)], name: &str) -> Option<String> {
    let named = |same: &dyn Fn(&str) -> bool| {
        let mut found = machines.iter().filter(|(_, host)| same(host)).map(|(key, _)| key);
        let first = found.next()?;
        found.all(|key| key == first).then(|| first.clone())
    };
    named(&|host| host == name).or_else(|| named(&|host| host.eq_ignore_ascii_case(name)))
}

fn is_key(text: &str) -> bool {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.decode(text).is_ok_and(|bytes| bytes.len() == 32)
}

/// Serve a `_acpmux/remote.pipe` connection: dial, answer request `id` with one line, then carry
/// bytes between `reader`/`writer` (the unix socket) and the circuit until either side ends.
pub(crate) async fn serve_pipe<R, W>(
    hub: Arc<Hub>,
    id: Value,
    params: Value,
    reader: R,
    mut writer: W,
) where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let dialed = async {
        let (daemon, port) = pipe_target(&hub, &params).await?;
        let carrier = hub.hub_carrier.get().ok_or_else(|| {
            RpcError::new(
                -32000,
                "this machine's hub carrier is off (not joined to a Cloud account, or its node key is missing \
                 or was replaced): `acpmux machine join`, then `acpmux daemon restart`",
            )
            .with_data(json!({"reason": "carrier.off"}))
        })?;
        // The far machine's refusal keeps its own reason (`consent_required`, ...): the CLI
        // ends on one no redial cures and redials the rest (`machine.unreachable`).
        carrier.dial_service(&daemon, CircuitService::CmuxTui { port }).await.map_err(|e| {
            let refusal = crate::machine_routes::refusal_of(&e);
            let message =
                refusal.get("error").and_then(serde_json::Value::as_str).unwrap_or(&e).to_owned();
            RpcError::new(-32000, message).with_data(json!({"reason": refusal.get("reason")}))
        })
    }
    .await;
    let mut circuit = match dialed {
        Ok(circuit) => circuit,
        Err(error) => {
            let _ = writer.write_all(Message::err(id, error).to_line().as_bytes()).await;
            let _ = writer.shutdown().await;
            return;
        }
    };
    let reply = Message::ok(id, json!({"via": "hub"}));
    if writer.write_all(reply.to_line().as_bytes()).await.is_err() {
        return;
    }
    let mut local = tokio::io::join(reader, writer);
    let _ = tokio::io::copy_bidirectional(&mut local, &mut circuit).await;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn consent(required: bool, control: &str) -> Value {
        json!({"consentRequired": required, "consent": {"screen": "none", "control": control}})
    }

    #[test]
    fn a_machine_the_hub_lists_is_named_by_its_host() {
        let machines = vec![
            ("a".repeat(44), "gcp-lane-2".to_owned()),
            ("b".repeat(44), "air".to_owned()),
            ("c".repeat(44), "twice".to_owned()),
            ("d".repeat(44), "Twice".to_owned()),
        ];
        assert_eq!(book_key(&machines, "gcp-lane-2"), Some("a".repeat(44)));
        assert_eq!(book_key(&machines, "AIR"), Some("b".repeat(44)));
        // Two machines listed under one name: neither is picked.
        assert_eq!(book_key(&machines, "twice"), None);
        assert_eq!(book_key(&machines, "nowhere"), None);
    }

    #[test]
    fn no_configured_daemon_admits_nothing() {
        let refused = admit(None, &consent(false, "none"), 7781).unwrap_err();
        assert_eq!(refused.reason, "service.off");
    }

    #[test]
    fn a_joined_machine_needs_control_consent() {
        let refused = admit(Some("127.0.0.1:7781"), &consent(true, "none"), 7781).unwrap_err();
        assert_eq!(refused.reason, crate::cli::cloud_join::CONSENT_REQUIRED);
        // An unreadable consent status counts as required and not granted.
        let refused = admit(Some("127.0.0.1:7781"), &json!({}), 7781).unwrap_err();
        assert_eq!(refused.reason, crate::cli::cloud_join::CONSENT_REQUIRED);
        let address = admit(Some("127.0.0.1:7781"), &consent(true, "granted"), 7781).unwrap();
        assert_eq!(address, "127.0.0.1:7781".parse().unwrap());
    }

    #[test]
    fn only_the_configured_loopback_port_is_reached() {
        let refused = admit(Some("127.0.0.1:7781"), &consent(false, "none"), 22).unwrap_err();
        assert_eq!(refused.reason, "service.port");
        let refused = admit(Some("10.0.0.5:7781"), &consent(false, "none"), 7781).unwrap_err();
        assert_eq!(refused.reason, "service.misconfigured");
        assert!(admit(Some("[::1]:7781"), &consent(false, "none"), 7781).is_ok());
    }

    #[test]
    fn config_set_takes_only_a_loopback_address() {
        let mut config = crate::config::Config::default();
        config.set("remote_daemon", "127.0.0.1:7781").unwrap();
        assert_eq!(config.remote_daemon.as_deref(), Some("127.0.0.1:7781"));
        assert!(config.set("remote-daemon", "0.0.0.0:7781").is_err());
        assert!(config.set("remote_daemon", "example.com:7781").is_err());
        config.set("remoteDaemon", "none").unwrap();
        assert_eq!(config.remote_daemon, None);
        // The hub carrier needs no transport: the transport's switch is refused without its
        // static settings (`config/start_check.rs`), and set with them.
        assert!(config.set("transport.wireguard", "true").is_err());
        assert!(!config.transport.wireguard);
        config.transport.wireguard_static = Some(crate::wireguard::StaticConfig {
            listen: "127.0.0.1:0".parse().unwrap(),
            address: "10.77.0.1:4100".parse().unwrap(),
        });
        config.set("transport.wireguard", "true").unwrap();
        assert!(config.transport.wireguard);
        assert!(config.set("transport.wireguard", "maybe").is_err());
    }
}
