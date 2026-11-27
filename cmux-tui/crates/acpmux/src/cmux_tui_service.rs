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
//!   (WebSocket upgrade, Noise, device enrollment), as over TCP. `{machine, service:
//!   "lane-gh-broker"}` reaches M's lane-gh broker instead (`hub_carrier_broker.rs`).
//! - Serving side: [`ConfiguredGate`] lets a circuit through only to the loopback address the
//!   owner named (`remoteDaemon`, `acpmux config --set remote_daemon=127.0.0.1:PORT`), only for
//!   that port, and on a joined machine only while its "control" consent is granted
//!   (`cli/machine_consent.rs`, the gate on anything that reaches a joined Mac from elsewhere).
//!   Without both, no circuit reaches it. `remotePipe.ssh` (off by default, `acpmux config --set
//!   remote_pipe.ssh=true`) also lets a circuit that asks for port 22 reach loopback sshd, beside
//!   the remote daemon, under the same consent: ssh rides the carrier as a ProxyCommand
//!   (leo-workspace `tools/carrier-pipe`) and sshd still checks every login.
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
        let (configured, ssh) = {
            let config = hub.config.read().await;
            (config.remote_daemon.clone(), config.remote_pipe.ssh)
        };
        let consent =
            tokio::task::spawn_blocking(|| crate::cli::cloud_join::consent_status_for(&json!({})))
                .await
                .unwrap_or_else(|_| json!({"consentRequired": true}));
        let admitted = admit_with(configured.as_deref(), ssh, &consent, port);
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

/// sshd's port, which `remotePipe.ssh` lets a circuit reach on loopback.
pub const SSH_PORT: u16 = 22;

/// Whether a circuit that asked for `port` reaches `configured` (`remoteDaemon`), given the
/// machine's consent status (`_acpmux/machine_consent_get`'s answer for a use from elsewhere).
pub fn admit(
    configured: Option<&str>,
    consent: &Value,
    port: u16,
) -> Result<SocketAddr, ServiceRefusal> {
    admit_with(configured, false, consent, port)
}

/// [`admit`], and with `ssh` (`remotePipe.ssh`) also loopback sshd for a circuit that asked for
/// port 22, under the same consent. The remote daemon's own port is unchanged by it.
pub fn admit_with(
    configured: Option<&str>,
    ssh: bool,
    consent: &Value,
    port: u16,
) -> Result<SocketAddr, ServiceRefusal> {
    if ssh && port == SSH_PORT {
        consented(consent)?;
        return Ok(SocketAddr::from(([127, 0, 0, 1], SSH_PORT)));
    }
    let Some(configured) = configured else {
        return Err(ServiceRefusal::new(
            "service.off",
            "this machine serves no cmux-tui remote daemon to its other machines; its owner sets \
             one with `acpmux config --set remote_daemon=127.0.0.1:PORT`",
        ));
    };
    let address = crate::config::loopback_daemon_address(configured)
        .map_err(|e| ServiceRefusal::new("service.misconfigured", format!("{e:#}")))?;
    consented(consent)?;
    if address.port() != port {
        let more = if port == SSH_PORT && !ssh {
            "; its sshd is reached only once its owner sets `acpmux config --set \
             remote_pipe.ssh=true`"
        } else {
            ""
        };
        return Err(ServiceRefusal::new(
            "service.port",
            format!(
                "this machine serves its cmux-tui remote daemon on port {}{more}",
                address.port()
            ),
        ));
    }
    Ok(address)
}

/// Whether the machine's owner granted control from elsewhere, where it is required.
fn consented(consent: &Value) -> Result<(), ServiceRefusal> {
    let required = consent.get("consentRequired").and_then(Value::as_bool) != Some(false);
    let granted = consent.pointer("/consent/control").and_then(Value::as_str) == Some("granted");
    if required && !granted {
        return Err(ServiceRefusal::new(
            crate::cli::cloud_join::CONSENT_REQUIRED,
            "this machine's owner has not granted control from elsewhere",
        ));
    }
    Ok(())
}

/// The machine a pipe dials: its hub `daemonId` (its node key, standard base64), given as
/// `daemonId`, or by `machine`: a peer whose config names its WireGuard key, a route the carrier
/// was given, a key itself, or the name the hub lists the machine by (`acpmux machine ls`, the
/// address book's host). This machine's own key is refused: the hub carries only between two of
/// the person's machines, and its daemon is on loopback here.
/// A pipe to the far machine's lane-gh broker (`service: "lane-gh-broker"`) names no port: its
/// port is 0 here.
async fn pipe_target(hub: &Hub, params: &Value) -> Result<(String, u16), RpcError> {
    let text = |key: &str| params.get(key).and_then(Value::as_str).filter(|v| !v.is_empty());
    let port = if is_broker_pipe(params) {
        0
    } else {
        params
            .get("port")
            .and_then(Value::as_u64)
            .and_then(|p| u16::try_from(p).ok())
            .filter(|p| *p != 0)
            .ok_or_else(|| {
                RpcError::invalid_params("port is required (the remote daemon's loopback port)")
            })?
    };
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
                // Any machine the carrier lends, by the name the platform gave its Connect
                // ticket: one joined in another team of the person too, which this team's book
                // never lists (cmux16 was `machine.unknown` to every lane VM, 2026-11-24).
                .or_else(|| carrier.as_ref().and_then(|c| c.lent_machine(machine)))
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

/// Whether a `remote.pipe` asks for the far machine's lane-gh broker (RFD 0127 cut 2,
/// `hub_carrier_broker.rs`) rather than its cmux-tui remote daemon.
fn is_broker_pipe(params: &Value) -> bool {
    params.get("service").and_then(Value::as_str)
        == Some(crate::hub_carrier::LANE_GH_BROKER_SERVICE)
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
///
/// `early: N` in the params: the N bytes after the request line are the stream's first bytes
/// (a client that speaks first, as `lane-gh` does to its broker). They are read before the dial
/// and go right behind the stream's OPEN (`HubCarrier::dial_service_early`), so the far
/// service's reply comes one relay round trip after the dial instead of two. An acpmux from
/// before `early` ignores the field and carries those bytes after its reply, as any others, so
/// a client may send it to any daemon.
pub(crate) async fn serve_pipe<R, W>(
    hub: Arc<Hub>,
    id: Value,
    params: Value,
    mut reader: R,
    mut writer: W,
) where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let dialed = async {
        let early = read_early(&mut reader, &params).await?;
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
        // `service: "lane-gh-broker"`: the far machine's lane-gh broker (RFD 0127 cut 2).
        // `resume`: the far acpmux holds the pipe across this one's end (RFD 0127 cut 4,
        // `hub_carrier_resume.rs`); the client resumes it on its next pipe.
        let service = if is_broker_pipe(&params) {
            CircuitService::LaneGhBroker
        } else if params.get("resume").and_then(Value::as_bool) == Some(true) {
            CircuitService::CmuxTuiResume { port }
        } else {
            CircuitService::CmuxTui { port }
        };
        carrier.dial_service_early(&daemon, service, &early).await.map_err(|e| {
            let refusal = crate::machine_routes::refusal_of(&e);
            let message =
                refusal.get("error").and_then(serde_json::Value::as_str).unwrap_or(&e).to_owned();
            RpcError::new(-32000, message).with_data(json!({"reason": refusal.get("reason")}))
        })
    }
    .await;
    let (mut circuit, report) = match dialed {
        Ok(circuit) => circuit,
        Err(error) => {
            let _ = writer.write_all(Message::err(id, error).to_line().as_bytes()).await;
            let _ = writer.shutdown().await;
            return;
        }
    };
    // `dial` says where the open's time went (a stream on the kept circuit, or a new circuit's
    // ticket, relay, join, Noise and answer), so a caller such as NOW's weft probe splits its
    // first byte by step instead of inferring it.
    let reply = Message::ok(id, json!({"via": report.via.name(), "dial": report.to_json()}));
    if writer.write_all(reply.to_line().as_bytes()).await.is_err() {
        return;
    }
    let mut local = tokio::io::join(reader, writer);
    let _ = tokio::io::copy_bidirectional(&mut local, &mut circuit).await;
}

/// How long a pipe's declared early bytes may take to arrive after its request line.
const EARLY_READ_BOUND: std::time::Duration = std::time::Duration::from_secs(10);

/// The `early` bytes a `remote.pipe` request declares (`early: N`), read from `reader`. At most
/// [`crate::hub_carrier::HubCarrier::EARLY_BYTES`] are taken; past that the client's bytes stay
/// in the stream and are carried after the reply.
async fn read_early<R: AsyncRead + Unpin>(
    reader: &mut R,
    params: &Value,
) -> Result<Vec<u8>, RpcError> {
    use tokio::io::AsyncReadExt;
    let declared = params.get("early").and_then(Value::as_u64).unwrap_or(0);
    let take = usize::try_from(declared)
        .unwrap_or(usize::MAX)
        .min(crate::hub_carrier::HubCarrier::EARLY_BYTES);
    let mut early = vec![0u8; take];
    if take > 0 {
        tokio::time::timeout(EARLY_READ_BOUND, reader.read_exact(&mut early))
            .await
            .map_err(|_| "the early bytes did not arrive in time".to_owned())
            .and_then(|read| read.map_err(|e| format!("the early bytes: {e}")))
            .map_err(|why| {
                RpcError::invalid_params(why).with_data(json!({"reason": "pipe.early"}))
            })?;
    }
    Ok(early)
}

#[cfg(test)]
#[path = "cmux_tui_service_tests.rs"]
mod tests;
