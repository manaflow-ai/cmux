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

use crate::cli::consent_grant::{self, MAX_REQUEST_BYTES, OwnGrantor, Target};
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
        let own = own_grantor(&hub);
        let fixed = self.fixed.clone();
        let host = host.to_owned();
        tokio::task::spawn_blocking(move || {
            let (authority, mut target) = match fixed {
                Some((root, target)) => {
                    let legacy = root.join("daemon-home");
                    (crate::cli::machine_consent::Authority::at(root, legacy), target)
                }
                None => match crate::cli::cloud_join::authority() {
                    Ok(authority) => (authority, daemon_target(None, own)),
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

/// This machine's own app key, as the app here gave it (`_acpmux/mac_approver_set`).
pub fn own_grantor(hub: &Hub) -> Option<OwnGrantor> {
    OwnGrantor::of(&hub.person.macs.view(&json!({})))
}

/// This machine as its joined record names it: the account, the machine id, its name, its node
/// key (`node_key`, the carrier's) and its own app key. Blocking: it reads the record.
fn daemon_target(node_key: Option<String>, own: Option<OwnGrantor>) -> Target {
    let record = crate::cli::cloud_join::machine_credential()
        .ok()
        .flatten()
        .filter(|record| !record.revoked);
    Target {
        account: crate::cli::cloud_join::machine_user_id(),
        machine_id: record.as_ref().map(|record| record.machine_id.clone()),
        node_key,
        name: record.map(|record| record.name),
        own_grantor: own,
    }
}

/// [`daemon_target`] for `hub`, off the async thread.
async fn this_target(hub: &Hub) -> Target {
    let node_key = hub.hub_carrier.get().map(|carrier| carrier.public_key());
    let own = own_grantor(hub);
    tokio::task::spawn_blocking(move || daemon_target(node_key, own)).await.unwrap_or_default()
}

/// Runs `work` on the account's consent authority off the async thread; None when it is
/// unavailable.
async fn with_authority<T: Send + 'static>(
    work: impl FnOnce(&crate::cli::machine_consent::Authority) -> T + Send + 'static,
) -> Option<T> {
    tokio::task::spawn_blocking(move || {
        crate::cli::cloud_join::authority().ok().map(|authority| work(&authority))
    })
    .await
    .ok()
    .flatten()
}

/// `_acpmux/consent_account_set {grant}`: an account-wide grant this machine's own app key
/// signed, applied here, then handed to every listed machine of the account through the carrier.
/// `{"ok", "reason"?, "error"?, "self": {ok, reason?}, "applied": [{daemonId, host, ok, reason?}]}`;
/// `ok` is false only when the grant is not this Mac's own (nothing is applied or sent then).
pub async fn account_set(hub: &Arc<Hub>, grant: &Value) -> Value {
    let own = own_grantor(hub);
    if let Err(refusal) = consent_grant::own_account_grant(grant, own.as_ref()) {
        return refusal.answer();
    }
    let target = this_target(hub).await;
    let local = grant.clone();
    let here = with_authority(move |authority| {
        let now = crate::store::now_ms();
        consent_grant::apply(authority, &local, &target, None, now).map(|_| ())
    })
    .await;
    let here = match here {
        Some(Ok(())) => json!({"ok": true}),
        Some(Err(refusal)) => {
            json!({"ok": false, "reason": refusal.reason, "error": refusal.error})
        }
        None => json!({"ok": false, "reason": consent_grant::STORE}),
    };
    let request = json!({"op": "set", "grant": grant});
    let mut asks = tokio::task::JoinSet::new();
    for (daemon, host) in hub.mesh_book_machines() {
        let hub = Arc::clone(hub);
        let request = request.clone();
        asks.spawn(async move {
            let answer = remote(&hub, &daemon, &request).await;
            let ok = answer.get("ok").and_then(Value::as_bool) == Some(true);
            let mut row = json!({"daemonId": daemon, "host": host, "ok": ok});
            if let (Some(reason), Some(fields)) = (answer.get("reason"), row.as_object_mut()) {
                fields.insert("reason".into(), reason.clone());
            }
            row
        });
    }
    let mut applied = Vec::new();
    while let Some(row) = asks.join_next().await {
        if let Ok(row) = row {
            applied.push(row);
        }
    }
    json!({"ok": true, "self": here, "applied": applied})
}

/// One enrollment collection at a time per daemon.
static COLLECTING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// After a step the person took here that enrolls this machine (a sign-in's new join): opens the
/// enrollment window and collects in the background ([`collect_while_open`]).
pub fn enrolled(hub: &Arc<Hub>) {
    let hub = Arc::clone(hub);
    hub.clone().scope.spawn_until_cancelled("consent-enrollment", async move {
        let now = crate::store::now_ms();
        if with_authority(move |authority| consent_grant::open_window(authority, now).is_ok()).await
            == Some(true)
        {
            collect_while_open(&hub).await;
        }
    });
}

/// When the carrier starts with the enrollment window open (a join line just ran), collects in
/// the background ([`collect_while_open`]).
pub fn collect_if_open(hub: &Arc<Hub>) {
    let hub = Arc::clone(hub);
    hub.clone().scope.spawn_until_cancelled("consent-enrollment", async move {
        let now = crate::store::now_ms();
        if with_authority(move |authority| consent_grant::window_open(authority, now)).await
            == Some(true)
        {
            collect_while_open(&hub).await;
        }
    });
}

/// Passes of [`collect`] every few seconds while the window is open, until every listed machine
/// answered.
async fn collect_while_open(hub: &Arc<Hub>) {
    use std::sync::atomic::Ordering;
    if COLLECTING.swap(true, Ordering::SeqCst) {
        return;
    }
    let mut done = std::collections::BTreeSet::new();
    loop {
        let pass = collect(hub, &mut done).await;
        let pinned = pass.get("pinned").cloned().unwrap_or_default();
        tracing::info!(%pinned, "consent: enrollment collection pass");
        let now = crate::store::now_ms();
        let open = with_authority(move |authority| consent_grant::window_open(authority, now))
            .await
            == Some(true);
        let listed = hub.mesh_book_machines();
        let all = !listed.is_empty() && listed.iter().all(|(daemon, _)| done.contains(daemon));
        if !open || all {
            break;
        }
        tokio::time::sleep(Duration::from_secs(5)).await;
    }
    COLLECTING.store(false, Ordering::SeqCst);
}

/// `_acpmux/consent_trust_refresh {}`: the person's Refresh trusted Macs. Opens the enrollment
/// window and runs one collection pass now: `{"ok", "pinned": [id], "asked": [id], "policy": bool,
/// "peers": [{daemonId, host, ok, reason?}]}`.
pub async fn trust_refresh(hub: &Arc<Hub>) -> Value {
    let now = crate::store::now_ms();
    if with_authority(move |authority| consent_grant::open_window(authority, now).is_ok()).await
        != Some(true)
    {
        return json!({"ok": false, "reason": consent_grant::STORE,
            "error": "this machine's consent store is unavailable"});
    }
    collect(hub, &mut std::collections::BTreeSet::new()).await
}

/// One enrollment collection pass while the window is open: pins this machine's OWN app key only,
/// then asks each listed machine of the account not yet in `done` for the key its app reported
/// (`op: "status"`, `ownGrantor`), which becomes a pending ask, never a pin, then for its account
/// policy (`op: "policy"`),
/// which is applied here when it is newer than the one kept (its signer must be pinned).
async fn collect(hub: &Arc<Hub>, done: &mut std::collections::BTreeSet<String>) -> Value {
    let target = this_target(hub).await;
    let Some(account) = target.account.clone() else {
        return json!({"ok": false, "reason": consent_grant::NOT_JOINED,
            "error": "this machine is not joined to an account", "pinned": []});
    };
    let (mut pinned, mut asked) = (Vec::new(), Vec::new());
    let mut policy = false;
    if let Some(own) = target.own_grantor.clone() {
        let account = account.clone();
        let pin = with_authority(move |authority| {
            let now = crate::store::now_ms();
            consent_grant::pin_enrolled(authority, &own.public_key, &own.name, &account, now)
                .map(|new| new.then_some(own.id))
        })
        .await;
        if let Some(Ok(Some(id))) = pin {
            pinned.push(id);
        }
    }
    let mut peers = Vec::new();
    for (daemon, host) in hub.mesh_book_machines() {
        if done.contains(&daemon) {
            continue;
        }
        let status = remote(hub, &daemon, &json!({"op": "status"})).await;
        if status.get("ok").and_then(Value::as_bool) != Some(true) {
            peers.push(json!({"daemonId": daemon, "host": host, "ok": false,
                "reason": status.get("reason")}));
            continue;
        }
        done.insert(daemon.clone());
        peers.push(json!({"daemonId": daemon, "host": host, "ok": true}));
        if status.get("account").and_then(Value::as_str) != Some(account.as_str()) {
            continue;
        }
        // The key the peer's app reported is never pinned here: it becomes an ask the person
        // confirms with its four words in the app on this machine.
        let (reported, from) = (status.clone(), host.clone());
        let account_now = account.clone();
        let ask = with_authority(move |authority| {
            let now = crate::store::now_ms();
            consent_grant::note_reported(authority, &reported, &from, &account_now, now)
        })
        .await;
        if let Some(Ok(Some(id))) = ask {
            asked.push(id);
        }
        let handed = remote(hub, &daemon, &json!({"op": "policy"})).await;
        let Some(grant) = handed.get("grant").filter(|grant| grant.is_object()).cloned() else {
            continue;
        };
        let (account, target) = (account.clone(), target.clone());
        let applied = with_authority(move |authority| {
            if !consent_grant::policy_replaces(authority, &account, &grant) {
                return false;
            }
            let now = crate::store::now_ms();
            consent_grant::apply(authority, &grant, &target, Some(&host), now).is_ok()
        })
        .await;
        policy |= applied == Some(true);
    }
    json!({"ok": true, "pinned": pinned, "asked": asked, "policy": policy, "peers": peers})
}

/// Whether the gate admits the machine whose hub `daemonId` is `from` (as the Noise handshake
/// proved it): the gate and the host its book lists, else the refusal.
pub(crate) async fn admit(
    gate: Option<Arc<dyn ConsentGate>>,
    from: Option<String>,
) -> Result<(Arc<dyn ConsentGate>, String), ServiceRefusal> {
    match (gate, from) {
        (Some(gate), Some(from)) => gate.admit(&from).await.map(|host| (gate, host)),
        (None, _) => Err(ServiceRefusal::new(
            "service.off",
            "this machine takes no consent changes from its other machines",
        )),
        (Some(_), None) => Err(ServiceRefusal::new(
            "service.unknown_machine",
            "the circuit's machine key is not one this machine admitted",
        )),
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
    let (gate, host) = match admit(gate, from).await {
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

/// Serves one consent stream of a kept circuit that `gate` admitted for `host` (the circuit
/// already answered its hello): one request, one answer, then the stream ends.
pub(crate) async fn serve_stream<S>(
    gate: Arc<dyn ConsentGate>,
    host: String,
    mut io: S,
    wait: Duration,
) where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let answer = match tokio::time::timeout(wait, read_stream_request(&mut io)).await {
        Ok(Some(request)) => gate.answer(&host, request).await,
        _ => json!({"ok": false, "reason": "request.malformed", "error": "no request arrived"}),
    };
    let _ = io.write_all(answer.to_string().as_bytes()).await;
    let _ = io.shutdown().await;
}

/// [`read_request`] on a byte stream: bytes until they make one JSON value, or past
/// [`MAX_REQUEST_BYTES`] (which the handler refuses).
async fn read_stream_request<S>(io: &mut S) -> Option<Vec<u8>>
where
    S: tokio::io::AsyncRead + Unpin,
{
    let mut request = Vec::new();
    let mut buf = [0u8; 4096];
    loop {
        let n = io.read(&mut buf).await.ok()?;
        if n == 0 {
            return None;
        }
        request.extend_from_slice(buf.get(..n)?);
        if request.len() > MAX_REQUEST_BYTES
            || serde_json::from_slice::<serde::de::IgnoredAny>(&request).is_ok()
        {
            return Some(request);
        }
    }
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
