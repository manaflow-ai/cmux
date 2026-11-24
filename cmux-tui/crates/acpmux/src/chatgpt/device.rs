//! ChatGPT device authorization as implemented by the upstream login crate:
//! https://github.com/openai/codex/blob/main/codex-rs/login/src/device_code_auth.rs
//! https://github.com/openai/codex/blob/main/codex-rs/login/src/server.rs
//! OpenAI returns pending as HTTP 403/404 and the CLI allows 15 minutes. For explicit
//! slow-down replies, increase the interval by 5 seconds per RFC 8628 §3.5.
//! https://www.rfc-editor.org/rfc/rfc8628.html#section-3.5

use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::Deserialize;
use serde_json::json;
use tokio::sync::watch;
use tokio::time::{Instant, timeout_at};

use super::{
    ATTEMPT_TTL, Attempt, Failure, Places, Service, Status, now_unix, oauth, sign_in_scope,
};

/// The person-facing challenge. Deliberately has no Debug representation.
#[derive(Clone)]
pub struct DeviceBegun {
    pub attempt: String,
    pub user_code: String,
    pub verification_url: String,
    pub expires_at: i64,
    pub interval: u64,
}

#[derive(Deserialize)]
struct UserCode {
    device_auth_id: String,
    #[serde(alias = "usercode")]
    user_code: String,
    // The upstream API sends seconds as a decimal string. RFC 8628 defaults to 5.
    interval: Option<String>,
}

#[derive(Deserialize)]
struct Authorization {
    authorization_code: String,
    #[serde(rename = "code_challenge")]
    _code_challenge: String,
    code_verifier: String,
}

impl Service {
    /// Requests one challenge and starts the daemon-owned wait for the person's approval.
    pub async fn begin_device(
        self: &Arc<Self>,
        places: Places,
        reauth: Option<String>,
        on_finish: impl FnOnce(&Status) + Send + 'static,
    ) -> Result<DeviceBegun, Failure> {
        let _begin = self.device_begin.lock().await;
        self.prune();
        let previous = self
            .attempts
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .values()
            .find_map(|a| {
                let (home, target, begun) = a.device_request.as_ref()?;
                (home == &places.home && target == &reauth
                    && begun.expires_at > now_unix() && *a.status.borrow() == Status::Pending)
                    .then(|| begun.clone())
            });
        if let Some(previous) = previous {
            return Ok(previous);
        }
        let attempt = oauth::random_token(18)?;
        let issuer = &self.oauth.endpoints.issuer;
        let url = format!("{issuer}/api/accounts/deviceauth/usercode");
        let (status, body) = self
            .oauth
            .post_json(
                &url,
                &json!({
                    "client_id": self.oauth.endpoints.client_id,
                }),
            )
            .await?;
        if !(200..300).contains(&status) {
            return Err(device_failure(status, oauth::error_code(&body)));
        }
        let invalid = || Failure::new("bad_reply", "invalid ChatGPT device challenge");
        let code: UserCode = serde_json::from_value(body).map_err(|_| invalid())?;
        if code.user_code.is_empty() || code.device_auth_id.is_empty() {
            return Err(invalid());
        }
        let interval = code
            .interval
            .as_deref()
            .map(|value| value.trim().parse::<u64>())
            .transpose()
            .map_err(|_| invalid())?
            .unwrap_or(5)
            .max(1);
        let expires = Instant::now() + ATTEMPT_TTL;
        let begun = DeviceBegun {
            attempt: attempt.clone(),
            user_code: code.user_code.clone(),
            verification_url: format!("{issuer}/codex/device"),
            expires_at: now_unix() + ATTEMPT_TTL.as_secs() as i64,
            interval,
        };
        let expires_at = begun.expires_at;
        let (status, _) = watch::channel(Status::Pending);
        let (cancel, mut cancelled) = watch::channel(false);
        let entry = Arc::new(Attempt {
            status,
            task: Mutex::new(None),
            device_cancel: Some(cancel),
            device_request: Some((places.home.clone(), reauth.clone(), begun.clone())),
            started: std::time::Instant::now(),
        });
        self.attempts.lock().unwrap_or_else(|p| p.into_inner()).insert(attempt, entry.clone());
        let service = self.clone();
        let _task = sign_in_scope().spawn_named("chatgpt device sign-in", async move {
            let request = async {
                let sign_in = service.poll_device(code, interval, expires, expires_at).await?;
                Ok::<_, Failure>((sign_in, service.oauth.save_slot().await))
            };
            let status = tokio::select! {
                biased;
                _ = cancelled.changed() => Status::Cancelled,
                outcome = timeout_at(expires, request) => match outcome {
                    Ok(Ok((sign_in, guard))) if Instant::now() < expires && now_unix() < expires_at => {
                        // Once the verified sign-in starts writing, report its actual outcome to
                        // Cancel too. Dropping a blocking write could report cancellation after saving.
                        match service.oauth.save_sign_in(places, reauth, sign_in, true, guard).await {
                            Ok(id) => Status::Done(id),
                            Err(error) => Status::failed(error),
                        }
                    }
                    Ok(Err(error)) => Status::failed(error),
                    _ => Status::Failed("expired_token".to_owned()),
                },
            };
            entry.status.send_replace(status.clone());
            on_finish(&status);
        });
        Ok(begun)
    }

    /// Cancels polling and waits for the daemon's final status.
    pub async fn cancel_device(&self, attempt: &str) -> Result<Status, Failure> {
        let entry = self.attempt(attempt, true)?;
        let mut status = entry.status.subscribe();
        if let Some(cancel) = &entry.device_cancel {
            cancel.send_replace(true);
        }
        let _ = status.wait_for(|s| *s != Status::Pending).await;
        let result = status.borrow().clone();
        Ok(result)
    }

    async fn poll_device(
        &self,
        code: UserCode,
        mut interval: u64,
        expires: Instant,
        expires_at: i64,
    ) -> Result<oauth::VerifiedSignIn, Failure> {
        let issuer = &self.oauth.endpoints.issuer;
        let url = format!("{issuer}/api/accounts/deviceauth/token");
        let body = json!({"device_auth_id": code.device_auth_id, "user_code": code.user_code});
        loop {
            let seconds_left = expires_at.saturating_sub(now_unix()).max(0) as u64;
            tokio::time::sleep(Duration::from_secs(interval.min(seconds_left))).await;
            if Instant::now() >= expires || now_unix() >= expires_at {
                return Err(Failure::new("expired_token", "the ChatGPT device code expired"));
            }
            let (status, answer) = match self.oauth.post_json(&url, &body).await {
                Ok((status, answer)) if status < 500 => (status, answer),
                Ok(_) => {
                    interval = interval.saturating_mul(2).min(60);
                    continue;
                }
                Err(error) if error.code == "network" => {
                    interval = interval.saturating_mul(2).min(60);
                    continue;
                }
                Err(error) => return Err(error),
            };
            match oauth::error_code(&answer) {
                Some("slow_down") => interval = interval.saturating_add(5),
                Some("authorization_pending") => {}
                Some(
                    "access_denied"
                    | "authorization_declined"
                    | "expired_token"
                    | "device_code_expired",
                ) => {
                    return Err(device_failure(status, oauth::error_code(&answer)));
                }
                _ if (200..300).contains(&status) => {
                    let auth: Authorization = serde_json::from_value(answer).map_err(|_| {
                        Failure::new("bad_reply", "invalid ChatGPT device poll reply")
                    })?;
                    if auth.authorization_code.is_empty() || auth.code_verifier.is_empty() {
                        return Err(Failure::new("bad_reply", "invalid ChatGPT device poll reply"));
                    }
                    match self.oauth.exchange(
                            &auth.authorization_code,
                            &auth.code_verifier,
                            &format!("{issuer}/deviceauth/callback"),
                            None,
                        ).await {
                        Err(error) if error.code == "network" => {
                            interval = interval.saturating_mul(2).min(60);
                        }
                        result => return result,
                    }
                }
                _ if status == 429 => interval = interval.saturating_add(5),
                _ if status == 403 || status == 404 => {}
                _ => return Err(device_failure(status, oauth::error_code(&answer))),
            }
        }
    }
}

fn device_failure(status: u16, reason: Option<&str>) -> Failure {
    let code = match reason {
        Some("access_denied" | "authorization_declined") => "access_denied",
        Some("expired_token" | "device_code_expired") => "expired_token",
        _ if status >= 500 => "network",
        _ => "device_auth_failed",
    };
    Failure::new(code, format!("ChatGPT device sign-in received HTTP {status}"))
}
