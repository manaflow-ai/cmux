//! Stack Auth tokens for the Mac: a fixed access token, or a refresh token
//! exchanged for fresh access tokens at
//! `POST <stack api>/api/v1/auth/sessions/current/refresh`.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, bail};
use base64::Engine;
use tokio::sync::{Mutex, watch};

use crate::control;

pub const DEFAULT_STACK_API: &str = "https://api.stack-auth.com";
/// The dev Stack project (PROTOCOL.md).
pub const DEFAULT_STACK_PROJECT: &str = "454ecd03-1db2-4050-845e-4ce5b0cd9895";

#[derive(Debug, Clone)]
pub enum TokenSource {
    /// A fixed access token (expires; fine for tests and short runs).
    Access(String),
    /// Access tokens the supervising app sends over stdin (`control`); the
    /// app keeps the Stack session, hostd never sees a refresh token.
    Supplied(watch::Receiver<Option<String>>),
    Refresh {
        refresh_token: String,
        project_id: String,
        publishable_key: Option<String>,
        api: String,
    },
}

pub struct Tokens {
    source: TokenSource,
    cached: Mutex<Option<(String, Option<u64>)>>,
    /// A supplied token the backend refused; never handed out again.
    refused: Mutex<Option<String>>,
    http: reqwest::Client,
}

/// How long hostd waits for the app's first token before it asks for one.
const FIRST_TOKEN_GRACE: Duration = Duration::from_secs(2);

/// How long hostd waits for the app to answer `need_token`.
const SUPPLIED_TOKEN_WAIT: Duration = Duration::from_secs(30);

/// The claims cmux-mobile-host reads from a Stack access token (no verification:
/// the token is the Mac's own; the backend verifies it).
#[derive(Debug, Clone, Default)]
pub struct Claims {
    pub sub: Option<String>,
    pub exp: Option<u64>,
}

pub fn claims(token: &str) -> Claims {
    let Some(payload) = token.split('.').nth(1) else { return Claims::default() };
    let Ok(bytes) = base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(payload.trim_end_matches('='))
    else {
        return Claims::default();
    };
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(&bytes) else { return Claims::default() };
    Claims {
        sub: value.get("sub").and_then(|v| v.as_str()).map(str::to_owned),
        exp: value.get("exp").and_then(serde_json::Value::as_u64),
    }
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or(Duration::ZERO).as_secs()
}

impl Tokens {
    pub fn new(source: TokenSource) -> Self {
        cmux_mobile_link::install_crypto_provider();
        Self { source, cached: Mutex::new(None), refused: Mutex::new(None), http: reqwest::Client::new() }
    }

    /// A current access token, refreshed 60 s before it expires.
    pub async fn access_token(&self) -> Result<String> {
        if let TokenSource::Supplied(receiver) = &self.source {
            return self.supplied_token(receiver.clone()).await;
        }
        let mut cached = self.cached.lock().await;
        if let Some((token, exp)) = cached.as_ref()
            && exp.is_none_or(|exp| exp > now() + 60)
        {
            return Ok(token.clone());
        }
        let token = match &self.source {
            TokenSource::Access(token) => token.clone(),
            TokenSource::Supplied(_) => bail!("supplied tokens are read above"),
            TokenSource::Refresh { refresh_token, project_id, publishable_key, api } => {
                let mut request = self
                    .http
                    .post(format!("{}/api/v1/auth/sessions/current/refresh", api.trim_end_matches('/')))
                    .header("content-type", "application/json")
                    .header("x-stack-project-id", project_id)
                    .header("x-stack-access-type", "client")
                    .header("x-stack-refresh-token", refresh_token)
                    .body("{}");
                if let Some(key) = publishable_key {
                    request = request.header("x-stack-publishable-client-key", key);
                }
                let response = request.send().await.context("Stack refresh request")?;
                let status = response.status();
                let body: serde_json::Value = response.json().await.unwrap_or_default();
                match body.get("access_token").and_then(|v| v.as_str()) {
                    Some(token) if status.is_success() => token.to_owned(),
                    _ => bail!("Stack refresh failed with {status}"),
                }
            }
        };
        let exp = claims(&token).exp;
        *cached = Some((token.clone(), exp));
        Ok(token)
    }

    /// The app's current token while it has more than 60 s left and was not
    /// refused; otherwise asks the app (`need_token`) and waits for a new one.
    async fn supplied_token(&self, mut receiver: watch::Receiver<Option<String>>) -> Result<String> {
        let deadline = tokio::time::Instant::now() + SUPPLIED_TOKEN_WAIT;
        let mut asked = false;
        loop {
            let current = receiver.borrow_and_update().clone();
            if let Some(token) = current {
                let refused = self.refused.lock().await.as_deref() == Some(token.as_str());
                if !refused && claims(&token).exp.is_none_or(|exp| exp > now() + 60) {
                    return Ok(token);
                }
            }
            if !asked {
                // At start the app's first token is already on its way: ask only if it
                // does not arrive soon, or when the token we have expired or was refused.
                if receiver.borrow().is_none() {
                    match tokio::time::timeout(FIRST_TOKEN_GRACE, receiver.changed()).await {
                        Ok(Ok(())) => continue,
                        Ok(Err(_)) => bail!("the app closed the token channel"),
                        Err(_) => {}
                    }
                }
                control::emit(&control::Event::NeedToken);
                asked = true;
            }
            match tokio::time::timeout_at(deadline, receiver.changed()).await {
                Ok(Ok(())) => continue,
                Ok(Err(_)) => bail!("the app closed the token channel"),
                Err(_) => bail!("the app sent no access token"),
            }
        }
    }

    /// Forget the cached token (after the backend refused it).
    pub async fn invalidate(&self) {
        if let TokenSource::Supplied(receiver) = &self.source {
            let refused = receiver.borrow().clone();
            *self.refused.lock().await = refused;
        }
        *self.cached.lock().await = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_sub_and_exp() {
        let payload =
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(br#"{"sub":"user-1","exp":99}"#);
        let claims = claims(&format!("h.{payload}.s"));
        assert_eq!(claims.sub.as_deref(), Some("user-1"));
        assert_eq!(claims.exp, Some(99));
        assert!(super::claims("not-a-jwt").sub.is_none());
    }

    fn token(exp: u64) -> String {
        let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(format!(r#"{{"sub":"user-1","exp":{exp}}}"#).as_bytes());
        format!("h.{payload}.s")
    }

    #[tokio::test]
    async fn supplied_tokens_wait_for_a_fresh_one() {
        let (sender, receiver) = watch::channel(Some(token(now() + 10)));
        let tokens = Tokens::new(TokenSource::Supplied(receiver));
        let fresh = token(now() + 3600);
        let send = fresh.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(50)).await;
            sender.send_replace(Some(send));
            // Keep the channel open past the read.
            tokio::time::sleep(Duration::from_secs(1)).await;
        });
        assert_eq!(tokens.access_token().await.unwrap(), fresh);
    }

    #[tokio::test]
    async fn a_refused_supplied_token_is_not_reused() {
        let first = token(now() + 3600);
        let (sender, receiver) = watch::channel(Some(first.clone()));
        let tokens = Tokens::new(TokenSource::Supplied(receiver));
        assert_eq!(tokens.access_token().await.unwrap(), first);
        tokens.invalidate().await;
        let second = token(now() + 7200);
        let send = second.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(50)).await;
            sender.send_replace(Some(send));
            tokio::time::sleep(Duration::from_secs(1)).await;
        });
        assert_eq!(tokens.access_token().await.unwrap(), second);
    }
}
