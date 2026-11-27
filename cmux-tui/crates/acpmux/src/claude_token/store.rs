//! Where a captured token goes: a login Keychain item (`security -i`, the value on its stdin only;
//! `secret-tool` off macOS) under [`SERVICE`], named `<store>-<8 hex>` as the app names them. The
//! connection keeps only its `keychain:SERVICE/ACCOUNT` reference. `cmux cloud connect` stores
//! through the same functions.

use std::path::PathBuf;

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

/// `value` into the login Keychain as `SERVICE`/`account`.
pub fn keychain_store(account: &str, label: &str, value: &str) -> Result<(), String> {
    use crate::cli::harness_secret::{run_store, store_item};
    let command = store_item(os(), SERVICE, account, label, value).map_err(|e| e.to_string())?;
    run_store(&command).map_err(|error| format!("cannot store it in the Keychain: {error}"))
}

/// Deletes `SERVICE`/`account` from the login Keychain; an item already gone is fine.
pub fn keychain_delete(account: &str) {
    let argv: &[&str] = if os() == "macos" {
        &["/usr/bin/security", "delete-generic-password", "-s", SERVICE, "-a", account]
    } else {
        &["secret-tool", "clear", "service", SERVICE, "account", account]
    };
    let Some((program, rest)) = argv.split_first() else { return };
    let _ = cmux_process::Command::new(program)
        .args(rest)
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::null())
        .status();
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
        keychain_delete(account);
    }
}

/// Owner-only files in `dir`, as `file:PATH` references (tests).
pub struct Files(pub PathBuf);

impl Store for Files {
    fn store(&self, _label: &str, value: &str) -> Result<(String, String), String> {
        let account = new_account("claude-token");
        let path = self.0.join(&account);
        std::fs::write(&path, format!("{value}\n")).map_err(|e| e.to_string())?;
        crate::private_file::owner_only(&path);
        Ok((format!("file:{}", path.display()), account))
    }

    fn delete(&self, account: &str) {
        let _ = std::fs::remove_file(self.0.join(account));
    }
}
