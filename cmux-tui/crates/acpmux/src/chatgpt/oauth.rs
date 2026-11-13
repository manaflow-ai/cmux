//! The OAuth side of Sign in with ChatGPT: the authorize URL, the loopback callback, the code
//! exchange, refresh and revocation, and the OpenID configuration's JWKS.

use std::collections::HashMap;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use base64::Engine as _;
use serde::Deserialize;
use serde_json::Value;
use sha2::Digest as _;
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};

use super::store::{self, Host, Record};
use super::{DYNAMIC_CLIENT_ID, Failure, PLAN_SCOPE, Places, RESOURCE, SCOPES, jwt};
use crate::routes::{self, RouteFile, RouteKind};

/// How long the JWKS is kept before a refetch.
const KEYS_TTL: Duration = Duration::from_secs(60 * 60);
/// The most of a callback request read.
const MAX_REQUEST: usize = 16 * 1024;
/// How long one callback connection may take to send its request.
const REQUEST_WAIT: Duration = Duration::from_secs(10);

/// Where the OAuth requests go. `openai()` is production; tests point `at` a local server.
#[derive(Debug, Clone, PartialEq)]
pub struct Endpoints {
    /// The ID token's expected `iss`.
    pub issuer: String,
    pub authorize_url: String,
    pub token_url: String,
    /// The OpenID configuration (its `jwks_uri` and `revocation_endpoint`).
    pub discovery_url: String,
    /// The `resource` every token is for.
    pub resource: String,
}

impl Endpoints {
    pub fn openai() -> Self {
        Self::at("https://auth.openai.com")
    }

    /// Every endpoint under `issuer` (an origin without a trailing slash).
    pub fn at(issuer: &str) -> Self {
        let issuer = issuer.trim_end_matches('/');
        Self {
            issuer: issuer.to_owned(),
            authorize_url: format!("{issuer}/api/accounts/authorize"),
            token_url: format!("{issuer}/api/accounts/oauth/token"),
            discovery_url: format!("{issuer}/.well-known/openid-configuration"),
            resource: RESOURCE.to_owned(),
        }
    }
}

/// `bytes` random bytes, base64url without padding.
pub(crate) fn random_token(bytes: usize) -> Result<String, Failure> {
    let mut buf = vec![0u8; bytes];
    getrandom::fill(&mut buf).map_err(|e| Failure::new("internal", e.to_string()))?;
    Ok(base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(buf))
}

/// The PKCE S256 challenge of `verifier`.
pub(crate) fn challenge(verifier: &str) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(sha2::Sha256::digest(verifier))
}

/// `application/x-www-form-urlencoded`.
pub(crate) fn form_encode(pairs: &[(&str, &str)]) -> String {
    fn enc(out: &mut String, text: &str) {
        for b in text.bytes() {
            match b {
                b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'*' => {
                    out.push(b as char)
                }
                b' ' => out.push('+'),
                _ => out.push_str(&format!("%{b:02X}")),
            }
        }
    }
    let mut out = String::new();
    for (i, (k, v)) in pairs.iter().enumerate() {
        if i > 0 {
            out.push('&');
        }
        enc(&mut out, k);
        out.push('=');
        enc(&mut out, v);
    }
    out
}

/// One sign-in's secrets, kept in memory only.
pub(crate) struct Pending {
    pub host: Host,
    pub state: String,
    pub nonce: String,
    pub verifier: String,
    pub redirect_uri: String,
    pub reauth: Option<String>,
    id_token_hint: Option<String>,
    login_hint: Option<String>,
}

impl Pending {
    pub fn new(
        host: Host,
        port: u16,
        reauth: Option<String>,
        prior: Option<&Record>,
    ) -> Result<Self, Failure> {
        Ok(Self {
            host,
            state: random_token(24)?,
            nonce: random_token(24)?,
            verifier: random_token(32)?,
            redirect_uri: format!("http://127.0.0.1:{port}/auth/callback"),
            reauth,
            id_token_hint: prior.map(|r| r.id_token.clone()).filter(|t| !t.is_empty()),
            login_hint: prior.and_then(|r| r.email.clone()),
        })
    }

    /// A first registration: no client id issued yet.
    pub fn registering(&self) -> bool {
        self.host.client_id.is_none()
    }
}

#[derive(Debug, Clone)]
struct Keys {
    fetched: Instant,
    jwks: Vec<Value>,
    revocation: Option<String>,
}

/// A token endpoint answer. Not `Debug`: it holds tokens.
#[derive(Deserialize)]
pub(crate) struct TokenAnswer {
    access_token: String,
    #[serde(default)]
    refresh_token: Option<String>,
    #[serde(default)]
    id_token: Option<String>,
    #[serde(default)]
    expires_in: Option<i64>,
    #[serde(default)]
    scope: Option<String>,
}

impl TokenAnswer {
    fn scopes(&self) -> Option<Vec<String>> {
        self.scope.as_deref().map(|s| s.split_whitespace().map(str::to_owned).collect())
    }

    /// Replaces the record's access token, expiry, scopes and (rotated) refresh token together;
    /// the caller writes the record once.
    pub fn apply(self, record: &mut Record, now: i64) {
        let scopes = self.scopes();
        record.access_token = self.access_token;
        record.expires_at = now + self.expires_in.unwrap_or(3600).max(0);
        if let Some(refresh) = self.refresh_token.filter(|r| !r.is_empty()) {
            record.refresh_token = refresh;
        }
        if let Some(id_token) = self.id_token.filter(|t| !t.is_empty()) {
            record.id_token = id_token;
        }
        if let Some(scopes) = scopes {
            record.scopes = scopes;
        }
    }
}

pub(crate) struct Client {
    pub endpoints: Endpoints,
    http: OnceLock<reqwest::Client>,
    keys: tokio::sync::Mutex<Option<Keys>>,
}

/// The OAuth `error` code of an answer, only when it is a plain code (never echoed text).
fn error_code(body: &Value) -> Option<&str> {
    body.get("error")
        .and_then(Value::as_str)
        .filter(|c| c.len() <= 64 && c.bytes().all(|b| b.is_ascii_lowercase() || b == b'_'))
}

impl Client {
    pub fn new(endpoints: Endpoints) -> Self {
        Self { endpoints, http: OnceLock::new(), keys: tokio::sync::Mutex::new(None) }
    }

    fn http(&self) -> &reqwest::Client {
        self.http.get_or_init(|| {
            let _ = rustls::crypto::ring::default_provider().install_default();
            reqwest::Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .connect_timeout(Duration::from_secs(10))
                .timeout(Duration::from_secs(30))
                .build()
                .unwrap_or_default()
        })
    }

    pub fn authorize_url(&self, p: &Pending) -> Result<String, Failure> {
        let challenge = challenge(&p.verifier);
        let client_id = p.host.client_id.as_deref().unwrap_or(DYNAMIC_CLIENT_ID);
        let mut pairs: Vec<(&str, &str)> = vec![
            ("client_id", client_id),
            ("ext_agent_host_id", p.host.host_id.as_str()),
            ("response_type", "code"),
            ("redirect_uri", p.redirect_uri.as_str()),
            ("scope", SCOPES),
            ("resource", self.endpoints.resource.as_str()),
            ("state", p.state.as_str()),
            ("nonce", p.nonce.as_str()),
            ("code_challenge", challenge.as_str()),
            ("code_challenge_method", "S256"),
        ];
        if p.registering() && p.reauth.is_none() {
            pairs.push(("agent_name_hint", "cmux"));
        }
        if p.reauth.is_some() {
            if let Some(hint) = &p.id_token_hint {
                pairs.push(("id_token_hint", hint.as_str()));
            }
            if let Some(hint) = &p.login_hint {
                pairs.push(("login_hint", hint.as_str()));
            }
        }
        Ok(format!("{}?{}", self.endpoints.authorize_url, form_encode(&pairs)))
    }

    async fn post_form(&self, url: &str, pairs: &[(&str, &str)]) -> Result<(u16, Value), Failure> {
        let answer = self
            .http()
            .post(url)
            .header("content-type", "application/x-www-form-urlencoded")
            .header("accept", "application/json")
            .body(form_encode(pairs))
            .send()
            .await
            // reqwest's error names the URL, never the form body.
            .map_err(|e| Failure::new("network", e.without_url().to_string()))?;
        let status = answer.status().as_u16();
        let body = answer.bytes().await.map_err(|e| Failure::new("network", e.to_string()))?;
        Ok((status, serde_json::from_slice(&body).unwrap_or(Value::Null)))
    }

    async fn get_json(&self, url: &str) -> Result<Value, Failure> {
        let answer = self
            .http()
            .get(url)
            .header("accept", "application/json")
            .send()
            .await
            .map_err(|e| Failure::new("network", e.to_string()))?;
        if !answer.status().is_success() {
            return Err(Failure::new("discovery_failed", format!("{url}: {}", answer.status())));
        }
        answer.json().await.map_err(|e| Failure::new("discovery_failed", e.to_string()))
    }

    async fn keys(&self, refetch: bool) -> Result<Keys, Failure> {
        let mut cached = self.keys.lock().await;
        if let Some(keys) = cached.as_ref()
            && !refetch
            && keys.fetched.elapsed() < KEYS_TTL
        {
            return Ok(keys.clone());
        }
        let config = self.get_json(&self.endpoints.discovery_url).await?;
        if let Some(issuer) = config.get("issuer").and_then(Value::as_str)
            && issuer != self.endpoints.issuer
        {
            return Err(Failure::new(
                "discovery_failed",
                "the OpenID configuration names another issuer",
            ));
        }
        let jwks_uri = config
            .get("jwks_uri")
            .and_then(Value::as_str)
            .ok_or_else(|| Failure::new("discovery_failed", "no jwks_uri"))?;
        let jwks = self.get_json(jwks_uri).await?;
        let keys = Keys {
            fetched: Instant::now(),
            jwks: jwks.get("keys").and_then(Value::as_array).cloned().unwrap_or_default(),
            revocation: config
                .get("revocation_endpoint")
                .and_then(Value::as_str)
                .map(str::to_owned),
        };
        *cached = Some(keys.clone());
        Ok(keys)
    }

    async fn verify_id_token(
        &self,
        token: &str,
        client_id: &str,
        nonce: &str,
    ) -> Result<jwt::Claims, Failure> {
        let now = super::now_unix();
        let check = |keys: &Keys| {
            jwt::verify(token, &keys.jwks, &self.endpoints.issuer, client_id, nonce, now)
        };
        let mut result = check(&self.keys(false).await?);
        if result == Err(jwt::Invalid::UnknownKey) {
            // The issuer rotated its keys since the last fetch.
            result = check(&self.keys(true).await?);
        }
        result.map_err(|e| Failure::new("invalid_id_token", e.as_str()))
    }

    /// Serves the loopback listener until the callback arrives, and finishes the sign-in with it.
    pub async fn serve_callback(
        &self,
        listener: tokio::net::TcpListener,
        pending: &Pending,
        places: &Places,
        locks: &super::Locks,
    ) -> Result<String, Failure> {
        loop {
            let (mut stream, _) =
                listener.accept().await.map_err(|e| Failure::new("listener", e.to_string()))?;
            let Ok(Some(target)) =
                tokio::time::timeout(REQUEST_WAIT, read_target(&mut stream)).await
            else {
                let _ = respond(&mut stream, "400 Bad Request", "Bad request.").await;
                continue;
            };
            let Ok(url) = reqwest::Url::parse(&format!("http://127.0.0.1{target}")) else {
                let _ = respond(&mut stream, "400 Bad Request", "Bad request.").await;
                continue;
            };
            if url.path() != "/auth/callback" {
                let _ = respond(&mut stream, "404 Not Found", "Not found.").await;
                continue;
            }
            let query: HashMap<String, String> = url.query_pairs().into_owned().collect();
            let result = self.complete(pending, &query, places, locks).await;
            let page = match &result {
                Ok(_) => "Signed in to cmux with ChatGPT. You can close this tab.".to_owned(),
                Err(f) => format!("ChatGPT sign-in did not finish ({}). Return to cmux.", f.code),
            };
            let _ = respond(&mut stream, "200 OK", &page).await;
            return result;
        }
    }

    /// The callback's parameters to a stored sign-in.
    pub async fn complete(
        &self,
        pending: &Pending,
        query: &HashMap<String, String>,
        places: &Places,
        locks: &super::Locks,
    ) -> Result<String, Failure> {
        if query.get("state").map(String::as_str) != Some(pending.state.as_str()) {
            return Err(Failure::new(
                "state_mismatch",
                "the callback's state is not this sign-in's",
            ));
        }
        if let Some(error) = query.get("error") {
            let code = match error.as_str() {
                "access_denied" => "access_denied",
                _ => "authorize_failed",
            };
            return Err(Failure::new(code, "the authorization was not granted"));
        }
        let code = query
            .get("code")
            .filter(|c| !c.is_empty())
            .ok_or_else(|| Failure::new("no_code", "the callback carried no code"))?;
        let client_id = match &pending.host.client_id {
            Some(id) => id.clone(),
            None => {
                let issued = query
                    .get("client_id")
                    .filter(|c| valid_client_id(c))
                    .ok_or_else(|| {
                        Failure::new("no_client_id", "the registration issued no client id")
                    })?
                    .clone();
                // Recorded before the exchange, so a failed exchange never registers again.
                let home = places.home.clone();
                let id = issued.clone();
                tokio::task::spawn_blocking(move || store::set_client_id(&home, &id))
                    .await
                    .map_err(|e| Failure::new("internal", e.to_string()))?
                    .map_err(|e| Failure::new("storage", e.to_string()))?;
                issued
            }
        };
        let (status, body) = self
            .post_form(
                &self.endpoints.token_url,
                &[
                    ("grant_type", "authorization_code"),
                    ("client_id", client_id.as_str()),
                    ("code", code.as_str()),
                    ("code_verifier", pending.verifier.as_str()),
                    ("redirect_uri", pending.redirect_uri.as_str()),
                    ("resource", self.endpoints.resource.as_str()),
                ],
            )
            .await?;
        if !(200..300).contains(&status) {
            let why = error_code(&body).unwrap_or("no error code");
            return Err(Failure::new("token_exchange_failed", format!("{status} {why}")));
        }
        let answer: TokenAnswer = serde_json::from_value(body).map_err(|_| {
            Failure::new("token_exchange_failed", "the token answer has no access_token")
        })?;
        let id_token = answer
            .id_token
            .clone()
            .filter(|t| !t.is_empty())
            .ok_or_else(|| Failure::new("invalid_id_token", "no ID token"))?;
        let claims = self.verify_id_token(&id_token, &client_id, &pending.nonce).await?;
        // The granted scopes: the token answer's, else the callback's `scope`. Neither names them:
        // the requested ones, as RFC 6749 section 5.1 lets a server omit `scope` when it grants
        // what was asked. Only a returned list without the plan scope is a refusal.
        let scopes = answer
            .scopes()
            .or_else(|| {
                query.get("scope").map(|s| s.split_whitespace().map(str::to_owned).collect())
            })
            .unwrap_or_else(|| SCOPES.split_whitespace().map(str::to_owned).collect());
        let refresh = answer.refresh_token.clone().filter(|r| !r.is_empty());
        if !scopes.iter().any(|s| s == PLAN_SCOPE) {
            if let Some(refresh) = refresh {
                let unused = Record {
                    client_id: client_id.clone(),
                    refresh_token: refresh,
                    ..Record::default()
                };
                let _ = self.revoke(&unused).await;
            }
            return Err(Failure::new("no_plan_scope", "ChatGPT did not grant use of the plan"));
        }
        if refresh.is_none() {
            return Err(Failure::new("token_exchange_failed", "no refresh token"));
        }
        let joined = |e: tokio::task::JoinError| Failure::new("internal", e.to_string());
        let (p, reauth, c, sub) =
            (places.clone(), pending.reauth.clone(), client_id.clone(), claims.sub.clone());
        let id = tokio::task::spawn_blocking(move || choose_id(&p, reauth, &c, &sub))
            .await
            .map_err(joined)??;
        // The account's lock: a refresh in flight for it finishes first, and cannot then write
        // its record over this new sign-in's.
        let lock = locks.for_id(&id);
        let _one = lock.lock().await;
        let places = places.clone();
        let now = super::now_unix();
        tokio::task::spawn_blocking(move || save(&places, &id, &client_id, claims, answer, now))
            .await
            .map_err(joined)?
    }

    /// A refresh of `record`'s tokens.
    pub async fn refresh(&self, record: &Record) -> Result<TokenAnswer, Failure> {
        let (status, body) = self
            .post_form(
                &self.endpoints.token_url,
                &[
                    ("grant_type", "refresh_token"),
                    ("client_id", record.client_id.as_str()),
                    ("refresh_token", record.refresh_token.as_str()),
                    ("resource", self.endpoints.resource.as_str()),
                ],
            )
            .await?;
        if !(200..300).contains(&status) {
            let why = error_code(&body);
            let code = if matches!(status, 400 | 401) && why == Some("invalid_grant") {
                "reauth_required"
            } else {
                "refresh_failed"
            };
            return Err(Failure::new(code, format!("{status} {}", why.unwrap_or("no error code"))));
        }
        serde_json::from_value(body)
            .map_err(|_| Failure::new("refresh_failed", "the token answer has no access_token"))
    }

    /// Revokes `record`'s refresh token at the OpenID configuration's revocation endpoint.
    pub async fn revoke(&self, record: &Record) -> Result<(), Failure> {
        let endpoint = self.keys(false).await?.revocation.ok_or_else(|| {
            Failure::new("no_revocation_endpoint", "the OpenID configuration names none")
        })?;
        let (status, body) = self
            .post_form(
                &endpoint,
                &[
                    ("token", record.refresh_token.as_str()),
                    ("token_type_hint", "refresh_token"),
                    ("client_id", record.client_id.as_str()),
                ],
            )
            .await?;
        if (200..300).contains(&status) {
            Ok(())
        } else {
            Err(Failure::new(
                "revoke_failed",
                format!("{status} {}", error_code(&body).unwrap_or("no error code")),
            ))
        }
    }
}

fn valid_client_id(id: &str) -> bool {
    id != DYNAMIC_CLIENT_ID
        && !id.is_empty()
        && id.len() <= 200
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.'))
}

/// The route id a sign-in of (`client_id`, `sub`) saves to: its existing record's, a reauth's
/// own (the same person under a new client id), else the next free `chatgpt[-N]`, reserved
/// before this returns. One choice at a time in this daemon (so two sign-ins of one new person
/// share one id), and a new id is claimed by creating its record file, never by overwriting one
/// (so two choices never take the same id, from this daemon or another).
pub(super) fn choose_id(
    places: &Places,
    reauth: Option<String>,
    client_id: &str,
    sub: &str,
) -> Result<String, Failure> {
    static CHOOSING: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let _one = CHOOSING.lock().unwrap_or_else(|p| p.into_inner());
    let dir = places.routes.as_deref();
    let records = store::all(&places.home);
    let same = |r: &Record| r.client_id == client_id && r.sub == sub;
    if let Some((id, _)) = records.iter().find(|(_, r)| same(r)) {
        return Ok(id.clone());
    }
    // A reauth of the same person whose client id changed keeps its connection.
    if let Some(id) = reauth.filter(|id| records.iter().any(|(rid, r)| rid == id && r.sub == sub)) {
        return Ok(id);
    }
    let reservation =
        Record { client_id: client_id.to_owned(), sub: sub.to_owned(), ..Record::default() };
    for id in std::iter::once("chatgpt".to_owned()).chain((2..1000).map(|n| format!("chatgpt-{n}")))
    {
        if records.iter().any(|(rid, _)| *rid == id) || routes::find(dir, &id).is_ok() {
            continue;
        }
        match store::create(&places.home, &id, &reservation) {
            Ok(()) => return Ok(id),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(Failure::new("storage", e.to_string())),
        }
    }
    Err(Failure::new("storage", "no free ChatGPT connection id"))
}

/// Writes the account's record and its `chatgpt-plan` route under `id`; the route id.
fn save(
    places: &Places,
    id: &str,
    client_id: &str,
    claims: jwt::Claims,
    answer: TokenAnswer,
    now: i64,
) -> Result<String, Failure> {
    let storage = |e: std::io::Error| Failure::new("storage", e.to_string());
    let dir = places.routes.as_deref();
    let mut record = Record {
        client_id: client_id.to_owned(),
        sub: claims.sub,
        email: claims.email,
        plan: claims.plan,
        ..Record::default()
    };
    answer.apply(&mut record, now);
    store::write(&places.home, id, &record).map_err(storage)?;
    let disabled = routes::find(dir, id)
        .ok()
        .filter(|r| r.file.kind == RouteKind::ChatgptPlan)
        .is_some_and(|r| r.file.disabled);
    let file = RouteFile {
        name: Some(match &record.email {
            Some(email) => format!("ChatGPT plan ({email})"),
            None => "ChatGPT plan".to_owned(),
        }),
        kind: RouteKind::ChatgptPlan,
        families: vec!["codex".into()],
        anthropic_base_url: None,
        openai_base_url: Some(RESOURCE.to_owned()),
        auth: None,
        secret: None,
        headers: Default::default(),
        health_url: None,
        fallback: vec![],
        auto_fallback: false,
        notes: Some("Sign in with ChatGPT: the daemon holds and refreshes its tokens".into()),
        account_home: None,
        shadow_of: None,
        disabled,
        provider: Some("openai".into()),
    };
    routes::add(dir, id, &file, true).map_err(|e| Failure::new("storage", e.to_string()))?;
    Ok(id.to_owned())
}

/// The request target of an HTTP request line (`GET /auth/callback?... HTTP/1.1`).
async fn read_target(stream: &mut tokio::net::TcpStream) -> Option<String> {
    let mut buf = Vec::with_capacity(1024);
    let mut chunk = [0u8; 1024];
    while !buf.windows(4).any(|w| w == b"\r\n\r\n") {
        let n = stream.read(&mut chunk).await.ok()?;
        if n == 0 || buf.len() + n > MAX_REQUEST {
            break;
        }
        buf.extend_from_slice(&chunk[..n]);
    }
    let text = std::str::from_utf8(&buf).ok()?;
    let mut line = text.lines().next()?.split(' ');
    match (line.next(), line.next()) {
        (Some("GET"), Some(target)) if target.starts_with('/') => Some(target.to_owned()),
        _ => None,
    }
}

async fn respond(
    stream: &mut tokio::net::TcpStream,
    status: &str,
    text: &str,
) -> std::io::Result<()> {
    let body = format!(
        "<!doctype html><meta charset=\"utf-8\"><title>cmux</title><p style=\"font-family:system-ui;margin:3em\">{text}</p>"
    );
    let head = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: {}\r\n\r\n",
        body.len()
    );
    stream.write_all(head.as_bytes()).await?;
    stream.write_all(body.as_bytes()).await?;
    stream.shutdown().await
}
