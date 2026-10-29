//! The acpmux node identity used by the Labs WireGuard transport.
//!
//! The key is raw Curve25519 private-key bytes in `node.wg.key`. The file is
//! created below [`crate::config::home`] after the same owner-only checks as
//! every other acpmux state file. Only the public half leaves this module.

use anyhow::{Context, Result, anyhow};
use base64::Engine;
use std::io::{Read, Write};
use std::path::Path;
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroizing;

const KEY_FILE: &str = "node.wg.key";

/// A node's WireGuard identity. The private key is retained only in a
/// zeroizing buffer and is never included in `Debug`, JSON or error text.
pub struct NodeKeypair {
    private_key: Zeroizing<[u8; 32]>,
    pub public_key: [u8; 32],
}

impl std::fmt::Debug for NodeKeypair {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("NodeKeypair").field("public_key", &self.public_key).finish()
    }
}

impl NodeKeypair {
    /// The private half for the transport in this process only.
    pub(crate) fn private_key(&self) -> Zeroizing<[u8; 32]> {
        self.private_key.clone()
    }

    /// Standard padded RFC 4648 base64, the spelling used by WireGuard tools.
    pub fn public_key_base64(&self) -> String {
        base64::engine::general_purpose::STANDARD.encode(self.public_key)
    }

    /// Alias used by `acpmux host join` and the platform API contract.
    pub fn public_key_b64(&self) -> String {
        self.public_key_base64()
    }
}

/// Load this daemon's node key, creating it on first use.
pub fn load_or_create() -> Result<NodeKeypair> {
    load_or_create_at(&crate::config::home())
}

/// Load or create a node key in `state_dir`. This is public for the host-join
/// command and tests; callers should pass the acpmux state directory, not a
/// user-controlled key path.
pub fn load_or_create_at(state_dir: &Path) -> Result<NodeKeypair> {
    crate::config::private_state_dir(state_dir)?;
    let path = state_dir.join(KEY_FILE);
    let private = match std::fs::symlink_metadata(&path) {
        Ok(_) => read_key(&path)?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let mut bytes = Zeroizing::new([0u8; 32]);
            getrandom::fill(&mut *bytes).map_err(|error| anyhow!("generate node key: {error}"))?;
            // A fully synced temporary file is hard-linked into place. Unlike
            // rename, hard-link refuses to replace a key another process won.
            create_key_if_absent(&path, &bytes)
                .with_context(|| format!("write node key in {}", state_dir.display()))?;
            read_key(&path)?
        }
        Err(error) => return Err(error.into()),
    };
    let secret = StaticSecret::from(*private);
    let public = PublicKey::from(&secret).to_bytes();
    Ok(NodeKeypair { private_key: private, public_key: public })
}

fn read_key(path: &Path) -> Result<Zeroizing<[u8; 32]>> {
    let mut file = crate::config::private_state_file(path)?;
    let mut key = Zeroizing::new([0u8; 32]);
    file.read_exact(&mut *key).with_context(|| format!("read node key in {}", path.display()))?;
    let mut trailing = [0u8; 1];
    if file.read(&mut trailing)? != 0 {
        return Err(anyhow!("node key has invalid length"));
    }
    Ok(key)
}

fn create_key_if_absent(path: &Path, bytes: &[u8; 32]) -> Result<()> {
    static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let temporary = path.with_extension(format!("tmp-{}-{n}", std::process::id()));
    let result = (|| {
        let mut file = std::fs::OpenOptions::new();
        file.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            file.mode(0o600).custom_flags(libc::O_NOFOLLOW);
        }
        let mut file = file.open(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        match std::fs::hard_link(&temporary, path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => Ok(()),
            Err(error) => Err(error),
        }
    })();
    let _ = std::fs::remove_file(&temporary);
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn creates_a_stable_owner_only_key_and_public_encoding() {
        let dir = tempfile::tempdir().unwrap();
        let first = load_or_create_at(dir.path()).unwrap();
        let second = load_or_create_at(dir.path()).unwrap();
        assert_eq!(first.public_key, second.public_key);
        assert_eq!(first.public_key_base64().len(), 44);
        #[cfg(unix)]
        {
            let mode = std::fs::metadata(dir.path().join(KEY_FILE)).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        let bytes =
            base64::engine::general_purpose::STANDARD.decode(first.public_key_base64()).unwrap();
        assert_eq!(bytes.len(), 32);
        assert!(!format!("{first:?}").contains("private"));
    }

    #[test]
    fn refuses_a_malformed_key_without_echoing_bytes() {
        let dir = tempfile::tempdir().unwrap();
        crate::config::private_state_dir(dir.path()).unwrap();
        std::fs::write(dir.path().join(KEY_FILE), b"too short").unwrap();
        #[cfg(unix)]
        std::fs::set_permissions(
            dir.path().join(KEY_FILE),
            std::os::unix::fs::PermissionsExt::from_mode(0o600),
        )
        .unwrap();
        let error = load_or_create_at(dir.path()).unwrap_err().to_string();
        assert_eq!(error, "node key has invalid length");
        assert!(!error.contains("too short"));
    }

    #[test]
    fn concurrent_first_use_keeps_one_public_identity() {
        let dir = tempfile::tempdir().unwrap();
        let paths = std::iter::repeat_with(|| dir.path().to_owned()).take(8);
        let keys = std::thread::scope(|scope| {
            paths
                .map(|path| scope.spawn(move || load_or_create_at(&path).unwrap().public_key))
                .map(|thread| thread.join().unwrap())
                .collect::<Vec<_>>()
        });
        assert!(keys.windows(2).all(|pair| pair[0] == pair[1]));
    }
}
