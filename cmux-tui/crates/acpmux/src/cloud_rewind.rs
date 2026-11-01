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
use std::time::Duration;
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

/// Ephemeral turn capability from the owner bridge. It cannot be logged or serialized.
pub struct EphemeralCapability(Zeroizing<String>);

impl EphemeralCapability {
    pub fn new(token: String) -> Result<Self> {
        anyhow::ensure!(token.starts_with("trc_"), "turn capability is malformed");
        Ok(Self(Zeroizing::new(token)))
    }
}

impl OwnerCapability for EphemeralCapability {
    fn bearer(&self) -> Result<Zeroizing<String>> {
        Ok(Zeroizing::new(self.0.to_string()))
    }
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
        anyhow::ensure!(
            origin.username().is_empty() && origin.password().is_none(),
            "cloud origin must not contain credentials"
        );
        let workspace = workspace.into();
        let machine = machine.into();
        valid_component("workspace", &workspace)?;
        valid_component("machine", &machine)?;
        let http = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(30))
            .build()
            .context("build cloud turn HTTP client")?;
        Ok(Self { http, origin, workspace, machine, auth })
    }

    /// Stable idempotency key for one acpmux session. It contains no secret.
    pub fn client_key(session: &str) -> Result<String> {
        valid_component("session", session)?;
        Ok(format!("acpmux-{session}"))
    }

    /// Returns a client fenced to a replacement machine after a successful rewind.
    pub fn for_machine(&self, machine: impl Into<String>) -> Result<Self> {
        let machine = machine.into();
        valid_component("machine", &machine)?;
        Ok(Self {
            http: self.http.clone(),
            origin: self.origin.clone(),
            workspace: self.workspace.clone(),
            machine,
            auth: self.auth.clone(),
        })
    }

    fn check_machine(&self, expected: &str) -> Result<()> {
        valid_component("machine", expected)?;
        anyhow::ensure!(expected == self.machine, "cloud machine fence mismatch");
        Ok(())
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

    /// Claims the one-use execution capability immediately before the harness prompt is sent.
    /// The supplied capability must be the opaque `trc_…` token minted by the owner bridge.
    pub async fn claim_execution(&self, scope: &TurnScope) -> Result<ExecutionReply> {
        anyhow::ensure!(scope.purpose == "execute", "execution requires execute purpose");
        let reply: ExecutionReply = self.execution_post("claim", scope).await?;
        reply.check(scope, "claim")?;
        Ok(reply)
    }

    /// Verifies preparation against the live backend without starting or consuming execution.
    pub async fn verify_preparation(&self, scope: &TurnScope) -> Result<TurnScope> {
        anyhow::ensure!(scope.purpose == "prepare", "preparation requires prepare purpose");
        let reply: ExecutionReply = self.execution_post("claim", scope).await?;
        reply.check(scope, "claim")?;
        Ok(reply.scope)
    }

    /// Finishes a claimed execution after the harness outcome is recorded.
    pub async fn finish_execution(&self, scope: &TurnScope) -> Result<ExecutionReply> {
        anyhow::ensure!(scope.purpose == "execute", "execution requires execute purpose");
        let reply: ExecutionReply = self.execution_post("finish", scope).await?;
        reply.check(scope, "finish")?;
        Ok(reply)
    }

    async fn execution_post<R: for<'de> Deserialize<'de>>(
        &self,
        operation: &str,
        scope: &TurnScope,
    ) -> Result<R> {
        anyhow::ensure!(scope.workspace == self.workspace, "cloud workspace fence mismatch");
        self.check_machine(&scope.machine)?;
        for (name, value) in [
            ("team", &scope.team),
            ("user", &scope.user),
            ("workspace", &scope.workspace),
            ("machine", &scope.machine),
            ("session", &scope.session),
            ("turn", &scope.turn),
        ] {
            valid_component(name, value)?;
        }
        anyhow::ensure!(
            matches!(scope.purpose.as_str(), "prepare" | "execute"),
            "turn purpose is malformed"
        );
        valid_component("attempt_id", &scope.attempt_id)?;
        let token = self.auth.bearer().context("turn capability unavailable")?;
        anyhow::ensure!(token.starts_with("trc_"), "turn capability is malformed");
        let mut url = self.origin.clone();
        url.set_path(&format!("/v1/turn-execution/{operation}"));
        let response = self
            .http
            .post(url)
            .bearer_auth(token.as_str())
            .json(scope)
            .send()
            .await
            .with_context(|| format!("turn execution {operation} request failed"))?;
        let status = response.status();
        let bytes = response.bytes().await.context("read turn execution response")?;
        if !status.is_success() {
            bail!("turn execution {operation} failed ({})", status.as_u16());
        }
        serde_json::from_slice(&bytes).context("decode turn execution response")
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
        self.check_machine(expected_machine)?;
        self.post(
            turn,
            "snapshot",
            &SnapshotRequest { session, client_key, expected_machine, expected_generation },
        )
        .await
    }

    /// Mints a short-lived, turn-scoped capability through the owner route. The returned token
    /// must be held only in memory and claimed immediately before the prompt is sent.
    pub async fn mint_capability(
        &self,
        turn: &str,
        session: &str,
        expected_machine: &str,
        expected_generation: u64,
    ) -> Result<MintedCapability> {
        self.check_machine(expected_machine)?;
        Self::client_key(session)?;
        self.post(
            turn,
            "capability",
            &CapabilityRequest { session, expected_machine, expected_generation },
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
        Self::client_key(session)?;
        self.check_machine(expected_machine)?;
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
        Self::client_key(session)?;
        self.check_machine(expected_machine)?;
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
        self.check_machine(expected_machine)?;
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
        || value == "."
        || value == ".."
        || !value.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
    {
        bail!("cloud {name} is malformed")
    }
    Ok(())
}

/// Full scope bound into an opaque, one-use `trc_…` execution capability.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TurnScope {
    pub team: String,
    pub user: String,
    pub workspace: String,
    pub machine: String,
    pub generation: u64,
    pub session: String,
    pub turn: String,
    #[serde(default)]
    pub purpose: String,
    #[serde(default, rename = "attemptId")]
    pub attempt_id: String,
}

/// Native-prepared turn capability carried only in the in-memory prompt request.
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CloudTurnEnvelope {
    pub capability: String,
    pub team: String,
    pub user: String,
    pub workspace: String,
    pub machine: String,
    pub generation: u64,
    pub session: String,
    pub turn: String,
    pub expires_at: u64,
    #[serde(default)]
    pub purpose: String,
    #[serde(default, rename = "attemptId")]
    pub attempt_id: String,
}

impl CloudTurnEnvelope {
    pub fn scope(&self) -> TurnScope {
        TurnScope {
            team: self.team.clone(),
            user: self.user.clone(),
            workspace: self.workspace.clone(),
            machine: self.machine.clone(),
            generation: self.generation,
            session: self.session.clone(),
            turn: self.turn.clone(),
            purpose: if self.purpose.is_empty() { "execute".into() } else { self.purpose.clone() },
            attempt_id: if self.attempt_id.is_empty() {
                self.turn.clone()
            } else {
                self.attempt_id.clone()
            },
        }
    }
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ExecutionReply {
    #[serde(default)]
    pub claimed: Option<bool>,
    #[serde(default)]
    pub finished: Option<bool>,
    #[serde(flatten)]
    pub scope: TurnScope,
}

impl ExecutionReply {
    fn check(&self, expected: &TurnScope, operation: &str) -> Result<()> {
        anyhow::ensure!(&self.scope == expected, "turn capability response scope mismatch");
        let acknowledged = match operation {
            "claim" => self.claimed == Some(true),
            "finish" => self.finished == Some(true),
            _ => false,
        };
        anyhow::ensure!(acknowledged, "turn capability response was not acknowledged");
        Ok(())
    }
}

/// Checks the native request against trusted daemon scope before consulting the backend.
/// The returned scope is safe to use for reservation admission; no bearer is retained in it.
#[allow(clippy::too_many_arguments)]
pub async fn verify_preparation(
    origin: &str,
    workspace: &str,
    machine: &str,
    session: &str,
    turn: &str,
    generation: u64,
    attempt_id: &str,
    authorization: &CloudTurnEnvelope,
) -> Result<TurnScope> {
    let scope = preparation_scope(
        workspace,
        machine,
        session,
        turn,
        generation,
        attempt_id,
        authorization,
    )?;
    let auth = Arc::new(EphemeralCapability::new(authorization.capability.clone())?);
    let cloud = CloudTurnClient::new(origin, workspace, machine, auth)?;
    cloud.verify_preparation(&scope).await
}

fn preparation_scope(
    workspace: &str,
    machine: &str,
    session: &str,
    turn: &str,
    generation: u64,
    attempt_id: &str,
    authorization: &CloudTurnEnvelope,
) -> Result<TurnScope> {
    anyhow::ensure!(
        authorization.purpose == "prepare",
        "preparation requires explicit prepare purpose"
    );
    anyhow::ensure!(
        authorization.workspace == workspace
            && authorization.machine == machine
            && authorization.session == session
            && authorization.turn == turn
            && authorization.generation == generation
            && authorization.attempt_id == attempt_id,
        "preparation authorization scope mismatch"
    );
    valid_component("attempt_id", attempt_id)?;
    // Expiry and current generation are checked by the backend, never the restored guest clock.
    Ok(authorization.scope())
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
struct CapabilityRequest<'a> {
    session: &'a str,
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

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MintedCapability {
    pub capability: String,
    pub team: String,
    pub user: String,
    pub workspace: String,
    pub machine: String,
    pub generation: u64,
    pub session: String,
    pub turn: String,
    pub expires_at: u64,
    #[serde(default)]
    pub purpose: String,
    #[serde(default, rename = "attemptId")]
    pub attempt_id: String,
}

impl MintedCapability {
    pub fn into_scope_and_auth(self) -> Result<(TurnScope, EphemeralCapability)> {
        let scope = TurnScope {
            team: self.team,
            user: self.user,
            workspace: self.workspace,
            machine: self.machine,
            generation: self.generation,
            session: self.session,
            turn: self.turn.clone(),
            purpose: if self.purpose.is_empty() { "execute".into() } else { self.purpose },
            attempt_id: if self.attempt_id.is_empty() {
                self.turn.clone()
            } else {
                self.attempt_id
            },
        };
        Ok((scope, EphemeralCapability::new(self.capability)?))
    }
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
    pub session: String,
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
    pub fn claim(&self, session: impl Into<String>, turn: impl Into<String>) -> Result<ActiveTurn> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if state.active.is_some() {
            bail!("cloud turn admission already active")
        }
        let active =
            ActiveTurn { session: session.into(), turn: turn.into(), generation: state.generation };
        state.active = Some(active.clone());
        Ok(active)
    }

    /// Records a capture exactly once. Repeating a lost response with the same turn is idempotent.
    pub fn record_capture(&self, capture: SnapshotReply) -> Result<SnapshotReply> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if capture.machine_generation != state.generation {
            bail!("cloud capture generation mismatch")
        }
        anyhow::ensure!(
            Some(capture.machine_id.as_str()) == state.machine.as_deref(),
            "cloud capture machine mismatch"
        );
        let key = capture_key(&capture.session, &capture.turn);
        if let Some(existing) = state.captures.get(&key) {
            if existing.snapshot_id != capture.snapshot_id {
                bail!("cloud turn has conflicting captures")
            }
            return Ok(existing.clone());
        }
        state.captures.insert(key, capture.clone());
        Ok(capture)
    }

    /// Finishes only the admitted turn; a stale finish cannot clear a replacement turn.
    pub fn finish(&self, session: &str, turn: &str, generation: u64) -> Result<()> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        match state.active.as_ref() {
            Some(active)
                if active.session == session
                    && active.turn == turn
                    && active.generation == generation =>
            {
                state.active = None;
                Ok(())
            }
            _ => bail!("cloud turn finish fence mismatch"),
        }
    }

    /// Applies a successful provider rewind and fences all old turns/captures.
    pub fn apply_rewind(
        &self,
        session: &str,
        turn: &str,
        replacement: &MachineReplacement,
    ) -> Result<()> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        anyhow::ensure!(state.active.is_none(), "cannot rewind an active turn");
        anyhow::ensure!(
            state.captures.contains_key(&capture_key(session, turn)),
            "unknown cloud capture"
        );
        anyhow::ensure!(
            replacement.generation > state.generation,
            "rewind generation did not advance"
        );
        state.machine = Some(replacement.id.clone());
        state.generation = replacement.generation;
        state.captures.retain(|_, capture| capture.machine_generation >= replacement.generation);
        Ok(())
    }

    pub fn capture(&self, session: &str, turn: &str) -> Option<SnapshotReply> {
        self.state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .captures
            .get(&capture_key(session, turn))
            .cloned()
    }
}

fn capture_key(session: &str, turn: &str) -> String {
    format!("{session}\u{1f}{turn}")
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

    fn preparation() -> CloudTurnEnvelope {
        CloudTurnEnvelope {
            capability: format!("trc_{}", "a".repeat(43)),
            team: "team".into(),
            user: "user".into(),
            workspace: "ws".into(),
            machine: "machine".into(),
            generation: 7,
            session: "session".into(),
            turn: "prompt".into(),
            expires_at: 0,
            purpose: "prepare".into(),
            attempt_id: "attempt".into(),
        }
    }

    #[test]
    fn preparation_requires_explicit_purpose_and_exact_request_scope() {
        let auth = preparation();
        let check = |auth: &CloudTurnEnvelope| {
            preparation_scope("ws", "machine", "session", "prompt", 7, "attempt", auth)
        };
        assert!(check(&auth).is_ok());
        for field in [
            "workspace",
            "machine",
            "session",
            "turn",
            "generation",
            "attempt",
            "purpose",
            "missing-purpose",
        ] {
            let mut wrong = auth.clone();
            match field {
                "workspace" => wrong.workspace = "other".into(),
                "machine" => wrong.machine = "other".into(),
                "session" => wrong.session = "other".into(),
                "turn" => wrong.turn = "other".into(),
                "generation" => wrong.generation += 1,
                "attempt" => wrong.attempt_id = "other".into(),
                "purpose" => wrong.purpose = "execute".into(),
                _ => wrong.purpose.clear(),
            }
            assert!(check(&wrong).is_err(), "accepted wrong {field}");
        }
        let mut missing = auth;
        missing.attempt_id.clear();
        assert!(preparation_scope("ws", "machine", "session", "prompt", 7, "", &missing).is_err());
    }

    async fn claim_server(status: u16, body: Value) -> (String, tokio::task::JoinHandle<String>) {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let task = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            loop {
                let mut chunk = [0; 4096];
                let count = socket.read(&mut chunk).await.unwrap();
                assert!(count > 0);
                request.extend_from_slice(&chunk[..count]);
                if let Some(end) = request.windows(4).position(|part| part == b"\r\n\r\n") {
                    let header = String::from_utf8_lossy(&request[..end]);
                    let length: usize = header
                        .lines()
                        .find_map(|line| {
                            line.to_ascii_lowercase()
                                .strip_prefix("content-length: ")
                                .map(str::parse)
                        })
                        .unwrap()
                        .unwrap();
                    if request.len() >= end + 4 + length {
                        break;
                    }
                }
            }
            let body = body.to_string();
            socket.write_all(format!("HTTP/1.1 {status} Response\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes()).await.unwrap();
            String::from_utf8(request).unwrap()
        });
        (origin, task)
    }

    fn test_client(origin: &str) -> CloudTurnClient {
        let auth = Arc::new(EphemeralCapability::new(preparation().capability).unwrap());
        let mut client =
            CloudTurnClient::new("https://cloud.example", "ws", "machine", auth).unwrap();
        // Only tests can replace the validated HTTPS origin with a local HTTP listener.
        client.origin = reqwest::Url::parse(origin).unwrap();
        client
    }

    #[tokio::test]
    async fn preparation_claim_posts_scope_and_requires_authoritative_confirmation() {
        let scope = preparation().scope();
        let mut body = serde_json::to_value(&scope).unwrap();
        body["claimed"] = Value::Bool(true);
        let (origin, server) = claim_server(200, body).await;
        let verified = test_client(&origin).verify_preparation(&scope).await.unwrap();
        assert_eq!(verified, scope);
        let request = server.await.unwrap();
        assert!(request.starts_with("POST /v1/turn-execution/claim HTTP/1.1"));
        let (_, body) = request.split_once("\r\n\r\n").unwrap();
        assert_eq!(serde_json::from_str::<TurnScope>(body).unwrap(), scope);
        assert!(!body.contains("trc_"));
    }

    #[tokio::test]
    async fn preparation_refuses_denial_missing_ack_and_mismatched_backend_scope() {
        let scope = preparation().scope();
        for variation in [
            "denied",
            "empty",
            "false",
            "team",
            "user",
            "workspace",
            "machine",
            "session",
            "turn",
            "generation",
            "purpose",
            "attemptId",
        ] {
            let mut body = serde_json::to_value(&scope).unwrap();
            body["claimed"] = Value::Bool(true);
            let status = if variation == "denied" { 409 } else { 200 };
            match variation {
                "denied" => {}
                "empty" => body = serde_json::json!({}),
                "false" => body["claimed"] = Value::Bool(false),
                "generation" => body[variation] = Value::from(8),
                field => body[field] = Value::from("other"),
            }
            let (origin, server) = claim_server(status, body).await;
            assert!(
                test_client(&origin).verify_preparation(&scope).await.is_err(),
                "accepted {variation}"
            );
            server.await.unwrap();
        }
    }

    #[tokio::test]
    async fn preparation_cannot_be_used_as_execution_or_for_another_machine() {
        let client = test_client("http://127.0.0.1:1");
        let scope = preparation().scope();
        assert!(
            client
                .claim_execution(&scope)
                .await
                .unwrap_err()
                .to_string()
                .contains("execute purpose")
        );
        assert!(
            client
                .finish_execution(&scope)
                .await
                .unwrap_err()
                .to_string()
                .contains("execute purpose")
        );
        let mut wrong = scope.clone();
        wrong.machine = "other".into();
        assert!(
            client
                .verify_preparation(&wrong)
                .await
                .unwrap_err()
                .to_string()
                .contains("machine fence")
        );
        wrong = scope;
        wrong.workspace = "other".into();
        assert!(
            client
                .verify_preparation(&wrong)
                .await
                .unwrap_err()
                .to_string()
                .contains("workspace fence")
        );
    }

    #[test]
    fn ledger_is_idempotent_and_fenced() {
        let ledger = TurnCaptureLedger::new("machine-a", 3);
        let active = ledger.claim("session", "turn-a").unwrap();
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
        ledger.finish("session", "turn-a", 3).unwrap();
        assert!(ledger.finish("session", "turn-a", 3).is_err());
        ledger
            .apply_rewind(
                "session",
                "turn-a",
                &MachineReplacement { id: "machine-b".into(), generation: 4 },
            )
            .unwrap();
        assert_eq!(ledger.machine().as_deref(), Some("machine-b"));
        assert_eq!(ledger.generation(), 4);
        assert!(ledger.capture("session", "turn-a").is_none());
    }

    #[test]
    fn rejects_conflicting_capture_and_stale_rewind() {
        let ledger = TurnCaptureLedger::new("machine-a", 8);
        ledger.claim("session", "turn-a").unwrap();
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
                    "session",
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
