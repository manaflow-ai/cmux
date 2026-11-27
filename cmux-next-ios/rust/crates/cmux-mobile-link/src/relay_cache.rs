//! The relay cache's client (RFD 0142 R2 and R9; the Worker's `/v1/relay-cache/...`, backend
//! `src/relay-cache.ts`).
//!
//! The Mac seals its newest snapshot of a stream to each phone's key and puts it on the relay; it
//! appends every change after it as a sealed delta on `<stream>/delta`. A phone that cold-opens
//! while the Mac sleeps reads the snapshot from the relay ([`RelayCache::cold_open`]); a phone that
//! resumes after sleep asks for the deltas after the position it holds ([`RelayCache::resume`]),
//! opens them in order and acknowledges them ([`RelayCache::ack`]). The relay holds only sealed
//! envelopes: [`cmux_relay_snapshot`] checks the source's signature and refuses an older position
//! than the viewer's floor, so a relay can withhold state but never make the phone show older state.
//!
//! Off unless [`RelayCacheConfig::enabled`] is set (default off): every call answers
//! [`RelayCacheError::Off`] without a request. This adds a read path; it replaces no transport.
//! What the relay cannot give (a cut surface, a gap, a delta that does not open) the phone asks the
//! Mac for over the link once it wakes, as today.

use base64::Engine as _;
use cmux_relay_snapshot::delta::{self, ApplyError};
use cmux_relay_snapshot::{Floor, Opened, Position};
use p256::{PublicKey, SecretKey};
use serde::{Deserialize, Serialize};

use crate::api::{ApiClient, ApiError};

/// The catch-up budget the Worker uses when a request names none (`budgetBytes`, 64 KiB).
pub const DEFAULT_BUDGET_BYTES: usize = 64 * 1024;
/// The largest catch-up budget the Worker accepts (256 KiB).
pub const MAX_BUDGET_BYTES: usize = 256 * 1024;
/// The most surfaces one catch-up may ask for.
pub const MAX_SURFACES: usize = 64;
/// The most plaintext a first-screen snapshot holds: 12 KiB, so its sealed envelope and the HTTP
/// reply fit TCP's initial window (10 segments, about 14 KB) and arrive in one round trip.
pub const FIRST_SCREEN_BYTES: usize = 12 * 1024;

/// The stream a first-screen snapshot of `stream` is sealed and stored on: the newest
/// [`FIRST_SCREEN_BYTES`] of the same state, at the same position. A cold open reads it before the
/// whole snapshot ([`RelayCache::cold_open_first_screen`]) so the screen fills in one round trip.
pub fn first_screen_stream(stream: &str) -> String {
    format!("{stream}/first")
}

/// Whether this client talks to the relay cache at all. Default off.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct RelayCacheConfig {
    pub enabled: bool,
}

#[derive(Debug, thiserror::Error)]
pub enum RelayCacheError {
    /// [`RelayCacheConfig::enabled`] is false: nothing was sent.
    #[error("the relay cache is off on this device")]
    Off,
    /// The Worker's switch is off (`503 relay_off` or `relay_cache_off`).
    #[error("the relay cache is turned off ({0})")]
    RelayOff(String),
    /// The relay refused with this status and error code.
    #[error("relay cache refused: {status} {code}")]
    Refused { status: u16, code: String },
    #[error(transparent)]
    Api(#[from] ApiError),
    /// The snapshot did not open (wrong source, bad signature, stale, not ours).
    #[error("snapshot did not open: {0}")]
    Seal(cmux_relay_snapshot::Error),
    /// A reply that is not the relay's shape.
    #[error("bad relay cache reply: {0}")]
    Bad(String),
}

/// A position as the Worker writes it: a JSON number or a digit string (a `u64` past 2^53).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WirePosition(pub Position);

impl Serialize for WirePosition {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeStruct as _;
        let mut s = serializer.serialize_struct("Position", 2)?;
        s.serialize_field("epoch", &self.0.epoch)?;
        s.serialize_field("seq", &self.0.seq)?;
        s.end()
    }
}

impl<'de> Deserialize<'de> for WirePosition {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum U64 {
            Number(u64),
            Text(String),
        }
        fn value<E: serde::de::Error>(v: U64) -> Result<u64, E> {
            match v {
                U64::Number(n) => Ok(n),
                U64::Text(t) if !t.is_empty() && t.bytes().all(|b| b.is_ascii_digit()) => {
                    t.parse().map_err(E::custom)
                }
                U64::Text(t) => Err(E::custom(format!("not a position: {t:?}"))),
            }
        }
        #[derive(Deserialize)]
        struct Raw {
            epoch: U64,
            seq: U64,
        }
        let raw = Raw::deserialize(deserializer)?;
        Ok(Self(Position { epoch: value(raw.epoch)?, seq: value(raw.seq)? }))
    }
}

/// One surface the viewer resumes, and the position it holds.
#[derive(Debug, Clone, Serialize)]
pub struct CatchUpAsk {
    pub surface: String,
    pub after: WirePosition,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CatchUpSurface {
    pub surface: String,
    /// The sealed deltas, base64url without padding, in order.
    pub sealed: Vec<String>,
    pub head: WirePosition,
}

/// `POST catch-up`'s reply.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CatchUpReply {
    #[serde(default)]
    pub from_relay: bool,
    pub surfaces: Vec<CatchUpSurface>,
    /// Surfaces the relay could not cover (a gap, nothing held, or over the budget): ask the Mac.
    #[serde(default)]
    pub cut: Vec<String>,
}

/// A cold open's result: the snapshot opened, and when the relay got it (ms since the epoch).
#[derive(Debug, Clone)]
pub struct ColdOpen {
    pub opened: Opened,
    pub cached_at_ms: Option<u64>,
    /// The envelope's size on the wire.
    pub bytes: usize,
}

/// One surface's resume: what it applied, where its floor stands, and why it stopped early.
#[derive(Debug, Clone)]
pub struct Resumed {
    pub surface: String,
    pub applied: Vec<Opened>,
    pub floor: Floor,
    /// The first delta that was not the next one or did not open; the rest wait for the Mac.
    pub stopped: Option<ApplyError>,
}

/// A whole resume: every surface the relay answered, and those it cut.
#[derive(Debug, Clone, Default)]
pub struct Resume {
    pub surfaces: Vec<Resumed>,
    pub cut: Vec<String>,
    /// Sealed bytes the relay sent.
    pub bytes: usize,
    /// Newest snapshots opened for surfaces the catch-up cut or stopped
    /// ([`RelayCache::resume_or_snapshot`]); empty from [`RelayCache::resume`].
    pub snapshots: Vec<Opened>,
}

/// The relay cache as one device sees it: a phone reading its own slots, or the Mac (the source)
/// writing a phone's.
#[derive(Debug, Clone)]
pub struct RelayCache {
    api: ApiClient,
    /// This device's id (`?deviceId=`).
    device: String,
    config: RelayCacheConfig,
}

fn b64url_decode(text: &str) -> Option<Vec<u8>> {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(text.trim_end_matches('=')).ok()
}

impl RelayCache {
    pub fn new(api: ApiClient, device: &str, config: RelayCacheConfig) -> Self {
        Self { api, device: device.to_ascii_lowercase(), config }
    }

    pub fn config(&self) -> RelayCacheConfig {
        self.config
    }

    fn on(&self) -> Result<(), RelayCacheError> {
        if self.config.enabled { Ok(()) } else { Err(RelayCacheError::Off) }
    }

    fn path(&self, source: &str, what: &str, query: &[(&str, &str)]) -> String {
        let mut path =
            format!("/v1/relay-cache/{}/{what}?deviceId={}", source.to_ascii_lowercase(), self.device);
        for (name, value) in query {
            path.push('&');
            path.push_str(name);
            path.push('=');
            path.push_str(&encode_query(value));
        }
        path
    }

    async fn send(&self, request: reqwest::RequestBuilder) -> Result<reqwest::Response, RelayCacheError> {
        let response = request.send().await.map_err(|e| ApiError::Http(e.to_string()))?;
        let status = response.status();
        if status.is_success() {
            return Ok(response);
        }
        let body = response.text().await.unwrap_or_default();
        let code = serde_json::from_str::<serde_json::Value>(&body)
            .ok()
            .and_then(|v| {
                let error = v.get("error")?;
                error.get("code").and_then(|c| c.as_str()).or_else(|| error.as_str()).map(str::to_owned)
            })
            .unwrap_or_default();
        if status.as_u16() == 503 && (code == "relay_off" || code == "relay_cache_off") {
            return Err(RelayCacheError::RelayOff(code));
        }
        Err(RelayCacheError::Refused { status: status.as_u16(), code })
    }

    /// `GET snapshot`: this viewer's sealed snapshot of `stream` from `source`, unopened; `None`
    /// when the relay holds none (`404 no_snapshot`).
    pub async fn snapshot(
        &self,
        source: &str,
        stream: &str,
    ) -> Result<Option<(Vec<u8>, Option<u64>)>, RelayCacheError> {
        self.on()?;
        let request =
            self.api.request(reqwest::Method::GET, &self.path(source, "snapshot", &[("stream", stream)]));
        let response = match self.send(request).await {
            Ok(response) => response,
            Err(RelayCacheError::Refused { status: 404, .. }) => return Ok(None),
            Err(error) => return Err(error),
        };
        let at = response
            .headers()
            .get("x-cmux-cache-at")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.parse().ok());
        let bytes = response.bytes().await.map_err(|e| ApiError::Http(e.to_string()))?;
        Ok(Some((bytes.to_vec(), at)))
    }

    /// A cold open: the snapshot from the relay, opened under `floor` (which rises to it). `None`
    /// when the relay holds none; then the phone waits for the Mac as today.
    pub async fn cold_open(
        &self,
        source: &str,
        source_key: &PublicKey,
        viewer: &SecretKey,
        stream: &str,
        floor: &mut Floor,
    ) -> Result<Option<ColdOpen>, RelayCacheError> {
        let Some((envelope, cached_at_ms)) = self.snapshot(source, stream).await? else { return Ok(None) };
        let opened = floor.open(viewer, source_key, stream, &envelope).map_err(RelayCacheError::Seal)?;
        Ok(Some(ColdOpen { opened, cached_at_ms, bytes: envelope.len() }))
    }

    /// A cold open of `stream`'s first screen ([`first_screen_stream`]), opened under `floor` (the
    /// first screen's own floor; its signature names its own stream). `None` when the source put
    /// none; then the caller opens the whole snapshot.
    pub async fn cold_open_first_screen(
        &self,
        source: &str,
        source_key: &PublicKey,
        viewer: &SecretKey,
        stream: &str,
        floor: &mut Floor,
    ) -> Result<Option<ColdOpen>, RelayCacheError> {
        self.cold_open(source, source_key, viewer, &first_screen_stream(stream), floor).await
    }

    /// `POST catch-up`: every sealed delta after each ask's position, unopened.
    pub async fn catch_up(
        &self,
        source: &str,
        asks: &[CatchUpAsk],
        budget_bytes: usize,
    ) -> Result<CatchUpReply, RelayCacheError> {
        self.on()?;
        if asks.len() > MAX_SURFACES {
            return Err(RelayCacheError::Bad(format!("{} surfaces is over {MAX_SURFACES}", asks.len())));
        }
        let body = serde_json::json!({ "surfaces": asks, "budgetBytes": budget_bytes.min(MAX_BUDGET_BYTES) });
        let request =
            self.api.request(reqwest::Method::POST, &self.path(source, "catch-up", &[])).json(&body);
        let response = self.send(request).await?;
        response.json().await.map_err(|e| RelayCacheError::Bad(e.to_string()))
    }

    /// A resume after sleep: asks the relay for every surface's deltas after its floor, opens each
    /// surface's in order and stops that surface at the first that is not the next or does not
    /// open. Each floor in `floors` rises to what applied. A surface with no floor (never opened)
    /// is not asked: it needs a snapshot first.
    pub async fn resume(
        &self,
        source: &str,
        source_key: &PublicKey,
        viewer: &SecretKey,
        floors: &mut [(String, Floor)],
        budget_bytes: usize,
    ) -> Result<Resume, RelayCacheError> {
        let asks: Vec<CatchUpAsk> = floors
            .iter()
            .filter_map(|(surface, floor)| {
                Some(CatchUpAsk { surface: surface.clone(), after: WirePosition(floor.position()?) })
            })
            .collect();
        if asks.is_empty() {
            return Ok(Resume::default());
        }
        let reply = self.catch_up(source, &asks, budget_bytes).await?;
        let mut resume = Resume { cut: reply.cut, ..Resume::default() };
        for answered in reply.surfaces {
            let Some((_, floor)) = floors.iter_mut().find(|(s, _)| *s == answered.surface) else { continue };
            let mut sealed = Vec::with_capacity(answered.sealed.len());
            for text in &answered.sealed {
                match b64url_decode(text) {
                    Some(bytes) => sealed.push(bytes),
                    None => return Err(RelayCacheError::Bad("a delta is not base64url".into())),
                }
            }
            resume.bytes += sealed.iter().map(Vec::len).sum::<usize>();
            let (applied, stopped) = delta::apply(floor, viewer, source_key, &answered.surface, &sealed);
            resume.surfaces.push(Resumed { surface: answered.surface, applied, floor: *floor, stopped });
        }
        Ok(resume)
    }

    /// [`RelayCache::resume`], then for each surface the relay cut (over the budget, or its deltas
    /// wrapped) or that stopped early, the newest snapshot instead: one catch-up and at most one
    /// `GET snapshot` per such surface, so a long sleep still lands on the Mac's newest state.
    pub async fn resume_or_snapshot(
        &self,
        source: &str,
        source_key: &PublicKey,
        viewer: &SecretKey,
        floors: &mut [(String, Floor)],
        budget_bytes: usize,
    ) -> Result<Resume, RelayCacheError> {
        let mut resume = self.resume(source, source_key, viewer, floors, budget_bytes).await?;
        let mut behind: Vec<String> = resume.cut.clone();
        behind.extend(resume.surfaces.iter().filter(|s| s.stopped.is_some()).map(|s| s.surface.clone()));
        for surface in behind {
            let Some((_, floor)) = floors.iter_mut().find(|(s, _)| *s == surface) else { continue };
            let Some((envelope, _)) = self.snapshot(source, &surface).await? else { continue };
            resume.bytes += envelope.len();
            // A snapshot no newer than what the phone holds is stale: the deltas it has stand.
            if let Ok(opened) = floor.open(viewer, source_key, &surface, &envelope) {
                resume.snapshots.push(opened);
            }
        }
        Ok(resume)
    }

    /// `POST ack`: the viewer holds every delta of `stream` through `through`; the relay drains
    /// them. Returns how many it drained.
    pub async fn ack(&self, source: &str, stream: &str, through: Position) -> Result<u64, RelayCacheError> {
        self.on()?;
        let body = serde_json::json!({ "through": WirePosition(through) });
        let request = self
            .api
            .request(reqwest::Method::POST, &self.path(source, "ack", &[("stream", stream)]))
            .json(&body);
        let reply: serde_json::Value =
            self.send(request).await?.json().await.map_err(|e| RelayCacheError::Bad(e.to_string()))?;
        Ok(reply.get("drained").and_then(serde_json::Value::as_u64).unwrap_or(0))
    }

    /// The source's `PUT snapshot` for `viewer` (this device is the source).
    pub async fn put_snapshot(
        &self,
        viewer: &str,
        stream: &str,
        envelope: Vec<u8>,
    ) -> Result<(), RelayCacheError> {
        self.write(reqwest::Method::PUT, "snapshot", viewer, stream, envelope).await
    }

    /// The source's `POST delta` for `viewer`: one envelope sealed on `<stream>/delta`.
    pub async fn append_delta(
        &self,
        viewer: &str,
        stream: &str,
        envelope: Vec<u8>,
    ) -> Result<(), RelayCacheError> {
        self.write(reqwest::Method::POST, "delta", viewer, stream, envelope).await
    }

    async fn write(
        &self,
        method: reqwest::Method,
        what: &str,
        viewer: &str,
        stream: &str,
        envelope: Vec<u8>,
    ) -> Result<(), RelayCacheError> {
        self.on()?;
        let viewer = viewer.to_ascii_lowercase();
        let path = self.path(&self.device, what, &[("viewer", &viewer), ("stream", stream)]);
        let request =
            self.api.request(method, &path).header("content-type", "application/octet-stream").body(envelope);
        self.send(request).await.map(drop)
    }
}

/// Percent-encodes what a stream name may hold (`[A-Za-z0-9._/-]`) and anything else.
fn encode_query(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-') {
            out.push(byte as char);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_position_reads_as_a_number_or_a_digit_string() {
        let p: WirePosition = serde_json::from_str(r#"{"epoch": 3, "seq": "18446744073709551615"}"#).unwrap();
        assert_eq!(p.0, Position { epoch: 3, seq: u64::MAX });
        assert!(serde_json::from_str::<WirePosition>(r#"{"epoch": "-1", "seq": 0}"#).is_err());
        assert!(serde_json::from_str::<WirePosition>(r#"{"epoch": "", "seq": 0}"#).is_err());
        assert_eq!(
            serde_json::to_string(&WirePosition(Position { epoch: 1, seq: 2 })).unwrap(),
            r#"{"epoch":1,"seq":2}"#
        );
    }

    #[test]
    fn a_stream_with_a_slash_is_escaped_in_the_query() {
        assert_eq!(encode_query("chat/abc-1.x_y"), "chat%2Fabc-1.x_y");
    }

    #[tokio::test]
    async fn off_by_default_sends_nothing() {
        // Port 9 on loopback: a request would fail with Http, not Off.
        let cache =
            RelayCache::new(ApiClient::new("http://127.0.0.1:9", "t"), "phone", RelayCacheConfig::default());
        assert!(matches!(cache.snapshot("mac", "s").await, Err(RelayCacheError::Off)));
        assert!(matches!(cache.put_snapshot("phone", "s", vec![1]).await, Err(RelayCacheError::Off)));
        assert!(matches!(
            cache.ack("mac", "s", Position { epoch: 0, seq: 0 }).await,
            Err(RelayCacheError::Off)
        ));
    }
}
