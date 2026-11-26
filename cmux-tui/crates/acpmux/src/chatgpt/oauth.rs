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

use super::store::{self, Record};
use super::{
    CALLBACK_PORT, CODEX_BACKEND, CODEX_CLIENT_ID, Failure, Places, REFRESH_SCOPES, SCOPES, jwt,
};
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
    /// The OpenID configuration (its `jwks_uri`).
    pub discovery_url: String,
    /// Where a sign-out revokes the refresh token (Codex's `/oauth/revoke`, a JSON body).
    pub revoke_url: String,
    /// The OAuth client signed in with: Codex's.
    pub client_id: String,
    /// The loopback port the callback listens on ([`CALLBACK_PORT`]; 0 in tests: any free one).
    pub callback_port: u16,
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
            authorize_url: format!("{issuer}/oauth/authorize"),
            token_url: format!("{issuer}/oauth/token"),
            discovery_url: format!("{issuer}/.well-known/openid-configuration"),
            revoke_url: format!("{issuer}/oauth/revoke"),
            client_id: CODEX_CLIENT_ID.to_owned(),
            callback_port: CALLBACK_PORT,
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
    pub state: String,
    pub nonce: String,
    pub verifier: String,
    pub redirect_uri: String,
    pub reauth: Option<String>,
    login_hint: Option<String>,
}

impl Pending {
    pub fn new(port: u16, reauth: Option<String>, prior: Option<&Record>) -> Result<Self, Failure> {
        Ok(Self {
            state: random_token(24)?,
            nonce: random_token(24)?,
            verifier: random_token(32)?,
            // Codex's registered redirect, on the address the listener binds (Codex moved from
            // `localhost` to 127.0.0.1: a browser that tries ::1 first never reaches 127.0.0.1).
            redirect_uri: format!("http://127.0.0.1:{port}/auth/callback"),
            reauth,
            login_hint: prior.and_then(|r| r.email.clone()),
        })
    }
}

#[derive(Debug, Clone)]
struct Keys {
    fetched: Instant,
    jwks: Vec<Value>,
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
/// Read where Codex reads it: `error` as a string, `error.code`, or a top-level `code`.
fn error_code(body: &Value) -> Option<&str> {
    fn plain(v: Option<&Value>) -> Option<&str> {
        v.and_then(Value::as_str)
            .filter(|c| c.len() <= 64 && c.bytes().all(|b| b.is_ascii_lowercase() || b == b'_'))
    }
    plain(body.get("error"))
        .or_else(|| plain(body.pointer("/error/code")))
        .or_else(|| plain(body.get("code")))
}

impl Client {
    pub fn new(endpoints: Endpoints) -> Self {
        Self { endpoints, http: OnceLock::new(), keys: tokio::sync::Mutex::new(None) }
    }

    fn http(&self) -> &reqwest::Client {
        self.http.get_or_init(|| {
            let _ = rustls::crypto::ring::default_provider().install_default();
            crate::happy_dial::http_client()
                .redirect(reqwest::redirect::Policy::none())
                .connect_timeout(Duration::from_secs(10))
                .timeout(Duration::from_secs(30))
                .build()
                .unwrap_or_default()
        })
    }

    /// Codex's own authorize request (`codex login`), so the tokens are the ones Codex runs on.
    pub fn authorize_url(&self, p: &Pending) -> Result<String, Failure> {
        let challenge = challenge(&p.verifier);
        let mut pairs: Vec<(&str, &str)> = vec![
            ("response_type", "code"),
            ("client_id", self.endpoints.client_id.as_str()),
            ("redirect_uri", p.redirect_uri.as_str()),
            ("scope", SCOPES),
            ("code_challenge", challenge.as_str()),
            ("code_challenge_method", "S256"),
            ("id_token_add_organizations", "true"),
            ("codex_cli_simplified_flow", "true"),
            ("state", p.state.as_str()),
            ("nonce", p.nonce.as_str()),
            ("originator", "codex_cli_rs"),
        ];
        if p.reauth.is_some()
            && let Some(hint) = &p.login_hint
        {
            pairs.push(("login_hint", hint.as_str()));
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

    async fn post_json(&self, url: &str, body: &Value) -> Result<(u16, Value), Failure> {
        let answer = self
            .http()
            .post(url)
            .header("content-type", "application/json")
            .header("accept", "application/json")
            .body(body.to_string())
            .send()
            .await
            // reqwest's error names the URL, never the body.
            .map_err(|e| Failure::new("network", e.without_url().to_string()))?;
        let status = answer.status().as_u16();
        let bytes = answer.bytes().await.map_err(|e| Failure::new("network", e.to_string()))?;
        Ok((status, serde_json::from_slice(&bytes).unwrap_or(Value::Null)))
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
        };
        *cached = Some(keys.clone());
        Ok(keys)
    }

    async fn verify_id_token(
        &self,
        token: &str,
        client_id: &str,
        nonce: Option<&str>,
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
            if url.path() == "/cancel" {
                // `codex login` asks an earlier login server on the shared port to stop before it
                // binds: this sign-in gives the port up instead of making Codex's fail.
                let _ = respond(&mut stream, "200 OK", "Login cancelled.").await;
                return Err(Failure::new("cancelled", "another ChatGPT sign-in took the port"));
            }
            if url.path() != "/auth/callback" {
                let _ = respond(&mut stream, "404 Not Found", "Not found.").await;
                continue;
            }
            let query: HashMap<String, String> = url.query_pairs().into_owned().collect();
            if query.get("state").map(String::as_str) != Some(pending.state.as_str()) {
                // A stray request (a stale tab, a page that navigates here) never ends the
                // sign-in on this well-known port; only this sign-in's own callback does.
                let _ = respond(&mut stream, "400 Bad Request", "Not this sign-in.").await;
                continue;
            }
            let result = self.complete(pending, &query, places).await;
            let page = match &result {
                Ok(_) => Page::signed_in(),
                Err(f) => Page::failed(&f.code),
            };
            let _ = respond_page(&mut stream, "200 OK", &page).await;
            return result;
        }
    }

    /// The callback's parameters to a stored sign-in.
    pub async fn complete(
        &self,
        pending: &Pending,
        query: &HashMap<String, String>,
        places: &Places,
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
        let client_id = self.endpoints.client_id.clone();
        let (status, body) = self
            .post_form(
                &self.endpoints.token_url,
                &[
                    ("grant_type", "authorization_code"),
                    ("client_id", client_id.as_str()),
                    ("code", code.as_str()),
                    ("code_verifier", pending.verifier.as_str()),
                    ("redirect_uri", pending.redirect_uri.as_str()),
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
        let claims = self.verify_id_token(&id_token, &client_id, Some(&pending.nonce)).await?;
        if claims.account.is_none() {
            // An API-only OpenAI account: no ChatGPT plan for Codex to run on.
            return Err(Failure::new("no_chatgpt_account", "the sign-in names no ChatGPT account"));
        }
        let refresh = answer.refresh_token.clone().filter(|r| !r.is_empty());
        if refresh.is_none() {
            return Err(Failure::new("token_exchange_failed", "no refresh token"));
        }
        let places = places.clone();
        let reauth = pending.reauth.clone();
        let now = super::now_unix();
        tokio::task::spawn_blocking(move || save(&places, reauth, &client_id, claims, answer, now))
            .await
            .map_err(|e| Failure::new("internal", e.to_string()))?
    }

    /// A refresh of `record`'s tokens: Codex's own refresh request (a JSON body).
    pub async fn refresh(&self, record: &Record) -> Result<TokenAnswer, Failure> {
        let (status, body) = self
            .post_json(
                &self.endpoints.token_url,
                &serde_json::json!({
                    "client_id": record.client_id,
                    "grant_type": "refresh_token",
                    "refresh_token": record.refresh_token,
                    "scope": REFRESH_SCOPES,
                }),
            )
            .await?;
        if !(200..300).contains(&status) {
            let why = error_code(&body);
            // Codex treats every 401 as a dead sign-in, and so do the codes below on a 400.
            let dead = status == 401
                || matches!(
                    why,
                    Some(
                        "invalid_grant"
                            | "refresh_token_expired"
                            | "refresh_token_reused"
                            | "refresh_token_invalidated"
                    )
                );
            let code = if dead { "reauth_required" } else { "refresh_failed" };
            return Err(Failure::new(code, format!("{status} {}", why.unwrap_or("no error code"))));
        }
        serde_json::from_value(body)
            .map_err(|_| Failure::new("refresh_failed", "the token answer has no access_token"))
    }

    /// Revokes `record`'s refresh token the way Codex does (`/oauth/revoke`, a JSON body).
    pub async fn revoke(&self, record: &Record) -> Result<(), Failure> {
        let (status, body) = self
            .post_json(
                &self.endpoints.revoke_url,
                &serde_json::json!({
                    "token": record.refresh_token,
                    "token_type_hint": "refresh_token",
                    "client_id": record.client_id,
                }),
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

/// Writes the account's record and its `chatgpt-plan` route; the route id.
pub(super) fn save(
    places: &Places,
    reauth: Option<String>,
    client_id: &str,
    claims: jwt::Claims,
    answer: TokenAnswer,
    now: i64,
) -> Result<String, Failure> {
    let storage = |e: std::io::Error| Failure::new("storage", e.to_string());
    let dir = places.routes.as_deref();
    let records = store::all(&places.home);
    let same = |r: &Record| r.client_id == client_id && r.sub == claims.sub;
    let id = records
        .iter()
        .find(|(_, r)| same(r))
        .map(|(id, _)| id.clone())
        .or_else(|| {
            // A reauth of the same person whose client id changed keeps its connection.
            reauth
                .clone()
                .filter(|id| records.iter().any(|(rid, r)| rid == id && r.sub == claims.sub))
        })
        .or_else(|| {
            // A reauth of a ChatGPT route this home holds no sign-in for takes that route (`begin`).
            reauth.filter(|id| {
                !records.iter().any(|(rid, _)| rid == id) && super::is_chatgpt_route(dir, id)
            })
        })
        .unwrap_or_else(|| {
            let taken = |id: &str| {
                records.iter().any(|(rid, _)| rid == id) || routes::find(dir, id).is_ok()
            };
            std::iter::once("chatgpt".to_owned())
                .chain((2..).map(|n| format!("chatgpt-{n}")))
                .find(|id| !taken(id))
                .unwrap_or_else(|| "chatgpt".to_owned())
        });
    let mut record = Record {
        client_id: client_id.to_owned(),
        sub: claims.sub,
        email: claims.email,
        plan: claims.plan,
        ..Record::default()
    };
    answer.apply(&mut record, now);
    store::write(&places.home, &id, &record).map_err(storage)?;
    let disabled = routes::find(dir, &id)
        .ok()
        .filter(|r| r.file.kind == RouteKind::ChatgptPlan)
        .is_some_and(|r| r.file.disabled);
    let file = RouteFile {
        name: Some(match &record.email {
            Some(email) => format!("ChatGPT ({email})"),
            None => "ChatGPT".to_owned(),
        }),
        kind: RouteKind::ChatgptPlan,
        families: vec!["codex".into()],
        anthropic_base_url: None,
        openai_base_url: Some(CODEX_BACKEND.to_owned()),
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
    routes::add(dir, &id, &file, true).map_err(|e| Failure::new("storage", e.to_string()))?;
    Ok(id)
}

/// The request target of an HTTP request line (`GET /auth/callback?... HTTP/1.1`).
async fn read_target(stream: &mut tokio::net::TcpStream) -> Option<String> {
    let mut buf = Vec::with_capacity(1024);
    let mut chunk = [0u8; 1024];
    while !buf.windows(4).any(|w| w == b"\r\n\r\n") {
        let n = stream.read(&mut chunk).await.ok()?;
        let Some(read) = chunk.get(..n).filter(|_| n != 0 && buf.len() + n <= MAX_REQUEST) else {
            break;
        };
        buf.extend_from_slice(read);
    }
    let text = std::str::from_utf8(&buf).ok()?;
    let mut line = text.lines().next()?.split(' ');
    match (line.next(), line.next()) {
        (Some("GET"), Some(target)) if target.starts_with('/') => Some(target.to_owned()),
        _ => None,
    }
}

/// A page of the loopback listener: a centered card with the outcome's mark, in light and dark.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Page {
    pub ok: bool,
    pub title: String,
    pub detail: String,
    /// The failure code, shown small under the detail.
    pub code: Option<String>,
}

impl Page {
    pub(crate) fn signed_in() -> Self {
        Self {
            ok: true,
            title: "Signed in to ChatGPT".into(),
            detail: "You can close this tab and return to cmux.".into(),
            code: None,
        }
    }

    pub(crate) fn failed(code: &str) -> Self {
        let detail = match code {
            "access_denied" => "The sign-in was cancelled. Return to cmux to try again.",
            "no_chatgpt_account" => {
                "This OpenAI account has no ChatGPT plan. Return to cmux and sign in with a ChatGPT account."
            }
            _ => "ChatGPT sign-in did not finish. Return to cmux and try again.",
        };
        Self {
            ok: false,
            title: "Couldn\u{2019}t sign in to ChatGPT".into(),
            detail: detail.into(),
            code: Some(code.to_owned()),
        }
    }

    /// A short notice (a stray or bad request) in the same frame.
    pub(crate) fn notice(text: &str) -> Self {
        Self { ok: false, title: text.into(), detail: String::new(), code: None }
    }

    pub(crate) fn html(&self) -> String {
        auth_page(self.ok, &self.title, &self.detail, self.code.as_deref())
    }
}

/// The cmux NEXT sign-in page's frame (web/app/handler: `cmux-sign-in.tsx`'s `Page` and
/// `Heading`, `auth-error/page.tsx`'s body, the "Last used" chip for the code) with the tokens of
/// web/app/globals.css, for a page a loopback listener serves with no web build behind it.
/// Keep in step with the copies in optchat-chief's `mcp_hub::oauth` and coderouter's `oauth`.
pub(crate) fn auth_page(ok: bool, title: &str, detail: &str, code: Option<&str>) -> String {
    let detail = if detail.is_empty() {
        String::new()
    } else {
        format!("<p class=\"body\">{}</p>", escape(detail))
    };
    let code = code
        .map(|c| format!("<p class=\"code\">Error code <span>{}</span></p>", escape(c)))
        .unwrap_or_default();
    format!(
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">\
<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\
<meta name=\"color-scheme\" content=\"light dark\"><meta name=\"robots\" content=\"noindex\">\
<title>{title} \u{b7} cmux</title><style>{AUTH_PAGE_CSS}</style></head>\
<body><main><section class=\"card\" data-auth-state=\"{state}\">\
<div class=\"mark\" aria-hidden=\"true\">{mark}</div><h1>{title}</h1>{detail}{code}</section></main></body></html>",
        title = escape(title),
        state = if ok { "ok" } else { "error" },
        mark = if ok { AUTH_MARK_OK } else { AUTH_MARK_ERROR },
    )
}

/// The loopback sign-in page: a centered card in the system font, with web/app/globals.css's
/// light and dark tokens, the outcome as an inline check or alert mark (no logo, no fetched
/// asset: the page renders the same offline).
pub(crate) const AUTH_PAGE_CSS: &str = "\
:root{--background:#fafafa;--foreground:#171717;--muted:#707070;--border:#e5e5e5;--card:#ffffff;\
--ok:#10a37f;--error:#d93025}\
@media (prefers-color-scheme:dark){:root{--background:#0a0a0a;--foreground:#ededed;--muted:#a3a3a3;--border:#262626;\
--card:#171717;--ok:#19c37d;--error:#f28b82}}\
*,::before,::after{box-sizing:border-box;margin:0;padding:0;border:0 solid}\
html{line-height:1.5;-webkit-text-size-adjust:100%;\
font-family:ui-sans-serif,-apple-system,BlinkMacSystemFont,\"Segoe UI\",system-ui,Helvetica,Arial,sans-serif;\
-webkit-font-smoothing:antialiased;-moz-osx-font-smoothing:grayscale}\
body{background:var(--background);color:var(--foreground)}\
main{display:flex;min-height:100vh;align-items:center;justify-content:center;padding:48px 16px}\
.card{width:100%;max-width:400px;padding:40px 32px 36px;text-align:center;background:var(--card);\
border:1px solid var(--border);border-radius:16px;box-shadow:0 1px 2px rgba(0,0,0,.04),0 8px 24px rgba(0,0,0,.06)}\
.mark{display:flex;justify-content:center;margin-bottom:20px}\
.mark svg{width:44px;height:44px}\
[data-auth-state=ok] .mark{color:var(--ok)}\
[data-auth-state=error] .mark{color:var(--error)}\
h1{font-size:22px;font-weight:600;line-height:30px;letter-spacing:-0.01em}\
.body{margin-top:8px;font-size:15px;line-height:24px;color:var(--muted)}\
.code{margin-top:20px;font-size:12px;line-height:18px;color:var(--muted)}\
.code span{margin-left:4px;padding:1px 6px;border:1px solid var(--border);border-radius:6px;\
font-family:ui-monospace,SFMono-Regular,Menlo,monospace}";

/// The success mark: a check in a circle, in the page's own color.
const AUTH_MARK_OK: &str = "<svg viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.75\" \
stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"12\" cy=\"12\" r=\"10\"/><path d=\"m7.5 12.5 3 3 6-6.5\"/></svg>";

/// The failure mark: an exclamation in a circle.
const AUTH_MARK_ERROR: &str = "<svg viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.75\" \
stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"12\" cy=\"12\" r=\"10\"/><path d=\"M12 7.5v5.5\"/><path d=\"M12 16.5h.01\"/></svg>";

fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            c => out.push(c),
        }
    }
    out
}

async fn respond(
    stream: &mut tokio::net::TcpStream,
    status: &str,
    text: &str,
) -> std::io::Result<()> {
    respond_page(stream, status, &Page::notice(text)).await
}

async fn respond_page(
    stream: &mut tokio::net::TcpStream,
    status: &str,
    page: &Page,
) -> std::io::Result<()> {
    let body = page.html();
    let head = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: {}\r\n\r\n",
        body.len()
    );
    stream.write_all(head.as_bytes()).await?;
    stream.write_all(body.as_bytes()).await?;
    stream.shutdown().await
}
