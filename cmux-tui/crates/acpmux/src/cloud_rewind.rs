//! Cloud whole-machine rewind transport and turn fence.
//!
//! The machine credential is intentionally not accepted here: platform machine credentials
//! authenticate machine self-management, while capture/rewind are owner-authorized operations.
//! Callers provide a short-lived owner capability for each request. The capability provider is
//! never serialized, logged, or placed in session metadata.

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use zeroize::Zeroizing;

const MAX_COMPONENT: usize = 256;

/// A short-lived owner capability supplied by the authenticated app/broker.
///
/// Implementations must mint/read the capability from the live authority on every call. In
/// particular, a machine join credential (`cmm_…`) is not an owner capability and must be
/// rejected by the implementation that supplies this trait.
pub trait OwnerCapability: Send + Sync {
    fn bearer(&self) -> Result<Zeroizing<String>>;
}

#[derive(Clone)]
pub struct CloudTurnClient {
    http: reqwest::Client,
    origin: reqwest::Url,
    workspace: String,
    machine: String,
    auth: Arc<dyn OwnerCapability>,
}

impl std::fmt::Debug for CloudTurnClient {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CloudTurnClient")
            .field("origin", &self.origin)
            .field("workspace", &self.workspace)
            .field("machine", &self.machine)
            .finish_non_exhaustive()
    }
}

impl CloudTurnClient {
    pub fn new(
        origin: &str,
        workspace: impl Into<String>,
        machine: impl Into<String>,
        auth: Arc<dyn OwnerCapability>,
    ) -> Result<Self> {
        let origin = reqwest::Url::parse(origin).context("cloud origin is malformed")?;
        anyhow::ensure!(origin.scheme() == "https", "cloud origin must use https");
        anyhow::ensure!(
            origin.path() == "/" && origin.query().is_none() && origin.fragment().is_none(),
            "cloud origin must be an origin"
        );
        let workspace = workspace.into();
        let machine = machine.into();
        valid_component("workspace", &workspace)?;
        valid_component("machine", &machine)?;
        Ok(Self { http: reqwest::Client::new(), origin, workspace, machine, auth })
    }

    #[cfg(test)]
    fn with_http(
        http: reqwest::Client,
        origin: &str,
        workspace: impl Into<String>,
        machine: impl Into<String>,
        auth: Arc<dyn OwnerCapability>,
    ) -> Result<Self> {
        let mut client = Self::new(origin, workspace, machine, auth)?;
        client.http = http;
        Ok(client)
    }

    /// Stable idempotency key for one acpmux session. It contains no secret.
    pub fn client_key(session: &str) -> Result<String> {
        valid_component("session", session)?;
        Ok(format!("acpmux-{session}"))
    }

    fn route(&self, turn: &str, operation: &str) -> Result<reqwest::Url> {
        valid_component("turn", turn)?;
        let mut url = self.origin.clone();
        url.set_path(&format!(
            "/v1/workspaces/{}/machine/turns/{}/{}",
            self.workspace, turn, operation
        ));
        Ok(url)
    }

    fn state_route(&self, turn: &str) -> Result<reqwest::Url> {
        valid_component("turn", turn)?;
        let mut url = self.origin.clone();
        url.set_path(&format!("/v1/workspaces/{}/machine/turns/{}", self.workspace, turn));
        Ok(url)
    }

    async fn post<T: Serialize, R: for<'de> Deserialize<'de>>(
        &self,
        turn: &str,
        operation: &str,
        body: &T,
    ) -> Result<R> {
        let token = self.auth.bearer().context("owner capability unavailable")?;
        anyhow::ensure!(!token.is_empty(), "owner capability is empty");
        let response = self
            .http
            .post(self.route(turn, operation)?)
            .bearer_auth(token.as_str())
            .json(body)
            .send()
            .await
            .with_context(|| format!("cloud turn {operation} request failed"))?;
        let status = response.status();
        let bytes = response.bytes().await.context("read cloud turn response")?;
        if !status.is_success() {
            let detail = serde_json::from_slice::<Value>(&bytes)
                .ok()
                .and_then(|v| v.get("error").cloned())
                .map(|v| v.to_string())
                .unwrap_or_else(|| String::from_utf8_lossy(&bytes).into_owned());
            bail!("cloud turn {operation} failed ({}): {detail}", status.as_u16());
        }
        serde_json::from_slice(&bytes).context("decode cloud turn response")
    }

    /// Reads the authoritative capture state before dispatch or after reconnect. The caller must
    /// compare `machine_generation` with its local fence; a restored guest can still be running
    /// old process state, so a local socket reconnect is not proof of freshness.
    pub async fn state(&self, turn: &str, session: &str) -> Result<SnapshotReply> {
        valid_component("session", session)?;
        let token = self.auth.bearer().context("owner capability unavailable")?;
        anyhow::ensure!(!token.is_empty(), "owner capability is empty");
        let mut url = self.state_route(turn)?;
        url.query_pairs_mut().append_pair("session", session);
        let response = self
            .http
            .get(url)
            .bearer_auth(token.as_str())
            .send()
            .await
            .context("cloud turn state request failed")?;
        let status = response.status();
        let bytes = response.bytes().await.context("read cloud turn state")?;
        if !status.is_success() {
            bail!("cloud turn state failed ({})", status.as_u16());
        }
        serde_json::from_slice(&bytes).context("decode cloud turn state")
    }

    /// Reads the workspace gate and immutable captures after reconnect.
    pub async fn captures(&self) -> Result<TurnLedgerState> {
        let token = self.auth.bearer().context("owner capability unavailable")?;
        anyhow::ensure!(!token.is_empty(), "owner capability is empty");
        let mut url = self.origin.clone();
        url.set_path(&format!("/v1/workspaces/{}/machine/turns", self.workspace));
        let response = self
            .http
            .get(url)
            .bearer_auth(token.as_str())
            .send()
            .await
            .context("cloud turn list request failed")?;
        let status = response.status();
        let bytes = response.bytes().await.context("read cloud turn list")?;
        if !status.is_success() {
            bail!("cloud turn list failed ({})", status.as_u16());
        }
        serde_json::from_slice(&bytes).context("decode cloud turn list")
    }

    pub async fn snapshot(
        &self,
        turn: &str,
        session: &str,
        expected_machine: &str,
        expected_generation: u64,
    ) -> Result<SnapshotReply> {
        let client_key = Self::client_key(session)?;
        valid_component("machine", expected_machine)?;
        self.post(
            turn,
            "snapshot",
            &SnapshotRequest { session, client_key, expected_machine, expected_generation },
        )
        .await
    }

    pub async fn start(
        &self,
        turn: &str,
        session: &str,
        expected_machine: &str,
        expected_generation: u64,
    ) -> Result<SnapshotReply> {
        valid_component("machine", expected_machine)?;
        self.post(
            turn,
            "start",
            &TurnBarrierRequest { session, expected_machine, expected_generation },
        )
        .await
    }

    pub async fn finish(
        &self,
        turn: &str,
        session: &str,
        expected_machine: &str,
        expected_generation: u64,
    ) -> Result<SnapshotReply> {
        valid_component("machine", expected_machine)?;
        self.post(
            turn,
            "finish",
            &TurnBarrierRequest { session, expected_machine, expected_generation },
        )
        .await
    }

    pub async fn rewind(
        &self,
        turn: &str,
        session: &str,
        expected_machine: &str,
        expected_generation: u64,
    ) -> Result<RewindReply> {
        valid_component("machine", expected_machine)?;
        let client_key = Self::client_key(session)?;
        self.post(
            turn,
            "rewind",
            &RewindRequest { session, client_key, expected_machine, expected_generation },
        )
        .await
    }
}

fn valid_component(name: &str, value: &str) -> Result<()> {
    if value.is_empty()
        || value.len() > MAX_COMPONENT
        || !value.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
    {
        bail!("cloud {name} is malformed")
    }
    Ok(())
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct SnapshotRequest<'a> {
    session: &'a str,
    client_key: String,
    expected_machine: &'a str,
    expected_generation: u64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct TurnBarrierRequest<'a> {
    session: &'a str,
    expected_machine: &'a str,
    expected_generation: u64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RewindRequest<'a> {
    session: &'a str,
    client_key: String,
    expected_machine: &'a str,
    expected_generation: u64,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SnapshotReply {
    pub id: String,
    pub workspace: String,
    pub session: String,
    pub turn: String,
    pub machine_id: String,
    pub machine_generation: u64,
    pub snapshot_id: String,
    pub status: String,
    #[serde(default)]
    pub created_at: Option<String>,
    #[serde(default)]
    pub updated_at: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RewindReply {
    pub machine: MachineReplacement,
    pub capture: SnapshotReply,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct MachineReplacement {
    pub id: String,
    pub generation: u64,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TurnLedgerState {
    pub machine_id: String,
    pub generation: u64,
    pub revision: u64,
    pub gate: TurnGate,
    #[serde(default)]
    pub captures: Vec<SnapshotReply>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum TurnGatePhase {
    Idle,
    Capturing,
    Reserved,
    Running,
    Rewinding,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TurnGate {
    pub phase: TurnGatePhase,
    #[serde(default)]
    pub capture_id: Option<String>,
    #[serde(default)]
    pub rewind_id: Option<String>,
}

/// The local side of the per-turn capture ledger. It is a fence, not authority: the platform
/// validates the generation and active-turn admission again. A rewind can therefore never be
/// authorized by stale local state alone.
#[derive(Debug, Default)]
pub struct TurnCaptureLedger {
    state: Mutex<LedgerState>,
}

#[derive(Debug, Default)]
struct LedgerState {
    generation: u64,
    machine: Option<String>,
    active: Option<ActiveTurn>,
    captures: BTreeMap<String, SnapshotReply>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActiveTurn {
    pub turn: String,
    pub generation: u64,
}

impl TurnCaptureLedger {
    pub fn new(machine: impl Into<String>, generation: u64) -> Self {
        Self {
            state: Mutex::new(LedgerState {
                generation,
                machine: Some(machine.into()),
                ..LedgerState::default()
            }),
        }
    }

    pub fn generation(&self) -> u64 {
        self.state.lock().unwrap_or_else(|e| e.into_inner()).generation
    }

    pub fn machine(&self) -> Option<String> {
        self.state.lock().unwrap_or_else(|e| e.into_inner()).machine.clone()
    }

    /// Claims a turn at the current generation. A second claim is refused until `finish`.
    pub fn claim(&self, turn: impl Into<String>) -> Result<ActiveTurn> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if state.active.is_some() {
            bail!("cloud turn admission already active")
        }
        let active = ActiveTurn { turn: turn.into(), generation: state.generation };
        state.active = Some(active.clone());
        Ok(active)
    }

    /// Records a capture exactly once. Repeating a lost response with the same turn is idempotent.
    pub fn record_capture(&self, capture: SnapshotReply) -> Result<SnapshotReply> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if capture.machine_generation != state.generation {
            bail!("cloud capture generation mismatch")
        }
        if let Some(existing) = state.captures.get(&capture.turn) {
            if existing.snapshot_id != capture.snapshot_id {
                bail!("cloud turn has conflicting captures")
            }
            return Ok(existing.clone());
        }
        state.captures.insert(capture.turn.clone(), capture.clone());
        Ok(capture)
    }

    /// Finishes only the admitted turn; a stale finish cannot clear a replacement turn.
    pub fn finish(&self, turn: &str, generation: u64) -> Result<()> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        match state.active.as_ref() {
            Some(active) if active.turn == turn && active.generation == generation => {
                state.active = None;
                Ok(())
            }
            _ => bail!("cloud turn finish fence mismatch"),
        }
    }

    /// Applies a successful provider rewind and fences all old turns/captures.
    pub fn apply_rewind(&self, turn: &str, replacement: &MachineReplacement) -> Result<()> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        anyhow::ensure!(state.active.is_none(), "cannot rewind an active turn");
        anyhow::ensure!(state.captures.contains_key(turn), "unknown cloud capture");
        anyhow::ensure!(
            replacement.generation > state.generation,
            "rewind generation did not advance"
        );
        state.machine = Some(replacement.id.clone());
        state.generation = replacement.generation;
        state.captures.retain(|_, capture| capture.machine_generation >= replacement.generation);
        Ok(())
    }

    pub fn capture(&self, turn: &str) -> Option<SnapshotReply> {
        self.state.lock().unwrap_or_else(|e| e.into_inner()).captures.get(turn).cloned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct FakeCapability {
        calls: AtomicUsize,
    }
    impl OwnerCapability for FakeCapability {
        fn bearer(&self) -> Result<Zeroizing<String>> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            Ok(Zeroizing::new("owner-capability".into()))
        }
    }

    #[test]
    fn ledger_is_idempotent_and_fenced() {
        let ledger = TurnCaptureLedger::new("machine-a", 3);
        let active = ledger.claim("turn-a").unwrap();
        assert_eq!(active.generation, 3);
        let capture = SnapshotReply {
            id: "capture-a".into(),
            workspace: "ws".into(),
            session: "session".into(),
            turn: "turn-a".into(),
            machine_id: "machine-a".into(),
            machine_generation: 3,
            snapshot_id: "snapshot-a".into(),
            status: "ready".into(),
            created_at: None,
            updated_at: None,
        };
        assert_eq!(ledger.record_capture(capture.clone()).unwrap(), capture);
        assert_eq!(ledger.record_capture(capture.clone()).unwrap(), capture);
        ledger.finish("turn-a", 3).unwrap();
        assert!(ledger.finish("turn-a", 3).is_err());
        ledger
            .apply_rewind("turn-a", &MachineReplacement { id: "machine-b".into(), generation: 4 })
            .unwrap();
        assert_eq!(ledger.machine().as_deref(), Some("machine-b"));
        assert_eq!(ledger.generation(), 4);
        assert!(ledger.capture("turn-a").is_none());
    }

    #[test]
    fn rejects_conflicting_capture_and_stale_rewind() {
        let ledger = TurnCaptureLedger::new("machine-a", 8);
        ledger.claim("turn-a").unwrap();
        let mut capture = SnapshotReply {
            id: "capture-a".into(),
            workspace: "ws".into(),
            session: "session".into(),
            turn: "turn-a".into(),
            machine_id: "machine-a".into(),
            machine_generation: 8,
            snapshot_id: "snapshot-a".into(),
            status: "ready".into(),
            created_at: None,
            updated_at: None,
        };
        ledger.record_capture(capture.clone()).unwrap();
        capture.snapshot_id = "snapshot-other".into();
        assert!(ledger.record_capture(capture).is_err());
        assert!(
            ledger
                .apply_rewind(
                    "turn-a",
                    &MachineReplacement { id: "machine-b".into(), generation: 8 }
                )
                .is_err()
        );
    }

    #[test]
    fn client_rejects_untrusted_origin_and_stable_key_has_no_secret() {
        let auth = Arc::new(FakeCapability { calls: AtomicUsize::new(0) });
        assert!(
            CloudTurnClient::new("http://cloud.example", "ws", "machine", auth.clone()).is_err()
        );
        assert_eq!(CloudTurnClient::client_key("session-1").unwrap(), "acpmux-session-1");
        assert!(CloudTurnClient::client_key("session/evil").is_err());
        assert_eq!(auth.calls.load(Ordering::SeqCst), 0);
    }
}
