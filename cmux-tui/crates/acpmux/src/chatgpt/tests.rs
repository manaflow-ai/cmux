//! Sign in with ChatGPT against a local fake of the OAuth server (`Endpoints::at`).

use std::collections::{HashMap, VecDeque};
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
    device_replies: VecDeque<(StatusCode, Value)>,
    device_polls: Vec<tokio::time::Instant>,
    refresh_gate: Option<Arc<Gate>>,
    revoke_gate: Option<Arc<Gate>>,
    device_poll_gate: Option<Arc<Gate>>,
}

#[derive(Default)]
struct Gate {
    entered: tokio::sync::Notify,
    release: tokio::sync::Notify,
}

#[derive(Clone, Default)]
struct Traces(Arc<Mutex<Vec<u8>>>);

impl std::io::Write for Traces {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Gate {
    async fn hold(&self) {
        self.entered.notify_one();
        self.release.notified().await;
    }
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
            device_replies: VecDeque::new(),
            device_polls: Vec::new(),
            refresh_gate: None,
            revoke_gate: None,
            device_poll_gate: None,
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

async fn user_code(Json(body): Json<Value>) -> (StatusCode, Json<Value>) {
    assert!(body == json!({"client_id": super::CODEX_CLIENT_ID}));
    (
        StatusCode::OK,
        Json(json!({
            "device_auth_id": "mock-device-id", "usercode": "MOCK-1234", "interval": "1",
        })),
    )
}

async fn device_poll(State(app): State<App>, Json(body): Json<Value>) -> (StatusCode, Json<Value>) {
    assert!(body == json!({"device_auth_id": "mock-device-id", "user_code": "MOCK-1234"}));
    let (gate, (status, body)) = {
        let mut state = app.state.lock().unwrap();
        state.device_polls.push(tokio::time::Instant::now());
        (
            state.device_poll_gate.clone(),
            state.device_replies.pop_front().unwrap_or((StatusCode::FORBIDDEN, Value::Null)),
        )
    };
    if let Some(gate) = gate {
        gate.hold().await;
    }
    (status, Json(body))
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
    let (gate, failure) = {
        let state = app.state.lock().unwrap();
        (state.refresh_gate.clone(), state.refresh_error.clone())
    };
    if let Some(gate) = gate {
        gate.hold().await;
    }
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
    let gate = {
        let mut fake = app.state.lock().unwrap();
        fake.revoke_forms.push(form);
        fake.revoke_gate.take()
    };
    if let Some(gate) = gate {
        gate.hold().await;
    }
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
        .route("/api/accounts/deviceauth/usercode", post(user_code))
        .route("/api/accounts/deviceauth/token", post(device_poll))
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

fn device_approved() -> (StatusCode, Value) {
    (
        StatusCode::OK,
        json!({
            "authorization_code": "mock-authorization",
            "code_challenge": challenge("mock-verifier"),
            "code_verifier": "mock-verifier",
        }),
    )
}

#[tokio::test]
async fn chatgpt_device_waits_backs_off_and_uses_the_browser_store() {
    let traces = Traces::default();
    let writer = traces.clone();
    let _subscriber = tracing::subscriber::set_default(
        tracing_subscriber::fmt()
            .with_max_level(tracing::Level::TRACE)
            .with_writer(move || writer.clone())
            .finish(),
    );
    let s = setup().await;
    s.fake.state.lock().unwrap().device_replies = VecDeque::from([
        (StatusCode::FORBIDDEN, Value::Null),
        (StatusCode::TOO_MANY_REQUESTS, json!({"error": "slow_down"})),
        device_approved(),
        device_approved(),
    ]);
    let begun = s.service.begin_device(s.places.clone(), None, |_| {}).await.ok().expect("begin");
    assert!(begun.user_code == "MOCK-1234");
    assert_eq!(begun.verification_url, format!("{}/codex/device", s.fake.base));
    assert_eq!(begun.interval, 1);
    assert!((now() + 895..=now() + 900).contains(&begun.expires_at));
    assert_eq!(
        s.service.wait_device(&begun.attempt, Duration::ZERO).await.unwrap(),
        Status::Pending
    );
    // Browser callers cannot wait on, or cancel, a device attempt even with its id.
    assert!(s.service.wait(&begun.attempt, Duration::ZERO).await.is_err());
    assert!(s.service.cancel(&begun.attempt).await.is_err());
    let outcome = s.service.wait_device(&begun.attempt, Duration::from_secs(20)).await.unwrap();
    let Status::Done(id) = outcome else { panic!("device sign-in failed: {outcome:?}") };
    {
        let fake = s.fake.state.lock().unwrap();
        assert_eq!(fake.device_polls.len(), 3);
        assert!(fake.device_polls[1] - fake.device_polls[0] >= Duration::from_secs(1));
        assert!(fake.device_polls[2] - fake.device_polls[1] >= Duration::from_secs(6));
        let form = fake.token_forms.last().expect("exchange form");
        assert_eq!(form["grant_type"], "authorization_code");
        assert_eq!(form["redirect_uri"], format!("{}/deviceauth/callback", s.fake.base));
        assert!(form["code"] == "mock-authorization" && form["code_verifier"] == "mock-verifier");
    }
    let device = store::read(&s.places.home, &id).unwrap().expect("stored sign-in");
    let browser = setup().await;
    let (status, _) = sign_in(&browser, &[("code", "mock-browser-code")]).await;
    assert_eq!(status, Status::Done(id.clone()));
    let browser_record = store::read(&browser.places.home, &id).unwrap().expect("stored sign-in");
    assert!(device.access_token == browser_record.access_token);
    assert!(device.refresh_token == browser_record.refresh_token);
    assert_eq!(device.client_id, browser_record.client_id);
    assert_eq!(device.email, browser_record.email);
    assert_eq!(
        routes::find(s.places.routes.as_deref(), &id).unwrap().file.kind,
        RouteKind::ChatgptPlan
    );
    let repeat = s.service.begin_device(s.places.clone(), None, |_| {}).await.ok().expect("begin");
    assert_eq!(
        s.service.wait_device(&repeat.attempt, Duration::from_secs(5)).await.unwrap(),
        Status::Failed("already_signed_in".into())
    );
    let debug = format!("{device:?}");
    let traces = traces.0.lock().unwrap();
    let logged = String::from_utf8_lossy(&traces);
    for secret in [
        "MOCK-1234",
        "mock-device-id",
        "mock-authorization",
        "mock-verifier",
        "access-0",
        "refresh-0",
    ] {
        assert!(!logged.contains(secret) && !debug.contains(secret));
    }
}

#[tokio::test]
async fn chatgpt_device_denied_and_expired_replies_are_sanitized() {
    let s = setup().await;
    for (response, expected) in
        [("authorization_declined", "access_denied"), ("expired_token", "expired_token")]
    {
        s.fake.state.lock().unwrap().device_replies.push_back((
            StatusCode::UNAUTHORIZED,
            json!({"error": response, "error_description": "mock-authorization"}),
        ));
        let begun =
            s.service.begin_device(s.places.clone(), None, |_| {}).await.ok().expect("begin");
        assert_eq!(
            s.service.wait_device(&begun.attempt, Duration::from_secs(5)).await.unwrap(),
            Status::Failed(expected.into())
        );
    }
    assert!(store::all(&s.places.home).is_empty());
}

#[tokio::test]
async fn chatgpt_device_cancel_and_deadline_stop_polling() {
    let s = setup().await;
    let begun = s.service.begin_device(s.places.clone(), None, |_| {}).await.ok().expect("begin");
    assert_eq!(s.service.cancel_device(&begun.attempt).await.unwrap(), Status::Cancelled);
    assert_eq!(
        s.service.wait_device(&begun.attempt, Duration::ZERO).await.unwrap(),
        Status::Cancelled
    );
    let begun = s.service.begin_device(s.places.clone(), None, |_| {}).await.ok().expect("begin");
    tokio::time::pause();
    tokio::time::advance(super::ATTEMPT_TTL).await;
    assert_eq!(
        s.service.wait_device(&begun.attempt, Duration::from_secs(1)).await.unwrap(),
        Status::Failed("expired_token".into())
    );
    assert!(s.fake.state.lock().unwrap().device_polls.is_empty());
    assert!(store::all(&s.places.home).is_empty());
}

#[tokio::test]
async fn chatgpt_device_cancel_discards_an_in_flight_approval() {
    let s = setup().await;
    let gate = Arc::new(Gate::default());
    {
        let mut fake = s.fake.state.lock().unwrap();
        fake.device_poll_gate = Some(gate.clone());
        fake.device_replies.push_back(device_approved());
    }
    let begun = s.service.begin_device(s.places.clone(), None, |_| {}).await.ok().expect("begin");
    tokio::time::timeout(Duration::from_secs(5), gate.entered.notified())
        .await
        .expect("poll entered");
    assert_eq!(s.service.cancel_device(&begun.attempt).await.unwrap(), Status::Cancelled);
    gate.release.notify_one();
    assert!(s.fake.state.lock().unwrap().token_forms.is_empty());
    assert!(store::all(&s.places.home).is_empty());
}

#[tokio::test]
async fn chatgpt_device_reauth_wins_over_a_stale_refresh_failure() {
    let s = setup().await;
    let (status, _) = sign_in(&s, &[("code", "mock-browser-code")]).await;
    let Status::Done(id) = status else { panic!("browser sign-in failed: {status:?}") };
    let mut initial = store::read(&s.places.home, &id).unwrap().expect("stored sign-in");
    initial.expires_at = 0;
    store::write(&s.places.home, &id, &initial).unwrap();
    let gate = Arc::new(Gate::default());
    {
        let mut fake = s.fake.state.lock().unwrap();
        fake.refresh_gate = Some(gate.clone());
        fake.refresh_error = Some((401, json!({"error": "invalid_grant"})));
        fake.device_replies.push_back(device_approved());
    }
    let (service, home, route) = (s.service.clone(), s.places.home.clone(), id.clone());
    let refresh = tokio::spawn(async move { service.token(&home, &route).await });
    tokio::time::timeout(Duration::from_secs(5), gate.entered.notified())
        .await
        .expect("refresh entered");
    let begun = s
        .service
        .begin_device(s.places.clone(), Some(id.clone()), |_| {})
        .await
        .ok()
        .expect("begin");
    assert_eq!(
        s.service.wait_device(&begun.attempt, Duration::from_secs(5)).await.unwrap(),
        Status::Done(id.clone())
    );
    gate.release.notify_one();
    let (_, expiry) = refresh.await.unwrap().expect("the new sign-in wins");
    let current = store::read(&s.places.home, &id).unwrap().expect("stored sign-in");
    assert!(current.signed_in());
    assert_eq!(current.expires_at, expiry);
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
    assert!(
        s.service
            .token(&s.places.home, "chatgpt")
            .await
            .is_ok_and(|(token, _)| token == "access-0")
    );
    assert!(store::read(&s.places.home, "chatgpt").unwrap().unwrap().signed_in());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn remove_revokes_the_refresh_token() {
    let s = setup().await;
    sign_in(&s, &[("code", "c1")]).await;
    let route = routes::find(s.places.routes.as_deref(), "chatgpt").unwrap();
    let instance = route.file.credential_instance.as_deref().unwrap();
    assert!(s.service.remove(&s.places, "chatgpt", instance).await.unwrap());
    let revoked = s.fake.state.lock().unwrap().revoke_forms.clone();
    assert_eq!(revoked[0]["token"], "refresh-0");
    assert_eq!(revoked[0]["token_type_hint"], "refresh_token");
    assert_eq!(revoked[0]["client_id"], super::CODEX_CLIENT_ID);
    assert!(store::read(&s.places.home, "chatgpt").unwrap().is_none());
    assert!(routes::find(s.places.routes.as_deref(), "chatgpt").is_err());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn older_account_toggle_preserves_chatgpt_redelivery_and_disconnect() {
    for comment_only in [false, true] {
        let s = setup().await;
        let id = "chatgpt";
        assert_eq!(sign_in(&s, &[("code", "c1")]).await.0, Status::Done(id.into()));
        let dir = s.places.routes.as_deref();
        let original = routes::find(dir, id).unwrap();
        let instance = original.file.credential_instance.as_deref().unwrap();
        if comment_only {
            let text = toml::to_string_pretty(&original.file).unwrap();
            std::fs::write(
                &original.path,
                crate::agent_credentials::with_stored_instance(&text, instance),
            )
            .unwrap();
        }
        let delivered = routes::for_credential(dir, id).unwrap();
        assert_eq!(delivered.file.credential_instance.as_deref(), Some(instance));

        for disabled in [true, false] {
            // The older account writer preserves TOML fields and drops comments.
            let text = std::fs::read_to_string(&original.path).unwrap();
            let mut older: routes::RouteFile = toml::from_str(&text).unwrap();
            older.disabled = disabled;
            std::fs::write(&original.path, toml::to_string_pretty(&older).unwrap()).unwrap();
            let current = routes::find(dir, id).unwrap();
            assert_eq!(current.file.disabled, disabled);
            assert_eq!(current.file.credential_instance.as_deref(), Some(instance));
            assert_eq!(current.file.notes, original.file.notes);
        }

        let redelivered = routes::for_credential(dir, id).unwrap();
        assert_eq!(redelivered.file.credential_instance, delivered.file.credential_instance);
        assert!(
            s.service
                .token_lasting(&s.places.home, id, super::CREDENTIAL_MARGIN_SECS)
                .await
                .is_ok_and(|(token, _)| token == "access-0")
        );
        assert!(s.service.remove(&s.places, id, instance).await.unwrap());
        assert!(
            routes::bindings_with_disconnects(&s.places.home).disconnected_credentials[id]
                .contains(instance)
        );
        assert!(routes::find(dir, id).is_err());
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn disconnect_revokes_before_a_route_backup_failure() {
    let s = setup().await;
    let id = "chatgpt";
    assert_eq!(sign_in(&s, &[("code", "c1")]).await.0, Status::Done(id.into()));
    let route = routes::find(s.places.routes.as_deref(), id).unwrap();
    let instance = route.file.credential_instance.as_deref().unwrap();
    let backups = s.places.home.join("route-backups");
    std::fs::write(&backups, "blocks backup directory creation").unwrap();
    let gate = Arc::new(Gate::default());
    s.fake.state.lock().unwrap().revoke_gate = Some(gate.clone());
    let removing = s.service.remove(&s.places, id, instance);
    tokio::pin!(removing);
    tokio::select! {
        result = &mut removing => panic!("Disconnect completed before revocation: {result:?}"),
        reached = tokio::time::timeout(Duration::from_secs(5), gate.entered.notified()) => {
            reached.expect("provider received revocation");
        }
    }
    assert!(store::read(&s.places.home, id).unwrap().unwrap().signed_in());
    gate.release.notify_one();
    assert_eq!(removing.await.unwrap_err().code, "storage");
    assert!(routes::find(s.places.routes.as_deref(), id).is_ok());
    assert_eq!(s.fake.state.lock().unwrap().revoke_forms[0]["token"], "refresh-0");

    std::fs::remove_file(backups).unwrap();
    s.service.remove(&s.places, id, instance).await.unwrap();
    assert!(routes::find(s.places.routes.as_deref(), id).is_err());
    assert_eq!(s.fake.state.lock().unwrap().revoke_forms.len(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_stale_disconnect_does_not_revoke_the_replacement_grant() {
    let s = setup().await;
    sign_in(&s, &[("code", "c1")]).await;
    let id = "chatgpt";
    let dir = s.places.routes.as_deref();
    let original = routes::find(dir, id).unwrap();
    let stale = original.file.credential_instance.as_deref().unwrap();
    routes::remove(dir, &s.places.home, id).unwrap();
    let replacement = routes::add(dir, id, &original.file, false).unwrap();
    assert_ne!(replacement.file.credential_instance.as_deref(), Some(stale));
    let record = store::read(&s.places.home, id).unwrap().unwrap();

    assert!(s.service.remove(&s.places, id, stale).await.is_err());
    assert_eq!(store::read(&s.places.home, id).unwrap(), Some(record));
    assert!(s.fake.state.lock().unwrap().revoke_forms.is_empty());
    assert_eq!(
        routes::find(dir, id).unwrap().file.credential_instance,
        replacement.file.credential_instance
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn chatgpt_remove_reports_an_unreadable_keychain_and_keeps_the_index() {
    let s = setup().await;
    sign_in(&s, &[("code", "c1")]).await;
    let home = &s.places.home;
    let id = "chatgpt";
    let store = crate::subscription_store::Store::new(home, id);
    store.refuse_test_item(id, crate::subscription_store::Error::KeychainOtherBuild);
    assert!(matches!(
        store::read(home, id),
        Err(crate::subscription_store::Error::KeychainOtherBuild)
    ));

    let route = routes::find(s.places.routes.as_deref(), id).unwrap();
    let error = s
        .service
        .remove(&s.places, id, route.file.credential_instance.as_deref().unwrap())
        .await
        .unwrap_err();
    assert_eq!(error.code, "keychain_other_build");
    assert_eq!(store.metadata(id).unwrap()["signed_in"], true);
    assert!(s.fake.state.lock().unwrap().revoke_forms.is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn chatgpt_disconnect_requires_cleanup_of_the_retired_grant() {
    let s = setup().await;
    let id = "chatgpt";
    let home = &s.places.home;
    assert_eq!(sign_in(&s, &[("code", "c1")]).await.0, Status::Done(id.into()));
    let store = crate::subscription_store::Store::new(home, "chatgpt");
    let mut prior = store::read(home, id).unwrap().unwrap();
    prior.refresh_token = "fixture-retired-refresh".into();
    store::write(home, id, &prior).unwrap();
    let retired = store.test_account(id);
    store.refuse_test_item(id, crate::subscription_store::Error::KeychainOtherBuild);
    assert!(matches!(
        store::read(home, id),
        Err(crate::subscription_store::Error::KeychainOtherBuild)
    ));

    assert_eq!(sign_in_again(&s, Some(id), &[("code", "c2")]).await.0, Status::Done(id.into()));
    let active = store.test_account(id);
    assert_ne!(active, retired);
    let route = crate::routes::find(s.places.routes.as_deref(), id).unwrap();
    let instance = route.file.credential_instance.as_deref().unwrap();
    assert_eq!(
        s.service.remove(&s.places, id, instance).await.unwrap_err().code,
        "keychain_other_build"
    );
    assert!(routes::find(s.places.routes.as_deref(), id).is_ok());
    assert!(store.has_test_item(&active));

    store.allow_test_item(&retired);
    assert!(store.has_test_item(&retired));
    assert!(s.service.remove(&s.places, id, instance).await.unwrap());
    assert!(store::read(home, id).unwrap().is_none());
    assert!(!store.has_test_item(&retired));
    assert!(!store.has_test_item(&active));
    let revoked = &s.fake.state.lock().unwrap().revoke_forms;
    assert_eq!(
        revoked.iter().map(|form| form["token"].as_str()).collect::<Vec<_>>(),
        ["refresh-0", "fixture-retired-refresh"]
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn chatgpt_disconnect_revokes_and_removes_a_keychain_grant_after_legacy_restore() {
    let s = setup().await;
    let id = "chatgpt";
    assert_eq!(sign_in(&s, &[("code", "c1")]).await.0, Status::Done(id.into()));
    let home = &s.places.home;
    let grants = crate::subscription_store::Store::new(home, id);
    let keychain_account = grants.test_account(id);
    let mut legacy = store::read(home, id).unwrap().unwrap();
    legacy.refresh_token = "fixture-legacy-refresh".into();
    let path = store::dir(home).join("chatgpt.json");
    store::write_atomic(&path, &serde_json::to_vec(&legacy).unwrap()).unwrap();
    assert!(grants.has_test_item(&keychain_account));
    assert_eq!(store::read(home, id).unwrap(), Some(legacy));

    let route = routes::find(s.places.routes.as_deref(), id).unwrap();
    let instance = route.file.credential_instance.as_deref().unwrap();
    assert!(s.service.remove(&s.places, id, instance).await.unwrap());
    assert!(!path.exists());
    assert!(!grants.has_test_item(&keychain_account));
    assert!(routes::find(s.places.routes.as_deref(), id).is_err());
    let revoked = &s.fake.state.lock().unwrap().revoke_forms;
    assert_eq!(
        revoked.iter().map(|form| form["token"].as_str()).collect::<Vec<_>>(),
        ["fixture-legacy-refresh", "refresh-0"]
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn chatgpt_reapproval_refuses_a_different_workspace_for_the_same_subject() {
    let s = setup().await;
    let id = "chatgpt";
    let home = &s.places.home;
    assert_eq!(sign_in(&s, &[("code", "c1")]).await.0, Status::Done(id.into()));
    let prior = store::read(home, id).unwrap().unwrap();
    s.fake.state.lock().unwrap().account = Some("other-workspace");

    assert_eq!(
        sign_in_again(&s, Some(id), &[("code", "c2")]).await.0,
        Status::Failed("different_account".into())
    );
    assert!(store::read(home, id).is_ok_and(|current| current.as_ref() == Some(&prior)));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn chatgpt_cannot_deliver_a_pending_grant_when_a_restored_index_is_unreadable() {
    let s = setup().await;
    let id = "chatgpt";
    let home = &s.places.home;
    assert_eq!(sign_in(&s, &[("code", "c1")]).await.0, Status::Done(id.into()));
    let previous = store::read(home, id).unwrap().unwrap();
    let current = store::Record {
        access_token: "fixture-pending-access".into(),
        expires_at: now() + 3600,
        ..previous.clone()
    };
    s.service
        .pending_writes
        .lock()
        .unwrap()
        .insert((home.clone(), id.into()), super::PendingWrite { previous, current });
    let path = store::dir(home).join(format!("{id}.json"));
    let mut index: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    index["workspace"] = json!("restored-workspace");
    store::write_atomic(&path, &serde_json::to_vec(&index).unwrap()).unwrap();
    crate::subscription_store::Store::new(home, "chatgpt")
        .refuse_test_item(id, crate::subscription_store::Error::KeychainOtherBuild);

    assert_eq!(s.service.token(home, id).await.unwrap_err().code, "keychain_other_build");
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

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_failed_refresh_cannot_supply_a_short_machine_credential() {
    let s = setup().await;
    sign_in(&s, &[("code", "c1")]).await;
    expire(&s);
    s.fake.state.lock().unwrap().refresh_error = Some((503, json!({"error": "unavailable"})));
    let failure = s
        .service
        .token_lasting(&s.places.home, "chatgpt", super::CREDENTIAL_MARGIN_SECS)
        .await
        .unwrap_err();
    assert_ne!(failure.code, "reauth_required");
    assert!(store::read(&s.places.home, "chatgpt").unwrap().unwrap().signed_in());
}

/// A `chatgpt-plan` route this acpmux home holds no sign-in for (the route folder is shared by every
/// cmux on the Mac; another build, or the retired token-sharing client, wrote it): the row reads
/// signed out, and its Sign In signs in on that same route instead of failing `not_found` (cmux#45774).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn signing_in_again_on_a_route_with_no_sign_in_here_takes_that_route() {
    let s = setup().await;
    let dir = s.places.routes.as_deref();
    let mut stale = crate::routes::RouteFile {
        credential_instance: None,
        name: Some("ChatGPT plan (alex@example.com)".into()),
        kind: RouteKind::ChatgptPlan,
        families: vec!["codex".into()],
        anthropic_base_url: None,
        openai_base_url: Some("https://api.openai.com/v1".into()),
        auth: None,
        secret: None,
        claude_token_expires_at: None,
        cloud_enabled: None,
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

#[tokio::test]
async fn chatgpt_device_joins_the_attempt_and_recovers_from_a_server_error() {
    let s = setup().await;
    s.fake.state.lock().unwrap().device_replies =
        VecDeque::from([(StatusCode::SERVICE_UNAVAILABLE, Value::Null), device_approved()]);
    let first = s.service.begin_device(s.places.clone(), None, |_| {}).await.unwrap();
    let joined = s.service.begin_device(s.places.clone(), None, |_| {}).await.unwrap();

    assert_eq!(first.attempt, joined.attempt);
    assert!(matches!(
        s.service.wait_device(&joined.attempt, Duration::from_secs(10)).await.unwrap(),
        Status::Done(_)
    ));
    let fake = s.fake.state.lock().unwrap();
    assert_eq!(fake.device_polls.len(), 2);
    assert!(fake.device_polls[1] - fake.device_polls[0] >= Duration::from_secs(2));
}

#[tokio::test]
async fn chatgpt_reconnect_rejects_another_account_and_add_another_accepts_it() {
    let s = setup().await;
    let (status, _) = sign_in(&s, &[("code", "first")]).await;
    assert_eq!(status, Status::Done("chatgpt".into()));
    {
        let mut account = store::read(&s.places.home, "chatgpt").unwrap().unwrap();
        account.sub = "fixture-other-subject".into();
        account.email = Some("prior@example.com".into());
        store::write(&s.places.home, "chatgpt", &account).unwrap();
    }
    let (status, _) = sign_in_again(&s, Some("chatgpt"), &[("code", "reconnect")]).await;
    assert_eq!(
        status,
        Status::WrongAccount {
            actual: "alex@example.com".into(),
            expected: "prior@example.com".into(),
        }
    );
    assert_eq!(store::all(&s.places.home).len(), 1);
    let (status, _) = sign_in(&s, &[("code", "add")]).await;
    assert_eq!(status, Status::Done("chatgpt-2".into()));
    assert_eq!(store::all(&s.places.home).len(), 2);
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
