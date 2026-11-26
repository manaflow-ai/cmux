//! Where the phone keeps a tailnet key, and what the key sheet tells the person.
//!
//! - The app's own Keychain, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, synchronizable false:
//!   never in iCloud Keychain, never in a backup restored to another phone.
//! - One item per tailnet (account = the login server's host, or `tailscale`), so a second
//!   tailnet never overwrites the first.
//! - Forget deletes the item and logs the node out ([`KeyStore::forget`]).
//! - Keys never reach a log: [`cmux_tailnet_join::Secret`] redacts itself in `Debug` and serde.

use cmux_tailnet_join::{Checked, Credential, Invalid, JoinRequest, Secret};
use serde::{Deserialize, Serialize};

/// The Keychain item's service, shared by every tailnet's item.
pub const KEYCHAIN_SERVICE: &str = "dev.cmux.tailnet";
/// The account of Tailscale's own control server.
pub const TAILSCALE_ACCOUNT: &str = "tailscale";

/// The Keychain attributes the Swift store writes, spelled out so the rule is tested here.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeychainItem {
    pub service: String,
    pub account: String,
    /// `kSecAttrAccessible`.
    pub accessible: String,
    /// `kSecAttrSynchronizable`.
    pub synchronizable: bool,
}

/// The tailnet a key belongs to: the login server's host (with its port), or Tailscale's.
pub fn tailnet_account(control_url: Option<&str>) -> String {
    let Some(url) = control_url else {
        return TAILSCALE_ACCOUNT.to_owned();
    };
    let rest = url.split_once("://").map_or(url, |(_, rest)| rest);
    let host = rest.split('/').next().unwrap_or_default().to_ascii_lowercase();
    if host.is_empty() { TAILSCALE_ACCOUNT.to_owned() } else { host }
}

pub fn keychain_item(control_url: Option<&str>) -> KeychainItem {
    KeychainItem {
        service: KEYCHAIN_SERVICE.to_owned(),
        account: tailnet_account(control_url),
        accessible: "kSecAttrAccessibleWhenUnlockedThisDeviceOnly".to_owned(),
        synchronizable: false,
    }
}

/// The app's Keychain, behind a trait (Swift implements it through the FFI; tests use memory).
pub trait KeyStore {
    fn save(&mut self, item: &KeychainItem, key: &Secret) -> Result<(), String>;
    fn load(&self, item: &KeychainItem) -> Result<Option<Secret>, String>;
    fn delete(&mut self, item: &KeychainItem) -> Result<(), String>;
}

/// What the phone stores beside the key (in settings, never the Keychain): enough to show the
/// tailnet in the list and to rebuild the item.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PhoneTailnet {
    pub control_url: Option<String>,
    pub hostname: Option<String>,
    pub ephemeral: bool,
    /// Plain http to this login server, chosen by the person for this server only.
    #[serde(default)]
    pub allow_http: bool,
}

impl PhoneTailnet {
    pub fn item(&self) -> KeychainItem {
        keychain_item(self.control_url.as_deref())
    }

    /// The join request for the embedded node, checked by the same rules as the Mac and VMs
    /// (https unless chosen for this server, the key's shape).
    pub fn request(&self, key: Secret) -> Result<Checked, Invalid> {
        JoinRequest {
            credential: Credential::AuthKey { key },
            control_url: self.control_url.clone(),
            hostname: self.hostname.clone(),
            tags: Vec::new(),
            ssh: false,
            ephemeral: self.ephemeral,
            serve: Vec::new(),
            switch_from_other_tailnet: false,
            allow_http: self.allow_http,
        }
        .check()
    }

    /// Checks the key, then saves it. A key that fails the check is never stored.
    pub fn save_key(&self, store: &mut dyn KeyStore, key: Secret) -> Result<Checked, String> {
        let checked = self.request(key.clone()).map_err(|e| e.0)?;
        store.save(&self.item(), &key)?;
        Ok(checked)
    }

    /// Forget: delete the key. The caller logs the node out and removes its state
    /// (`tsnet::TsnetNode::leave`) in the same action.
    pub fn forget(&self, store: &mut dyn KeyStore) -> Result<(), String> {
        store.delete(&self.item())
    }
}

/// How the person described the key they made (the key sheet's toggles, which mirror the admin
/// console's). The phone cannot read these from the key itself.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyKind {
    pub reusable: bool,
    pub ephemeral: bool,
}

/// One line the key sheet shows.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "level", content = "text", rename_all = "kebab-case")]
pub enum Advice {
    Suggest(String),
    Warn(String),
}

/// The key sheet's advice: always suggest an ephemeral, single-use key with a short expiry; warn
/// when the key is reusable (anyone who reads it can add machines until it expires) or not
/// ephemeral (a lost phone stays a node until someone removes it), and on plain http.
pub fn key_advice(kind: KeyKind, tailnet: &PhoneTailnet) -> Vec<Advice> {
    let mut out = vec![Advice::Suggest(
        "Make an ephemeral, single-use key with a short expiry for this phone.".to_owned(),
    )];
    if kind.reusable {
        out.push(Advice::Warn(
            "This key is reusable: anyone who sees it can add machines to your tailnet until it expires. Prefer a single-use key."
                .to_owned(),
        ));
    }
    if !kind.ephemeral {
        out.push(Advice::Warn(
            "This key is not ephemeral: if the phone is lost, it stays on your tailnet until you remove it."
                .to_owned(),
        ));
    }
    if tailnet.allow_http {
        out.push(Advice::Warn(
            "Plain http sends the key unencrypted to this server. Use it only for a server you trust the path to."
                .to_owned(),
        ));
    }
    out
}
