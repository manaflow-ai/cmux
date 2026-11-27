//! Sign in with ChatGPT against a local fake of the OAuth server (`Endpoints::at`).

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::routing::{get, post};
use axum::{Json, Router};
use base64::Engine as _;
use ring::rand::SystemRandom;
use ring::signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair, KeyPair as _};
use serde_json::{Value, json};

use super::oauth::{challenge, form_encode};
use super::{Endpoints, Places, Service, Status, jwt, store};
use crate::routes::{self, RouteKind};

const ACCOUNT: &str = "acct-1234";

struct Fake {
    nonce: String,
    /// Whether the ID token echoes the nonce (Codex's issuer may not).
    echo_nonce: bool,
    /// The ChatGPT account the ID token names (None: an API-only account).
    account: Option<&'static str>,
    refresh_calls: usize,
    /// A refresh's failure: its status and body.
    refresh_error: Option<(u16, Value)>,
    token_forms: Vec<HashMap<String, String>>,
    revoke_forms: Vec<HashMap<String, String>>,
    /// The content type of each token request, in order.
    token_types: Vec<String>,
}

impl Default for Fake {
    fn default() -> Self {
        Self {
            nonce: String::new(),
            echo_nonce: true,
            account: Some(ACCOUNT),
            refresh_calls: 0,
            refresh_error: None,
            token_forms: Vec::new(),
            revoke_forms: Vec::new(),
            token_types: Vec::new(),
        }
    }
}

struct Server {
    base: String,
    state: Arc<Mutex<Fake>>,
}

#[derive(Clone)]
struct App {
    base: String,
    state: Arc<Mutex<Fake>>,
    key: Arc<EcdsaKeyPair>,
}

fn b64(bytes: &[u8]) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

fn now() -> i64 {
    super::now_unix()
}

fn sign(key: &EcdsaKeyPair, claims: &Value) -> String {
    let head = b64(json!({"alg": "ES256", "kid": "k1", "typ": "JWT"}).to_string().as_bytes());
    let body = b64(claims.to_string().as_bytes());
    let message = format!("{head}.{body}");
    let sig = key.sign(&SystemRandom::new(), message.as_bytes()).expect("sign");
    format!("{message}.{}", b64(sig.as_ref()))
}

fn key_pair() -> EcdsaKeyPair {
    let rng = SystemRandom::new();
    let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).expect("key");
    EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8.as_ref(), &rng).expect("key")
}

fn jwk(key: &EcdsaKeyPair) -> Value {
    let point = key.public_key().as_ref();
    json!({"kty": "EC", "crv": "P-256", "kid": "k1", "alg": "ES256",
           "x": b64(&point[1..33]), "y": b64(&point[33..65])})
}

async fn discovery(State(app): State<App>) -> Json<Value> {
    Json(json!({
        "issuer": app.base,
        "jwks_uri": format!("{}/jwks", app.base),
        "revocation_endpoint": format!("{}/api/accounts/oauth/revoke", app.base),
    }))
}

async fn jwks(State(app): State<App>) -> Json<Value> {
    Json(json!({"keys": [jwk(&app.key)]}))
}

/// The token endpoint: a form (the code exchange) or a JSON body (Codex's refresh).
async fn token(
    State(app): State<App>,
    headers: HeaderMap,
    body: axum::body::Bytes,
) -> (StatusCode, Json<Value>) {
    let kind =
        headers.get("content-type").and_then(|v| v.to_str().ok()).unwrap_or_default().to_owned();
    let form: HashMap<String, String> = if kind.starts_with("application/json") {
        let v: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
        v.as_object()
            .map(|o| {
                o.iter()
                    .map(|(k, v)| (k.clone(), v.as_str().unwrap_or_default().to_owned()))
                    .collect()
            })
            .unwrap_or_default()
    } else {
        reqwest::Url::parse(&format!("http://x/?{}", String::from_utf8_lossy(&body)))
            .map(|u| u.query_pairs().into_owned().collect())
            .unwrap_or_default()
    };
    let grant = form.get("grant_type").cloned().unwrap_or_default();
    {
        let mut s = app.state.lock().unwrap();
        s.token_forms.push(form.clone());
        s.token_types.push(kind);
    }
    if grant == "authorization_code" {
        let (nonce, echo, account) = {
            let s = app.state.lock().unwrap();
            (s.nonce.clone(), s.echo_nonce, s.account)
        };
        let mut auth = json!({"chatgpt_plan_type": "pro"});
        if let Some(account) = account {
            auth["chatgpt_account_id"] = json!(account);
        }
        let mut claims = json!({"iss": app.base, "aud": form.get("client_id"), "exp": now() + 3600,
                                "sub": "user-1", "email": "alex@example.com",
                                "https://api.openai.com/auth": auth});
        if echo {
            claims["nonce"] = json!(nonce);
        }
        let id_token = sign(&app.key, &claims);
        return (
            StatusCode::OK,
            Json(json!({"access_token": "access-0", "refresh_token": "refresh-0",
                        "id_token": id_token, "expires_in": 3600,
                        "scope": "openid profile email offline_access", "token_type": "Bearer"})),
        );
    }
    let failure = app.state.lock().unwrap().refresh_error.clone();
    if let Some((status, body)) = failure {
        return (StatusCode::from_u16(status).unwrap(), Json(body));
    }
    // Slow enough that concurrent callers overlap with it.
    tokio::time::sleep(Duration::from_millis(200)).await;
    let n = {
        let mut s = app.state.lock().unwrap();
        s.refresh_calls += 1;
        s.refresh_calls
    };
    (
        StatusCode::OK,
        Json(
            json!({"access_token": format!("access-r{n}"), "refresh_token": format!("refresh-r{n}"),
                    "expires_in": 1800, "scope": "openid profile email"}),
        ),
    )
}

/// Codex's revocation: a JSON body.
async fn revoke(State(app): State<App>, Json(body): Json<Value>) -> StatusCode {
    let form = body
        .as_object()
        .map(|o| {
            o.iter().map(|(k, v)| (k.clone(), v.as_str().unwrap_or_default().to_owned())).collect()
        })
        .unwrap_or_default();
    app.state.lock().unwrap().revoke_forms.push(form);
    StatusCode::OK
}

async fn server() -> Server {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let base = format!("http://127.0.0.1:{}", listener.local_addr().expect("addr").port());
    let state = Arc::new(Mutex::new(Fake::default()));
    let app = App { base: base.clone(), state: state.clone(), key: Arc::new(key_pair()) };
    let router = Router::new()
        .route("/.well-known/openid-configuration", get(discovery))
        .route("/jwks", get(jwks))
        .route("/oauth/token", post(token))
        .route("/oauth/revoke", post(revoke))
        .with_state(app);
    tokio::spawn(async move {
        let _ = axum::serve(listener, router).await;
    });
    Server { base, state }
}

struct Setup {
    _root: tempfile::TempDir,
    places: Places,
    service: Arc<Service>,
    fake: Server,
}

async fn setup() -> Setup {
    // The test's own callback requests (`reqwest::get`) need the process's TLS provider.
    let _ = rustls::crypto::ring::default_provider().install_default();
    let root = tempfile::tempdir().expect("tempdir");
    let places =
        Places { routes: Some(root.path().join("routes")), home: root.path().join("home") };
    let fake = server().await;
    // Any free port: the real one is Codex's registered 1455.
    let endpoints = Endpoints { callback_port: 0, ..Endpoints::at(&fake.base) };
    let service = Arc::new(Service::new(endpoints));
    Setup { _root: root, places, service, fake }
}

fn query(url: &str) -> HashMap<String, String> {
    reqwest::Url::parse(url).expect("url").query_pairs().into_owned().collect()
}

/// Begins a sign-in, then calls its callback with `extra` (and the right state unless `extra`
/// names one), and waits for the attempt.
async fn sign_in(s: &Setup, extra: &[(&str, &str)]) -> (Status, HashMap<String, String>) {
    sign_in_again(s, None, extra).await
}

/// [`sign_in`] that signs in again on the route `reauth`.
async fn sign_in_again(
    s: &Setup,
    reauth: Option<&str>,
    extra: &[(&str, &str)],
) -> (Status, HashMap<String, String>) {
    let begun =
        s.service.begin(s.places.clone(), reauth.map(str::to_owned), |_| {}).await.expect("begin");
    let params = query(&begun.url);
    s.fake.state.lock().unwrap().nonce = params["nonce"].clone();
    let mut pairs: Vec<(&str, &str)> = extra.to_vec();
    if !extra.iter().any(|(k, _)| *k == "state") {
        pairs.push(("state", params["state"].as_str()));
    }
    let callback = format!("{}?{}", params["redirect_uri"], form_encode(&pairs));
    let page = reqwest::get(&callback).await.expect("callback");
    assert_eq!(page.status(), 200);
    let html = page.text().await.expect("page");
    // The loopback listener answers the cmux page (mark, card), not plain text.
    assert!(html.contains("data-auth-state=") && html.contains("--background:#fafafa"), "{html}");
    let status = s.service.wait(&begun.attempt, Duration::from_secs(10)).await.expect("wait");
    if let Ok(dir) = std::env::var("CHATGPT_CALLBACK_PAGE_DUMP") {
        let kind = if html.contains("data-auth-state=\"ok\"") { "live-ok" } else { "live-err" };
        std::fs::write(format!("{dir}/{kind}.html"), &html).unwrap();
    }
    (status, params)
}

#[test]
fn production_signs_in_with_codex_s_own_client() {
    let e = Endpoints::openai();
    assert_eq!(e.client_id, "app_EMoamEEZ73f0CkXaXp7hrann");
    assert_eq!(e.callback_port, 1455);
    assert_eq!(e.authorize_url, "https://auth.openai.com/oauth/authorize");
    assert_eq!(e.token_url, "https://auth.openai.com/oauth/token");
    assert_eq!(e.revoke_url, "https://auth.openai.com/oauth/revoke");
}

/// cmux#45774: Sign in with ChatGPT is Codex's own sign-in, so its token runs Codex on the
/// ChatGPT Codex backend (the token-sharing protocol's token was refused for most accounts).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn sign_in_with_chatgpt_is_codex_s_own_sign_in() {
    let s = setup().await;
    let (status, params) = sign_in(&s, &[("code", "c1")]).await;
    assert_eq!(status, Status::Done("chatgpt".into()));
    assert_eq!(params["client_id"], super::CODEX_CLIENT_ID);
    assert_eq!(params["response_type"], "code");
    assert_eq!(params["scope"], super::SCOPES);
    assert_eq!(params["code_challenge_method"], "S256");
    assert_eq!(params["id_token_add_organizations"], "true");
    assert_eq!(params["codex_cli_simplified_flow"], "true");
    assert_eq!(params["originator"], "codex_cli_rs");
    for gone in ["resource", "ext_agent_host_id", "agent_name_hint"] {
        assert!(!params.contains_key(gone), "{gone} is the token-sharing protocol's");
    }
    assert!(params["redirect_uri"].starts_with("http://127.0.0.1:"), "the address it listens on");
    assert!(params["redirect_uri"].ends_with("/auth/callback"));

    let forms = s.fake.state.lock().unwrap().token_forms.clone();
    let exchange = &forms[0];
    assert_eq!(exchange["grant_type"], "authorization_code");
    assert_eq!(exchange["client_id"], super::CODEX_CLIENT_ID);
    assert_eq!(exchange["code"], "c1");
    assert_eq!(exchange["redirect_uri"], params["redirect_uri"]);
    assert!(!exchange.contains_key("resource"));
    assert_eq!(challenge(&exchange["code_verifier"]), params["code_challenge"]);

    let record = store::read(&s.places.home, "chatgpt").unwrap().expect("record");
    assert_eq!(record.client_id, super::CODEX_CLIENT_ID);
    assert!(record.signed_in());
    assert_eq!(record.sub, "user-1");
    assert_eq!(record.email.as_deref(), Some("alex@example.com"));
    assert_eq!(record.plan.as_deref(), Some("pro"));
    assert_eq!(record.refresh_token, "refresh-0");
    assert!(!store::dir(&s.places.home).join("host.json").exists(), "no registration kept");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(store::dir(&s.places.home).join("chatgpt.json"))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o600, "the record is owner-only");
    }
    let route = routes::find(s.places.routes.as_deref(), "chatgpt").expect("route");
    assert_eq!(route.file.kind, RouteKind::ChatgptPlan);
    assert_eq!(route.file.families, vec!["codex".to_owned()]);
    assert_eq!(route.file.openai_base_url.as_deref(), Some(super::CODEX_BACKEND));
    assert_eq!(route.file.name.as_deref(), Some("ChatGPT (alex@example.com)"));

    // A later sign-in of the same person keeps one record.
    let (status, _) = sign_in(&s, &[("code", "c2")]).await;
    assert_eq!(status, Status::Done("chatgpt".into()));
    assert_eq!(store::all(&s.places.home).len(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_id_token_without_the_nonce_is_taken_one_with_another_is_not() {
    let s = setup().await;
    s.fake.state.lock().unwrap().echo_nonce = false;
    let (status, _) = sign_in(&s, &[("code", "c1")]).await;
    assert_eq!(status, Status::Done("chatgpt".into()), "PKCE and state carry the sign-in");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_sign_in_with_no_chatgpt_account_stores_nothing() {
    let s = setup().await;
    s.fake.state.lock().unwrap().account = None;
    let (status, _) = sign_in(&s, &[("code", "c1")]).await;
    assert_eq!(status, Status::Failed("no_chatgpt_account".into()));
    assert!(store::all(&s.places.home).is_empty(), "nothing stored");
    assert!(routes::find(s.places.routes.as_deref(), "chatgpt").is_err());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_stray_callback_is_turned_away_and_the_sign_in_goes_on() {
    let s = setup().await;
    let begun = s.service.begin(s.places.clone(), None, |_| {}).await.expect("begin");
    let params = query(&begun.url);
    s.fake.state.lock().unwrap().nonce = params["nonce"].clone();
    // A stale tab or a page that navigates to the well-known port: 400, no exchange, still waiting.
    let forged = format!(
        "{}?{}",
        params["redirect_uri"],
        form_encode(&[("code", "x"), ("state", "forged")])
    );
    assert_eq!(reqwest::get(&forged).await.unwrap().status(), 400);
    assert!(s.fake.state.lock().unwrap().token_forms.is_empty());
    let status = s.service.wait(&begun.attempt, Duration::from_millis(50)).await.unwrap();
    assert_eq!(status, Status::Pending);
    // This sign-in's own callback still finishes it.
    let real = format!(
        "{}?{}",
        params["redirect_uri"],
        form_encode(&[("code", "c1"), ("state", params["state"].as_str())])
    );
    assert_eq!(reqwest::get(&real).await.unwrap().status(), 200);
    let status = s.service.wait(&begun.attempt, Duration::from_secs(10)).await.unwrap();
    assert_eq!(status, Status::Done("chatgpt".into()));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn codex_login_s_cancel_ends_the_sign_in_and_frees_the_port() {
    let s = setup().await;
    let begun = s.service.begin(s.places.clone(), None, |_| {}).await.expect("begin");
    let redirect = reqwest::Url::parse(&query(&begun.url)["redirect_uri"]).unwrap();
    let cancel = format!("http://127.0.0.1:{}/cancel", redirect.port().unwrap());
    assert_eq!(reqwest::get(&cancel).await.unwrap().status(), 200);
    let status = s.service.wait(&begun.attempt, Duration::from_secs(10)).await.unwrap();
    assert_eq!(status, Status::Failed("cancelled".into()));
    assert!(store::all(&s.places.home).is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn access_denied_stops_the_sign_in() {
    let s = setup().await;
    let (status, _) = sign_in(&s, &[("error", "access_denied")]).await;
    assert_eq!(status, Status::Failed("access_denied".into()));
    assert!(s.fake.state.lock().unwrap().token_forms.is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_new_sign_in_ends_the_pending_one_on_the_shared_port() {
    let s = setup().await;
    let first = s.service.begin(s.places.clone(), None, |_| {}).await.unwrap();
    let second = s.service.begin(s.places.clone(), None, |_| {}).await.unwrap();
    let status = s.service.wait(&first.attempt, Duration::from_millis(50)).await.unwrap();
    assert_eq!(status, Status::Cancelled);
    let status = s.service.wait(&second.attempt, Duration::from_millis(50)).await.unwrap();
    assert_eq!(status, Status::Pending);
}

fn expire(s: &Setup) {
    let mut record = store::read(&s.places.home, "chatgpt").unwrap().unwrap();
    record.expires_at = now() + 60;
    store::write(&s.places.home, "chatgpt", &record).unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_refresh_is_codex_s_json_request_and_replaces_the_tokens_together() {
    let s = setup().await;
    sign_in(&s, &[("code", "c1")]).await;
    // An hour left: handed out as it is.
    let (token, _) = s.service.token(&s.places.home, "chatgpt").await.unwrap();
    assert_eq!(token, "access-0");
    assert_eq!(s.fake.state.lock().unwrap().refresh_calls, 0);
    expire(&s);
    let (token, expires_at) = s.service.token(&s.places.home, "chatgpt").await.unwrap();
    assert_eq!(token, "access-r1");
    assert!((expires_at - (now() + 1800)).abs() < 30);
    let record = store::read(&s.places.home, "chatgpt").unwrap().unwrap();
    assert_eq!(record.access_token, "access-r1");
    assert_eq!(record.refresh_token, "refresh-r1", "the rotated refresh token is kept");
    assert_eq!(record.expires_at, expires_at);
    let (forms, types) = {
        let st = s.fake.state.lock().unwrap();
        (st.token_forms.clone(), st.token_types.clone())
    };
    let refresh = forms.last().unwrap();
    assert!(types.last().unwrap().starts_with("application/json"));
    assert_eq!(refresh["grant_type"], "refresh_token");
    assert_eq!(refresh["refresh_token"], "refresh-0");
    assert_eq!(refresh["client_id"], super::CODEX_CLIENT_ID);
    assert_eq!(refresh["scope"], super::REFRESH_SCOPES);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn concurrent_token_calls_share_one_refresh() {
    let s = setup().await;
    sign_in(&s, &[("code", "c1")]).await;
    expire(&s);
    let calls = (0..8).map(|_| {
        let service = s.service.clone();
        let home = s.places.home.clone();
        tokio::spawn(async move { service.token(&home, "chatgpt").await })
    });
    let tokens: Vec<String> =
        futures::future::join_all(calls).await.into_iter().map(|r| r.unwrap().unwrap().0).collect();
    assert_eq!(s.fake.state.lock().unwrap().refresh_calls, 1, "one refresh in flight");
    assert!(tokens.iter().all(|t| t == "access-r1"), "{tokens:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_dead_refresh_token_signs_the_account_out() {
    // The shapes the real server answers (Codex's own tests model 401 with `error.code`), and any
    // 401: each signs the account out so the person is asked to sign in again.
    for (status, body) in [
        (401, json!({"error": {"code": "refresh_token_expired"}})),
        (401, json!({"error": {"code": "refresh_token_reused"}})),
        (401, json!({"error": "something_new"})),
        (400, json!({"error": "invalid_grant"})),
        (400, json!({"code": "refresh_token_invalidated"})),
    ] {
        let s = setup().await;
        sign_in(&s, &[("code", "c1")]).await;
        expire(&s);
        s.fake.state.lock().unwrap().refresh_error = Some((status, body.clone()));
        let failure = s.service.token(&s.places.home, "chatgpt").await.unwrap_err();
        assert_eq!(failure.code, "reauth_required", "{status} {body}");
        let record = store::read(&s.places.home, "chatgpt").unwrap().unwrap();
        assert!(!record.signed_in());
        assert_eq!(record.sub, "user-1", "the identity stays for a reauth");
    }
    // A passing server error keeps the sign-in.
    let s = setup().await;
    sign_in(&s, &[("code", "c1")]).await;
    expire(&s);
    s.fake.state.lock().unwrap().refresh_error = Some((503, json!({"error": "unavailable"})));
    let failure = s.service.token(&s.places.home, "chatgpt").await.unwrap_err();
    assert_eq!(failure.code, "refresh_failed");
    assert!(store::read(&s.places.home, "chatgpt").unwrap().unwrap().signed_in());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn remove_revokes_the_refresh_token() {
    let s = setup().await;
    sign_in(&s, &[("code", "c1")]).await;
    assert!(s.service.remove(&s.places.home, "chatgpt").await.unwrap());
    let revoked = s.fake.state.lock().unwrap().revoke_forms.clone();
    assert_eq!(revoked[0]["token"], "refresh-0");
    assert_eq!(revoked[0]["token_type_hint"], "refresh_token");
    assert_eq!(revoked[0]["client_id"], super::CODEX_CLIENT_ID);
    assert!(store::read(&s.places.home, "chatgpt").unwrap().is_none());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_cancelled_sign_in_closes_its_listener() {
    let s = setup().await;
    let begun = s.service.begin(s.places.clone(), None, |_| {}).await.unwrap();
    assert_eq!(s.service.cancel(&begun.attempt).await.unwrap(), Status::Cancelled);
    let status = s.service.wait(&begun.attempt, Duration::from_millis(50)).await.unwrap();
    assert_eq!(status, Status::Cancelled);
    let redirect = query(&begun.url)["redirect_uri"].clone();
    let port = reqwest::Url::parse(&redirect).unwrap().port().unwrap();
    // A child another test spawns holds a copy of the dropped listener between its fork and
    // exec, so a connect can still land for that moment: the listener is closed once a connect
    // is refused, within a bound no fork-to-exec window reaches.
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while tokio::net::TcpStream::connect(("127.0.0.1", port)).await.is_ok() {
        assert!(std::time::Instant::now() < deadline, "the listener is closed");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

#[test]
fn id_tokens_are_checked_for_issuer_audience_expiry_nonce_and_signature() {
    let key = key_pair();
    let keys = vec![jwk(&key)];
    let good = json!({"iss": "https://auth.example", "aud": "oaiapp_a", "exp": now() + 600,
                      "nonce": "n1", "sub": "user-1"});
    let token = sign(&key, &good);
    let ok = jwt::verify(&token, &keys, "https://auth.example", "oaiapp_a", Some("n1"), now());
    assert_eq!(ok.map(|c| c.sub), Ok("user-1".to_owned()));
    let check = |claims: Value| {
        jwt::verify(
            &sign(&key, &claims),
            &keys,
            "https://auth.example",
            "oaiapp_a",
            Some("n1"),
            now(),
        )
    };
    let with = |k: &str, v: Value| {
        let mut c = good.clone();
        c[k] = v;
        c
    };
    assert_eq!(check(with("iss", json!("https://evil.example"))), Err(jwt::Invalid::Issuer));
    assert_eq!(check(with("aud", json!("oaiapp_b"))), Err(jwt::Invalid::Audience));
    assert!(check(with("aud", json!(["x", "oaiapp_a"]))).is_ok());
    assert_eq!(check(with("exp", json!(now() - 3600))), Err(jwt::Invalid::Expired));
    assert_eq!(check(with("nonce", json!("n2"))), Err(jwt::Invalid::Nonce));
    // No nonce in the token: taken (Codex's issuer may not echo it); PKCE and state carry it.
    let mut bare = good.clone();
    bare.as_object_mut().unwrap().remove("nonce");
    assert!(check(bare).is_ok());
    let other = key_pair();
    assert_eq!(
        jwt::verify(
            &sign(&other, &good),
            &keys,
            "https://auth.example",
            "oaiapp_a",
            Some("n1"),
            now()
        ),
        Err(jwt::Invalid::Signature)
    );
    let mut tampered: Vec<&str> = token.split('.').collect();
    let forged = b64(with("sub", json!("user-2")).to_string().as_bytes());
    tampered[1] = &forged;
    assert_eq!(
        jwt::verify(
            &tampered.join("."),
            &keys,
            "https://auth.example",
            "oaiapp_a",
            Some("n1"),
            now()
        ),
        Err(jwt::Invalid::Signature)
    );
    assert_eq!(
        jwt::verify(&token, &[], "https://auth.example", "oaiapp_a", Some("n1"), now()),
        Err(jwt::Invalid::UnknownKey)
    );
}

#[test]
fn form_encoding_escapes_reserved_bytes() {
    assert_eq!(form_encode(&[("a b", "x&y=z/é"), ("k", "v")]), "a+b=x%26y%3Dz%2F%C3%A9&k=v");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_machine_credential_is_refreshed_to_ten_minutes_left() {
    let s = setup().await;
    sign_in(&s, &[("code", "c1")]).await;
    let mut record = store::read(&s.places.home, "chatgpt").unwrap().unwrap();
    record.expires_at = now() + 8 * 60;
    store::write(&s.places.home, "chatgpt", &record).unwrap();
    // Eight minutes left is enough for the gateway's 5-minute margin ...
    let (token, _) = s.service.token(&s.places.home, "chatgpt").await.unwrap();
    assert_eq!(token, "access-0");
    // ... but a machine launch needs ten.
    let (token, expires_at) = s
        .service
        .token_lasting(&s.places.home, "chatgpt", super::CREDENTIAL_MARGIN_SECS)
        .await
        .unwrap();
    assert_eq!(token, "access-r1");
    assert!(expires_at - now() >= super::CREDENTIAL_MARGIN_SECS);
}

/// A `chatgpt-plan` route this acpmux home holds no sign-in for (the route folder is shared by every
/// cmux on the Mac; another build, or the retired token-sharing client, wrote it): the row reads
/// signed out, and its Sign In signs in on that same route instead of failing `not_found` (cmux#45774).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn signing_in_again_on_a_route_with_no_sign_in_here_takes_that_route() {
    let s = setup().await;
    let dir = s.places.routes.as_deref();
    let mut stale = crate::routes::RouteFile {
        name: Some("ChatGPT plan (alex@example.com)".into()),
        kind: RouteKind::ChatgptPlan,
        families: vec!["codex".into()],
        anthropic_base_url: None,
        openai_base_url: Some("https://api.openai.com/v1".into()),
        auth: None,
        secret: None,
        headers: Default::default(),
        health_url: None,
        fallback: vec![],
        auto_fallback: false,
        notes: None,
        account_home: None,
        shadow_of: None,
        disabled: false,
        provider: Some("openai".into()),
    };
    routes::add(dir, "chatgpt", &stale, true).expect("route");

    let (status, _) = sign_in_again(&s, Some("chatgpt"), &[("code", "c1")]).await;
    assert_eq!(status, Status::Done("chatgpt".into()), "the same route, not a second one");
    let record = store::read(&s.places.home, "chatgpt").unwrap().expect("record");
    assert!(record.signed_in());
    let route = routes::find(dir, "chatgpt").expect("route");
    assert_eq!(route.file.openai_base_url.as_deref(), Some(super::CODEX_BACKEND));
    assert!(routes::find(dir, "chatgpt-2").is_err(), "no duplicate connection");

    // A route that is not a ChatGPT sign-in, or none at all, is still not one to sign in again.
    stale.kind = RouteKind::DirectSubscription;
    routes::add(dir, "other", &stale, true).expect("route");
    for id in ["other", "nope"] {
        let failure = s.service.begin(s.places.clone(), Some(id.into()), |_| {}).await.err();
        assert_eq!(failure.map(|f| f.code), Some("not_found".into()), "{id}");
    }
}

#[test]
fn callback_pages_use_the_cmux_sign_in_page_styles() {
    use super::oauth::{AUTH_PAGE_CSS, Page};
    let ok = Page::signed_in().html();
    assert!(ok.contains("<h1>Signed in to ChatGPT</h1>"));
    assert!(ok.contains("You can close this tab and return to cmux."));
    assert!(ok.contains("class=\"card\"") && ok.contains("<svg"));
    // Self-contained: no fetched font, script or image.
    assert!(!ok.contains("@import") && !ok.contains("<script") && !ok.contains("http"), "{ok}");
    assert!(ok.contains("data-auth-state=\"ok\""));
    let err = Page::failed("access_denied").html();
    assert!(err.contains("data-auth-state=\"error\""));
    assert!(err.contains("<h1>Couldn\u{2019}t sign in to ChatGPT</h1>"));
    assert!(err.contains("<p class=\"code\">Error code <span>access_denied</span></p>"));
    assert!(err.contains("cancelled"));
    // A code never injects markup.
    let odd = Page::failed("<script>").html();
    assert!(!odd.contains("<script>"));
    assert!(odd.contains("&lt;script&gt;"));
    // The colors are the web sign-in page's own (web/app/globals.css), light and dark.
    let globals = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../web/app/globals.css"
    ))
    .expect("web/app/globals.css");
    let token = |block: &str, name: &str| -> String {
        let start = globals.find(block).expect(block);
        let rest = &globals[start..];
        let at = rest.find(&format!("--{name}:")).expect(name);
        rest[at..].split(';').next().unwrap().replace(' ', "")
    };
    let (light, dark) = AUTH_PAGE_CSS.split_once("@media").unwrap();
    for name in ["background", "foreground", "muted", "border"] {
        assert!(light.contains(&token(":root {", name)), "light {name}");
        assert!(dark.contains(&token(".dark {", name)), "dark {name}");
    }
    // The other loopback sign-in pages of cmux NEXT carry the same styles.
    let css_of = |text: &str| -> String {
        let start = text.find("const AUTH_PAGE_CSS: &str = ").expect("AUTH_PAGE_CSS");
        let rest = &text[start..];
        rest[..rest.find("\";").unwrap()].to_owned()
    };
    let own = css_of(include_str!("oauth.rs"));
    let other = "Native/OptChat/optchat-chief/src/mcp_hub/oauth.rs";
    let path = format!("{}/../../../{other}", env!("CARGO_MANIFEST_DIR"));
    let text = std::fs::read_to_string(&path).expect(other);
    assert_eq!(css_of(&text), own, "{other} drifted from the sign-in page styles");
    if let Ok(dir) = std::env::var("CHATGPT_CALLBACK_PAGE_DUMP") {
        std::fs::write(format!("{dir}/success.html"), ok).unwrap();
        std::fs::write(format!("{dir}/error.html"), err).unwrap();
    }
}
