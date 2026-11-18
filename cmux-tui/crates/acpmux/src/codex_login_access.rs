//! The access token of a Codex CLI login on this Mac (`codex login` with ChatGPT), for a Cloud chat
//! (cmux#45774). Cloud multiplayer (cmux#40159) gave a Cloud chat's agent only a connection that
//! "serves Cloud" and removed the Mac's Codex holder, so a person signed in to Codex with ChatGPT got
//! no Codex on a Cloud machine: the `codex-login` connection did not serve Cloud, the only ChatGPT
//! way left was a separate Sign in with ChatGPT, and that plan route (`api.openai.com/v1`) refuses a
//! Codex CLI token ("Missing scopes: api.responses.write").
//!
//! Read only, never a second refresher: Codex rotates its refresh token, and another refresher would
//! invalidate the Mac's copy and sign the person out of Codex on the Mac. So this never runs Codex,
//! never refreshes and never writes; it returns only the access token and its expiry. The machine's
//! Codex sends it to the ChatGPT Codex backend ([`BASE_URL`], `agent_credentials.rs`), with the
//! account id the token itself names ([`account_id`]). The refresh token, the ID token and
//! `auth.json` never leave the Mac. A token too close to its end is not offered: the Mac's own Codex
//! renews it the next time it runs, and the app pushes the newer one then.
//!
//! Only the file store is read (`cli_auth_credentials_store` unset or `"file"`): in keyring or auto
//! mode the file may be stale and the Keychain item is Codex's own, so nothing is offered.

use std::path::Path;

use base64::Engine as _;
use serde_json::Value;

/// Where a Codex CLI login's token is sent: the ChatGPT Codex backend Codex itself uses for a
/// ChatGPT sign-in.
pub const BASE_URL: &str = "https://chatgpt.com/backend-api/codex";
/// The header that names the ChatGPT account (workspace) the token acts for.
pub const ACCOUNT_HEADER: &str = "chatgpt-account-id";
/// A token with less left than this (seconds) is not offered. Under the app's refresh lead
/// (`CloudAgentCredentialRefresher.lead`, 10 min), so the refresh read at that lead still answers
/// (the same token until the Mac's Codex renews it, which the app pushes then), and the connection
/// does not drop out of Cloud for the last minutes of every token.
pub const MINIMUM_LIFETIME_SECS: i64 = 5 * 60;
/// `auth.json` is a few KiB; anything larger is not Codex's.
#[cfg(unix)]
const SIZE_LIMIT: u64 = 64 * 1024;

/// A Codex CLI login's access token and its expiry (Unix seconds). Its `Debug` never shows the token.
#[derive(Clone, PartialEq, Eq)]
pub struct Access {
    pub token: String,
    pub expires_at: i64,
}

impl std::fmt::Debug for Access {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Access").field("expires_at", &self.expires_at).finish_non_exhaustive()
    }
}

/// The login's access in Codex home `folder` that a Cloud chat may use, or None: no ChatGPT
/// sign-in, an API key sign-in, keyring storage, a file that is not this user's private regular
/// file, a token that names no account, or one with less than [`MINIMUM_LIFETIME_SECS`] left.
/// Blocking file IO.
#[cfg(unix)]
pub fn read(folder: &Path, now: i64) -> Option<Access> {
    if !uses_file_store(&folder.join("config.toml")) {
        return None;
    }
    access(&private_file(&folder.join("auth.json"), true, false)?, now)
}

#[cfg(not(unix))]
pub fn read(_folder: &Path, _now: i64) -> Option<Access> {
    None
}

/// The access in an `auth.json`'s bytes ([`read`]'s rule, without the file checks).
pub fn access(auth_json: &[u8], now: i64) -> Option<Access> {
    let root: Value = serde_json::from_slice(auth_json).ok()?;
    let root = root.as_object()?;
    // An API key sign-in is not a subscription; a mode other than ChatGPT is not this reader's.
    if root.get("OPENAI_API_KEY").and_then(Value::as_str).is_some_and(|key| !key.is_empty()) {
        return None;
    }
    if root.get("auth_mode").and_then(Value::as_str).is_some_and(|mode| mode != "chatgpt") {
        return None;
    }
    let tokens = root.get("tokens")?.as_object()?;
    let token = tokens.get("access_token")?.as_str()?;
    if token.is_empty() || token.len() >= 16 * 1024 || !token.bytes().all(|b| b > 32 && b < 127) {
        return None;
    }
    // The machine names the account from the token alone: it must name one, the one `auth.json` says.
    let account = account_id(token)?;
    if tokens.get("account_id").and_then(Value::as_str).is_some_and(|a| a != account) {
        return None;
    }
    let expires_at = expiry(token, now)?;
    (expires_at - now >= MINIMUM_LIFETIME_SECS)
        .then(|| Access { token: token.to_owned(), expires_at })
}

/// The ChatGPT account id a Codex access token names (its `https://api.openai.com/auth` claim's
/// `chatgpt_account_id`); None for a token that names none.
pub fn account_id(jwt: &str) -> Option<String> {
    let all = claims(jwt)?;
    all.get("https://api.openai.com/auth")
        .and_then(|auth| auth.get("chatgpt_account_id"))
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty() && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-'))
        .map(str::to_owned)
}

/// A JWT's claims (its middle part), when it has three parts.
fn claims(jwt: &str) -> Option<serde_json::Map<String, Value>> {
    let parts: Vec<&str> = jwt.split('.').collect();
    let [_, payload, _] = parts.as_slice() else { return None };
    let data = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload.trim_end_matches('='))
        .ok()?;
    match serde_json::from_slice(&data).ok()? {
        Value::Object(map) => Some(map),
        _ => None,
    }
}

/// The token's expiry: a NumericDate within a year of now (a far or non-finite one is malformed).
fn expiry(jwt: &str, now: i64) -> Option<i64> {
    let exp = claims(jwt)?.get("exp")?.as_f64()?;
    (exp.is_finite() && exp > 0.0 && exp < (now + 366 * 86_400) as f64).then_some(exp as i64)
}

/// Whether config.toml keeps Codex's credentials in `auth.json` (its default). No config.toml:
/// the default. One cmux cannot read: nothing is offered.
#[cfg(unix)]
fn uses_file_store(config: &Path) -> bool {
    if let Err(error) = std::fs::symlink_metadata(config) {
        return error.kind() == std::io::ErrorKind::NotFound;
    }
    // An added account's home links the base's `config.toml` (`route_shadow::link`), and a person's
    // may be a dotfiles link: follow it, then check the file it names.
    let Some(text) =
        private_file(config, false, true).and_then(|data| String::from_utf8(data).ok())
    else {
        return false;
    };
    for line in text.lines() {
        // A top-level key only: a table's keys (`[profiles.x]`) start after the first header.
        if line.trim_start().starts_with('[') {
            break;
        }
        let Some((key, value)) = line.split_once('=') else { continue };
        if key.trim() != "cli_auth_credentials_store" {
            continue;
        }
        let value = value.split('#').next().unwrap_or_default();
        return value.trim().trim_matches(|c| c == '"' || c == '\'') == "file";
    }
    true
}

/// A regular file of this user's within the size limit, not a symlink unless `follow` (then the
/// file it names is checked); `require_private` also requires no group or other access (Codex
/// writes `auth.json` 0600).
#[cfg(unix)]
fn private_file(path: &Path, require_private: bool, follow: bool) -> Option<Vec<u8>> {
    use std::io::Read as _;
    use std::os::unix::fs::{MetadataExt as _, OpenOptionsExt as _};
    let flags = if follow { libc::O_NONBLOCK } else { libc::O_NOFOLLOW | libc::O_NONBLOCK };
    let file = std::fs::OpenOptions::new().read(true).custom_flags(flags).open(path).ok()?;
    let metadata = file.metadata().ok()?;
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    if !metadata.is_file()
        || metadata.uid() != uid
        || (require_private && metadata.mode() & 0o077 != 0)
        || metadata.len() > SIZE_LIMIT
    {
        return None;
    }
    let mut data = Vec::new();
    file.take(SIZE_LIMIT + 1).read_to_end(&mut data).ok()?;
    (data.len() as u64 <= SIZE_LIMIT).then_some(data)
}
