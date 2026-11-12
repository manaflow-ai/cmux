//! The phone's own Cloud carrier: a cmux-remote client session to one Cloud
//! machine's cmux-tui daemon over the machine's relay slot, admitted by a
//! carrier grant the platform signs for this phone's Noise key, and pinned to
//! the daemon key the platform names. It is the same session `cmux carrier
//! dial` opens for the Mac (cmux-tui `carrier/client.rs`), reduced to the relay
//! route: no ssh backup, no handed-over answer, no desktop datagram link.
//!
//! Who may ask: the platform's carrier route admits a person's session and an
//! `ios` install with `execute` or `cloud-link` (cmux-platform `CarrierRoute.ts`
//! `carrierClient`). The grant carries the platform's `vmk` claim, which the
//! machine's session host stamps on every stream (`carrier-role`), so the
//! daemon sees the person's own role, never one the phone names.
//!
//! Each [`CarrierStream`] is one mux control stream on the session: the
//! `cmux.protocol/2` lines a Mac's daemon socket carries, so the app's daemon
//! client (list, attach, send, resize) runs over it unchanged.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use cmux_link::carrier_answer::{self, RelayAnswer};
use cmux_remote::bridge::OpenedMuxControl;
use cmux_remote::connection::{ClientConnection, ClientConnectionConfig, ConnectionError, ReconnectPolicy};
use cmux_remote::crypto::{ClientAuthMode, CryptoError, StaticIdentity};
use cmux_remote::provider::{
    ConnectRequest, ProviderError, RelayClientConfig, RelayCredentialSource, RelayProvider, RelayTls,
    TransportProvider,
};
use cmux_remote::service::{EndpointRole, ServiceMultiplexer};
use cmux_remote::session::SessionLimits;
use cmux_remote_protocol::{LanePolicy, SessionId};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream, ReadHalf, WriteHalf};
use tokio::time::Instant;
use url::Url;
use zeroize::Zeroizing;

pub use cmux_remote::crypto::StaticIdentity as NoiseIdentity;

/// The relay's frame bound for a carrier (the Mac's carrier uses the same).
const MAX_FRAME_BYTES: usize = 65_535;
/// Each relay control step other than the parked allocation.
const CONTROL_TIMEOUT: Duration = Duration::from_secs(15);
/// The Noise handshake of one attempt, at most.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(15);
/// How long an established session tries to resume before its streams end
/// (the app then dials a fresh one), as the Mac's carrier.
const RESUME_DEADLINE: Duration = Duration::from_secs(10);
/// How long one attempt's link may stay parked before the dial opens a new
/// one: a machine that registers is allocated in well under a second.
const PARK_REDIAL: Duration = Duration::from_secs(10);
/// One platform ask, at most.
const FETCH_TIMEOUT: Duration = Duration::from_secs(20);
/// A ticket is reused until this long before it expires.
const TICKET_MARGIN_SECS: u64 = 30;
/// The team selector cmux-platform reads (`TeamSelect.ts` `TEAM_HEADER`).
const TEAM_HEADER: &str = "x-cmux-team";
/// One stream's buffer between the bridge and the app.
const STREAM_BUFFER: usize = 256 * 1024;
/// The longest read handed to the app at once.
const READ_CHUNK: usize = 64 * 1024;

/// Why a carrier did not come up, or ended.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum CarrierError {
    /// The platform refused the access token (401): the app refreshes it
    /// once, then asks the person to sign in.
    #[error("the cmux service refused the access token")]
    Unauthorized,
    /// The platform refused the ask (`cloud.machine.paused`,
    /// `cloud.machine.not_found`, `auth.forbidden`, ...).
    #[error("refused: {code}: {message}")]
    Refused { code: String, message: String, retryable: bool },
    /// The machine's daemon is not the one the platform pinned, or refused
    /// the grant: no retry admits it.
    #[error("the machine's daemon refused this phone: {0}")]
    Handshake(String),
    /// The relay, the network or a step's own deadline.
    #[error("{step}: {detail}")]
    Transport { step: &'static str, detail: String, retryable: bool },
    /// An argument or answer that is not valid.
    #[error("invalid: {0}")]
    Invalid(String),
    /// The session or stream is closed.
    #[error("closed")]
    Closed,
}

impl CarrierError {
    /// Asking again inside the dial's deadline may pass.
    pub fn retryable(&self) -> bool {
        match self {
            Self::Refused { retryable, .. } | Self::Transport { retryable, .. } => *retryable,
            Self::Unauthorized | Self::Handshake(_) | Self::Invalid(_) | Self::Closed => false,
        }
    }

    fn transport(step: &'static str, detail: impl Into<String>) -> Self {
        Self::Transport { step, detail: detail.into(), retryable: true }
    }
}

/// A Cloud machine id as the platform's carrier route takes it
/// (`/^vm_[a-z0-9]{20}$/`, cmux `platform-forward.ts` `CARRIER_PATH`), so
/// no phone input reaches the URL path unchecked.
pub fn valid_machine(machine: &str) -> bool {
    machine.len() == 23
        && machine.starts_with("vm_")
        && machine[3..].bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
}

/// A team id the header may carry: `team_` and up to 64 id characters.
fn valid_team(team: &str) -> bool {
    team.len() <= 69
        && team.starts_with("team_")
        && team.len() > 5
        && team[5..].bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// Where carrier answers come from: the platform, asked with the person's
/// access token, which the app replaces as it refreshes ([`Platform::set_token`]).
pub struct Platform {
    api_base: Url,
    team: Option<String>,
    machine: String,
    token: Mutex<Zeroizing<String>>,
    http: reqwest::Client,
}

impl Platform {
    pub fn new(
        api_base: &str,
        team: Option<String>,
        machine: &str,
        token: String,
    ) -> Result<Self, CarrierError> {
        let api_base = Url::parse(api_base).map_err(|_| CarrierError::Invalid("api base".into()))?;
        if api_base.scheme() != "https" && !local(&api_base) {
            return Err(CarrierError::Invalid("the api base is not https".into()));
        }
        if !valid_machine(machine) {
            return Err(CarrierError::Invalid("machine id".into()));
        }
        let team = team.filter(|team| !team.is_empty());
        if team.as_deref().is_some_and(|team| !valid_team(team)) {
            return Err(CarrierError::Invalid("team id".into()));
        }
        let http = reqwest::Client::builder()
            .timeout(FETCH_TIMEOUT)
            .build()
            .map_err(|error| CarrierError::Invalid(error.to_string()))?;
        Ok(Self {
            api_base,
            team,
            machine: machine.to_owned(),
            token: Mutex::new(Zeroizing::new(token)),
            http,
        })
    }

    /// Replace the access token (the app refreshes it before it expires).
    pub fn set_token(&self, token: String) {
        *self.token.lock().unwrap_or_else(PoisonError::into_inner) = Zeroizing::new(token);
    }

    fn token(&self) -> Zeroizing<String> {
        self.token.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    fn url(&self) -> Result<Url, CarrierError> {
        self.api_base
            .join(&format!("v1/cloud/machines/{}/carrier", self.machine))
            .map_err(|_| CarrierError::Invalid("api base".into()))
    }

    /// A Connect ticket, and a grant naming `noise_key` when given (a grant is
    /// single-use, so each attempt asks again).
    pub async fn fetch(&self, noise_key: Option<&[u8; 32]>) -> Result<RelayAnswer, CarrierError> {
        let body = match noise_key {
            Some(key) => json!({ "noise_key": carrier_answer::key_text(key) }),
            None => json!({}),
        };
        let mut request = self
            .http
            .post(self.url()?)
            .bearer_auth(self.token().as_str())
            .header("content-type", "application/json")
            .body(body.to_string());
        if let Some(team) = &self.team {
            request = request.header(TEAM_HEADER, team);
        }
        let reply = request.send().await.map_err(|error| {
            // Never the URL's query or a header: reqwest's error names the URL only.
            CarrierError::transport("ticket", error.without_url().to_string())
        })?;
        let status = reply.status().as_u16();
        if status == 401 {
            return Err(CarrierError::Unauthorized);
        }
        let text = reply
            .text()
            .await
            .map_err(|error| CarrierError::transport("ticket", error.without_url().to_string()))?;
        let value: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
        read_answer(status, &value)
    }
}

/// One platform reply: the relay answer, else the refusal.
pub fn read_answer(status: u16, body: &Value) -> Result<RelayAnswer, CarrierError> {
    match carrier_answer::reply_value(status, body) {
        Ok(value) => carrier_answer::parse_relay(value)
            .map_err(|why| CarrierError::Invalid(format!("the carrier answer: {why}"))),
        Err(refusal) => Err(CarrierError::Refused {
            code: refusal.code,
            message: refusal.message,
            retryable: refusal.retryable,
        }),
    }
}

fn local(url: &Url) -> bool {
    url.scheme() == "http" && matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"))
}

fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_secs())
}

/// The relay tickets of one session: the answer's own while it is fresh,
/// then a ticket-only ask (a resume needs a ticket, never a grant).
struct Tickets {
    platform: Arc<Platform>,
    current: tokio::sync::Mutex<Option<(Zeroizing<String>, u64)>>,
}

impl Tickets {
    fn new(platform: Arc<Platform>, answer: &RelayAnswer) -> Arc<Self> {
        Arc::new(Self {
            platform,
            current: tokio::sync::Mutex::new(Some((answer.ticket.clone(), answer.expires_at))),
        })
    }

    async fn ticket(&self) -> Result<String, CarrierError> {
        let mut current = self.current.lock().await;
        if let Some((ticket, expires_at)) = current.as_ref()
            && now_secs() + TICKET_MARGIN_SECS < *expires_at
        {
            return Ok(ticket.to_string());
        }
        let answer = self.platform.fetch(None).await?;
        let ticket = answer.ticket.to_string();
        *current = Some((answer.ticket, answer.expires_at));
        Ok(ticket)
    }
}

/// The Web PKI roots: iOS has no root store rustls-native-certs can read.
fn web_pki() -> Result<RelayTls, CarrierError> {
    let roots = rustls::RootCertStore { roots: webpki_roots::TLS_SERVER_ROOTS.to_vec() };
    let config =
        rustls::ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions()
            .map_err(|error| CarrierError::Invalid(format!("relay TLS: {error}")))?
            .with_root_certificates(roots)
            .with_no_client_auth();
    Ok(RelayTls::with_client_config(Arc::new(config)))
}

fn random_session() -> Result<SessionId, CarrierError> {
    let mut bytes = [0_u8; 16];
    getrandom::fill(&mut bytes).map_err(|error| CarrierError::Invalid(error.to_string()))?;
    Ok(SessionId(bytes))
}

fn provider_error(error: &ProviderError) -> CarrierError {
    let detail = error.to_string();
    if detail.contains("allocation timed out") {
        CarrierError::transport("parked", "the machine did not answer on its relay")
    } else {
        CarrierError::Transport {
            step: "relay",
            retryable: error.is_retryable_carrier_failure() || matches!(error, ProviderError::Transport(_)),
            detail,
        }
    }
}

fn connection_error(error: &ConnectionError) -> CarrierError {
    let detail = error.to_string();
    match error {
        ConnectionError::Provider(provider) => provider_error(provider),
        // A daemon that is not the pinned one, or that refused the grant.
        ConnectionError::Crypto(CryptoError::DaemonKeyMismatch { .. } | CryptoError::Unauthorized(_)) => {
            CarrierError::Handshake(detail)
        }
        _ => CarrierError::Transport {
            step: "handshake",
            retryable: error.is_retryable_carrier_failure()
                || matches!(error, ConnectionError::SessionUnavailable),
            detail,
        },
    }
}

/// One machine's carrier session: its mux streams share one Noise session.
pub struct CarrierSession {
    connection: Arc<ClientConnection>,
    multiplexer: Arc<ServiceMultiplexer>,
    /// The stream opened to prove the grant admits mux control, handed to
    /// the first [`CarrierSession::open_stream`].
    first: Mutex<Option<OpenedMuxControl>>,
}

impl CarrierSession {
    /// Dial `platform`'s machine as `identity` until `deadline`: each attempt
    /// asks for a fresh grant, opens the relay link (parked until the
    /// machine's daemon registers), runs the Noise handshake pinned to the
    /// daemon key and opens a mux control stream. A retryable failure is
    /// tried again after a short wait while time is left.
    pub async fn dial(
        platform: Arc<Platform>,
        identity: StaticIdentity,
        device_name: String,
        deadline: Instant,
    ) -> Result<Self, CarrierError> {
        let mut wait = Duration::from_millis(250);
        loop {
            match attempt(&platform, &identity, &device_name, deadline).await {
                Ok(session) => return Ok(session),
                Err(error) if error.retryable() && Instant::now() + wait < deadline => {
                    tracing::debug!(%error, "carrier attempt failed; retrying");
                    // An intentional, bounded retry delay inside the dial's deadline.
                    tokio::time::sleep(wait).await;
                    wait = (wait * 2).min(Duration::from_secs(4));
                }
                Err(error) => return Err(error),
            }
        }
    }

    /// One more `cmux.protocol/2` line stream on the session.
    pub async fn open_stream(&self) -> Result<CarrierStream, CarrierError> {
        let first = self.first.lock().unwrap_or_else(PoisonError::into_inner).take();
        let mux = match first {
            Some(mux) => mux,
            None => OpenedMuxControl::open(&self.multiplexer)
                .await
                .map_err(|error| CarrierError::transport("stream", error.to_string()))?,
        };
        let (ours, theirs) = tokio::io::duplex(STREAM_BUFFER);
        let (their_read, their_write) = tokio::io::split(theirs);
        let bridge = tokio::spawn(async move {
            if let Err(error) = mux.bridge(their_read, their_write).await {
                tracing::debug!(%error, "carrier stream ended");
            }
        });
        let (read, write) = tokio::io::split(ours);
        Ok(CarrierStream {
            read: tokio::sync::Mutex::new(read),
            write: tokio::sync::Mutex::new(Some(write)),
            bridge,
        })
    }

    /// The session ended (its resume gave up, or it was closed).
    pub fn is_closed(&self) -> bool {
        matches!(
            *self.connection.subscribe_state().borrow(),
            cmux_remote::observability::ConnectionState::Closed
        )
    }

    pub async fn close(&self) {
        self.multiplexer.shutdown().await;
        let _ = self.connection.close().await;
    }
}

async fn attempt(
    platform: &Arc<Platform>,
    identity: &StaticIdentity,
    device_name: &str,
    deadline: Instant,
) -> Result<CarrierSession, CarrierError> {
    let answer = platform.fetch(Some(&identity.public_key())).await?;
    let grant = answer
        .grant
        .clone()
        .ok_or_else(|| CarrierError::Invalid("cmux-platform sent no carrier grant".into()))?;
    // A machine that has not bound yet has no stored key; it binds within
    // seconds of its start, so the next attempt has it. Never unpinned.
    let daemon = answer
        .daemon_key
        .ok_or_else(|| CarrierError::transport("ticket", "the machine has no daemon key yet"))?;
    let tickets = Tickets::new(platform.clone(), &answer);
    let credentials = RelayCredentialSource::callback(move || {
        let tickets = tickets.clone();
        async move { tickets.ticket().await }
    });
    let provider = RelayProvider::with_credentials(
        RelayClientConfig {
            slot: answer.slot.clone(),
            ticket: String::new(),
            maximum_frame_bytes: MAX_FRAME_BYTES,
            control_timeout: CONTROL_TIMEOUT,
        },
        credentials,
    )
    .map_err(|error| CarrierError::Invalid(error.to_string()))?
    .with_allocation_deadline(deadline.min(Instant::now() + PARK_REDIAL))
    .with_tls(web_pki()?);
    let session = random_session()?;
    let group = provider
        .connect(ConnectRequest {
            endpoint: answer.relay.clone(),
            session,
            lane_policy: LanePolicy::Auto,
            routing: BTreeMap::new(),
        })
        .await
        .map_err(|error| provider_error(&error))?;
    let remaining = deadline.saturating_duration_since(Instant::now());
    let config = ClientConnectionConfig {
        identity: identity.clone(),
        expected_daemon: Some(daemon),
        auth: ClientAuthMode::Grant { token: grant },
        device_name: device_name.to_owned(),
        session,
        lane_policy: LanePolicy::Auto,
        limits: SessionLimits::default(),
        reconnect: ReconnectPolicy {
            attempt_timeout: HANDSHAKE_TIMEOUT.min(remaining.max(Duration::from_millis(1))),
            maximum_duration: Some(RESUME_DEADLINE),
            ..ReconnectPolicy::default()
        },
    };
    let connection = match ClientConnection::connect(group.clone(), config).await {
        Ok(connection) => connection,
        Err(error) => {
            let _ = group.close().await;
            return Err(connection_error(&error));
        }
    };
    let multiplexer = ServiceMultiplexer::new(connection.clone(), EndpointRole::Client);
    // A grant that does not admit mux control is refused here, before the
    // dial reports success.
    match OpenedMuxControl::open(&multiplexer).await {
        Ok(mux) => Ok(CarrierSession { connection, multiplexer, first: Mutex::new(Some(mux)) }),
        Err(error) => {
            multiplexer.shutdown().await;
            let _ = connection.close().await;
            Err(CarrierError::Handshake(format!("the daemon did not open its mux control stream: {error}")))
        }
    }
}

/// One `cmux.protocol/2` line stream to the machine's daemon.
pub struct CarrierStream {
    read: tokio::sync::Mutex<ReadHalf<DuplexStream>>,
    write: tokio::sync::Mutex<Option<WriteHalf<DuplexStream>>>,
    bridge: tokio::task::JoinHandle<()>,
}

impl CarrierStream {
    /// Write `bytes` (whole protocol lines) to the daemon.
    pub async fn send(&self, bytes: &[u8]) -> Result<(), CarrierError> {
        let mut write = self.write.lock().await;
        let writer = write.as_mut().ok_or(CarrierError::Closed)?;
        writer.write_all(bytes).await.map_err(|_| CarrierError::Closed)?;
        writer.flush().await.map_err(|_| CarrierError::Closed)
    }

    /// The next bytes from the daemon (any split of its lines), or None once
    /// the stream ended.
    pub async fn receive(&self) -> Option<Vec<u8>> {
        let mut buffer = vec![0_u8; READ_CHUNK];
        let count = self.read.lock().await.read(&mut buffer).await.ok()?;
        if count == 0 {
            return None;
        }
        buffer.truncate(count);
        Some(buffer)
    }

    pub async fn close(&self) {
        if let Some(mut writer) = self.write.lock().await.take() {
            let _ = writer.shutdown().await;
        }
        self.bridge.abort();
    }
}

impl Drop for CarrierStream {
    fn drop(&mut self) {
        self.bridge.abort();
    }
}

/// A new Noise static private key for this phone (the app keeps it in its
/// Keychain, so the daemon sees one device across launches).
pub fn generate_private_key() -> Result<Zeroizing<[u8; 32]>, CarrierError> {
    let identity = StaticIdentity::generate().map_err(|error| CarrierError::Invalid(error.to_string()))?;
    Ok(Zeroizing::new(*identity.private_key()))
}

#[cfg(test)]
mod tests;
