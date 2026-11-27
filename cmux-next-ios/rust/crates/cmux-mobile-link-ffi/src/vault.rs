//! The cmux vault on the iPhone (cmuxterm-hq `docs/design/e2e-vault.md`): the person's secrets
//! and env values, end to end encrypted, with this phone as one of their enrolled devices.
//!
//! The logic is `cmux-vault-e2e`'s [`Vault`]: crypto, planning, `.env` parsing. This file is its
//! surface for Swift:
//!
//! - [`VaultHttp`] is implemented by the app: one request to `/v1/cloud/vault` as the signed-in
//!   person, over the account's own Cloud path (bearer and build space are the app's).
//! - [`VaultKeyStore`] is implemented by the app: this phone's vault device record in the
//!   Keychain (this device only, after first unlock). Rust encodes it; Swift keeps the bytes.
//! - [`PhoneVault`] runs each operation on its own thread with a time budget, so nothing waits on
//!   the main thread and no call runs unbounded.
//!
//! A value goes in (Add, Edit, an imported `.env`'s text) and never comes back out: every answer
//! is names, scopes, revisions, device labels and safety codes, with values shown as `••••••••`.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use cmux_vault_e2e::client::{
    self as vault_client, DeviceRecord, DeviceStore, Failure, Http, Vault, VaultRef,
};
use cmux_vault_e2e::{Scope, b64, dotenv};
use serde::Serialize;
use serde_json::Value;
use zeroize::Zeroizing;

/// One request to the vault routes. `path` starts with `/v1/cloud/vault`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct VaultHttpRequest {
    pub method: String,
    pub path: String,
    /// This phone's vault device id, sent as `x-cmux-vault-device` (the server answers that
    /// device's wrap of the vault key).
    pub device: Option<String>,
    /// A JSON body, when the request has one. It holds sealed bytes only, never a value.
    pub body: Option<String>,
    /// Give up after this long.
    pub timeout_ms: u64,
}

/// The service's answer, whatever its status.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct VaultHttpReply {
    pub status: u16,
    pub body: String,
}

/// A request that got no answer, or a Keychain that could not be read or written.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum VaultBridgeError {
    #[error("{message}")]
    Failed { message: String },
}

impl From<uniffi::UnexpectedUniFFICallbackError> for VaultBridgeError {
    fn from(error: uniffi::UnexpectedUniFFICallbackError) -> Self {
        Self::Failed { message: error.reason }
    }
}

/// The app's HTTP path to the vault routes as the signed-in person.
#[uniffi::export(with_foreign)]
#[async_trait::async_trait]
pub trait VaultHttp: Send + Sync {
    async fn send(&self, request: VaultHttpRequest) -> Result<VaultHttpReply, VaultBridgeError>;
}

/// This phone's vault device record, one Keychain item (this device only, after first unlock).
#[uniffi::export(with_foreign)]
pub trait VaultKeyStore: Send + Sync {
    /// The record's bytes, or nil when this phone never turned the vault on.
    fn load(&self) -> Result<Option<Vec<u8>>, VaultBridgeError>;
    fn save(&self, record: Vec<u8>) -> Result<(), VaultBridgeError>;
}

/// Why an operation failed.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum VaultError {
    /// No answer (no network, the time budget ran out). The same call may work later.
    #[error("no answer: {message}")]
    Unreachable { message: String },
    /// The vault refused: a stable code (`vault.not_approved`, `vault.bad_name`, …) and words
    /// free of any value.
    #[error("{code}: {message}")]
    Refused { code: String, message: String },
}

impl From<Failure> for VaultError {
    fn from(failure: Failure) -> Self {
        if failure.code == "vault.transport" {
            Self::Unreachable { message: failure.message }
        } else {
            Self::Refused { code: failure.code, message: failure.message }
        }
    }
}

/// How long one operation may take, all its requests together.
pub const OPERATION_BUDGET: Duration = Duration::from_secs(45);
/// How long a sync may take: one GET each for the vault and the machines, one PUT per machine.
pub const SYNC_BUDGET: Duration = Duration::from_secs(60);
/// How long one request may take.
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(20);

/// The [`Http`] the vault client sends through: the app's [`VaultHttp`], each request blocking
/// this operation's own thread, none sent after the budget ran out.
struct Bridge {
    http: Arc<dyn VaultHttp>,
    runtime: tokio::runtime::Runtime,
    deadline: Instant,
}

impl Http for Bridge {
    fn send(
        &self,
        method: &str,
        path: &str,
        headers: &[(&str, &str)],
        body: Option<&Value>,
    ) -> Result<(u16, Value), String> {
        let left = self.deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Err("the vault did not answer in time".to_owned());
        }
        let device = headers
            .iter()
            .find(|(name, _)| *name == vault_client::DEVICE_HEADER)
            .map(|(_, value)| (*value).to_owned());
        let request = VaultHttpRequest {
            method: method.to_owned(),
            path: path.to_owned(),
            device,
            body: body.map(Value::to_string),
            timeout_ms: u64::try_from(left.min(REQUEST_TIMEOUT).as_millis()).unwrap_or(20_000),
        };
        let http = Arc::clone(&self.http);
        let reply = self
            .runtime
            .block_on(async move { http.send(request).await })
            .map_err(|_| "cmux Cloud did not answer".to_owned())?;
        let value = if reply.body.trim().is_empty() {
            Value::Null
        } else {
            serde_json::from_str(&reply.body).unwrap_or(Value::Null)
        };
        Ok((reply.status, value))
    }
}

/// The record's bytes: the device id, a newline, the private key in base64url. Wiped when dropped.
fn encode_record(id: &str, private_key: &[u8]) -> Zeroizing<Vec<u8>> {
    let mut out = Zeroizing::new(Vec::with_capacity(id.len() + 1 + 44));
    out.extend_from_slice(id.as_bytes());
    out.push(b'\n');
    out.extend_from_slice(b64::encode(private_key).as_bytes());
    out
}

fn decode_record(bytes: &[u8]) -> Option<DeviceRecord> {
    let text = std::str::from_utf8(bytes).ok()?;
    let (id, key) = text.split_once('\n')?;
    let valid_id = id.starts_with("dev_")
        && id.len() <= 64
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b));
    let key = Zeroizing::new(b64::decode(key.trim())?);
    (valid_id && key.len() == 32).then(|| (id.to_owned(), key))
}

/// The [`DeviceStore`] over the app's [`VaultKeyStore`].
struct KeyStore(Arc<dyn VaultKeyStore>);

impl DeviceStore for KeyStore {
    fn load(&self) -> Result<Option<DeviceRecord>, String> {
        match self.0.load() {
            Ok(None) => Ok(None),
            Ok(Some(bytes)) => {
                let bytes = Zeroizing::new(bytes);
                decode_record(&bytes).map(Some).ok_or_else(|| "this iPhone's vault key is damaged".to_owned())
            }
            Err(_) => Err("the Keychain could not be read (is the iPhone unlocked?)".to_owned()),
        }
    }

    fn save(&self, id: &str, private_key: &[u8]) -> Result<(), String> {
        let record = encode_record(id, private_key);
        self.0
            .save(record.to_vec())
            .map_err(|_| "the Keychain could not keep this iPhone's vault key".to_owned())
    }
}

/// The scope wire text for what the person picked: `all` (every machine), `repo` with
/// `owner/name`, or `machine` with `vm_…`. Nil when the target is not one the vault takes.
#[uniffi::export]
pub fn vault_scope(kind: String, target: String) -> Option<String> {
    let target = target.trim();
    let text = match kind.as_str() {
        "all" => "*".to_owned(),
        "repo" => format!("repo:{target}"),
        "machine" => format!("machine:{target}"),
        _ => return None,
    };
    Scope::parse(&text).map(|scope| scope.wire())
}

/// Whether the vault keeps `name` (an environment name that the shell, the loader and cmux
/// do not own).
#[uniffi::export]
pub fn vault_valid_name(name: String) -> bool {
    cmux_vault_e2e::valid_name(&name)
}

/// What a sync did: `off` (this phone holds no vault key), `pending` (not approved yet),
/// `busy` (another sync is running), `done` with one row per machine.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct SyncAnswer {
    outcome: &'static str,
    machines: Vec<vault_client::MachineSync>,
}

/// The names a `.env` sets, for the person to pick from: never a value.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct ImportPreview {
    rows: Vec<vault_client::PreviewRow>,
    #[serde(rename = "skippedLines")]
    skipped_lines: Vec<usize>,
}

fn json_text<T: Serialize>(value: &T) -> Result<String, VaultError> {
    serde_json::to_string(value).map_err(|_| VaultError::Refused {
        code: "vault.encode".to_owned(),
        message: "the answer could not be written".to_owned(),
    })
}

fn bad_scope() -> Failure {
    Failure::new("vault.bad_scope", "pick every machine, a repo as owner/name, or a machine vm_…")
}

/// The person's vault on this phone.
#[derive(uniffi::Object)]
pub struct PhoneVault {
    http: Arc<dyn VaultHttp>,
    store: Arc<dyn VaultKeyStore>,
    /// The label the person's other devices see (`Leo's iPhone`).
    label: String,
    /// True while a sync runs: a second one answers `busy` instead of sealing twice.
    syncing: Arc<AtomicBool>,
}

type PhoneClient<'a> = Vault<'a, Bridge, KeyStore>;

impl PhoneVault {
    /// Runs `op` on its own thread against a client whose requests stop after `budget`.
    async fn run<T, F>(&self, budget: Duration, op: F) -> Result<T, VaultError>
    where
        T: Send + 'static,
        F: FnOnce(&PhoneClient<'_>) -> Result<T, Failure> + Send + 'static,
    {
        let (tx, rx) = tokio::sync::oneshot::channel();
        let http = Arc::clone(&self.http);
        let store = Arc::clone(&self.store);
        let label = self.label.clone();
        let spawned = std::thread::Builder::new().name("cmux-vault".to_owned()).spawn(move || {
            let answer = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
                Ok(runtime) => {
                    let bridge = Bridge { http, runtime, deadline: Instant::now() + budget };
                    let store = KeyStore(store);
                    let client = Vault {
                        http: &bridge,
                        store: &store,
                        vault: VaultRef::personal(),
                        kind: "iphone".to_owned(),
                        label,
                        now_ms: vault_client::system_now_ms,
                    };
                    op(&client)
                }
                Err(_) => Err(Failure::new("vault.transport", "the vault could not start")),
            };
            let _ = tx.send(answer);
        });
        if spawned.is_err() {
            return Err(VaultError::Unreachable { message: "the vault could not start".to_owned() });
        }
        rx.await
            .map_err(|_| VaultError::Unreachable { message: "the vault stopped".to_owned() })?
            .map_err(VaultError::from)
    }
}

#[uniffi::export]
impl PhoneVault {
    #[uniffi::constructor]
    pub fn new(http: Arc<dyn VaultHttp>, store: Arc<dyn VaultKeyStore>, label: String) -> Arc<Self> {
        let label = label.trim();
        let label = if label.is_empty() { "iPhone" } else { label };
        Arc::new(Self {
            http,
            store,
            label: label.chars().take(64).collect(),
            syncing: Arc::new(AtomicBool::new(false)),
        })
    }

    /// The vault as this phone sees it: the JSON of `cmux_vault_e2e::client::Status`
    /// (`{vault, state, epoch, deviceId, safetyCode, devices:[…], items:[…]}`); `state` is `off`,
    /// `pending`, `active` or `not_enrolled`. Never makes a key.
    pub async fn status(&self) -> Result<String, VaultError> {
        let status = self.run(OPERATION_BUDGET, |vault| vault.status()).await?;
        json_text(&status)
    }

    /// Turn the vault on for this phone: the first device makes the vault; a later one asks to
    /// join and waits for an approve by its safety code. Answers the new status.
    pub async fn turn_on(&self) -> Result<String, VaultError> {
        let status = self.run(OPERATION_BUDGET, |vault| vault.enroll()).await?;
        json_text(&status)
    }

    /// Approve the waiting device whose safety code is `code`. Answers the device's JSON.
    pub async fn approve(&self, code: String) -> Result<String, VaultError> {
        let device = self.run(OPERATION_BUDGET, move |vault| vault.approve(&code)).await?;
        json_text(&device)
    }

    /// Remove a device, then rotate the vault key. Answers the new epoch.
    pub async fn remove_device(&self, device_id: String) -> Result<u64, VaultError> {
        self.run(OPERATION_BUDGET, move |vault| vault.remove_device(&device_id)).await
    }

    /// Keep `value` for `name` in `scope` (wire text, from [`vault_scope`]), the app syncs after it
    /// (`sync`). Answers the item's revision.
    pub async fn set(&self, name: String, scope: String, value: String) -> Result<u64, VaultError> {
        let value = Zeroizing::new(value);
        let revision = self
            .run(OPERATION_BUDGET, move |vault| {
                let scope = Scope::parse(&scope).ok_or_else(bad_scope)?;
                vault.set(&name, &scope, &value)
            })
            .await?;
        Ok(revision)
    }

    /// Remove `name` from `scope`. Answers how many items went.
    pub async fn remove(&self, name: String, scope: String) -> Result<u32, VaultError> {
        let count = self
            .run(OPERATION_BUDGET, move |vault| {
                let scope = Scope::parse(&scope).ok_or_else(bad_scope)?;
                vault.remove(&name, Some(&scope))
            })
            .await?;
        Ok(u32::try_from(count).unwrap_or(u32::MAX))
    }

    /// The names `env_text` sets, in file order, each with whether the vault keeps such a name and
    /// whether it already holds it in `scope`: `{rows:[{name, line, keepable, alreadyKept,
    /// masked}], skippedLines:[n]}`. No value comes back.
    pub async fn import_preview(&self, env_text: String, scope: String) -> Result<String, VaultError> {
        let env_text = Zeroizing::new(env_text);
        let preview = self
            .run(OPERATION_BUDGET, move |vault| {
                let scope = Scope::parse(&scope).ok_or_else(bad_scope)?;
                let parsed = dotenv::parse(&env_text);
                let kept = vault.status()?.items;
                Ok(ImportPreview {
                    rows: vault_client::preview(&parsed, &kept, &scope),
                    skipped_lines: parsed.skipped_lines,
                })
            })
            .await?;
        json_text(&preview)
    }

    /// Keep the picked `names` of `env_text` in `scope`, the app syncs after it. Answers how
    /// many were kept.
    pub async fn import_names(
        &self,
        env_text: String,
        names: Vec<String>,
        scope: String,
    ) -> Result<u32, VaultError> {
        let env_text = Zeroizing::new(env_text);
        let count = self
            .run(OPERATION_BUDGET, move |vault| {
                let scope = Scope::parse(&scope).ok_or_else(bad_scope)?;
                let parsed = dotenv::parse(&env_text);
                let picked: Vec<(&str, &Scope, &str)> = parsed
                    .entries
                    .iter()
                    .filter(|entry| names.contains(&entry.name))
                    .map(|entry| (entry.name.as_str(), &scope, entry.value.as_str()))
                    .collect();
                if picked.is_empty() {
                    return Err(Failure::new("vault.nothing_picked", "pick at least one name"));
                }
                Ok(vault.set_many(&picked)?.len())
            })
            .await?;
        Ok(u32::try_from(count).unwrap_or(u32::MAX))
    }

    /// Seal each of the person's machines (spares too) what it should hold, where its delivery
    /// is missing or old. Sends nothing when this phone holds no vault key, and one sync at a
    /// time: `{outcome: "off" | "pending" | "busy" | "done", machines: [{id, name, spare, outcome,
    /// names}]}`. Bounded by [`SYNC_BUDGET`].
    pub async fn sync(&self) -> Result<String, VaultError> {
        if self.syncing.swap(true, Ordering::SeqCst) {
            return json_text(&SyncAnswer { outcome: "busy", machines: Vec::new() });
        }
        let syncing = Arc::clone(&self.syncing);
        let answer = self
            .run(SYNC_BUDGET, |vault| {
                if vault.store.load().map_err(|m| Failure::new("vault.device_store", m))?.is_none() {
                    return Ok(SyncAnswer { outcome: "off", machines: Vec::new() });
                }
                match vault.sync() {
                    Ok(machines) => Ok(SyncAnswer { outcome: "done", machines }),
                    Err(failure)
                        if failure.code == "vault.not_approved" || failure.code == "vault.stale_wrap" =>
                    {
                        Ok(SyncAnswer { outcome: "pending", machines: Vec::new() })
                    }
                    Err(failure) => Err(failure),
                }
            })
            .await;
        syncing.store(false, Ordering::SeqCst);
        json_text(&answer?)
    }
}

#[cfg(test)]
#[path = "vault_tests.rs"]
mod tests;
