//! The backend's HTTP API (PROTOCOL.md "HTTP").

use serde::{Deserialize, Serialize};

use crate::build_space::BuildSpace;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IceServer {
    pub urls: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub username: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub credential: Option<String>,
}

impl IceServer {
    /// A PoP hop/1 server. It lives outside the backend's `iceServers` array
    /// until this client normalizes the additive `hopServers` response field.
    pub fn hop(url: impl Into<String>, ticket: impl Into<String>) -> Self {
        Self { urls: vec![url.into()], username: None, credential: Some(ticket.into()) }
    }

    /// Returns the hop endpoint and its scoped BIND ticket.
    pub fn hop_config(&self) -> Option<(&str, &str)> {
        let url = self.urls.first().filter(|url| url.starts_with("hop://"))?;
        let ticket = self.credential.as_deref().filter(|ticket| !ticket.is_empty())?;
        Some((url.as_str(), ticket))
    }
}

fn normalize_hop_servers(config: &mut IceConfig) {
    config.ice_servers.extend(
        config
            .hop_servers
            .iter()
            .filter(|hop| hop.kind.as_deref().is_none_or(|kind| kind == "hop"))
            .filter_map(|hop| {
                let url = hop.url.as_deref().filter(|url| url.starts_with("hop://"))?;
                let ticket = hop.ticket.as_deref().filter(|ticket| !ticket.is_empty())?;
                Some(IceServer::hop(url, ticket))
            }),
    );
}

#[derive(Debug, Clone, Deserialize)]
pub struct HopServer {
    #[serde(default)]
    pub kind: Option<String>,
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default)]
    pub ticket: Option<String>,
}

// A future carrier may use structured credentials. One unfamiliar or
// malformed extension row must leave the standard ICE response usable.
fn decode_hop_entries<'de, D: serde::Deserializer<'de>>(de: D) -> Result<Vec<HopServer>, D::Error> {
    let value = serde_json::Value::deserialize(de)?;
    Ok(match value {
        serde_json::Value::Array(rows) => {
            rows.into_iter().filter_map(|row| serde_json::from_value(row).ok()).collect()
        }
        _ => Vec::new(),
    })
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IceConfig {
    pub ice_servers: Vec<IceServer>,
    #[serde(default, deserialize_with = "decode_hop_entries")]
    pub hop_servers: Vec<HopServer>,
    #[serde(default)]
    pub ttl: Option<u64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceRegistration {
    pub device_id: String,
    pub kind: String,
    pub name: String,
    pub team_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub wg_public_key: Option<String>,
    /// A Mac's machine id (PROTOCOL.md "Devices"): the same for every cmux
    /// build on one computer, never the raw hardware id.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub machine_id: Option<String>,
    /// Device ids other cmux builds on this Mac registered (at most 16).
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub sibling_device_ids: Vec<String>,
}

/// The body of `POST /v1/devices/:deviceId/notify` (PROTOCOL.md "Push
/// notifications (API 0.13.0)"): the event's kind and ids, and what a person
/// needs to act on it from the notification (the question, the command, the
/// options, the last lines). Never paths, prompts or tool arguments beyond the
/// permission's title. Every field past `kind` is optional; a 0.11 Worker
/// ignores the new ones.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NotifyEvent {
    pub event_id: String,
    /// `question`, `permission`, `completed`, `failed`, `chief` or `terminal`.
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub place: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    /// The workspace's title.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace_id: Option<String>,
    /// `s<surface>`, as the phone names a tab.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tab_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub permission_id: Option<String>,
    /// A Chief's home id.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub conversation_id: Option<String>,
    /// The daemon ledger id of a terminal notification.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub notification_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub options: Vec<NotifyOption>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub questions: Vec<NotifyQuestion>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub tail: Vec<String>,
    /// `waiting`, `finished`, `failed` or `notified`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub state: Option<String>,
    /// A terminal notification that takes a typed reply (`notification-reply-v1`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub replyable: Option<bool>,
}

/// One acpmux permission option (`optionId`, `name`, `kind`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NotifyOption {
    pub id: String,
    pub label: String,
    /// `allow_once`, `allow_always`, `reject_once` or `reject_always`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
}

/// One question of an AskUserQuestion-style ask.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NotifyQuestion {
    pub question: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub header: Option<String>,
    pub multi_select: bool,
    pub allows_other: bool,
    pub options: Vec<NotifyChoice>,
}

/// One choice of a question.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NotifyChoice {
    pub label: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

#[derive(Debug, thiserror::Error)]
pub enum ApiError {
    #[error("request failed: {0}")]
    Http(String),
    #[error("{status}: {body}")]
    Status { status: u16, body: String },
}

/// The HTTP client type behind [`ApiClient`] (one connection pool).
pub type HttpClient = reqwest::Client;

#[derive(Debug, Clone)]
pub struct ApiClient {
    base: String,
    token: String,
    http: reqwest::Client,
    /// Sent as `x-cmux-build-space` on every request when set (a dev build).
    build_space: Option<BuildSpace>,
}

impl ApiClient {
    pub fn new(base_url: &str, token: &str) -> Self {
        Self::with_http(base_url, token, Self::http_client())
    }

    /// A client sharing `http`'s connection pool, so a later call reuses a
    /// warm TLS connection instead of a new handshake. Keep one pool per
    /// Tokio runtime (pooled connections belong to the runtime that made them).
    pub fn with_http(base_url: &str, token: &str, http: reqwest::Client) -> Self {
        Self {
            base: base_url.trim_end_matches('/').to_owned(),
            token: token.to_owned(),
            http,
            build_space: None,
        }
    }

    /// This client sending `build_space` (a dev build's `dev:<slug>`) on
    /// every request; `None` sends no header.
    #[must_use]
    pub fn with_build_space(mut self, build_space: Option<BuildSpace>) -> Self {
        self.build_space = build_space;
        self
    }

    /// The build space this client sends, if any.
    pub fn build_space(&self) -> Option<&BuildSpace> {
        self.build_space.as_ref()
    }

    /// `method` on `path` with the bearer token and, for a dev build, the
    /// build space header.
    pub(crate) fn request(&self, method: reqwest::Method, path: &str) -> reqwest::RequestBuilder {
        let request = self.http.request(method, format!("{}{path}", self.base)).bearer_auth(&self.token);
        match &self.build_space {
            Some(space) => request.header(crate::build_space::HEADER, space.as_str()),
            None => request,
        }
    }

    /// Ask the system for the service's proxy now, off the runtime's threads
    /// (a PAC file may be fetched and run), so the client's proxy callback
    /// finds the answer cached instead of asking on a worker thread.
    async fn find_proxy(&self) {
        crate::egress::proxy::warm(&self.base).await;
    }

    /// A new HTTP client with the API's timeouts, through the system's proxy
    /// and verifying against the OS trust store ([`crate::egress`]).
    pub fn http_client() -> reqwest::Client {
        crate::install_crypto_provider();
        crate::egress::http_client_builder_with("cmux_mobile_link::api", RouteResolve)
            .timeout(std::time::Duration::from_secs(20))
            .pool_idle_timeout(std::time::Duration::from_secs(90))
            .build()
            .expect("HTTP client builds")
    }

    pub(crate) async fn check(response: reqwest::Response) -> Result<reqwest::Response, ApiError> {
        let status = response.status();
        if status.is_success() {
            return Ok(response);
        }
        let body = response.text().await.unwrap_or_default();
        Err(ApiError::Status { status: status.as_u16(), body: body.chars().take(512).collect() })
    }

    /// `GET /v1/ice`.
    pub async fn ice(&self) -> Result<IceConfig, ApiError> {
        self.find_proxy().await;
        let response = self
            .request(reqwest::Method::GET, "/v1/ice")
            .send()
            .await
            .map_err(|e| ApiError::Http(e.to_string()))?;
        let mut config: IceConfig =
            Self::check(response).await?.json().await.map_err(|e| ApiError::Http(e.to_string()))?;
        // `hopServers` is additive so an old client ignores it. New clients
        // normalize it into the common list after legacy ICE has parsed.
        normalize_hop_servers(&mut config);
        Ok(config)
    }

    /// Prepare a previously used ICE list for another WireGuard session.
    /// Only the PoP ticket is single-use across sessions. Keep usable TURN
    /// credentials even if the authenticated refresh cannot complete.
    pub async fn renew_hop_tickets(&self, servers: &mut Vec<IceServer>, budget: std::time::Duration) {
        if !servers.iter().any(|server| server.hop_config().is_some()) {
            return;
        }
        servers.retain(|server| server.hop_config().is_none());
        if let Ok(Ok(config)) = tokio::time::timeout(budget, self.ice()).await {
            servers.extend(config.ice_servers.into_iter().filter(|server| server.hop_config().is_some()));
        }
    }

    /// `POST /v1/devices` (upsert). Returns the backend's `device` object.
    pub async fn register_device(
        &self,
        registration: &DeviceRegistration,
    ) -> Result<serde_json::Value, ApiError> {
        self.find_proxy().await;
        let response = self
            .request(reqwest::Method::POST, "/v1/devices")
            .json(registration)
            .send()
            .await
            .map_err(|e| ApiError::Http(e.to_string()))?;
        let body: serde_json::Value =
            Self::check(response).await?.json().await.map_err(|e| ApiError::Http(e.to_string()))?;
        Ok(body.get("device").cloned().unwrap_or(body))
    }

    /// `POST /v1/devices/:deviceId/notify` (PROTOCOL.md): one Feed-worthy event
    /// for the owner's phones. Returns the backend's `{configured, sent, failed, dropped, wants?}`
    /// (`wants`, API 0.13.0: the kinds a phone that has not muted this Mac still wants).
    pub async fn notify(
        &self,
        mac_device_id: &str,
        event: &NotifyEvent,
    ) -> Result<serde_json::Value, ApiError> {
        self.find_proxy().await;
        let response = self
            .request(reqwest::Method::POST, &format!("/v1/devices/{mac_device_id}/notify"))
            .json(event)
            .send()
            .await
            .map_err(|e| ApiError::Http(e.to_string()))?;
        Self::check(response).await?.json().await.map_err(|e| ApiError::Http(e.to_string()))
    }

    /// [`Self::notify`] with a body already built (a sealed notify, API 0.13.0).
    pub async fn notify_body(
        &self,
        mac_device_id: &str,
        body: &serde_json::Value,
    ) -> Result<serde_json::Value, ApiError> {
        self.find_proxy().await;
        let response = self
            .request(reqwest::Method::POST, &format!("/v1/devices/{mac_device_id}/notify"))
            .json(body)
            .send()
            .await
            .map_err(|e| ApiError::Http(e.to_string()))?;
        Self::check(response).await?.json().await.map_err(|e| ApiError::Http(e.to_string()))
    }

    /// `GET /v1/me/devices`: every device the caller registered.
    pub async fn my_devices(&self) -> Result<Vec<MyDevice>, ApiError> {
        #[derive(Deserialize)]
        struct Devices {
            devices: Vec<MyDevice>,
        }
        self.find_proxy().await;
        let response = self
            .request(reqwest::Method::GET, "/v1/me/devices")
            .send()
            .await
            .map_err(|e| ApiError::Http(e.to_string()))?;
        let devices: Devices =
            Self::check(response).await?.json().await.map_err(|e| ApiError::Http(e.to_string()))?;
        Ok(devices.devices)
    }

    /// `GET /v1/teams/:teamId/macs`.
    pub async fn macs(&self, team_id: &str) -> Result<Vec<crate::signaling::MacPresence>, ApiError> {
        #[derive(Deserialize)]
        struct Macs {
            macs: Vec<crate::signaling::MacPresence>,
        }
        self.find_proxy().await;
        let response = self
            .request(reqwest::Method::GET, &format!("/v1/teams/{team_id}/macs"))
            .send()
            .await
            .map_err(|e| ApiError::Http(e.to_string()))?;
        let macs: Macs =
            Self::check(response).await?.json().await.map_err(|e| ApiError::Http(e.to_string()))?;
        Ok(macs.macs)
    }
}

/// One row of `GET /v1/me/devices` (the fields hostd reads).
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MyDevice {
    pub device_id: String,
    #[serde(default)]
    pub kind: String,
    /// The device's display name.
    #[serde(default)]
    pub name: String,
    /// Live presence for a Mac; `None` for a phone.
    #[serde(default)]
    pub online: Option<bool>,
    /// A Mac's machine id (one computer's builds share it).
    #[serde(default)]
    pub machine_id: Option<String>,
    /// When the device first registered (ISO 8601).
    #[serde(default)]
    pub created_at: Option<String>,
}

/// The API's names resolve as a dial's do: DNS, or the literals they last resolved to when DNS
/// is down ([`crate::route_literals`]). TLS still names and verifies the host.
struct RouteResolve;

impl reqwest::dns::Resolve for RouteResolve {
    fn resolve(&self, name: reqwest::dns::Name) -> reqwest::dns::Resolving {
        let host = name.as_str().to_owned();
        Box::pin(async move {
            let found = crate::route_literals::RouteLiterals::shared().resolve_host(&host).await?;
            let addrs: reqwest::dns::Addrs =
                Box::new(found.into_iter().map(|ip| std::net::SocketAddr::new(ip, 0)));
            Ok(addrs)
        })
    }
}

/// `GET /v1/ice` results kept while their credentials have plenty of life
/// left, so a dial does not wait on an HTTP round trip (PROTOCOL.md: the
/// response carries `ttl`, the TURN credentials' lifetime in seconds).
#[derive(Debug, Default)]
pub struct IceCache {
    entry: std::sync::Mutex<Option<(Vec<IceServer>, std::time::Instant)>>,
    /// The last servers fetched, kept past their expiry and through
    /// [`IceCache::mark_stale`] (a wake or a network change), so an answer
    /// can use them while a refresh runs in the background.
    last: std::sync::Mutex<Option<Vec<IceServer>>>,
}

impl IceCache {
    /// How long a STUN-only answer (no TURN, say a TURN outage) is kept:
    /// briefly, so TURN comes back soon.
    pub const STUN_ONLY_LIFETIME: std::time::Duration = std::time::Duration::from_secs(60);
    /// Lifetime when the service names no `ttl`.
    pub const DEFAULT_LIFETIME: std::time::Duration = std::time::Duration::from_secs(600);

    pub fn new() -> Self {
        Self::default()
    }

    /// How long `config` may be reused: half the credentials' lifetime, so
    /// a link dialed with them still has at least that long before they
    /// expire.
    pub fn lifetime(config: &IceConfig) -> std::time::Duration {
        if crate::dial::turn_url_count(&config.ice_servers) == 0 {
            return Self::STUN_ONLY_LIFETIME;
        }
        match config.ttl {
            Some(ttl) if ttl > 0 => std::time::Duration::from_secs(ttl / 2),
            _ => Self::DEFAULT_LIFETIME,
        }
    }

    /// The cached servers, while fresh.
    pub fn fresh(&self) -> Option<Vec<IceServer>> {
        let entry = self.entry.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        entry.as_ref().filter(|(_, expires)| std::time::Instant::now() < *expires).map(|(s, _)| s.clone())
    }

    pub fn store(&self, config: &IceConfig) {
        let hop_uncached = config.ice_servers.iter().any(|server| server.hop_config().is_some());
        let reusable: Vec<IceServer> =
            config.ice_servers.iter().filter(|server| server.hop_config().is_none()).cloned().collect();
        let expires = std::time::Instant::now() + Self::lifetime(config);
        *self.entry.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
            (!hop_uncached).then_some((reusable.clone(), expires));
        *self.last.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(reusable);
    }

    /// Forget everything, the last servers too.
    pub fn clear(&self) {
        *self.entry.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = None;
        *self.last.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = None;
    }

    /// No longer fresh (a wake can outlast the credentials), but kept as
    /// [`IceCache::last`]: the next caller answers with them and refreshes.
    pub fn mark_stale(&self) {
        *self.entry.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = None;
    }

    /// The last servers fetched, fresh or not.
    pub fn last(&self) -> Option<Vec<IceServer>> {
        self.last.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
    }

    /// The cached servers when fresh (`true`), else `GET /v1/ice` within
    /// `budget` (`false`); a failed fetch gives no servers (host candidates
    /// only) and caches nothing.
    pub async fn get(&self, api: &ApiClient, budget: std::time::Duration) -> (Vec<IceServer>, bool) {
        if let Some(servers) = self.fresh() {
            return (servers, true);
        }
        match tokio::time::timeout(budget, api.ice()).await {
            Ok(Ok(config)) => {
                self.store(&config);
                (config.ice_servers, false)
            }
            Ok(Err(error)) => {
                tracing::warn!(%error, "GET /v1/ice failed; host candidates only");
                (Vec::new(), false)
            }
            Err(_) => {
                tracing::warn!("GET /v1/ice timed out; host candidates only");
                (Vec::new(), false)
            }
        }
    }
}

/// STUN servers (`host:port`) named by `stun:` URLs.
pub fn stun_servers(servers: &[IceServer]) -> Vec<String> {
    servers
        .iter()
        .flat_map(|server| server.urls.iter())
        .filter_map(|url| url.strip_prefix("stun:"))
        .map(|rest| {
            let host = rest.split('?').next().unwrap_or(rest);
            if host.rsplit_once(':').is_some_and(|(_, port)| port.parse::<u16>().is_ok()) {
                host.to_owned()
            } else {
                format!("{host}:3478")
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config(urls: &[&str], ttl: Option<u64>) -> IceConfig {
        IceConfig {
            ice_servers: vec![IceServer {
                urls: urls.iter().map(|u| (*u).to_owned()).collect(),
                username: None,
                credential: None,
            }],
            hop_servers: Vec::new(),
            ttl,
        }
    }

    #[test]
    fn ice_cache_lifetime_follows_the_ttl() {
        use std::time::Duration;
        let turn = config(&["stun:s:3478", "turn:t:3478?transport=udp"], Some(14400));
        assert_eq!(IceCache::lifetime(&turn), Duration::from_secs(7200));
        assert_eq!(IceCache::lifetime(&config(&["turn:t"], None)), IceCache::DEFAULT_LIFETIME);
        assert_eq!(IceCache::lifetime(&config(&["stun:s"], Some(14400))), IceCache::STUN_ONLY_LIFETIME);
        let cache = IceCache::new();
        assert!(cache.fresh().is_none());
        cache.store(&turn);
        assert_eq!(cache.fresh().unwrap(), turn.ice_servers);
        // Already expired: a zero lifetime.
        cache.store(&config(&["turn:t"], Some(1)));
        assert!(cache.fresh().is_none());
        cache.store(&turn);
        cache.mark_stale();
        assert!(cache.fresh().is_none());
        assert_eq!(cache.last().unwrap(), turn.ice_servers, "stale servers stay as the last ones");
        cache.clear();
        assert!(cache.fresh().is_none());
        assert!(cache.last().is_none());
    }

    #[test]
    fn stun_urls() {
        let servers = vec![IceServer {
            urls: vec![
                "stun:stun.cloudflare.com:3478".into(),
                "turn:turn.x:3478?transport=udp".into(),
                "stun:a.b".into(),
            ],
            username: None,
            credential: None,
        }];
        assert_eq!(stun_servers(&servers), vec!["stun.cloudflare.com:3478", "a.b:3478"]);
    }

    #[test]
    fn hop_servers_are_additive_and_are_not_stun_servers() {
        let hop = IceServer::hop("hop://127.0.0.1:7422", "hop1.session.999.sig");
        assert_eq!(hop.hop_config(), Some(("hop://127.0.0.1:7422", "hop1.session.999.sig")));
        assert!(stun_servers(std::slice::from_ref(&hop)).is_empty());
        let old: IceConfig = serde_json::from_str(r#"{"iceServers":[{"urls":["stun:s:3478"]}],"hopServers":[{"kind":"hop","url":"hop://h:1","ticket":"t"}],"ttl":60}"#).unwrap();
        assert_eq!(old.ice_servers.len(), 1, "raw decode preserves old ICE list");
        assert_eq!(old.hop_servers[0].url.as_deref(), Some("hop://h:1"));
    }

    #[test]
    fn hop_tickets_are_never_reused_from_the_mobile_cache() {
        let cache = IceCache::new();
        let hop = IceServer::hop("hop://h:1", "hop1.a.1.sig");
        let config = IceConfig { ice_servers: vec![hop], hop_servers: Vec::new(), ttl: Some(600) };
        cache.store(&config);
        assert!(cache.fresh().is_none());
        assert!(cache.last().unwrap().is_empty());
    }

    #[test]
    fn old_clients_ignore_additive_hop_servers_and_new_clients_ignore_unknown_kinds() {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct OldIceConfig {
            ice_servers: Vec<IceServer>,
        }
        let json = r#"{"iceServers":[{"urls":["stun:s:3478"]}],"hopServers":[{"kind":"hop","url":"hop://h:1","ticket":"t"},{"kind":"future","ticket":{"scheme":"other"}},{"kind":"future","endpoint":"future://x:1"},{"kind":"hop","url":"http://x:1","ticket":"bad"},{"kind":"hop","url":"hop://x:1","ticket":""}]}"#;
        let old: OldIceConfig = serde_json::from_str(json).unwrap();
        assert_eq!(old.ice_servers.len(), 1);
        let mut new: IceConfig = serde_json::from_str(json).unwrap();
        normalize_hop_servers(&mut new);
        assert_eq!(new.ice_servers.iter().filter_map(IceServer::hop_config).count(), 1);
        let old_response: IceConfig =
            serde_json::from_str(r#"{"iceServers":[{"urls":["stun:s:3478"]}]}"#).unwrap();
        assert!(old_response.hop_servers.is_empty());
    }
}
