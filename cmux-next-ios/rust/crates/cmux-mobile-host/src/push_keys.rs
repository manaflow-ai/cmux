//! The push keys of paired phones (PROTOCOL.md "Keys at pairing"): a phone
//! sends its push key, signed by its identity key, on every `auth`; once
//! `auth` passes, hostd keeps it here and seals that phone's notifications
//! to it (`sealed_notify.rs`).
//!
//! An entry counts only while the Mac still pairs that phone with the same
//! identity key ([`PushKeys::for_paired`]): a removed or re-keyed phone gets
//! no sealed push. The file (`<state>/push-keys.json`, mode 0600) holds
//! public keys only.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::{Mutex, PoisonError};

use serde::{Deserialize, Serialize};

use crate::pairing::DeviceTrust;

/// At most this many phones are remembered (more than a person pairs).
const LIMIT: usize = 64;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Entry {
    identity_key: String,
    push_key: String,
    /// The order it was last set in: the one set longest ago goes first past the limit.
    #[serde(default)]
    updated: u64,
}

/// Paired phones' push keys, by phone device id.
#[derive(Debug, Default)]
pub struct PushKeys {
    path: Option<PathBuf>,
    keys: Mutex<BTreeMap<String, Entry>>,
}

impl PushKeys {
    /// Kept in memory only (tests, unsupervised hostd).
    pub fn memory() -> Self {
        Self::default()
    }

    /// Kept in `path`; starts with what the file holds (nothing when it is
    /// missing or unreadable).
    pub fn load(path: PathBuf) -> Self {
        let keys = std::fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<BTreeMap<String, Entry>>(&bytes).ok())
            .unwrap_or_default();
        Self { path: Some(path), keys: Mutex::new(keys) }
    }

    /// Records `push_key` for `phone`, which proved `identity_key`.
    pub fn set(&self, phone: &str, identity_key: &str, push_key: &str) {
        let mut keys = self.keys.lock().unwrap_or_else(PoisonError::into_inner);
        if keys.get(phone).is_some_and(|e| e.identity_key == identity_key && e.push_key == push_key) {
            return;
        }
        let next = keys.values().map(|e| e.updated).max().unwrap_or(0) + 1;
        let entry =
            Entry { identity_key: identity_key.to_owned(), push_key: push_key.to_owned(), updated: next };
        if keys.len() >= LIMIT && !keys.contains_key(phone) {
            // Drop the one set longest ago; it comes back on that phone's next link.
            if let Some(oldest) =
                keys.iter().min_by_key(|(id, e)| (e.updated, (*id).clone())).map(|(id, _)| id.clone())
            {
                keys.remove(&oldest);
            }
        }
        keys.insert(phone.to_owned(), entry);
        self.save(&keys);
    }

    /// Forgets `phone`'s push key.
    pub fn remove(&self, phone: &str) {
        let mut keys = self.keys.lock().unwrap_or_else(PoisonError::into_inner);
        if keys.remove(phone).is_some() {
            self.save(&keys);
        }
    }

    /// `(phone, push key)` for every phone the Mac pairs now with the same
    /// identity key that vouched for its push key.
    pub fn for_paired(&self, trust: &DeviceTrust) -> Vec<(String, String)> {
        let keys = self.keys.lock().unwrap_or_else(PoisonError::into_inner);
        trust
            .devices
            .iter()
            .filter_map(|device| {
                let entry = keys.get(&device.id)?;
                (entry.identity_key == device.identity_key)
                    .then(|| (device.id.clone(), entry.push_key.clone()))
            })
            .collect()
    }

    fn save(&self, keys: &BTreeMap<String, Entry>) {
        let Some(path) = &self.path else { return };
        if let Err(error) = write_private(path, &serde_json::to_vec(keys).unwrap_or_default()) {
            tracing::warn!(%error, "could not save phone push keys");
        }
    }
}

/// Writes `bytes` to `path` with mode 0600, through a temporary file and a rename.
pub fn write_private(path: &std::path::Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write as _;
    use std::os::unix::fs::OpenOptionsExt as _;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let temporary = path.with_extension("tmp");
    let mut file =
        std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&temporary)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    std::fs::rename(&temporary, path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pairing::TrustedDevice;

    fn trust(devices: &[(&str, &str)]) -> DeviceTrust {
        DeviceTrust {
            devices: devices
                .iter()
                .map(|(id, key)| TrustedDevice {
                    id: (*id).into(),
                    identity_key: (*key).into(),
                    approval_key: String::new(),
                })
                .collect(),
            denied: vec![],
        }
    }

    #[test]
    fn only_phones_still_paired_with_the_same_identity_count() {
        let keys = PushKeys::memory();
        keys.set("p1", "id1", "push1");
        keys.set("p2", "id2", "push2");
        keys.set("p3", "id3", "push3");
        // p2 re-keyed its identity; p3 was removed.
        let paired = keys.for_paired(&trust(&[("p1", "id1"), ("p2", "other")]));
        assert_eq!(paired, vec![("p1".to_owned(), "push1".to_owned())]);
        keys.remove("p1");
        assert!(keys.for_paired(&trust(&[("p1", "id1")])).is_empty());
    }

    #[test]
    fn past_the_limit_the_key_set_longest_ago_goes() {
        let keys = PushKeys::memory();
        // "p00" sorts first but was set again last: "p01" is the oldest now.
        for i in 0..LIMIT {
            keys.set(&format!("p{i:02}"), "id", "push");
        }
        keys.set("p00", "id", "push-new");
        keys.set("zz", "id", "push");
        let paired = keys.for_paired(&trust(&[("p00", "id"), ("p01", "id"), ("zz", "id")]));
        assert_eq!(
            paired,
            vec![("p00".to_owned(), "push-new".to_owned()), ("zz".to_owned(), "push".to_owned())]
        );
    }

    #[test]
    fn the_file_is_private_and_survives_a_restart() {
        use std::os::unix::fs::PermissionsExt as _;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("push-keys.json");
        PushKeys::load(path.clone()).set("p1", "id1", "push1");
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        let again = PushKeys::load(path);
        assert_eq!(again.for_paired(&trust(&[("p1", "id1")])), vec![("p1".to_owned(), "push1".to_owned())]);
    }
}
