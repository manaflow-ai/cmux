//! `acpmux machine vault pull|status|forget|keep|drop` (also `acpmux host vault ...`):
//! the person's vault on this joined machine (`crate::vault`), and the keys
//! agents keep here themselves (`keep`, `drop`: `crate::vault::kept`).
//!
//! `pull --json` prints one object: `state` is `ok` (with `env`, the names
//! present after the pull), `not_granted` (the person has not shared the vault
//! with this machine; exit 0) or `off` (the hub has no vault; exit 0). Any
//! other result is the error envelope with a `vault.*` code. `store` says
//! where the values are kept: `keychain`, `secret-service`, or `memory` (no
//! usable OS store, as on a headless Mac over ssh: the daemon keeps them in
//! memory). No field ever holds a value.
//!
//! `pull` and `forget` are done by the running daemon (`_acpmux/vault_pull`,
//! `_acpmux/vault_forget`), so the one process that gives agents the values
//! is the one that stores them. With no daemon running, a machine with a
//! usable OS store pulls here; one without starts the daemon.

use std::path::Path;
use std::sync::Arc;

use anyhow::Result;
use cmux_json::JsonGet as _;
use serde_json::{Value, json};
use zeroize::Zeroizing;

use crate::cli::errors::{AppError, Code};
use crate::cli::output::print_json;
use crate::vault::pull::{self, Failure, Outcome};
use crate::vault::store::{OsStore, SecretStore};

/// The running daemon predates `_acpmux/vault_pull` and the OS store is not
/// usable here, so nothing can keep the values.
pub const DAEMON_OUTDATED: &str = "vault.daemon_outdated";

fn failure(failure: Failure) -> anyhow::Error {
    let message = match failure.code.as_str() {
        "vault.not_joined" => "this machine is not joined; run `acpmux machine join` first",
        "vault.revoked" => "this machine's credential is revoked; its vault entries were removed",
        crate::vault::store::UNAVAILABLE => {
            "no OS secret store (Keychain or Secret Service) here; vault env is not stored in files"
        }
        "vault.busy" => "another vault pull is running",
        DAEMON_OUTDATED => {
            "the running acpmux daemon is older than this CLI and cannot keep vault env (this machine has no usable OS secret store); run `acpmux daemon restart`, then pull again"
        }
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

/// The outcome JSON with `store`.
fn with_store(mut out: Value, store: &str) -> Value {
    if let Some(map) = out.as_object_mut() {
        map.insert("store".into(), json!(store));
    }
    out
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

fn print_outcome(outcome: &Value, store: &str, json_out: bool) {
    if json_out {
        print_json(&with_store(outcome.clone(), store));
        return;
    }
    let names = |key: &str| -> Vec<String> {
        outcome
            .get(key)
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|v| v.as_str().map(str::to_owned))
            .collect()
    };
    let (env, stored, deleted) = (names("env"), names("stored"), names("deleted"));
    match outcome.get("state").and_then(Value::as_str).unwrap_or_default() {
        "not_granted" => {
            println!(
                "the vault is not shared with this machine (grant it in cmux, then pull again)"
            )
        }
        "off" => println!("this hub has no vault yet"),
        "forgotten" => {
            println!("vault: removed {} env var(s) from this machine", deleted.len())
        }
        _ => println!(
            "vault: {} env var(s){}{}{}",
            env.len(),
            if env.is_empty() { String::new() } else { format!(": {}", env.join(", ")) },
            if stored.is_empty() && deleted.is_empty() {
                String::new()
            } else {
                format!(" ({} stored, {} removed)", stored.len(), deleted.len())
            },
            if store == "memory" { " [kept in the daemon's memory]" } else { "" }
        ),
    }
    for failed in outcome.get("failed").and_then(Value::as_array).into_iter().flatten() {
        eprintln!(
            "{}: {}",
            failed.get_str("name").unwrap_or_default(),
            failed.get_str("code").unwrap_or_default()
        );
    }
}

/// `machine vault pull`.
pub async fn pull_cmd(json_out: bool) -> Result<()> {
    let reply = by_daemon(crate::rpc::method::MUX_VAULT_PULL, || async {
        let store: Arc<dyn SecretStore> = Arc::new(OsStore);
        pull::pull(crate::config::home(), store, true).await
    })
    .await;
    finish(reply?, json_out)
}

/// `machine vault forget`.
pub async fn forget_cmd(json_out: bool) -> Result<()> {
    let reply = by_daemon(crate::rpc::method::MUX_VAULT_FORGET, || async {
        let home = crate::config::home();
        tokio::task::spawn_blocking(move || pull::forget(&home, &OsStore)).await.unwrap_or_else(
            |_| Err(Failure { code: "vault.internal".into(), deleted: Vec::new(), outcome: None }),
        )
    })
    .await;
    finish(reply?, json_out)
}

/// Ask the running daemon to do `method`. With none running (or one too old
/// to know it), `here` does it in this process when the OS store is usable;
/// otherwise the daemon is started and asked, since only it can keep the
/// values (in memory). A running daemon too old to know `method` is not
/// asked again: that is [`DAEMON_OUTDATED`], which says to restart it.
async fn by_daemon<F, Fut>(method: &str, here: F) -> Result<Value>
where
    F: FnOnce() -> Fut,
    Fut: std::future::Future<Output = Result<Outcome, Failure>>,
{
    let ask =
        |client: Arc<crate::client::Client>| async move { client.request(method, json!({})).await };
    let mut outdated = false;
    if let Ok(client) = crate::daemon::connect(false).await {
        match ask(client).await {
            Ok(reply) => return Ok(reply),
            Err(e) => outdated = method_not_found(&e),
        }
    }
    if tokio::task::spawn_blocking(crate::vault::store::os_usable).await.unwrap_or(false) {
        return Ok(crate::server::vault_reply(OsStore.kind(), &here().await));
    }
    if outdated {
        return Err(failure(Failure {
            code: DAEMON_OUTDATED.into(),
            deleted: Vec::new(),
            outcome: None,
        }));
    }
    let client = crate::daemon::connect(true).await?;
    ask(client).await
}

/// Whether the daemon answered that it has no such method (an older daemon).
pub(crate) fn method_not_found(e: &anyhow::Error) -> bool {
    e.downcast_ref::<crate::client::DaemonError>().is_some_and(|d| d.0.code == -32601)
}

/// Print a pull's or forget's reply (`server/vault.rs`). A failed or partial
/// one prints its outcome (with `failed`) on stdout when it has one and
/// exits 1 with the error envelope.
fn finish(reply: Value, json_out: bool) -> Result<()> {
    let store = reply.get("store").and_then(Value::as_str).unwrap_or("unknown").to_owned();
    if let Some(outcome) = reply.get("outcome").filter(|o| !o.is_null()) {
        print_outcome(outcome, &store, json_out);
    }
    let Some(f) = reply.get("failure").filter(|f| !f.is_null()) else { return Ok(()) };
    Err(failure(Failure {
        code: f.get("code").and_then(Value::as_str).unwrap_or("vault.internal").to_owned(),
        deleted: f
            .get("deleted")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|v| v.as_str().map(str::to_owned))
            .collect(),
        outcome: None,
    }))
}

/// Where this machine keeps vault values: the running daemon's store
/// (`_acpmux/vault_status`), since it is the one that keeps them. With no
/// daemon, or one too old to say, what this process finds: the OS store's
/// kind, or `memory` when it cannot take a write here.
async fn store_kind() -> String {
    if let Ok(client) = crate::daemon::connect(false).await
        && let Ok(reply) = client.request(crate::rpc::method::MUX_VAULT_STATUS, json!({})).await
        && let Some(store) = reply.get("store").and_then(Value::as_str)
    {
        return store.to_owned();
    }
    let here = || if crate::vault::store::os_usable() { OsStore.kind() } else { "memory" };
    tokio::task::spawn_blocking(here).await.unwrap_or("unknown").to_owned()
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
        // Delivery, never a value: `proxy` agents get `cmux-secret://NAME`
        // (filled by the egress proxy toward `allowedHosts` only); `env` is
        // the value itself in the agent env, the weaker opt-out.
        "env": state.env.iter().map(|(name, r)| json!({
            "name": name,
            "revision": r.revision,
            "delivery": if r.proxy.is_some() { "proxy" } else { "env" },
            "allowedHosts": r.proxy.clone().unwrap_or_default(),
        })).collect::<Vec<_>>(),
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
    let kind = store_kind().await;
    let kept = crate::vault::kept::read(&home);
    let mut out = status_json(joined, &state, &kind, claude, codex);
    if let Some(map) = out.as_object_mut() {
        map.insert("kept".into(), kept_json(&kept));
    }
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
    println!("secret store: {kind}");
    if state.env.is_empty() {
        println!("env: none");
    }
    for (name, record) in &state.env {
        match &record.proxy {
            Some(hosts) if hosts.is_empty() => {
                println!("env {name}: proxy: no hosts (placeholder only)")
            }
            Some(hosts) => println!("env {name}: proxy: {}", hosts.join(", ")),
            None => println!("env {name}: env (weaker: agents can read the value)"),
        }
    }
    for (name, record) in &kept.env {
        match &record.proxy {
            Some(hosts) => println!("kept {name}: proxy: {}", hosts.join(", ")),
            None => println!("kept {name}: env (weaker: agents can read the value)"),
        }
    }
    for h in out.get("harnesses").and_then(Value::as_array).into_iter().flatten() {
        let (id, step) =
            (h.get_str("harness").unwrap_or_default(), h.get_str("signIn").unwrap_or_default());
        match h.get("signedIn").and_then(Value::as_str).unwrap_or("unknown") {
            "yes" => println!("{id}: signed in"),
            "no" => println!("{id}: not signed in here; {step}"),
            _ => println!("{id}: sign-in not visible here; if it fails, {step}"),
        }
    }
    Ok(())
}

/// The message of a `keep` or `drop` failure code.
fn kept_failure(code: &str) -> anyhow::Error {
    let message = match code {
        "vault.bad_name" => {
            "not a name an agent may keep: an env name ending in _TOKEN, _KEY, _KEY_ID, _SECRET, _PASSWORD, _PAT or _CREDENTIALS; never a model provider key, sign-in or base URL"
        }
        "vault.bad_host" => "a --host is not a host pattern (example.com or *.example.com)",
        "vault.too_many_hosts" => "at most 16 --host patterns",
        "vault.no_hosts" => {
            "name where the key may go with --host H (repeatable), or give it to agents as is with --env (weaker)"
        }
        "vault.empty_value" => {
            "no value on stdin: pipe the key in, `<command that prints it> | acpmux machine vault keep NAME --host H`"
        }
        "vault.bad_value" => "the value is too long or has a NUL byte",
        "vault.value_on_terminal" => {
            "the value comes on stdin from a pipe, never typed here or in argv: `<command that prints it> | acpmux machine vault keep NAME --host H`"
        }
        "vault.name_taken" => {
            "the person's vault already gives this machine that name; pick another"
        }
        crate::vault::store::UNAVAILABLE => {
            "no usable OS secret store (Keychain or Secret Service) here; kept keys are never stored in files"
        }
        "vault.busy" => "another vault change is running",
        _ => "the kept key could not be saved",
    };
    AppError::new(Code::Runtime, code, message).into()
}

/// `machine vault keep NAME (--host H... | --env)`: the value from stdin.
pub async fn keep_cmd(name: String, hosts: Vec<String>, env: bool, json_out: bool) -> Result<()> {
    use crate::vault::kept;
    use std::io::{IsTerminal as _, Read as _};
    kept::check_name(&name).map_err(kept_failure)?;
    let proxy = match (env, hosts.is_empty()) {
        (true, _) => None,
        (false, true) => return Err(kept_failure("vault.no_hosts")),
        (false, false) => Some(kept::check_hosts(&hosts).map_err(kept_failure)?),
    };
    if std::io::stdin().is_terminal() {
        return Err(kept_failure("vault.value_on_terminal"));
    }
    // The longest value and its line break (`\r\n`), plus one byte that
    // tells a longer input, which is refused rather than cut. Room for it up
    // front: a grown buffer would leave a copy behind.
    let fits = kept::MAX_VALUE_BYTES + 2;
    let mut raw = Zeroizing::new(Vec::with_capacity(fits + 1));
    std::io::stdin()
        .take(u64::try_from(fits + 1).unwrap_or(u64::MAX))
        .read_to_end(&mut raw)
        .map_err(|_| kept_failure("vault.bad_value"))?;
    if raw.len() > fits {
        return Err(kept_failure("vault.bad_value"));
    }
    let text = std::str::from_utf8(&raw).map_err(|_| kept_failure("vault.bad_value"))?;
    // A command's output ends with a line break that is not part of the key.
    let value = Zeroizing::new(text.trim_end_matches(['\n', '\r']).to_owned());
    let home = crate::config::home();
    let pulled: Vec<String> = pull::read_state(&home).env.into_keys().collect();
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX));
    let shown = proxy.clone();
    tokio::task::spawn_blocking(move || {
        if !crate::vault::store::os_usable() {
            return Err(crate::vault::store::UNAVAILABLE);
        }
        kept::keep(&home, &OsStore, &name, &value, proxy, &pulled, now_ms).map(|()| name)
    })
    .await
    .unwrap_or(Err("vault.internal"))
    .map_err(kept_failure)
    .map(|name| print_kept(&name, shown.as_deref(), json_out))
}

fn print_kept(name: &str, hosts: Option<&[String]>, json_out: bool) {
    if json_out {
        print_json(&json!({
            "name": name,
            "delivery": if hosts.is_some() { "proxy" } else { "env" },
            "allowedHosts": hosts.unwrap_or_default(),
        }));
        return;
    }
    match hosts {
        Some(hosts) => println!(
            "kept {name}: new agents here get {}, sent only to {}",
            cmux_vault_egress::placeholder(name),
            hosts.join(", ")
        ),
        None => println!(
            "kept {name}: new agents here get the value itself (weaker: agents can read it)"
        ),
    }
}

/// `machine vault drop NAME`: a kept key, from the record and the store.
pub async fn drop_cmd(name: String, json_out: bool) -> Result<()> {
    let home = crate::config::home();
    let shown = name.clone();
    let had =
        tokio::task::spawn_blocking(move || crate::vault::kept::remove(&home, &OsStore, &name))
            .await
            .unwrap_or(Err("vault.internal"))
            .map_err(kept_failure)?;
    if json_out {
        print_json(&json!({"name": shown, "removed": had}));
    } else if had {
        println!("dropped {shown}: new agents here no longer get it");
    } else {
        println!("no kept key named {shown}");
    }
    Ok(())
}

/// The kept keys, as `status` lists them: names and delivery, never a value.
pub fn kept_json(kept: &crate::vault::kept::Kept) -> Value {
    json!(
        kept.env
            .iter()
            .map(|(name, r)| json!({
                "name": name,
                "delivery": if r.proxy.is_some() { "proxy" } else { "env" },
                "allowedHosts": r.proxy.clone().unwrap_or_default(),
                "keptAt": r.kept_at,
            }))
            .collect::<Vec<_>>()
    )
}
