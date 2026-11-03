//! `acpmux machine vault pull|status|forget` (also `acpmux host vault ...`):
//! the person's vault on this joined machine (`crate::vault`).
//!
//! `pull --json` prints one object: `state` is `ok` (with `env`, the names
//! present after the pull), `not_granted` (the person has not shared the vault
//! with this machine; exit 0) or `off` (the hub has no vault; exit 0). Any
//! other result is the error envelope with a `vault.*` code. No field ever
//! holds a value.

use std::path::Path;
use std::sync::Arc;

use anyhow::Result;
use serde_json::{Value, json};

use crate::cli::errors::{AppError, Code};
use crate::cli::output::print_json;
use crate::vault::pull::{self, Failure, Outcome};
use crate::vault::store::{OsStore, SecretStore};

fn failure(failure: Failure) -> anyhow::Error {
    let message = match failure.code.as_str() {
        "vault.not_joined" => "this machine is not joined; run `acpmux machine join` first",
        "vault.revoked" => "this machine's credential is revoked; its vault entries were removed",
        crate::vault::store::UNAVAILABLE => {
            "no OS secret store (Keychain or Secret Service) here; vault env is not stored in files"
        }
        "vault.busy" => "another vault pull is running",
        _ => "vault pull failed",
    };
    let message = if failure.code == pull::PARTIAL {
        "some vault entries could not be stored or removed; see `failed`"
    } else {
        message
    };
    let mut error = AppError::new(Code::Runtime, &failure.code, message);
    if !failure.deleted.is_empty() {
        error.data = Some(json!({"deleted": failure.deleted}));
    }
    error.into()
}

#[cfg(test)]
pub(crate) fn failure_for_test(f: Failure) -> anyhow::Error {
    failure(f)
}

pub fn outcome_json(outcome: &Outcome) -> Value {
    json!({
        "state": outcome.state,
        "hub": outcome.hub,
        "env": outcome.env,
        "stored": outcome.stored,
        "deleted": outcome.deleted,
        "failed": outcome.failed.iter().map(|(name, code)| json!({"name": name, "code": code})).collect::<Vec<_>>(),
        "refused": outcome.refused,
    })
}

fn print_outcome(outcome: &Outcome, json_out: bool) {
    if json_out {
        print_json(&outcome_json(outcome));
        return;
    }
    match outcome.state {
        "not_granted" => {
            println!(
                "the vault is not shared with this machine (grant it in cmux, then pull again)"
            )
        }
        "off" => println!("this hub has no vault yet"),
        "forgotten" => {
            println!("vault: removed {} env var(s) from this machine", outcome.deleted.len())
        }
        _ => println!(
            "vault: {} env var(s){}{}",
            outcome.env.len(),
            if outcome.env.is_empty() {
                String::new()
            } else {
                format!(": {}", outcome.env.join(", "))
            },
            if outcome.stored.is_empty() && outcome.deleted.is_empty() {
                String::new()
            } else {
                format!(" ({} stored, {} removed)", outcome.stored.len(), outcome.deleted.len())
            }
        ),
    }
    for (name, code) in &outcome.failed {
        eprintln!("{name}: {code}");
    }
}

/// `machine vault pull`.
pub async fn pull_cmd(json_out: bool) -> Result<()> {
    let store: Arc<dyn SecretStore> = Arc::new(OsStore);
    let outcome = pull::pull(crate::config::home(), store, true).await;
    finish(outcome, json_out)
}

/// `machine vault forget`.
pub async fn forget_cmd(json_out: bool) -> Result<()> {
    let home = crate::config::home();
    let outcome =
        tokio::task::spawn_blocking(move || pull::forget(&home, &OsStore)).await.map_err(|_| {
            failure(Failure { code: "vault.internal".into(), deleted: Vec::new(), outcome: None })
        })?;
    finish(outcome, json_out)
}

/// Print what a pull or forget did. A partial one prints its outcome (with
/// `failed`) on stdout and still exits 1 with the error envelope.
fn finish(result: Result<Outcome, Failure>, json_out: bool) -> Result<()> {
    match result {
        Ok(outcome) => {
            print_outcome(&outcome, json_out);
            Ok(())
        }
        Err(f) => {
            if let Some(outcome) = &f.outcome {
                print_outcome(outcome, json_out);
            }
            Err(failure(f))
        }
    }
}

/// Whether a harness is signed in on this machine: a presence check of its own
/// login store, never a read of the token.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SignedIn {
    Yes,
    No,
    Unknown,
}

impl SignedIn {
    pub fn word(self) -> &'static str {
        match self {
            SignedIn::Yes => "yes",
            SignedIn::No => "no",
            SignedIn::Unknown => "unknown",
        }
    }
}

fn nonempty_file(path: &Path) -> bool {
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.len() > 0)
}

fn home_dir() -> Option<std::path::PathBuf> {
    std::env::var_os("HOME").map(std::path::PathBuf::from).or_else(dirs::home_dir)
}

/// Claude Code: `<CLAUDE_CONFIG_DIR or ~/.claude>/.credentials.json`, and on
/// macOS whether the Keychain item `Claude Code-credentials` exists (its
/// attributes only, no password read; bounded, and never from the daemon).
pub fn claude_signed_in(keychain: impl FnOnce() -> SignedIn) -> SignedIn {
    let dir = std::env::var_os("CLAUDE_CONFIG_DIR")
        .map(std::path::PathBuf::from)
        .or_else(|| home_dir().map(|h| h.join(".claude")));
    if dir.is_some_and(|d| nonempty_file(&d.join(".credentials.json"))) {
        return SignedIn::Yes;
    }
    if cfg!(target_os = "macos") { keychain() } else { SignedIn::No }
}

/// The macOS Keychain item's presence. `security` without `-g`/`-w` prints
/// attributes only; its output is discarded.
pub fn claude_keychain_item() -> SignedIn {
    use std::process::{Command, Stdio};
    use wait_timeout::ChildExt;
    let Ok(mut child) = Command::new("/usr/bin/security")
        .args(["find-generic-password", "-s", "Claude Code-credentials"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    else {
        return SignedIn::Unknown;
    };
    match child.wait_timeout(std::time::Duration::from_secs(5)) {
        Ok(Some(status)) if status.success() => SignedIn::Yes,
        Ok(Some(status)) if status.code() == Some(44) => SignedIn::No,
        Ok(Some(_)) => SignedIn::Unknown,
        _ => {
            let _ = child.kill();
            let _ = child.wait();
            SignedIn::Unknown
        }
    }
}

/// Codex: `<CODEX_HOME or ~/.codex>/auth.json` exists. Codex set to keep its
/// login in the OS keyring (`cli_auth_credentials_store`) cannot be seen here.
pub fn codex_signed_in() -> SignedIn {
    let Some(dir) = std::env::var_os("CODEX_HOME")
        .map(std::path::PathBuf::from)
        .or_else(|| home_dir().map(|h| h.join(".codex")))
    else {
        return SignedIn::Unknown;
    };
    if nonempty_file(&dir.join("auth.json")) {
        return SignedIn::Yes;
    }
    let keyring = std::fs::read_to_string(dir.join("config.toml"))
        .ok()
        .and_then(|text| text.parse::<toml::Table>().ok())
        .and_then(|t| {
            t.get("cli_auth_credentials_store").and_then(|v| v.as_str()).map(str::to_owned)
        })
        .is_some_and(|store| store != "file");
    if keyring { SignedIn::Unknown } else { SignedIn::No }
}

/// The status object, from what this machine has (no hub request).
pub fn status_json(
    joined: bool,
    state: &crate::vault::plan::State,
    store_kind: &str,
    claude: SignedIn,
    codex: SignedIn,
) -> Value {
    let harness = |id: &str, signed_in: SignedIn, step: &str| json!({"harness": id, "signedIn": signed_in.word(), "signIn": step});
    json!({
        "capability": crate::vault::CAPABILITY,
        "joined": joined,
        "hub": if state.hub.is_empty() { Value::Null } else { json!(state.hub) },
        "pulledAt": state.pulled_at,
        "lastResult": state.last_result,
        "secretStore": store_kind,
        "env": state.env.iter().map(|(name, r)| json!({"name": name, "revision": r.revision})).collect::<Vec<_>>(),
        // Subscription logins are never in the vault: each machine signs in itself.
        "harnesses": [
            harness("claude", claude, "run `claude`, then /login"),
            harness("codex", codex, "run `codex login`"),
        ],
    })
}

/// `machine vault status`.
pub async fn status_cmd(json_out: bool) -> Result<()> {
    let home = crate::config::home();
    let joined = crate::cli::cloud_join::machine_credential()
        .ok()
        .flatten()
        .is_some_and(|record| !record.revoked);
    let state = pull::read_state(&home);
    let (claude, codex) =
        tokio::task::spawn_blocking(|| (claude_signed_in(claude_keychain_item), codex_signed_in()))
            .await
            .unwrap_or((SignedIn::Unknown, SignedIn::Unknown));
    let out = status_json(joined, &state, OsStore.kind(), claude, codex);
    if json_out {
        print_json(&out);
        return Ok(());
    }
    println!("joined: {}", if joined { "yes" } else { "no" });
    println!(
        "last pull: {} ({})",
        state.pulled_at.map_or_else(|| "never".to_owned(), |ms| ms.to_string()),
        state.last_result.as_deref().unwrap_or("none")
    );
    println!("secret store: {}", OsStore.kind());
    println!(
        "env: {}",
        if state.env.is_empty() {
            "none".to_owned()
        } else {
            state.env.keys().cloned().collect::<Vec<_>>().join(", ")
        }
    );
    for h in out["harnesses"].as_array().into_iter().flatten() {
        let signed = h["signedIn"].as_str().unwrap_or("unknown");
        let id = h["harness"].as_str().unwrap_or("");
        let step = h["signIn"].as_str().unwrap_or("");
        match signed {
            "yes" => println!("{id}: signed in"),
            "no" => println!("{id}: not signed in here; {step}"),
            _ => println!("{id}: sign-in not visible here; if it fails, {step}"),
        }
    }
    Ok(())
}
