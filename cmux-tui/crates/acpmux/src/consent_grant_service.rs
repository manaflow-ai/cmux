//! The hub carrier's consent service ([`CircuitService::Consent`], hello
//! `{"service":"consent"}`): how the owner's app on one machine reads and switches Control and
//! Screen on another of his machines (`cli/consent_grant.rs` holds the trust design).
//!
//! - Served only to a dialer this machine's own read of the hub's book lists for its account
//!   ([`ConfiguredConsentGate::admit`], as the session gate does); any other gets
//!   `machine.unlisted`. The carrier's Noise handshake already proved the dialer's key.
//! - After the ok answer the dialer sends one request record (at most 8 KiB) and gets one answer
//!   record, then the circuit closes. `{"op":"status","grantor"?}` answers this machine's ids and
//!   switches; `{"op":"set","grant"}` applies a signed grant and answers the same, or the refusal.
//! - The carrier carries grants; it decides nothing. A grant counts only when a key this machine
//!   pinned signed it, so a carrier, relay or platform that forges or alters one is refused.

use std::path::PathBuf;
use std::sync::{Arc, Weak};
use std::time::Duration;

use async_trait::async_trait;
use bytes::Bytes;
use cmux_remote::link::FrameLink;
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::cli::consent_grant::{self, MAX_REQUEST_BYTES, Target};
use crate::hub::Hub;
use crate::hub_carrier::{CircuitService, HubCarrier, ServiceRefusal};

/// The longest answer a dialer reads.
const MAX_ANSWER_BYTES: usize = 256 * 1024;
/// How long a remote consent call may take, dial included.
pub const REMOTE_WAIT: Duration = Duration::from_secs(20);

/// Whether this machine takes a consent request from a dialer, and its answer to one.
#[async_trait]
pub trait ConsentGate: Send + Sync + 'static {
    /// The host the hub book lists for the dialer whose hub `daemonId` is `from` (as the Noise
    /// handshake proved it), or why it may not ask.
    async fn admit(&self, from: &str) -> Result<String, ServiceRefusal>;
    /// The answer to one request from the machine the book lists as `host`.
    async fn answer(&self, host: &str, request: Vec<u8>) -> Value;
}

/// The daemon's consent gate: the hub book, the joined identity and the account-wide consent
/// authority, or a fixed authority and identity ([`Self::at`]).
pub struct ConfiguredConsentGate {
    hub: Weak<Hub>,
    fixed: Option<(PathBuf, Target)>,
}

impl ConfiguredConsentGate {
    pub fn new(hub: &Arc<Hub>) -> Self {
        Self { hub: Arc::downgrade(hub), fixed: None }
    }

    /// A gate whose consent authority is the directory `root` and whose identity is `target`,
    /// not the OS account's and the joined record's: a carrier test's machine. The node key is
    /// the hub carrier's when one runs.
    pub fn at(hub: &Arc<Hub>, root: PathBuf, target: Target) -> Self {
        Self { hub: Arc::downgrade(hub), fixed: Some((root, target)) }
    }
}

#[async_trait]
impl ConsentGate for ConfiguredConsentGate {
    async fn admit(&self, from: &str) -> Result<String, ServiceRefusal> {
        let hub =
            self.hub.upgrade().ok_or_else(|| ServiceRefusal::new("service.off", "stopping"))?;
        hub.mesh_book_machine(from).ok_or_else(|| {
            ServiceRefusal::new(
                "machine.unlisted",
                "this machine's hub book does not list the asking machine for its account yet; \
                 try again in a moment",
            )
        })
    }

    async fn answer(&self, host: &str, request: Vec<u8>) -> Value {
        let Some(hub) = self.hub.upgrade() else {
            return json!({"ok": false, "reason": "service.off", "error": "stopping"});
        };
        let node_key = hub.hub_carrier.get().map(|carrier| carrier.public_key());
        let fixed = self.fixed.clone();
        let host = host.to_owned();
        tokio::task::spawn_blocking(move || {
            let (authority, mut target) = match fixed {
                Some((root, target)) => {
                    let legacy = root.join("daemon-home");
                    (crate::cli::machine_consent::Authority::at(root, legacy), target)
                }
                None => match crate::cli::cloud_join::authority() {
                    Ok(authority) => (authority, daemon_target()),
                    Err(_) => {
                        return json!({"ok": false, "reason": consent_grant::STORE,
                            "error": "this machine's consent store is unavailable"});
                    }
                },
            };
            if node_key.is_some() {
                target.node_key = node_key;
            }
            let now = crate::store::now_ms();
            consent_grant::handle_request(&authority, &target, Some(&host), &request, now)
        })
        .await
        .unwrap_or_else(|_| json!({"ok": false, "reason": consent_grant::STORE, "error": "failed"}))
    }
}

/// This machine as its joined record names it: the account, the machine id and its name. The
/// node key is the carrier's.
fn daemon_target() -> Target {
    let record = crate::cli::cloud_join::machine_credential()
        .ok()
        .flatten()
        .filter(|record| !record.revoked);
    Target {
        account: crate::cli::cloud_join::machine_user_id(),
        machine_id: record.as_ref().map(|record| record.machine_id.clone()),
        node_key: None,
        name: record.map(|record| record.name),
    }
}

/// Serves one consent circuit whose hello was read: the gate admits `from` or the refusal is the
/// answer; then one request, one answer, and the circuit closes.
pub(crate) async fn serve(
    gate: Option<Arc<dyn ConsentGate>>,
    from: Option<String>,
    link: Box<dyn FrameLink>,
    wait: Duration,
) {
    let admitted = match (gate, from) {
        (Some(gate), Some(from)) => gate.admit(&from).await.map(|host| (gate, host)),
        (None, _) => Err(ServiceRefusal::new(
            "service.off",
            "this machine takes no consent changes from its other machines",
        )),
        (Some(_), None) => Err(ServiceRefusal::new(
            "service.unknown_machine",
            "the circuit's machine key is not one this machine admitted",
        )),
    };
    let (gate, host) = match admitted {
        Ok(admitted) => admitted,
        Err(refusal) => {
            tracing::info!("hub carrier: a consent circuit was refused: {refusal}");
            let answer = json!({"ok": false, "reason": refusal.reason, "error": refusal.message});
            let _ = link.send(Bytes::from(answer.to_string())).await;
            let _ = link.close().await;
            return;
        }
    };
    if link.send(Bytes::from_static(b"{\"ok\":true}")).await.is_err() {
        let _ = link.close().await;
        return;
    }
    let answer = match tokio::time::timeout(wait, read_request(link.as_ref())).await {
        Ok(Some(request)) => gate.answer(&host, request).await,
        _ => json!({"ok": false, "reason": "request.malformed", "error": "no request arrived"}),
    };
    let _ = link.send(Bytes::from(answer.to_string())).await;
    let _ = link.close().await;
}

/// The request: records until they make one JSON value, or past [`MAX_REQUEST_BYTES`] (which the
/// handler refuses).
async fn read_request(link: &dyn FrameLink) -> Option<Vec<u8>> {
    let mut request = Vec::new();
    loop {
        let record = link.receive().await.ok()??;
        request.extend_from_slice(&record);
        if request.len() > MAX_REQUEST_BYTES
            || serde_json::from_slice::<serde::de::IgnoredAny>(&request).is_ok()
        {
            return Some(request);
        }
    }
}

/// One request to the consent service of the machine whose hub `daemonId` is `daemon`, through
/// `carrier`: its answer, or `{ok: false, reason, error}` when it refused or did not answer.
pub async fn ask(carrier: &HubCarrier, daemon: &str, request: &Value, wait: Duration) -> Value {
    let unreachable =
        |error: &str| json!({"ok": false, "reason": "machine.unreachable", "error": error});
    let exchange = async {
        let mut stream = match carrier.dial_service(daemon, CircuitService::Consent).await {
            Ok(stream) => stream,
            Err(error) => {
                let mut refusal = crate::machine_routes::refusal_of(&error);
                if let Some(fields) = refusal.as_object_mut() {
                    fields.insert("ok".into(), json!(false));
                }
                return refusal;
            }
        };
        if stream.write_all(request.to_string().as_bytes()).await.is_err() {
            return unreachable("the machine closed the circuit before the request");
        }
        // The far end closes after its one answer.
        let mut answer = Vec::new();
        let limit = u64::try_from(MAX_ANSWER_BYTES).unwrap_or(u64::MAX);
        if (&mut stream).take(limit).read_to_end(&mut answer).await.is_err() {
            return unreachable("the circuit failed before the answer");
        }
        serde_json::from_slice::<Value>(&answer)
            .ok()
            .filter(Value::is_object)
            .unwrap_or_else(|| unreachable("the machine sent no answer"))
    };
    tokio::time::timeout(wait, exchange)
        .await
        .unwrap_or_else(|_| unreachable("the machine did not answer in time"))
}

/// [`ask`] the machine `daemon` through this daemon's carrier, when the hub book lists it.
pub async fn remote(hub: &Hub, daemon: &str, request: &Value) -> Value {
    if hub.mesh_book_machine(daemon).is_none() {
        return json!({"ok": false, "reason": "machine.unlisted",
            "error": "the hub no longer lists that machine for this account"});
    }
    let Some(carrier) = hub.hub_carrier.get() else {
        return json!({"ok": false, "reason": "machine.unreachable",
            "error": "this machine's hub carrier is off (not joined, or no node key)"});
    };
    ask(&carrier, daemon, request, REMOTE_WAIT).await
}
