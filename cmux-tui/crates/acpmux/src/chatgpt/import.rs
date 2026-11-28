//! The CI-only import of a Codex `auth.json` (`_acpmux/connections/chatgpt.import`, cmuxterm-hq
//! #15720): the Codex CLI's own login file becomes a real `chatgpt-plan` connection, written by
//! the same store a browser sign-in ends with, so the record and the route are the ones a
//! sign-in makes and nothing about storage is new.
//!
//! What it cannot do is prove the tokens: there is no JWKS fetch here, so the ID token is read
//! unverified (its `aud` must still be Codex's client), the access token is stored expired-now
//! when it names no `exp`, and the daemon's first refresh is the proof (a dead token reads signed
//! out). `connections.rs` refuses it unless the daemon's environment sets [`ENV`], and on any
//! connection but the local socket. No token reaches a log line or an error message.

use std::io::Read as _;
use std::path::Path;

use base64::Engine as _;
use serde_json::{Value, json};

use super::oauth::{TokenAnswer, save_import};
use super::{CODEX_CLIENT_ID, Failure, Places, jwt, now_unix};

/// The daemon-environment switch that turns the import on; any other value is off.
pub const ENV: &str = "ACPMUX_CI_CHATGPT_IMPORT";
/// The most an `auth.json` may be: a Codex login file is a few KiB.
const MAX_FILE: u64 = 256 * 1024;

/// Whether the daemon's environment turned the import on (read at each call, never cached).
pub fn enabled() -> bool {
    enabled_by(std::env::var(ENV).ok().as_deref())
}

fn enabled_by(value: Option<&str>) -> bool {
    value.is_some_and(|v| v.trim() == "1")
}

fn invalid(message: &str) -> Failure {
    Failure::new("import_invalid", message)
}

/// The `exp` of an access token's payload, when it is a readable JWT.
fn access_expiry(token: &str) -> Option<i64> {
    let body = token.split('.').nth(1)?;
    let bytes =
        base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(body.trim_end_matches('=')).ok()?;
    serde_json::from_slice::<Value>(&bytes).ok()?.get("exp")?.as_i64()
}

fn read_file(path: &Path) -> Result<Vec<u8>, Failure> {
    if !path.is_absolute() {
        return Err(invalid("secret_file must be an absolute path"));
    }
    let unreadable = |e: std::io::Error| invalid(&format!("cannot read secret_file: {}", e.kind()));
    let file = std::fs::File::open(path).map_err(unreadable)?;
    let meta = file.metadata().map_err(unreadable)?;
    if !meta.is_file() || meta.len() > MAX_FILE {
        return Err(invalid("secret_file is not a Codex auth.json"));
    }
    let mut bytes = Vec::new();
    file.take(MAX_FILE).read_to_end(&mut bytes).map_err(unreadable)?;
    Ok(bytes)
}

/// Imports the Codex `auth.json` at `secret_file`; the new (or refreshed) connection's route id.
pub(crate) fn codex_auth(places: &Places, secret_file: &Path) -> Result<String, Failure> {
    import_text(places, &read_file(secret_file)?, now_unix())
}

fn import_text(places: &Places, bytes: &[u8], now: i64) -> Result<String, Failure> {
    let file: Value =
        serde_json::from_slice(bytes).map_err(|_| invalid("secret_file is not valid JSON"))?;
    let tokens = file.get("tokens").filter(|t| t.is_object()).ok_or_else(|| {
        invalid("auth.json has no ChatGPT tokens (an API-key login cannot be imported)")
    })?;
    let text = |key: &str| tokens.get(key).and_then(Value::as_str).filter(|s| !s.is_empty());
    let refresh = text("refresh_token")
        .ok_or_else(|| Failure::new("no_refresh_token", "auth.json has no refresh token"))?;
    let access = text("access_token").ok_or_else(|| invalid("auth.json has no access token"))?;
    let id_token = text("id_token").ok_or_else(|| invalid("auth.json has no ID token"))?;
    // Codex's own client is the one the refresh token belongs to: the ID token's audience.
    let (claims, _) = jwt::unverified(id_token, CODEX_CLIENT_ID).map_err(|why| match why {
        jwt::Invalid::Audience => {
            Failure::new("wrong_client", "the tokens are not Codex's OAuth client's")
        }
        other => invalid(&format!("the ID token is unreadable: {}", other.as_str())),
    })?;
    if claims.account.is_none() && text("account_id").is_none() {
        return Err(Failure::new("no_chatgpt_account", "auth.json names no ChatGPT account"));
    }
    let expires_in = access_expiry(access).map_or(0, |exp| (exp - now).max(0));
    let answer: TokenAnswer = serde_json::from_value(json!({
        "access_token": access,
        "refresh_token": refresh,
        "id_token": id_token,
        "expires_in": expires_in,
    }))
    .map_err(|_| invalid("auth.json tokens are unreadable"))?;
    save_import(places, CODEX_CLIENT_ID, claims, answer)
}

/// A Codex `auth.json` as tests write it (unsigned tokens: the import reads them unverified).
#[cfg(test)]
pub(crate) fn test_auth_json(aud: &str, refresh: Option<&str>, account: bool) -> String {
    let part = |v: Value| {
        base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(serde_json::to_vec(&v).unwrap_or_default())
    };
    let token = |payload: Value| format!("{}.{}.c2ln", part(json!({"alg": "none"})), part(payload));
    let mut claims = json!({"aud": [aud], "sub": "user-1", "email": "ci@example.com"});
    if account {
        claims["https://api.openai.com/auth"] =
            json!({"chatgpt_plan_type": "plus", "chatgpt_account_id": "acct-1"});
    }
    let mut tokens = json!({
        "id_token": token(claims),
        "access_token": token(json!({"exp": now_unix() + 3600})),
        "account_id": if account { json!("acct-1") } else { Value::Null },
    });
    if let Some(refresh) = refresh {
        tokens["refresh_token"] = json!(refresh);
    }
    json!({"auth_mode": "chatgpt", "OPENAI_API_KEY": null, "tokens": tokens}).to_string()
}
