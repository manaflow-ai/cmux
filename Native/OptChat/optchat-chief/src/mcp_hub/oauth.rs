//! OAuth 2.1 sign-in to a remote MCP server (the MCP authorization spec):
//! protected resource metadata (RFC 9728), authorization server metadata
//! (RFC 8414, else OpenID discovery), dynamic client registration (RFC 7591)
//! as a native public client, PKCE S256, the `resource` parameter (RFC 8707)
//! and a one-shot loopback redirect on 127.0.0.1. The rules (URL checks,
//! S256 required, state and `iss` checks) are cmux-mcp-connect's.
//!
//! The hub starts a sign-in when a server answers 401: it answers the Chief
//! with the authorize URL, which the Chief opens for the person (its
//! auth-escalation flow). The loopback listener waits off the turn; when the
//! person approves, the tokens are stored and the Chief wakes with a note.

use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::time::{Duration, Instant};

use cmux_mcp_connect::discovery::{self, AuthServer, AuthorizeRequest, ProtectedResource};
use cmux_mcp_connect::pkce;
use serde_json::Value;

use super::store::OAuthTokens;

/// How long the loopback listener waits for the person.
pub const SIGN_IN_WINDOW: Duration = Duration::from_secs(20 * 60);

pub struct Started {
    pub authorize_url: String,
    pub listener: TcpListener,
    pub pending: Pending,
}

pub struct Pending {
    pub auth: AuthServer,
    pub state: String,
    pub verifier: String,
    pub redirect_uri: String,
    pub client_id: String,
    pub resource: String,
}

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .redirects(0)
        .timeout(Duration::from_secs(20))
        .build()
}

fn get_json(url: &str) -> Result<Value, String> {
    cmux_mcp_connect::target::check_url(url).map_err(|e| e.to_string())?;
    let resp = agent()
        .get(url)
        .set("Accept", "application/json")
        .call()
        .map_err(|e| format!("{url}: {e}"))?;
    resp.into_json().map_err(|e| format!("{url}: {e}"))
}

fn random() -> [u8; 32] {
    use ring::rand::SecureRandom;
    let mut b = [0u8; 32];
    ring::rand::SystemRandom::new()
        .fill(&mut b)
        .expect("system random");
    b
}

/// The resource and its authorization server, from the 401's header.
fn discover(
    server_url: &str,
    www_authenticate: &str,
    registry_scopes: &[String],
) -> Result<(String, AuthServer, Vec<String>), String> {
    let prm_url = discovery::resource_metadata_url(www_authenticate)
        .map(Ok)
        .unwrap_or_else(|| {
            discovery::protected_resource_url(server_url).map_err(|e| e.to_string())
        })?;
    let challenge = discovery::challenge_scopes(www_authenticate);
    let (resource, issuer, supported) = match get_json(&prm_url)
        .and_then(|v| ProtectedResource::parse(&v.to_string()).map_err(|e| e.to_string()))
    {
        Ok(prm) => {
            // The resource must be this server (or the origin or path above it).
            let r = prm.resource.trim_end_matches('/');
            if !server_url.trim_end_matches('/').starts_with(r)
                || prm.authorization_servers.is_empty()
            {
                return Err(format!(
                    "the server's metadata names {} as its resource, not {server_url}",
                    prm.resource
                ));
            }
            (
                prm.resource.clone(),
                prm.authorization_servers[0].clone(),
                prm.scopes_supported,
            )
        }
        // An older server (2025-03-26) with no resource metadata: its origin
        // is its authorization server.
        Err(_) => {
            let u = url::Url::parse(server_url).map_err(|e| e.to_string())?;
            (
                server_url.to_owned(),
                u.origin().ascii_serialization(),
                Vec::new(),
            )
        }
    };
    let meta = discovery::auth_server_url(&issuer)
        .map_err(|e| e.to_string())
        .and_then(|u| get_json(&u))
        .or_else(|_| {
            let base = issuer.trim_end_matches('/');
            get_json(&format!("{base}/.well-known/openid-configuration"))
        })?;
    let auth = AuthServer::parse(&meta.to_string()).map_err(|e| e.to_string())?;
    auth.check(&issuer).map_err(|e| e.to_string())?;
    let scopes = discovery::choose_scopes(registry_scopes, &challenge, &supported);
    Ok((resource, auth, scopes))
}

/// What the registry knows about signing in to a server: a public client
/// registered ahead (servers with no dynamic registration, like Slack), and
/// the scopes to ask.
#[derive(Clone, Debug, Default)]
pub struct Known {
    pub client_id: Option<String>,
    pub redirect_port: Option<u16>,
    pub scopes: Vec<String>,
    pub scope_delimiter: Option<String>,
}

impl Known {
    /// The registry's entry for exactly this server URL.
    pub fn for_url(url: &str) -> Self {
        let registry = cmux_mcp_connect::registry::Registry::builtin();
        registry
            .by_url(url)
            .map(|e| Self {
                client_id: e.client_id.clone().filter(|c| !c.is_empty()),
                redirect_port: e.redirect_port,
                scopes: e.scopes.clone(),
                scope_delimiter: e.scope_delimiter.clone(),
            })
            .unwrap_or_default()
    }
}

/// Starts a sign-in for the server at `server_url` that answered 401 with
/// `www_authenticate`.
pub fn start(server_url: &str, www_authenticate: &str, known: &Known) -> Result<Started, String> {
    let (resource, auth, scopes) = discover(server_url, www_authenticate, &known.scopes)?;
    let (client_id, listener, redirect_uri) = match (&known.client_id, known.redirect_port) {
        // A client registered ahead: its redirect is fixed, so is the port.
        (Some(client_id), Some(port)) => {
            let listener = TcpListener::bind(("127.0.0.1", port)).map_err(|e| {
                format!("the sign-in needs port {port} on this machine and it is taken ({e}); close what holds it and try again")
            })?;
            (
                client_id.clone(),
                listener,
                format!("http://localhost:{port}/callback"),
            )
        }
        _ => {
            let listener = TcpListener::bind("127.0.0.1:0").map_err(|e| e.to_string())?;
            let port = listener.local_addr().map_err(|e| e.to_string())?.port();
            let redirect_uri = format!("http://127.0.0.1:{port}/callback");
            let Some(registration) = auth.registration_endpoint.clone() else {
                return Err(
                    "the server's sign-in takes no new apps (no dynamic client registration) and cmux has no app registered with it; add it with a key in headers instead"
                        .into(),
                );
            };
            let mut body = discovery::registration(&redirect_uri);
            body["client_name"] = "cmux Chief".into();
            body["application_type"] = "native".into();
            let reg: Value = agent()
                .post(&registration)
                .set("Accept", "application/json")
                .send_json(body)
                .map_err(|e| format!("client registration: {e}"))?
                .into_json()
                .map_err(|e| format!("client registration: {e}"))?;
            let client_id = reg["client_id"]
                .as_str()
                .ok_or("client registration: no client_id")?
                .to_owned();
            (client_id, listener, redirect_uri)
        }
    };
    let verifier = pkce::verifier(&random());
    let state = pkce::state(&random());
    let authorize_url = auth
        .authorize_url(&AuthorizeRequest {
            client_id: &client_id,
            redirect_uri: &redirect_uri,
            state: &state,
            code_challenge: &pkce::challenge_s256(&verifier),
            resource: &resource,
            scopes: &scopes,
        })
        .map_err(|e| e.to_string())?;
    let authorize_url = match known.scope_delimiter.as_deref() {
        Some(d) if d != " " => with_scope_delimiter(&authorize_url, d),
        _ => authorize_url,
    };
    Ok(Started {
        authorize_url,
        listener,
        pending: Pending {
            auth,
            state,
            verifier,
            redirect_uri,
            client_id,
            resource,
        },
    })
}

/// `url` with its `scope` parameter joined by `delimiter` instead of spaces.
pub fn with_scope_delimiter(url: &str, delimiter: &str) -> String {
    let Ok(mut u) = url::Url::parse(url) else {
        return url.to_owned();
    };
    let pairs: Vec<(String, String)> = u
        .query_pairs()
        .map(|(k, v)| {
            let v = if k == "scope" {
                v.split(' ').collect::<Vec<_>>().join(delimiter)
            } else {
                v.into_owned()
            };
            (k.into_owned(), v)
        })
        .collect();
    u.query_pairs_mut().clear().extend_pairs(pairs);
    u.to_string()
}

const DONE_PAGE: &str = "<!doctype html><meta charset=utf-8><title>Signed in</title><body style=\"font:15px -apple-system,system-ui;margin:3em\"><h2>Signed in</h2><p>cmux Chief is connecting the server. You can close this tab.</p>";

/// Waits on the loopback listener for the redirect, then trades the code
/// for tokens. Blocks (run it on its own thread).
pub fn wait(started: Started) -> Result<OAuthTokens, String> {
    let Started {
        listener, pending, ..
    } = started;
    let deadline = Instant::now() + SIGN_IN_WINDOW;
    listener.set_nonblocking(true).map_err(|e| e.to_string())?;
    loop {
        if Instant::now() > deadline {
            return Err("nobody finished the sign-in in 20 minutes".into());
        }
        let (mut conn, _) = match listener.accept() {
            Ok(c) => c,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(250));
                continue;
            }
            Err(e) => return Err(e.to_string()),
        };
        let _ = conn.set_nonblocking(false);
        let _ = conn.set_read_timeout(Some(Duration::from_secs(10)));
        let mut line = String::new();
        let _ = BufReader::new(&conn).read_line(&mut line);
        let path = line.split_whitespace().nth(1).unwrap_or("");
        let Some(query) = path.strip_prefix("/callback?") else {
            let _ = conn.write_all(
                b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            );
            continue;
        };
        let code = pending.auth.callback_code(query, &pending.state);
        let (status, page) = match &code {
            Ok(_) => ("200 OK", DONE_PAGE.to_owned()),
            Err(e) => (
                "400 Bad Request",
                format!("<!doctype html><meta charset=utf-8><p>Sign-in failed: {e}"),
            ),
        };
        let _ = write!(
            conn,
            "HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{page}",
            page.len()
        );
        let code = match code {
            Ok(c) => c,
            // A stray or forged request: keep waiting for the real one.
            Err(e) if e.to_string().contains("state") => continue,
            Err(e) => return Err(e.to_string()),
        };
        let form = discovery::token_form(
            &code,
            &pending.verifier,
            &pending.redirect_uri,
            &pending.client_id,
            &pending.resource,
        );
        return token(
            &pending.auth.token_endpoint,
            &form,
            &pending.client_id,
            &pending.auth.issuer,
            &pending.resource,
            None,
        );
    }
}

fn token(
    endpoint: &str,
    form: &[(&str, String)],
    client_id: &str,
    issuer: &str,
    resource: &str,
    old_refresh: Option<&str>,
) -> Result<OAuthTokens, String> {
    let pairs: Vec<(&str, &str)> = form.iter().map(|(k, v)| (*k, v.as_str())).collect();
    let v: Value = agent()
        .post(endpoint)
        .set("Accept", "application/json")
        .send_form(&pairs)
        .map_err(|e| match e {
            ureq::Error::Status(code, r) => format!(
                "the token request failed (HTTP {code}): {}",
                r.into_string()
                    .unwrap_or_default()
                    .chars()
                    .take(200)
                    .collect::<String>()
            ),
            e => format!("the token request failed: {e}"),
        })?
        .into_json()
        .map_err(|e| e.to_string())?;
    // Slack answers HTTP 200 with `{"ok": false, "error": ...}`.
    if v["ok"] == Value::Bool(false) {
        return Err(format!(
            "the token request was refused: {}",
            v["error"].as_str().unwrap_or("no reason given")
        ));
    }
    let access = v["access_token"]
        .as_str()
        .or_else(|| v["authed_user"]["access_token"].as_str())
        .ok_or("the token answer has no access_token")?;
    Ok(OAuthTokens {
        access_token: access.to_owned(),
        refresh_token: v["refresh_token"]
            .as_str()
            .map(str::to_owned)
            .or_else(|| old_refresh.map(str::to_owned)),
        expires_ms: v["expires_in"]
            .as_u64()
            .map(|s| super::now_ms() + s * 1000)
            .unwrap_or(0),
        client_id: client_id.to_owned(),
        token_endpoint: endpoint.to_owned(),
        issuer: issuer.to_owned(),
        resource: resource.to_owned(),
    })
}

/// A fresh access token from the refresh token.
pub fn refresh(old: &OAuthTokens) -> Result<OAuthTokens, String> {
    let r = old.refresh_token.as_deref().ok_or("no refresh token")?;
    let form = vec![
        ("grant_type", "refresh_token".to_owned()),
        ("refresh_token", r.to_owned()),
        ("client_id", old.client_id.clone()),
        ("resource", old.resource.clone()),
    ];
    token(
        &old.token_endpoint,
        &form,
        &old.client_id,
        &old.issuer,
        &old.resource,
        Some(r),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slack_scopes_are_joined_with_commas() {
        let url = "https://slack.com/oauth/v2_user/authorize?client_id=c&scope=chat%3Awrite+users%3Aread&state=s";
        let out = with_scope_delimiter(url, ",");
        let u = url::Url::parse(&out).unwrap();
        let scope: Vec<String> = u
            .query_pairs()
            .filter(|(k, _)| k == "scope")
            .map(|(_, v)| v.into_owned())
            .collect();
        assert_eq!(scope, vec!["chat:write,users:read".to_owned()]);
        assert!(
            out.contains("client_id=c") && out.contains("state=s"),
            "{out}"
        );
    }

    #[test]
    fn slack_is_a_known_client_with_a_fixed_redirect() {
        let k = Known::for_url("https://mcp.slack.com/mcp");
        assert!(
            k.client_id.is_some(),
            "Slack takes no dynamic registration: cmux's app id must be in the registry"
        );
        assert!(k.redirect_port.is_some());
        assert_eq!(k.scope_delimiter.as_deref(), Some(","));
        // Linear registers a client per sign-in (DCR), any port.
        let l = Known::for_url("https://mcp.linear.app/mcp");
        assert!(l.client_id.is_none() && l.redirect_port.is_none());
    }
}
