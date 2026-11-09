//! The acpmux node identity used by the Labs WireGuard transport.
//!
//! The key is raw Curve25519 private-key bytes in `node.wg.key`. The file is
//! created below [`crate::config::home`] after the same owner-only checks as
//! every other acpmux state file. It is opened only through
//! `cmux_link::key_holder`: the transport reads the private half with the key
//! lock held ([`load_or_create_held`]); everyone else gets the public half.

use anyhow::{Context, Result, anyhow};
use base64::Engine;
use cmux_link::key_holder::{self, KeyFile, KeyHolder};
use std::io::{Read, Write};
use std::path::Path;
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroizing;

/// A node's WireGuard identity: its public half. The private half leaves this
/// module only through [`load_or_create_held`].
#[derive(Debug)]
pub struct NodeKeypair {
    pub public_key: [u8; 32],
}

impl NodeKeypair {
    fn of(private: &[u8; 32]) -> Self {
        Self { public_key: PublicKey::from(&StaticSecret::from(*private)).to_bytes() }
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

/// Load or create a node key in `state_dir` for its public half. This is public
/// for the host-join command and tests; callers should pass the acpmux state
/// directory, not a user-controlled key path.
pub fn load_or_create_at(state_dir: &Path) -> Result<NodeKeypair> {
    let private = load_or_create_with(state_dir, || {
        key_holder::open_for_public_key(KeyFile::Node, state_dir, read_key)
    })?;
    Ok(NodeKeypair::of(&private))
}

/// The node key in `state_dir` for a session, created on first use: only
/// with this machine's WireGuard key lock (`holder`) held.
pub(crate) fn load_or_create_held(
    state_dir: &Path,
    holder: &KeyHolder,
) -> Result<(NodeKeypair, Zeroizing<[u8; 32]>)> {
    let private =
        load_or_create_with(state_dir, || holder.open(KeyFile::Node, state_dir, read_key))?;
    Ok((NodeKeypair::of(&private), private))
}

fn load_or_create_with(
    state_dir: &Path,
    read: impl Fn() -> Result<Zeroizing<[u8; 32]>>,
) -> Result<Zeroizing<[u8; 32]>> {
    crate::config::private_state_dir(state_dir)?;
    let path = KeyFile::Node.path_in(state_dir);
    match std::fs::symlink_metadata(&path) {
        Ok(_) => read(),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let mut bytes = Zeroizing::new([0u8; 32]);
            getrandom::fill(&mut *bytes).map_err(|error| anyhow!("generate node key: {error}"))?;
            // A fully synced temporary file is hard-linked into place. Unlike
            // rename, hard-link refuses to replace a key another process won.
            create_key_if_absent(&path, &bytes)
                .with_context(|| format!("write node key in {}", state_dir.display()))?;
            read()
        }
        Err(error) => Err(error.into()),
    }
}

/// A fresh node key in `state_dir`, in place of the one there: what a box whose home was copied
/// from another gets, so the two never answer with one WireGuard identity. Only the public half
/// of the new key is returned; the old key's bytes are not read.
pub fn replace_at(state_dir: &Path) -> Result<NodeKeypair> {
    crate::config::private_state_dir(state_dir)?;
    let path = KeyFile::Node.path_in(state_dir);
    match std::fs::symlink_metadata(&path) {
        Ok(meta) => {
            anyhow::ensure!(meta.file_type().is_file(), "node key is not a regular file");
            std::fs::remove_file(&path).context("remove the copied node key")?;
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    load_or_create_at(state_dir)
}

/// `private` as the pending node key ([`KeyFile::NodePending`]): owner-only, fully synced and
/// renamed into place, so a crash leaves the old pending key or this one, never part of one.
pub(crate) fn write_pending_held(
    state_dir: &Path,
    holder: &KeyHolder,
    private: &[u8; 32],
) -> Result<()> {
    crate::config::private_state_dir(state_dir)?;
    holder.open(KeyFile::NodePending, state_dir, |path| -> Result<()> {
        let temporary = write_temporary(path, private)?;
        let renamed = std::fs::rename(&temporary, path);
        if renamed.is_err() {
            let _ = std::fs::remove_file(&temporary);
        }
        renamed.context("write the pending node key")?;
        sync_parent(path)
    })
}

/// The pending node key, or `None` when no rekey left one.
pub(crate) fn read_pending_held(
    state_dir: &Path,
    holder: &KeyHolder,
) -> Result<Option<Zeroizing<[u8; 32]>>> {
    holder.open(KeyFile::NodePending, state_dir, |path| {
        if std::fs::symlink_metadata(path).is_err() {
            return Ok(None);
        }
        read_key(path).map(Some)
    })
}

/// The pending node key becomes the node key in one rename.
pub(crate) fn promote_pending_held(state_dir: &Path, holder: &KeyHolder) -> Result<()> {
    let pending = KeyFile::NodePending.path_in(state_dir);
    holder.open(KeyFile::Node, state_dir, |path| -> Result<()> {
        std::fs::rename(&pending, path).context("put the pending node key in place")?;
        sync_parent(path)
    })
}

/// No pending node key any more (none is fine).
pub(crate) fn drop_pending_held(state_dir: &Path, holder: &KeyHolder) -> Result<()> {
    holder.open(KeyFile::NodePending, state_dir, |path| -> Result<()> {
        match std::fs::remove_file(path) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => {
                Err(error).context("remove the pending node key")
            }
            _ => sync_parent(path),
        }
    })
}

fn read_key(path: &Path) -> Result<Zeroizing<[u8; 32]>> {
    let mut file = crate::config::private_state_file(path)?;
    let mut key = Zeroizing::new([0u8; 32]);
    if let Err(error) = file.read_exact(&mut *key) {
        if error.kind() == std::io::ErrorKind::UnexpectedEof {
            return Err(anyhow!("node key has invalid length"));
        }
        return Err(error).context("read node key");
    }
    let mut trailing = Zeroizing::new([0u8; 1]);
    if file.read(&mut *trailing).context("read node key")? != 0 {
        return Err(anyhow!("node key has invalid length"));
    }
    Ok(key)
}

fn create_key_if_absent(path: &Path, bytes: &[u8; 32]) -> Result<()> {
    let temporary = write_temporary(path, bytes)?;
    // Only remove a temporary file after this invocation created it.
    let result: Result<()> = (|| {
        match std::fs::hard_link(&temporary, path) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error.into()),
        }
        sync_parent(path)
    })();
    let _ = std::fs::remove_file(&temporary);
    result
}

/// `bytes` in a new owner-only file next to `path`, fully synced.
fn write_temporary(path: &Path, bytes: &[u8; 32]) -> Result<std::path::PathBuf> {
    let temporary = path.with_extension(format!("wg-key-{}", uuid::Uuid::new_v4()));
    #[cfg(unix)]
    let mut file = {
        use std::os::unix::fs::OpenOptionsExt;
        std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&temporary)?
    };
    #[cfg(windows)]
    let mut file = crate::owner_only::create_new(&temporary)?;
    let written: Result<()> = (|| {
        file.write_all(bytes)?;
        file.sync_all()?;
        Ok(())
    })();
    drop(file);
    if let Err(error) = written {
        let _ = std::fs::remove_file(&temporary);
        return Err(error);
    }
    Ok(temporary)
}

fn sync_parent(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        let parent = path.parent().ok_or_else(|| anyhow!("node key has no state directory"))?;
        std::fs::File::open(parent)?.sync_all()?;
    }
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
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
            let mode =
                std::fs::metadata(KeyFile::Node.path_in(dir.path())).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        let bytes =
            base64::engine::general_purpose::STANDARD.decode(first.public_key_base64()).unwrap();
        assert_eq!(bytes.len(), 32);
        assert!(!format!("{first:?}").contains("private"));
        let holder = KeyHolder::acquire(dir.path()).unwrap();
        let (held, private) = load_or_create_held(dir.path(), &holder).unwrap();
        assert_eq!(held.public_key, first.public_key);
        assert_eq!(NodeKeypair::of(&private).public_key, first.public_key);
    }

    #[test]
    fn replacing_a_key_gives_a_new_identity_that_then_stays() {
        let dir = tempfile::tempdir().unwrap();
        let copied = load_or_create_at(dir.path()).unwrap();
        let fresh = replace_at(dir.path()).unwrap();
        assert_ne!(copied.public_key, fresh.public_key);
        assert_eq!(load_or_create_at(dir.path()).unwrap().public_key, fresh.public_key);
        // With no key yet, a replacement is a first key.
        let empty = tempfile::tempdir().unwrap();
        let first = replace_at(empty.path()).unwrap();
        assert_eq!(load_or_create_at(empty.path()).unwrap().public_key, first.public_key);
    }

    #[test]
    fn refuses_a_truncated_key_without_echoing_bytes() {
        assert_invalid_length(b"too short");
    }

    #[test]
    fn refuses_an_oversized_key_without_echoing_bytes() {
        assert_invalid_length(b"private key fixture longer than thirty-two bytes");
    }

    fn assert_invalid_length(bytes: &[u8]) {
        let dir = tempfile::tempdir().unwrap();
        // Start with the helper's owner-only file on every supported platform.
        load_or_create_at(dir.path()).unwrap();
        std::fs::write(KeyFile::Node.path_in(dir.path()), bytes).unwrap();
        let error = load_or_create_at(dir.path()).unwrap_err();
        assert_eq!(format!("{error:#}"), "node key has invalid length");
        assert!(!format!("{error:?}").contains(std::str::from_utf8(bytes).unwrap()));
        assert_eq!(std::fs::read(KeyFile::Node.path_in(dir.path())).unwrap(), bytes);
    }

    #[test]
    fn concurrent_first_use_keeps_one_public_identity() {
        let dir = tempfile::tempdir().unwrap();
        let paths = std::iter::repeat_with(|| dir.path().to_owned()).take(8);
        let barrier = std::sync::Barrier::new(8);
        let keys = std::thread::scope(|scope| {
            let handles = paths
                .map(|path| {
                    let barrier = &barrier;
                    scope.spawn(move || {
                        barrier.wait();
                        load_or_create_at(&path).unwrap().public_key
                    })
                })
                .collect::<Vec<_>>();
            handles.into_iter().map(|thread| thread.join().unwrap()).collect::<Vec<_>>()
        });
        assert!(keys.windows(2).all(|pair| pair[0] == pair[1]));
    }
}
