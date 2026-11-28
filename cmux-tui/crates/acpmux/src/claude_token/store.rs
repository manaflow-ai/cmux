//! Where a model key or captured token goes: a login Keychain item under [`SERVICE`], named
//! `<store>-<8 hex>`. On macOS acpmux writes it through the Security framework ([`macos`]), so the
//! item trusts acpmux's signature and not `/usr/bin/security`; `secret-tool` off macOS. The
//! connection keeps only its `keychain:SERVICE/ACCOUNT` reference. The app and `cmux cloud connect`
//! store through the daemon (`connections/secret.store`) for that reason.

use std::path::PathBuf;

#[cfg(target_os = "macos")]
pub mod macos;

/// The Keychain service every model key and token cmux adds is stored under.
pub const SERVICE: &str = "cmux-model-key";

/// The Keychain account for a new item: `<store>-<8 hex>`.
pub fn new_account(store: &str) -> String {
    let id = uuid::Uuid::new_v4().simple().to_string();
    format!("{store}-{}", id.get(..8).unwrap_or(&id))
}

fn os() -> &'static str {
    if cfg!(target_os = "macos") { "macos" } else { "linux" }
}

/// Whether `account` is one [`new_account`] makes: lowercase letters, digits and dashes, then
/// `-<8 hex>`. A caller's account is checked before it reaches the Keychain.
pub fn is_account(account: &str) -> bool {
    account.len() <= 64
        && account.rsplit_once('-').is_some_and(|(store, hex)| {
            !store.is_empty()
                && store.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
                && hex.len() == 8
                && hex.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        })
}

/// `value` into the login Keychain as `SERVICE`/`account`.
pub fn keychain_store(account: &str, label: &str, value: &str) -> Result<(), String> {
    if value.contains(['\n', '\r', '\0']) {
        return Err("the value has a line break or NUL byte; a secret must be one line".into());
    }
    if cfg!(target_os = "macos") {
        #[cfg(target_os = "macos")]
        return macos::store(account, label, value);
    }
    use crate::cli::harness_secret::{run_store, store_item};
    let command = store_item(os(), SERVICE, account, label, value).map_err(|e| e.to_string())?;
    run_store(&command).map_err(|error| format!("cannot store it in the Keychain: {error}"))
}

/// Deletes `SERVICE`/`account` from the login Keychain; an item already gone is fine. An item
/// still there afterwards is an error (its reason, never its value), so no caller reports a key
/// removed that is not.
pub fn keychain_delete(account: &str) -> Result<(), String> {
    // An item acpmux wrote goes through the framework; only one `security` wrote runs `security`.
    #[cfg(target_os = "macos")]
    match macos::delete(account) {
        macos::Deleted::Gone => return Ok(()),
        macos::Deleted::Kept(why) => {
            tracing::warn!(%account, why, "a model key's Keychain item could not be removed");
            return Err(why.to_owned());
        }
        macos::Deleted::Legacy => {}
    }
    let argv: &[&str] = if os() == "macos" {
        &["/usr/bin/security", "delete-generic-password", "-s", SERVICE, "-a", account]
    } else {
        &["secret-tool", "clear", "service", SERVICE, "account", account]
    };
    let Some((program, rest)) = argv.split_first() else { return Ok(()) };
    let status = cmux_process::Command::new(program)
        .args(rest)
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::null())
        .status()
        .map_err(|error| format!("cannot run {program}: {error}"))?;
    // `security` exits 44 for an item already gone.
    if status.success() || status.code() == Some(44) {
        Ok(())
    } else {
        Err(format!("{program} could not remove the Keychain item ({status})"))
    }
}

/// A store for a captured token: the Keychain, or owner-only files in tests.
pub trait Store: Send + Sync {
    /// Stores `value` as a new item; its secret reference and the account to delete it by.
    fn store(&self, label: &str, value: &str) -> Result<(String, String), String>;
    fn delete(&self, account: &str);
}

/// The login Keychain.
pub struct Keychain;

impl Store for Keychain {
    fn store(&self, label: &str, value: &str) -> Result<(String, String), String> {
        let account = new_account("claude-token");
        keychain_store(&account, label, value)?;
        Ok((format!("keychain:{SERVICE}/{account}"), account))
    }

    fn delete(&self, account: &str) {
        let _ = keychain_delete(account);
    }
}

/// Owner-only files in `dir`, as `file:PATH` references (tests).
pub struct Files(pub PathBuf);

impl Store for Files {
    fn store(&self, _label: &str, value: &str) -> Result<(String, String), String> {
        let account = new_account("claude-token");
        let path = self.0.join(&account);
        std::fs::write(&path, format!("{value}\n")).map_err(|e| e.to_string())?;
        crate::router_socket::owner_only(&path);
        Ok((format!("file:{}", path.display()), account))
    }

    fn delete(&self, account: &str) {
        let _ = std::fs::remove_file(self.0.join(account));
    }
}

#[cfg(test)]
#[path = "store_account_tests.rs"]
mod account_tests;
