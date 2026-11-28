//! What a sign-in enroll sent the hub, said without the secret, so a refused mint explains itself
//! in daemon.log (cloud-carrier-ssh-failover row 2026-11-15T15:54Z: two `Some(401)
//! machine.unauthorized` lines and nothing else).
//!
//! The hub's machine routes (`POST /v1/machines/join-tokens`, the credentials list and revoke)
//! take only a cmux access token: the ES256 install token cmux-api mints (`cmux auth token`),
//! issuer `https://cmux-api/<env>`, with a `team` claim. Anything else answers 401
//! `machine.unauthorized`: a Stack session token, a token from another environment, one with no
//! team, or an expired one. The description names the issuer, team, user and expiry the token
//! claims (unverified; none of them is a secret), never the token.

use base64::Engine as _;
use serde_json::Value;

/// The issuer prefix of a cmux access token (cmux-platform `OwnerTokens`).
const CMUX_ISSUER_PREFIX: &str = "https://cmux-api/";

/// `token` as the hub's machine routes would read it, at `now_secs`.
pub(super) fn describe(token: &str, now_secs: u64) -> String {
    let Some(claims) = claims(token) else {
        return "an access token that is not a JWT (the hub's machine routes take only a cmux access token)".to_owned();
    };
    let text =
        |key: &str| claims.get(key).and_then(Value::as_str).filter(|value| !value.is_empty());
    let issuer = text("iss");
    let team = text("team");
    let user = text("sub");
    let expired = claims.get("exp").and_then(Value::as_f64).map(|exp| exp < now_secs as f64);
    let kind = match (issuer, team) {
        (Some(issuer), Some(_)) if issuer.starts_with(CMUX_ISSUER_PREFIX) => "a cmux access token",
        (Some(issuer), None) if issuer.starts_with(CMUX_ISSUER_PREFIX) => {
            "a cmux access token with no team claim (the hub refuses it)"
        }
        _ => "not a cmux access token (a sign-in session token? the hub refuses it)",
    };
    format!(
        "{kind}: issuer {}, team {}, user {}, {}",
        issuer.unwrap_or("none"),
        team.unwrap_or("none"),
        user.unwrap_or("none"),
        match expired {
            Some(true) => "expired",
            Some(false) => "unexpired",
            None => "no expiry",
        }
    )
}

/// The `team` claim of `token` (unverified; not a secret), or None when it is no JWT or names none.
pub(super) fn team(token: &str) -> Option<String> {
    claims(token)?.get("team")?.as_str().filter(|team| !team.is_empty()).map(str::to_owned)
}

/// The `sub` claim of `token`: the person it acts for (unverified; not a secret), or None when it
/// is no JWT or names none.
pub(super) fn user(token: &str) -> Option<String> {
    claims(token)?.get("sub")?.as_str().filter(|user| !user.is_empty()).map(str::to_owned)
}

/// The unverified payload of a three-part JWT.
fn claims(token: &str) -> Option<serde_json::Map<String, Value>> {
    let mut parts = token.trim().split('.');
    let (Some(header), Some(payload), Some(signature), None) =
        (parts.next(), parts.next(), parts.next(), parts.next())
    else {
        return None;
    };
    if header.is_empty() || payload.is_empty() || signature.is_empty() {
        return None;
    }
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload.trim_end_matches('='))
        .ok()?;
    match serde_json::from_slice(&bytes).ok()? {
        Value::Object(map) => Some(map),
        _ => None,
    }
}

#[cfg(test)]
#[path = "sent_credential_tests.rs"]
mod tests;
