//! The backend's HTTP API (PROTOCOL.md "HTTP").

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IceServer {
    pub urls: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub username: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub credential: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IceConfig {
    pub ice_servers: Vec<IceServer>,
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
}

impl ApiClient {
    pub fn new(base_url: &str, token: &str) -> Self {
        Self::with_http(base_url, token, Self::http_client())
    }

    /// A client sharing `http`'s connection pool, so a later call reuses a
    /// warm TLS connection instead of a new handshake. Keep one pool per
    /// Tokio runtime (pooled connections belong to the runtime that made them).
    pub fn with_http(base_url: &str, token: &str, http: reqwest::Client) -> Self {
        Self { base: base_url.trim_end_matches('/').to_owned(), token: token.to_owned(), http }
    }

    /// A new HTTP client with the API's timeouts.
    pub fn http_client() -> reqwest::Client {
        crate::install_crypto_provider();
        reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(20))
            .pool_idle_timeout(std::time::Duration::from_secs(90))
            .build()
            .expect("HTTP client builds")
    }

    async fn check(response: reqwest::Response) -> Result<reqwest::Response, ApiError> {
        let status = response.status();
        if status.is_success() {
            return Ok(response);
        }
        let body = response.text().await.unwrap_or_default();
        Err(ApiError::Status { status: status.as_u16(), body: body.chars().take(512).collect() })
    }

    /// `GET /v1/ice`.
    pub async fn ice(&self) -> Result<IceConfig, ApiError> {
        let response = self
            .http
            .get(format!("{}/v1/ice", self.base))
            .bearer_auth(&self.token)
            .send()
            .await
            .map_err(|e| ApiError::Http(e.to_string()))?;
        Self::check(response).await?.json().await.map_err(|e| ApiError::Http(e.to_string()))
    }

    /// `POST /v1/devices` (upsert). Returns the backend's `device` object.
    pub async fn register_device(
        &self,
        registration: &DeviceRegistration,
    ) -> Result<serde_json::Value, ApiError> {
        let response = self
            .http
            .post(format!("{}/v1/devices", self.base))
            .bearer_auth(&self.token)
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
        let response = self
            .http
            .post(format!("{}/v1/devices/{mac_device_id}/notify", self.base))
            .bearer_auth(&self.token)
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
        let response = self
            .http
            .post(format!("{}/v1/devices/{mac_device_id}/notify", self.base))
            .bearer_auth(&self.token)
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
        let response = self
            .http
            .get(format!("{}/v1/me/devices", self.base))
            .bearer_auth(&self.token)
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
        let response = self
            .http
            .get(format!("{}/v1/teams/{team_id}/macs", self.base))
            .bearer_auth(&self.token)
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
    /// When the device first registered (ISO 8601).
    #[serde(default)]
    pub created_at: Option<String>,
}

/// `GET /v1/ice` results kept while their credentials have plenty of life
/// left, so a dial does not wait on an HTTP round trip (PROTOCOL.md: the
/// response carries `ttl`, the TURN credentials' lifetime in seconds).
#[derive(Debug, Default)]
pub struct IceCache {
    entry: std::sync::Mutex<Option<(Vec<IceServer>, std::time::Instant)>>,
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
        let expires = std::time::Instant::now() + Self::lifetime(config);
        *self.entry.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
            Some((config.ice_servers.clone(), expires));
    }

    pub fn clear(&self) {
        *self.entry.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = None;
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
        cache.clear();
        assert!(cache.fresh().is_none());
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
}
