//! Sign in with ChatGPT against a local fake of the OAuth server (`Endpoints::at`).

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::extract::{Form, State};
use axum::http::StatusCode;
use axum::routing::{get, post};
use axum::{Json, Router};
use base64::Engine as _;
use ring::rand::SystemRandom;
use ring::signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair, KeyPair as _};
use serde_json::{Value, json};

use super::oauth::{challenge, form_encode};
use super::{Endpoints, Places, Service, Status, jwt, store};
use crate::routes::{self, RouteKind};

const ISSUED: &str = "oaiapp_test123";
const FULL_SCOPE: &str =
    "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct";

#[derive(Default)]
struct Fake {
    nonce: String,
    scope: String,
    refresh_calls: usize,
    refresh_error: Option<&'static str>,
    token_forms: Vec<HashMap<String, String>>,
    revoke_forms: Vec<HashMap<String, String>>,
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
        "revocation_endpoint": format!("{}/revoke", app.base),
    }))
}

async fn jwks(State(app): State<App>) -> Json<Value> {
    Json(json!({"keys": [jwk(&app.key)]}))
}

async fn token(
    State(app): State<App>,
    Form(form): Form<HashMap<String, String>>,
) -> (StatusCode, Json<Value>) {
    let grant = form.get("grant_type").cloned().unwrap_or_default();
    app.state.lock().unwrap().token_forms.push(form.clone());
    if grant == "authorization_code" {
        let (nonce, scope) = {
            let s = app.state.lock().unwrap();
            (s.nonce.clone(), s.scope.clone())
        };
        let id_token = sign(
            &app.key,
            &json!({"iss": app.base, "aud": form.get("client_id"), "exp": now() + 3600,
                    "nonce": nonce, "sub": "user-1", "email": "alex@example.com",
                    "https://api.openai.com/auth": {"chatgpt_plan_type": "pro"}}),
        );
        return (
            StatusCode::OK,
            Json(json!({"access_token": "access-0", "refresh_token": "refresh-0",
                        "id_token": id_token, "expires_in": 3600, "scope": scope,
                        "token_type": "Bearer"})),
        );
    }
    if let Some(error) = app.state.lock().unwrap().refresh_error {
        return (StatusCode::BAD_REQUEST, Json(json!({"error": error})));
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
                    "expires_in": 1800, "scope": "openid chatgpt.tokens.use.direct offline_access"}),
        ),
    )
}

async fn revoke(State(app): State<App>, Form(form): Form<HashMap<String, String>>) -> StatusCode {
    app.state.lock().unwrap().revoke_forms.push(form);
    StatusCode::OK
}

async fn server(scope: &str) -> Server {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let base = format!("http://127.0.0.1:{}", listener.local_addr().expect("addr").port());
    let state = Arc::new(Mutex::new(Fake { scope: scope.to_owned(), ..Fake::default() }));
    let app = App { base: base.clone(), state: state.clone(), key: Arc::new(key_pair()) };
    let router = Router::new()
        .route("/.well-known/openid-configuration", get(discovery))
        .route("/jwks", get(jwks))
        .route("/api/accounts/oauth/token", post(token))
        .route("/revoke", post(revoke))
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

async fn setup(scope: &str) -> Setup {
    // The test's own callback requests (`reqwest::get`) need the process's TLS provider.
    let _ = rustls::crypto::ring::default_provider().install_default();
    let root = tempfile::tempdir().expect("tempdir");
    let places =
        Places { routes: Some(root.path().join("routes")), home: root.path().join("home") };
    let fake = server(scope).await;
    let service = Arc::new(Service::new(Endpoints::at(&fake.base)));
    Setup { _root: root, places, service, fake }
}

fn query(url: &str) -> HashMap<String, String> {
    reqwest::Url::parse(url).expect("url").query_pairs().into_owned().collect()
}

/// Begins a sign-in, then calls its callback with `extra` (and the right state unless `extra`
/// names one), and waits for the attempt.
async fn sign_in(s: &Setup, extra: &[(&str, &str)]) -> (Status, HashMap<String, String>) {
    let begun = s.service.begin(s.places.clone(), None, |_| {}).await.expect("begin");
    let params = query(&begun.url);
    s.fake.state.lock().unwrap().nonce = params["nonce"].clone();
    let mut pairs: Vec<(&str, &str)> = extra.to_vec();
    if !extra.iter().any(|(k, _)| *k == "state") {
        pairs.push(("state", params["state"].as_str()));
    }
    let callback = format!("{}?{}", params["redirect_uri"], form_encode(&pairs));
    let page = reqwest::get(&callback).await.expect("callback");
    assert_eq!(page.status(), 200);
    let status = s.service.wait(&begun.attempt, Duration::from_secs(10)).await.expect("wait");
    (status, params)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn first_sign_in_registers_and_persists_the_issued_client_id() {
    let s = setup(FULL_SCOPE).await;
    let (status, params) = sign_in(&s, &[("code", "c1"), ("client_id", ISSUED)]).await;
    assert_eq!(status, Status::Done("chatgpt".into()));
    assert_eq!(params["client_id"], super::DYNAMIC_CLIENT_ID);
    assert_eq!(params["agent_name_hint"], "cmux");
    assert_eq!(params["response_type"], "code");
    assert_eq!(params["scope"], super::SCOPES);
    assert_eq!(params["resource"], super::RESOURCE);
    assert_eq!(params["code_challenge_method"], "S256");
    assert!(params["ext_agent_host_id"].starts_with("urn:uuid:"));
    assert!(params["redirect_uri"].starts_with("http://127.0.0.1:"));
    assert!(params["redirect_uri"].ends_with("/auth/callback"));

    let host = store::host(&s.places.home).unwrap();
    assert_eq!(host.client_id.as_deref(), Some(ISSUED), "the issued id is stored");
    assert_eq!(host.host_id, params["ext_agent_host_id"]);
    let forms = s.fake.state.lock().unwrap().token_forms.clone();
    let exchange = &forms[0];
    assert_eq!(exchange["grant_type"], "authorization_code");
    assert_eq!(exchange["client_id"], ISSUED);
    assert_eq!(exchange["code"], "c1");
    assert_eq!(exchange["redirect_uri"], params["redirect_uri"]);
    assert_eq!(exchange["resource"], super::RESOURCE);
    assert_eq!(challenge(&exchange["code_verifier"]), params["code_challenge"]);

    let record = store::read(&s.places.home, "chatgpt").unwrap().expect("record");
    assert_eq!(record.client_id, ISSUED);
    assert_eq!(record.sub, "user-1");
    assert_eq!(record.email.as_deref(), Some("alex@example.com"));
    assert_eq!(record.plan.as_deref(), Some("pro"));
    assert_eq!(record.refresh_token, "refresh-0");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        for file in ["chatgpt.json", "host.json"] {
            let mode = std::fs::metadata(store::dir(&s.places.home).join(file))
                .unwrap()
                .permissions()
                .mode();
            assert_eq!(mode & 0o777, 0o600, "{file} is owner-only");
        }
    }
    let route = routes::find(s.places.routes.as_deref(), "chatgpt").expect("route");
    assert_eq!(route.file.kind, RouteKind::ChatgptPlan);
    assert_eq!(route.file.families, vec!["codex".to_owned()]);
    assert_eq!(route.file.openai_base_url.as_deref(), Some(super::RESOURCE));

    // A later sign-in uses the issued id and gives no name hint; the same person keeps one record.
    let (status, params) = sign_in(&s, &[("code", "c2")]).await;
    assert_eq!(params["client_id"], ISSUED);
    assert!(!params.contains_key("agent_name_hint"));
    assert_eq!(status, Status::Done("chatgpt".into()));
    assert_eq!(store::all(&s.places.home).len(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_registration_without_an_issued_client_id_stores_nothing() {
    let s = setup(FULL_SCOPE).await;
    let (status, _) = sign_in(&s, &[("code", "c1"), ("client_id", super::DYNAMIC_CLIENT_ID)]).await;
    assert_eq!(status, Status::Failed("no_client_id".into()));
    assert_eq!(store::host(&s.places.home).unwrap().client_id, None, "never dynamic_agent_client");
    assert!(s.fake.state.lock().unwrap().token_forms.is_empty(), "no exchange");
    assert!(store::set_client_id(&s.places.home, super::DYNAMIC_CLIENT_ID).is_err());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_callback_with_another_state_fails_without_an_exchange() {
    let s = setup(FULL_SCOPE).await;
    let (status, _) =
        sign_in(&s, &[("code", "c1"), ("client_id", ISSUED), ("state", "forged")]).await;
    assert_eq!(status, Status::Failed("state_mismatch".into()));
    assert!(s.fake.state.lock().unwrap().token_forms.is_empty());
    assert!(store::all(&s.places.home).is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn access_denied_stops_the_sign_in() {
    let s = setup(FULL_SCOPE).await;
    let (status, _) = sign_in(&s, &[("error", "access_denied")]).await;
    assert_eq!(status, Status::Failed("access_denied".into()));
    assert!(s.fake.state.lock().unwrap().token_forms.is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn tokens_without_the_plan_scope_are_refused_and_revoked() {
    let s = setup("openid profile email offline_access").await;
    let (status, _) = sign_in(&s, &[("code", "c1"), ("client_id", ISSUED)]).await;
    assert_eq!(status, Status::Failed("no_plan_scope".into()));
    assert!(store::all(&s.places.home).is_empty(), "nothing stored");
    assert!(routes::find(s.places.routes.as_deref(), "chatgpt").is_err());
    let revoked = s.fake.state.lock().unwrap().revoke_forms.clone();
    assert_eq!(revoked.len(), 1);
    assert_eq!(revoked[0]["token"], "refresh-0");
}

fn expire(s: &Setup) {
    let mut record = store::read(&s.places.home, "chatgpt").unwrap().unwrap();
    record.expires_at = now() + 60;
    store::write(&s.places.home, "chatgpt", &record).unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_refresh_replaces_access_expiry_scopes_and_refresh_token_together() {
    let s = setup(FULL_SCOPE).await;
    sign_in(&s, &[("code", "c1"), ("client_id", ISSUED)]).await;
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
    assert_eq!(record.refresh_token, "refresh-r1");
    assert_eq!(record.expires_at, expires_at);
    assert_eq!(record.scopes, vec!["openid", "chatgpt.tokens.use.direct", "offline_access"]);
    let forms = s.fake.state.lock().unwrap().token_forms.clone();
    let refresh = forms.last().unwrap();
    assert_eq!(refresh["grant_type"], "refresh_token");
    assert_eq!(refresh["refresh_token"], "refresh-0");
    assert_eq!(refresh["client_id"], ISSUED);
    assert_eq!(refresh["resource"], super::RESOURCE);
    assert!(!refresh.contains_key("scope"), "a refresh names no scope");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn concurrent_token_calls_share_one_refresh() {
    let s = setup(FULL_SCOPE).await;
    sign_in(&s, &[("code", "c1"), ("client_id", ISSUED)]).await;
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
    let s = setup(FULL_SCOPE).await;
    sign_in(&s, &[("code", "c1"), ("client_id", ISSUED)]).await;
    expire(&s);
    s.fake.state.lock().unwrap().refresh_error = Some("invalid_grant");
    let failure = s.service.token(&s.places.home, "chatgpt").await.unwrap_err();
    assert_eq!(failure.code, "reauth_required");
    let record = store::read(&s.places.home, "chatgpt").unwrap().unwrap();
    assert!(!record.signed_in());
    assert_eq!(record.sub, "user-1", "the identity stays for a reauth");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn remove_revokes_the_refresh_token_and_keeps_the_registration() {
    let s = setup(FULL_SCOPE).await;
    sign_in(&s, &[("code", "c1"), ("client_id", ISSUED)]).await;
    let host = store::host(&s.places.home).unwrap();
    assert!(s.service.remove(&s.places.home, "chatgpt").await.unwrap());
    let revoked = s.fake.state.lock().unwrap().revoke_forms.clone();
    assert_eq!(revoked[0]["token"], "refresh-0");
    assert_eq!(revoked[0]["token_type_hint"], "refresh_token");
    assert_eq!(revoked[0]["client_id"], ISSUED);
    assert!(store::read(&s.places.home, "chatgpt").unwrap().is_none());
    assert_eq!(store::host(&s.places.home).unwrap(), host, "host id and client id stay");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_cancelled_sign_in_closes_its_listener() {
    let s = setup(FULL_SCOPE).await;
    let begun = s.service.begin(s.places.clone(), None, |_| {}).await.unwrap();
    assert_eq!(s.service.cancel(&begun.attempt).await.unwrap(), Status::Cancelled);
    let status = s.service.wait(&begun.attempt, Duration::from_millis(50)).await.unwrap();
    assert_eq!(status, Status::Cancelled);
    let redirect = query(&begun.url)["redirect_uri"].clone();
    let port = reqwest::Url::parse(&redirect).unwrap().port().unwrap();
    assert!(
        tokio::net::TcpStream::connect(("127.0.0.1", port)).await.is_err(),
        "the listener is closed"
    );
}

#[test]
fn id_tokens_are_checked_for_issuer_audience_expiry_nonce_and_signature() {
    let key = key_pair();
    let keys = vec![jwk(&key)];
    let good = json!({"iss": "https://auth.example", "aud": "oaiapp_a", "exp": now() + 600,
                      "nonce": "n1", "sub": "user-1"});
    let token = sign(&key, &good);
    let ok = jwt::verify(&token, &keys, "https://auth.example", "oaiapp_a", "n1", now());
    assert_eq!(ok.map(|c| c.sub), Ok("user-1".to_owned()));
    let check = |claims: Value| {
        jwt::verify(&sign(&key, &claims), &keys, "https://auth.example", "oaiapp_a", "n1", now())
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
    let other = key_pair();
    assert_eq!(
        jwt::verify(&sign(&other, &good), &keys, "https://auth.example", "oaiapp_a", "n1", now()),
        Err(jwt::Invalid::Signature)
    );
    let mut tampered: Vec<&str> = token.split('.').collect();
    let forged = b64(with("sub", json!("user-2")).to_string().as_bytes());
    tampered[1] = &forged;
    assert_eq!(
        jwt::verify(&tampered.join("."), &keys, "https://auth.example", "oaiapp_a", "n1", now()),
        Err(jwt::Invalid::Signature)
    );
    assert_eq!(
        jwt::verify(&token, &[], "https://auth.example", "oaiapp_a", "n1", now()),
        Err(jwt::Invalid::UnknownKey)
    );
}

#[test]
fn form_encoding_escapes_reserved_bytes() {
    assert_eq!(form_encode(&[("a b", "x&y=z/é"), ("k", "v")]), "a+b=x%26y%3Dz%2F%C3%A9&k=v");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_machine_credential_is_refreshed_to_ten_minutes_left() {
    let s = setup(FULL_SCOPE).await;
    sign_in(&s, &[("code", "c1"), ("client_id", ISSUED)]).await;
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
