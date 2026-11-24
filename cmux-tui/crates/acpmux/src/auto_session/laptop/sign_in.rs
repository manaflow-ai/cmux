//! The owner's sign-in for Auto mode's calls: the cmux app mints a short-lived token for the
//! signed-in person (`cmux --json auth token`, the way `hosted_mcp.rs` gets its token), and the
//! token goes only to the cmux API that issued it.
//!
//! A token is kept until shortly before it expires, and a refusal is kept for a short while, so
//! renewals of many chats ask the app once. The app is asked in a task of its own: a call that
//! gives up waiting does not stop the ask, and the next call finds its answer.

use std::ffi::OsString;
use std::future::Future;
use std::process::Stdio;
use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_cloud_api::auto_sessions::{OwnerSignIn, SignedIn};
use cmux_cloud_client::backend::Backend;
use cmux_cloud_environment::Environment;
use tokio::sync::Mutex;

/// How long the app may take to answer.
const MINT_TIMEOUT: Duration = Duration::from_secs(35);

/// A token is asked for again this long before it expires.
const REFRESH_EARLY: Duration = Duration::from_secs(60);

/// How long a refusal is kept before the app is asked again.
const REFUSED_FOR: Duration = Duration::from_secs(20);

/// The most the CLI's answer may be.
const MAX_ANSWER: usize = 64 << 10;

/// What the app last said, and until when it stands.
#[derive(Clone)]
struct Held {
    answer: Result<SignedIn, String>,
    until: Instant,
}

/// The person's sign-in, asked of the cmux app through the `cmux` CLI.
pub(super) struct AppSignIn {
    cmux: OsString,
    /// Whether this daemon is a DEV build's own (it runs from inside that app's bundle).
    dev_build: bool,
    held: Arc<Mutex<Option<Held>>>,
    /// Owns the tasks that ask the app.
    scope: Arc<cmux_scope::Scope>,
}

impl AppSignIn {
    /// The CLI from this process's environment (`CMUX_BIN`, else `cmux` on the PATH). `scope`
    /// owns the tasks that ask it.
    pub fn from_env(scope: cmux_scope::Scope) -> AppSignIn {
        let cmux = std::env::var_os(crate::hosted_mcp::CMUX_BIN_ENV)
            .filter(|path| !path.is_empty())
            .unwrap_or_else(|| OsString::from("cmux"));
        let dev_build = std::env::current_exe().is_ok_and(|exe| crate::daemon::in_dev_bundle(&exe));
        AppSignIn { cmux, dev_build, held: Arc::new(Mutex::new(None)), scope: Arc::new(scope) }
    }
}

/// The cmux API a token may go to: one of cmux's own, named by the token's issuer. A pull
/// request's preview of the API (`cmux-api-preview-<n>`, which signs in as development does)
/// is one of them: it is how a change to the store is tried before it lands. So is a DEV
/// build's own backend (one tag's stack on the dev VM, by its tailnet or public origin), for a
/// daemon that is a DEV build's own (`dev_build`): the app takes such a backend from no other
/// bundle. Nothing else is: not a loopback address, and not a tailnet one outside a DEV build.
fn api_of(issuer: &str, dev_build: bool) -> Option<String> {
    let issuer = issuer.trim().trim_end_matches('/');
    let own = [Backend::Production, Backend::Staging, Backend::Development]
        .into_iter()
        .map(Backend::owner_api)
        .find(|api| api.trim_end_matches('/') == issuer);
    if let Some(api) = own {
        return Some(api.to_owned());
    }
    // An origin, never an environment's bare name (`preview-42`), which `parse` also reads.
    if !issuer.starts_with("https://") {
        return None;
    }
    match Environment::parse(issuer) {
        Ok(preview @ Environment::Preview(_)) => Some(preview.configuration().api_origin),
        Ok(Environment::Tailnet(origin)) if dev_build => Some(origin),
        _ => None,
    }
}

/// The app's `auth.token` answer as the CLI prints it.
fn parse(stdout: &[u8], now: Instant, dev_build: bool) -> Held {
    #[derive(serde::Deserialize)]
    struct Answer {
        #[serde(default)]
        access_token: Option<String>,
        #[serde(default)]
        expires_in: Option<f64>,
        #[serde(default)]
        api_origin: Option<String>,
        #[serde(default)]
        team: Option<String>,
    }
    let refused = |why: &str| Held { answer: Err(why.to_owned()), until: now + REFUSED_FOR };
    let Ok(answer) = serde_json::from_slice::<Answer>(stdout) else {
        return refused("cmux could not get a sign-in token");
    };
    let token = answer.access_token.unwrap_or_default();
    if token.is_empty() || token.len() > 16_384 || !token.bytes().all(|b| b.is_ascii_graphic()) {
        return refused("cmux could not get a sign-in token");
    }
    let Some(api) = api_of(&answer.api_origin.unwrap_or_default(), dev_build) else {
        return refused("this cmux sign-in is for a cmux Cloud that has no Auto mode");
    };
    // No expiry said: the app's tokens last ten minutes.
    let lifetime = answer
        .expires_in
        .filter(|seconds| seconds.is_finite() && *seconds >= 0.0)
        .map_or(Duration::from_secs(600), |seconds| Duration::from_secs_f64(seconds.min(86_400.0)));
    let team = answer.team.filter(|team| !team.trim().is_empty());
    Held {
        answer: Ok(SignedIn { api, credential: token, team }),
        until: now + lifetime.saturating_sub(REFRESH_EARLY),
    }
}

/// Runs `cmux --json auth token` and reads its answer.
async fn mint(cmux: &OsString, dev_build: bool) -> Held {
    let refused =
        |why: &str| Held { answer: Err(why.to_owned()), until: Instant::now() + REFUSED_FOR };
    let run = tokio::process::Command::new(cmux)
        .args(["--json", "auth", "token"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .output();
    match tokio::time::timeout(MINT_TIMEOUT, run).await {
        Err(_) => refused("the cmux app did not answer the sign-in request"),
        Ok(Err(_)) => refused("the cmux app is not reachable to sign the request"),
        Ok(Ok(output)) if !output.status.success() || output.stdout.len() > MAX_ANSWER => {
            refused("cmux is not signed in")
        }
        Ok(Ok(output)) => parse(&output.stdout, Instant::now(), dev_build),
    }
}

impl OwnerSignIn for AppSignIn {
    fn sign_in(&self) -> impl Future<Output = Result<SignedIn, String>> + Send {
        let (held, cmux, scope) = (self.held.clone(), self.cmux.clone(), self.scope.clone());
        let dev_build = self.dev_build;
        async move {
            let mut slot = held.lock_owned().await;
            if let Some(known) = slot.as_ref().filter(|known| Instant::now() < known.until) {
                return known.answer.clone();
            }
            // In a task of its own, which keeps the slot: a caller that stops waiting leaves
            // the ask running, and whoever comes next waits for it.
            let asking = scope.spawn_named("auto-session sign-in", async move {
                let fresh = mint(&cmux, dev_build).await;
                let answer = fresh.answer.clone();
                *slot = Some(fresh);
                answer
            });
            asking.await.map_err(|error| error.to_string())?
        }
    }

    fn refused(&self, credential: &str) {
        // A slot that is busy is being asked for a new token already.
        if let Ok(mut slot) = self.held.try_lock()
            && slot.as_ref().is_some_and(|known| {
                known.answer.as_ref().is_ok_and(|s| s.credential == credential)
            })
        {
            *slot = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_token_goes_only_to_the_api_that_issued_it() {
        let now = Instant::now();
        let issuer = Backend::Production.owner_api();
        let good = format!(
            r#"{{"access_token":"tok","expires_in":600,"api_origin":"{issuer}/","team":"t1"}}"#
        );
        let held = parse(good.as_bytes(), now, false);
        let signed_in = held.answer.unwrap();
        assert_eq!(signed_in.api, issuer);
        assert_eq!(signed_in.team.as_deref(), Some("t1"));
        assert_eq!(held.until, now + Duration::from_secs(540));

        let elsewhere = r#"{"access_token":"tok","api_origin":"https://example.com"}"#;
        assert!(parse(elsewhere.as_bytes(), now, true).answer.is_err());
        // A pull request's preview of the API is cmux's own; a look-alike host is not.
        let preview = "https://cmux-api-preview-42.debussy.workers.dev";
        let at_preview = format!(r#"{{"access_token":"tok","api_origin":"{preview}/"}}"#);
        assert_eq!(parse(at_preview.as_bytes(), now, false).answer.unwrap().api, preview);
        for other in [
            "https://cmux-api-preview-42.debussy.workers.dev.example.com",
            "https://cmux-api-preview-x.debussy.workers.dev",
            "http://127.0.0.1:8787",
            "preview-42",
            "dev",
        ] {
            let json = format!(r#"{{"access_token":"tok","api_origin":"{other}"}}"#);
            assert!(parse(json.as_bytes(), now, true).answer.is_err(), "{other}");
        }
        // A tag's own stack on the dev VM: a DEV build's daemon only.
        let stack = "https://cmux-dev-backend-1.tail137216.ts.net:4321";
        let at_stack = format!(r#"{{"access_token":"tok","api_origin":"{stack}/"}}"#);
        assert_eq!(parse(at_stack.as_bytes(), now, true).answer.unwrap().api, stack);
        assert!(parse(at_stack.as_bytes(), now, false).answer.is_err());
        let none = r#"{"access_token":"","api_origin":"x"}"#;
        assert!(parse(none.as_bytes(), now, false).answer.is_err());
        assert!(parse(b"not json", now, false).answer.is_err());
    }
}
