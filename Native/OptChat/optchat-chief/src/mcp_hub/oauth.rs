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
    /// The registry's name for the server (`linear`), for the signed-in page; None off the registry.
    pub app: Option<String>,
}

pub(super) fn agent() -> ureq::Agent {
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
pub(super) struct Discovered {
    pub resource: String,
    pub auth: AuthServer,
    pub scopes: Vec<String>,
    /// The server's `device_authorization_endpoint` (RFC 8628), if any.
    pub device_endpoint: Option<String>,
}

pub(super) fn discover(
    server_url: &str,
    www_authenticate: &str,
    registry_scopes: &[String],
) -> Result<Discovered, String> {
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
    let device_endpoint = meta["device_authorization_endpoint"]
        .as_str()
        .map(str::to_owned);
    Ok(Discovered {
        resource,
        auth,
        scopes,
        device_endpoint,
    })
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
    /// The server signs in with a device code (RFC 8628) and `client_id`.
    pub device: bool,
    /// The registry entry's name (`linear`): the app the signed-in page names.
    pub name: Option<String>,
}

/// An extra registry file (the builtin's shape) whose entries sign in like
/// the builtin's: a person's own device-code server, or a test's fake.
pub const EXTRA_REGISTRY_ENV: &str = "CMUX_MCP_REGISTRY_EXTRA";

impl Known {
    /// The registry's entry for exactly this server URL.
    pub fn for_url(url: &str) -> Self {
        Self::in_registry(url, &cmux_mcp_connect::registry::Registry::builtin()).unwrap_or_default()
    }

    /// [`Known::for_url`], then the extra registry file `env` names
    /// ([`EXTRA_REGISTRY_ENV`]).
    pub fn for_url_with(url: &str, env: &dyn Fn(&str) -> Option<String>) -> Self {
        let builtin = cmux_mcp_connect::registry::Registry::builtin();
        Self::in_registry(url, &builtin)
            .or_else(|| {
                let text = std::fs::read_to_string(env(EXTRA_REGISTRY_ENV)?).ok()?;
                let extra = cmux_mcp_connect::registry::Registry::parse(&text).ok()?;
                Self::in_registry(url, &extra)
            })
            .unwrap_or_default()
    }

    fn in_registry(url: &str, registry: &cmux_mcp_connect::registry::Registry) -> Option<Self> {
        registry.by_url(url).map(|e| Self {
            client_id: e.client_id.clone().filter(|c| !c.is_empty()),
            redirect_port: e.redirect_port,
            scopes: e.scopes.clone(),
            scope_delimiter: e.scope_delimiter.clone(),
            device: e.auth == cmux_mcp_connect::registry::AuthKind::Device,
            name: Some(e.name.clone()),
        })
    }
}

/// Starts a sign-in for the server at `server_url` that answered 401 with
/// `www_authenticate`.
pub fn start(server_url: &str, www_authenticate: &str, known: &Known) -> Result<Started, String> {
    let Discovered {
        resource,
        auth,
        scopes,
        ..
    } = discover(server_url, www_authenticate, &known.scopes)?;
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
            app: known.name.clone(),
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

/// Where a finished browser sign-in lands: cmux.com's one "you're signed in, back to cmux" page
/// (web/app/connected/route.ts), the same page the cloud's MCP callback ends on.
pub const CONNECTED_PAGE_ORIGIN: &str = "https://cmux.com";

/// `<origin>/connected?app=<name>&status=ok|error`. The name is the registry's (only registry
/// servers have one), cut to `[a-z0-9-]`; anything else is `generic`, so no server-chosen text
/// reaches the page's URL.
pub fn connected_page_url(app: Option<&str>, ok: bool) -> String {
    let app = app
        .filter(|a| {
            !a.is_empty()
                && a.len() <= 64
                && a.bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        })
        .unwrap_or("generic");
    let status = if ok { "ok" } else { "error" };
    format!("{CONNECTED_PAGE_ORIGIN}/connected?app={app}&status={status}")
}

/// The loopback's answer once the code is in hand: a 302 to the cmux.com page, with the inline
/// page as the body for a browser that does not follow it.
fn signed_in_response(app: Option<&str>) -> String {
    let page = auth_page(
        true,
        "Signed in",
        "cmux Chief is connecting the server. You can close this tab.",
        None,
    );
    format!(
        "HTTP/1.1 302 Found\r\nLocation: {}\r\nCache-Control: no-store\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{page}",
        connected_page_url(app, true),
        page.len()
    )
}

/// The cmux NEXT sign-in page's frame (web/app/handler: `cmux-sign-in.tsx`'s `Page` and
/// `Heading`, `auth-error/page.tsx`'s body, the "Last used" chip for the code) with the tokens of
/// web/app/globals.css, for a page a loopback listener serves with no web build behind it.
/// Keep in step with the copies in acpmux's `chatgpt::oauth` and coderouter's `oauth`.
fn auth_page(ok: bool, title: &str, detail: &str, code: Option<&str>) -> String {
    let detail = if detail.is_empty() {
        String::new()
    } else {
        format!("<p class=\"body\">{}</p>", escape(detail))
    };
    let code = code
        .map(|c| format!("<p class=\"code\">{}</p>", escape(c)))
        .unwrap_or_default();
    format!(
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">\
<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\
<meta name=\"color-scheme\" content=\"light dark\"><meta name=\"robots\" content=\"noindex\">\
<title>{title} \u{b7} cmux</title><style>{AUTH_PAGE_CSS}</style></head>\
<body><main><section data-auth-state=\"{state}\"><h1>{title}</h1>{detail}{code}</section></main></body></html>",
        title = escape(title),
        state = if ok { "ok" } else { "error" },
    )
}

/// web/app/globals.css's tokens and the Tailwind classes of the sign-in page, written out, in
/// system fonts (a loopback page fetches nothing from outside).
const AUTH_PAGE_CSS: &str = "\
:root{--background:#fafafa;--foreground:#171717;--muted:#707070;--border:#e5e5e5}\
@media (prefers-color-scheme:dark){:root{--background:#0a0a0a;--foreground:#ededed;--muted:#a3a3a3;--border:#262626}}\
*,::before,::after{box-sizing:border-box;margin:0;padding:0;border:0 solid}\
html{line-height:1.5;-webkit-text-size-adjust:100%;\
font-family:ui-sans-serif,system-ui,sans-serif,\"Apple Color Emoji\",\"Segoe UI Emoji\";\
-webkit-font-smoothing:antialiased;-moz-osx-font-smoothing:grayscale}\
body{background:var(--background);color:var(--foreground)}\
main{display:flex;min-height:100vh;align-items:center;justify-content:center;padding:48px 16px}\
section{width:100%;max-width:340px}\
h1{font-size:22px;font-weight:600;letter-spacing:-0.02em}\
.body{margin-top:6px;font-size:14px;line-height:24px;color:var(--muted)}\
.code{display:inline-block;margin-top:24px;border:1px solid var(--border);padding:0 6px;\
font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:11px;line-height:18px;\
color:var(--muted)}";

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
        let _ = match &code {
            Ok(_) => conn.write_all(signed_in_response(pending.app.as_deref()).as_bytes()),
            // A failure stays on the loopback: its detail (the server's error) is shown here
            // and never leaves the machine in a URL.
            Err(e) => {
                let page = auth_page(
                    false,
                    "Sign-in failed",
                    "Return to cmux and try again.",
                    Some(&e.to_string()),
                );
                write!(
                    conn,
                    "HTTP/1.1 400 Bad Request\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{page}",
                    page.len()
                )
            }
        };
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
    tokens_from(&v, endpoint, client_id, issuer, resource, old_refresh)
}

/// The tokens in a token endpoint's answer.
pub(super) fn tokens_from(
    v: &Value,
    endpoint: &str,
    client_id: &str,
    issuer: &str,
    resource: &str,
    old_refresh: Option<&str>,
) -> Result<OAuthTokens, String> {
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
    fn a_registry_server_lands_on_its_named_signed_in_page() {
        let k = Known::for_url("https://mcp.linear.app/mcp");
        assert_eq!(k.name.as_deref(), Some("linear"));
        assert_eq!(
            connected_page_url(k.name.as_deref(), true),
            "https://cmux.com/connected?app=linear&status=ok"
        );
        let off_registry = Known::for_url("https://mcp.example.invalid/mcp");
        assert!(off_registry.name.is_none());
        assert_eq!(
            connected_page_url(off_registry.name.as_deref(), true),
            "https://cmux.com/connected?app=generic&status=ok"
        );
        for hostile in ["Linear", "a&b=c", "x/../y", "", &"a".repeat(65)] {
            assert!(
                connected_page_url(Some(hostile), false).ends_with("?app=generic&status=error"),
                "{hostile}"
            );
        }
    }

    #[test]
    fn the_signed_in_answer_redirects_and_keeps_the_inline_page() {
        let r = signed_in_response(Some("sentry"));
        assert!(r.starts_with("HTTP/1.1 302 Found\r\n"), "{r}");
        assert!(r.contains("\r\nLocation: https://cmux.com/connected?app=sentry&status=ok\r\n"));
        let (head, body) = r.split_once("\r\n\r\n").unwrap();
        assert!(head.contains(&format!("Content-Length: {}", body.len())));
        assert!(body.contains("data-auth-state=\"ok\"") && body.contains("Signed in"));
    }

    #[test]
    fn the_loopback_page_fetches_no_fonts() {
        let page = auth_page(false, "Sign-in failed", "x", Some("code"));
        assert!(
            !page.contains("@import") && !page.contains("fonts.googleapis"),
            "{page}"
        );
    }

    #[test]
    fn github_signs_in_with_a_device_code() {
        let k = Known::for_url("https://api.githubcopilot.com/mcp/");
        assert!(k.device && k.client_id.is_some(), "{k:?}");
        assert!(!Known::for_url("https://mcp.linear.app/mcp").device);
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
