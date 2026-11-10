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
pub fn load_or_create_held(
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

/// The public half of the node key now in `state_dir`, or None when there is none or it cannot
/// be read. Never creates one: the hub carrier's key check (`hub_carrier.rs`) uses it to see a
/// key [`replace_at`] replaced.
pub fn public_key_at(state_dir: &Path) -> Option<[u8; 32]> {
    let private = key_holder::open_for_public_key(KeyFile::Node, state_dir, read_key).ok()?;
    Some(NodeKeypair::of(&private).public_key)
}

/// The refusal of a node key change an adoption depends on ([`adoption_depends`]).
pub(crate) const ADOPTED: &str = "node_key.adopted";

/// Whether the cmux link in `link_dir` adopted the node key in `home` as its only key: an
/// adoption record names the adopted key's directory in `key_dir` (the link's
/// `key_adoption.rs`), either the current one (`key-adopted.json`) or one a sign-out or an
/// install switch archived with its install (`key-adopted.<install>.json`, restored when that
/// install comes back). The paired peers of that install know the link by that key alone, so
/// nothing deletes, replaces or rotates it then. A record naming another directory adopted
/// another home's key; one that cannot be read or names none, or a link directory that cannot
/// be listed, counts as this home's, so the key stays.
pub(crate) fn link_adopted(link_dir: Option<&Path>, home: &Path) -> bool {
    let Some(link_dir) = link_dir else { return false };
    let mut entries = match std::fs::read_dir(link_dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return false,
        Err(_) => return true,
    };
    let canonical = |path: &Path| std::fs::canonicalize(path).unwrap_or_else(|_| path.to_owned());
    let names_home = |record: &Path| {
        let key_dir = std::fs::read(record)
            .ok()
            .and_then(|text| serde_json::from_slice::<serde_json::Value>(&text).ok())
            .and_then(|record| record.get("key_dir")?.as_str().map(std::path::PathBuf::from));
        key_dir.is_none_or(|key_dir| canonical(&key_dir) == canonical(home))
    };
    entries.any(|entry| match entry {
        Ok(entry) => {
            entry
                .file_name()
                .to_str()
                .is_some_and(|name| name.starts_with("key-adopted.") && name.ends_with(".json"))
                && names_home(&entry.path())
        }
        Err(_) => true,
    })
}

/// Whether an adoption, current or archived, depends on the node key in `home`
/// ([`link_adopted`] in this machine's link state directory). The one check before anything
/// deletes, replaces or rotates that key: [`lock_to_remove`] (`machine leave`, [`replace_at`])
/// and [`adoption_depends_held`] (`machine.tunnel.rekey`, [`promote_pending_held`]) ask it under
/// the WireGuard key lock, which the link adopts under.
pub(crate) fn adoption_depends(home: &Path) -> bool {
    link_dirs_for(home).iter().any(|link_dir| link_adopted(Some(link_dir), home))
}

/// [`adoption_depends`], asked with the key lock (`_held`) held, so no adoption begins before
/// the change it allows is done.
pub(crate) fn adoption_depends_held(home: &Path, _held: &KeyHolder) -> bool {
    adoption_depends(home)
}

/// Refused [`ADOPTED`] when an adoption depends on the node key in `home`
/// ([`adoption_depends_held`]). Until the link rekeys its paired peers itself, a rotation
/// would leave every one of them dialing a key it no longer serves.
pub(crate) fn refuse_adopted_held(home: &Path, held: &KeyHolder) -> Result<()> {
    anyhow::ensure!(
        !adoption_depends_held(home, held),
        "{ADOPTED}: the cmux link serves this node key, and its paired peers know the link by it \
         alone; it is not replaced or rotated"
    );
    Ok(())
}

/// Every cmux link state directory that may depend on the node key in `home`: each one the
/// app ever recorded there ([`record_link_home`], never forgotten: a link that adopted keeps
/// depending on the key after another link directory is set up on the same home), and the one
/// by this process's environment (a test's is beside its home).
pub(crate) fn link_dirs_for(home: &Path) -> Vec<std::path::PathBuf> {
    let mut dirs = recorded_link_dirs(home);
    let by_env =
        if cfg!(test) { Some(home.join("link")) } else { crate::wireguard::env_link_state_dir() };
    dirs.extend(by_env.filter(|dir| !dirs.contains(dir)));
    dirs
}

/// In a cmux link's state directory: the acpmux home whose node key the link adopts, resolved
/// in the app's own process (`cmux link init|ensure|install-agent`). `cmux link serve`, which
/// launchd starts with none of the app's environment, trusts only this record; it never
/// re-derives the home from its own environment.
pub const LINK_ACPMUX_HOME: &str = "acpmux-home.json";

/// In an acpmux home: every cmux link state directory recorded for it, oldest first (the other
/// half of [`LINK_ACPMUX_HOME`]). A set, only ever added to: each may have adopted the node key.
pub const HOME_LINK_DIR: &str = "cmux-link.json";

/// In a cmux link's state directory, once the link found the acpmux home it adopts from copied
/// from another machine ([`home_copied`]): the link's identity there (its key, its pairings, its
/// adoption record) is that machine's, and the link never serves it again, a new join included.
/// Only moving the state directory aside (and pairing again) ends it.
pub const LINK_COPIED: &str = "copied-from-another-machine.json";

#[derive(serde::Serialize, serde::Deserialize)]
struct HomeRecord {
    acpmux_home: std::path::PathBuf,
}

#[derive(Default, serde::Serialize, serde::Deserialize)]
struct LinkDirRecord {
    #[serde(default)]
    link_dirs: Vec<std::path::PathBuf>,
    /// The single entry an earlier build of this change wrote.
    #[serde(default, skip_serializing)]
    link_dir: Option<std::path::PathBuf>,
}

/// Record that the cmux link in `link_dir` adopts the node key of acpmux home `home`, resolved
/// by the caller in the app's own process: [`LINK_ACPMUX_HOME`] in the link's state directory
/// and [`HOME_LINK_DIR`] in the home. `None` (the link has no acpmux home: another state
/// directory, a test) removes the link's record, so a stale home is never trusted.
pub fn record_link_home(link_dir: &Path, home: Option<&Path>) -> Result<()> {
    let record = link_dir.join(LINK_ACPMUX_HOME);
    let Some(home) = home else {
        return match std::fs::remove_file(&record) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => {
                Err(error).context("remove the link's acpmux home record")
            }
            _ => Ok(()),
        };
    };
    if recorded_home(link_dir).as_deref() != Some(home) {
        let bytes = serde_json::to_vec(&HomeRecord { acpmux_home: home.to_owned() })?;
        write_record(&record, &bytes)?;
    }
    let mut dirs = recorded_link_dirs(home);
    if !dirs.iter().any(|dir| dir == link_dir) {
        crate::config::private_state_dir(home)?;
        // Read and written under a lock of its own: two links set up at once both stay.
        let lock = crate::config::private_state_rw(&home.join("cmux-link.lock"))?;
        lock.lock().context("lock the home's link record")?;
        dirs = recorded_link_dirs(home);
        let written = if dirs.iter().any(|dir| dir == link_dir) {
            Ok(())
        } else {
            dirs.push(link_dir.to_owned());
            serde_json::to_vec(&LinkDirRecord { link_dirs: dirs, link_dir: None })
                .map_err(anyhow::Error::from)
                .and_then(|bytes| write_record(&home.join(HOME_LINK_DIR), &bytes))
        };
        let _ = lock.unlock();
        written?;
    }
    Ok(())
}

/// The acpmux home the app recorded for the link in `link_dir` ([`record_link_home`]).
pub fn recorded_home(link_dir: &Path) -> Option<std::path::PathBuf> {
    let text = std::fs::read(link_dir.join(LINK_ACPMUX_HOME)).ok()?;
    serde_json::from_slice::<HomeRecord>(&text).ok().map(|record| record.acpmux_home)
}

/// Every link state directory the app recorded in acpmux home `home` ([`record_link_home`]),
/// oldest first.
pub(crate) fn recorded_link_dirs(home: &Path) -> Vec<std::path::PathBuf> {
    let Some(record) = std::fs::read(home.join(HOME_LINK_DIR))
        .ok()
        .and_then(|text| serde_json::from_slice::<LinkDirRecord>(&text).ok())
    else {
        return Vec::new();
    };
    let mut dirs = record.link_dirs;
    dirs.extend(record.link_dir.filter(|dir| !dirs.contains(dir)));
    dirs
}

/// The link state directory recorded in `home` that serves (or will serve) its node key: one
/// that adopted it first, else the one recorded last.
pub(crate) fn recorded_link_dir(home: &Path) -> Option<std::path::PathBuf> {
    let dirs = recorded_link_dirs(home);
    let adopted = dirs.iter().find(|dir| {
        std::fs::read(dir.join("key-adopted.json"))
            .ok()
            .and_then(|text| serde_json::from_slice::<serde_json::Value>(&text).ok())
            .and_then(|record| record.get("key_dir")?.as_str().map(std::path::PathBuf::from))
            .is_some_and(|key_dir| same_path(&key_dir, home))
    });
    adopted.or(dirs.last()).cloned()
}

fn same_path(a: &Path, b: &Path) -> bool {
    let canonical = |path: &Path| std::fs::canonicalize(path).unwrap_or_else(|_| path.to_owned());
    canonical(a) == canonical(b)
}

/// Whether the node key in acpmux home `home` is another machine's: by acpmux's own clone
/// check, asked live (`cloud_join::node_key_copied_at`: a record copied and not settled on
/// this box, a copy of a copy included), or a key recorded as copied ([`serves_copied_key`]).
/// A copy it finds is recorded ([`record_copied_key`]) before it answers. A home settled on
/// this box (its own fresh key) is not.
pub fn home_copied(home: &Path) -> bool {
    crate::cli::cloud_join::node_key_copied_at(home)
}

/// Whether a node key rotation is pending in `home` (`machine.tunnel.rekey` wrote its
/// candidate, the platform's answer not settled): the cmux link never adopts the node key
/// while one is, since the platform may already hold the candidate. Asked under the key lock,
/// which every rekey takes, so none begins before the adoption commits.
pub fn rekey_pending(home: &Path) -> bool {
    std::fs::symlink_metadata(KeyFile::NodePending.path_in(home)).is_ok()
}

/// In an acpmux home: the public halves of every node key found copied from another machine
/// ([`record_copied_key`]), a copy of a copy included. Never removed; a key stays named after
/// it is replaced.
pub const COPIED_KEY: &str = "node-key-copied.json";

#[derive(Default, serde::Serialize, serde::Deserialize)]
struct CopiedKey {
    /// Standard base64, one per copy found.
    #[serde(default)]
    public_keys: std::collections::BTreeSet<String>,
}

/// Record, synced, that the node key now in `home` was copied from another machine, before
/// anything removes the evidence (a leave deletes the machine record) or keeps the key (the
/// link adopted it). It adds the key to the ones already named, under a lock of its own: a
/// home copied, settled with a fresh key, and copied again names both, so a stale entry never
/// lets a later copy through. A record that cannot be read is replaced by one naming this key
/// (the keys it named are no longer in use: each was replaced when it was found).
pub fn record_copied_key(home: &Path) -> Result<()> {
    let Some(key) = public_key_at(home) else { return Ok(()) };
    let key = base64::engine::general_purpose::STANDARD.encode(key);
    crate::config::private_state_dir(home)?;
    let lock = crate::config::private_state_rw(&home.join("node-key-copied.lock"))?;
    lock.lock().context("lock the copied node key record")?;
    let path = home.join(COPIED_KEY);
    let mut record = std::fs::read(&path)
        .ok()
        .and_then(|text| serde_json::from_slice::<CopiedKey>(&text).ok())
        .unwrap_or_default();
    let written = if record.public_keys.insert(key) {
        write_record(&path, &serde_json::to_vec(&record)?)
    } else {
        Ok(())
    };
    let _ = lock.unlock();
    written
}

/// Whether the node key now in `home` is one recorded as copied from another machine
/// ([`record_copied_key`]): nobody serves it here, not the WireGuard transport, the hub
/// carrier nor the cmux link. A record that cannot be read counts as naming it (fail closed).
pub fn serves_copied_key(home: &Path) -> bool {
    let path = home.join(COPIED_KEY);
    let text = match std::fs::read(&path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return false,
        Err(_) => return true,
    };
    let Ok(record) = serde_json::from_slice::<CopiedKey>(&text) else { return true };
    public_key_at(home)
        .map(|key| base64::engine::general_purpose::STANDARD.encode(key))
        .is_some_and(|now| record.public_keys.contains(&now))
}

/// This box's stamp: the fingerprint acpmux's clone check compares (`cloud_join`
/// `host_fingerprint`), or none when the OS names no machine.
pub fn box_stamp() -> Option<String> {
    crate::cli::cloud_join::host_fingerprint::current()
}

/// Whether `stamp`, recorded on the box that wrote it, is this box, by acpmux's clone check
/// (`host_fingerprint::same_box`, with `home`'s copy markers). A box with no fingerprint now
/// compares nothing, as acpmux does.
pub fn stamped_here(home: &Path, stamp: &str) -> bool {
    box_stamp()
        .is_none_or(|here| crate::cli::cloud_join::host_fingerprint::same_box(home, stamp, &here))
}

/// Whether the cmux link in `link_dir` serves the node key in `home` (or will, at its next
/// start), so acpmux's own WireGuard transport stays off for it: the link is set up (its
/// `config.json`), is no server-enrolled link, adopted this home's key (`key-adopted.json`
/// names it) or the app recorded this home for it ([`LINK_ACPMUX_HOME`]), and the link does not
/// refuse to serve it because the home or the link was copied from another machine
/// ([`LINK_COPIED`], [`home_copied`]). Any other link keeps a key of its own, or none, and the
/// transport runs.
pub fn link_serves_node_key(link_dir: Option<&Path>, home: &Path) -> bool {
    let Some(link_dir) = link_dir else { return false };
    let canonical = |path: &Path| std::fs::canonicalize(path).unwrap_or_else(|_| path.to_owned());
    let config = std::fs::read(link_dir.join("config.json"))
        .ok()
        .and_then(|text| serde_json::from_slice::<serde_json::Value>(&text).ok());
    let Some(config) = config else { return false };
    if config.get("server_identity").is_some_and(|identity| !identity.is_null()) {
        return false;
    }
    let adopted_here = std::fs::read(link_dir.join("key-adopted.json"))
        .ok()
        .and_then(|text| serde_json::from_slice::<serde_json::Value>(&text).ok())
        .and_then(|record| record.get("key_dir")?.as_str().map(std::path::PathBuf::from))
        .is_some_and(|key_dir| canonical(&key_dir) == canonical(home));
    let recorded_here =
        recorded_home(link_dir).is_some_and(|recorded| canonical(&recorded) == canonical(home));
    // Not adopted yet while a rekey is pending: the link puts the adoption off, and the
    // transport may take the lock and finish the rekey.
    (adopted_here || (recorded_here && !rekey_pending(home)))
        && !link_dir.join(LINK_COPIED).exists()
        && !home_copied(home)
}

/// `bytes` at `path`, owner-only: a synced temporary file renamed into place.
fn write_record(path: &Path, bytes: &[u8]) -> Result<()> {
    let temporary = write_temporary(path, bytes)?;
    let renamed = std::fs::rename(&temporary, path);
    if renamed.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    renamed.with_context(|| format!("write {}", path.display()))?;
    sync_parent(path)
}

/// Who may delete or replace the node key in `home` ([`lock_to_remove`]).
pub(crate) enum RemoveLock {
    /// The WireGuard key lock, held: the key may go while it is.
    Free(KeyHolder),
    /// An adoption, current or archived, depends on the key ([`adoption_depends`]): it stays.
    Adopted,
    /// Another process holds the key lock (a running link or WireGuard transport): it stays.
    Held,
}

/// The WireGuard key lock in `home` for deleting or replacing its node key, or why the key
/// stays. The adoption is checked under the lock, which the link adopts under.
pub(crate) fn lock_to_remove(home: &Path) -> Result<RemoveLock> {
    let holder = match KeyHolder::acquire(home) {
        Ok(holder) => holder,
        Err(key_holder::KeyHolderError::KeyHeld { .. }) => return Ok(RemoveLock::Held),
        Err(key_holder::KeyHolderError::Io(e)) => {
            return Err(anyhow::Error::from(e).context("take the WireGuard key lock"));
        }
    };
    if adoption_depends(home) {
        return Ok(RemoveLock::Adopted);
    }
    Ok(RemoveLock::Free(holder))
}

/// A fresh node key in `state_dir`, in place of the one there: what a box whose home was copied
/// from another gets, so the two never answer with one WireGuard identity. Only the public half
/// of the new key is returned; the old key's bytes are not read. Refused, with the key left as it
/// is, when the cmux link adopted it or another process holds it ([`lock_to_remove`]).
pub fn replace_at(state_dir: &Path) -> Result<NodeKeypair> {
    crate::config::private_state_dir(state_dir)?;
    // Held until the new key is in place.
    let _lock = match lock_to_remove(state_dir)? {
        RemoveLock::Free(holder) => holder,
        RemoveLock::Adopted => anyhow::bail!(
            "{ADOPTED}: the cmux link serves this node key, and its paired peers know the \
             link by it alone; it is not replaced"
        ),
        RemoveLock::Held => anyhow::bail!(
            "node_key.held: another process holds this machine's WireGuard key; the node key is \
             not replaced while it does"
        ),
    };
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

/// The pending node key becomes the node key in one rename; refused, with both left as they
/// are, while an adoption depends on the node key ([`refuse_adopted_held`]).
pub(crate) fn promote_pending_held(state_dir: &Path, holder: &KeyHolder) -> Result<()> {
    refuse_adopted_held(state_dir, holder)?;
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
fn write_temporary(path: &Path, bytes: &[u8]) -> Result<std::path::PathBuf> {
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
        // What the hub carrier's key check reads: the replacement, never the copied key.
        assert_eq!(public_key_at(dir.path()), Some(fresh.public_key));
        // With no key yet, a replacement is a first key.
        let empty = tempfile::tempdir().unwrap();
        let first = replace_at(empty.path()).unwrap();
        assert_eq!(load_or_create_at(empty.path()).unwrap().public_key, first.public_key);
    }

    /// A copied home's key is never replaced when the cmux link adopted it or another process
    /// holds the key lock: the key stays, and the replacement says why.
    #[test]
    fn replacing_never_touches_an_adopted_or_held_key() {
        let dir = tempfile::tempdir().unwrap();
        let kept = load_or_create_at(dir.path()).unwrap();
        std::fs::create_dir_all(dir.path().join("link")).unwrap();
        std::fs::write(dir.path().join("link/key-adopted.json"), b"{}").unwrap();
        let refused = replace_at(dir.path()).unwrap_err();
        assert!(refused.to_string().starts_with("node_key.adopted:"), "{refused}");
        assert_eq!(public_key_at(dir.path()), Some(kept.public_key));
        std::fs::remove_file(dir.path().join("link/key-adopted.json")).unwrap();
        let held = KeyHolder::acquire(dir.path()).unwrap();
        let refused = replace_at(dir.path()).unwrap_err();
        assert!(refused.to_string().starts_with("node_key.held:"), "{refused}");
        assert_eq!(public_key_at(dir.path()), Some(kept.public_key));
        drop(held);
        // A record of another home's adoption does not keep this home's key.
        let other = tempfile::tempdir().unwrap();
        let record = serde_json::json!({ "key_dir": other.path() });
        std::fs::write(dir.path().join("link/key-adopted.json"), record.to_string()).unwrap();
        let fresh = replace_at(dir.path()).unwrap();
        assert_ne!(fresh.public_key, kept.public_key);
        // This home's own record does.
        let record = serde_json::json!({ "key_dir": dir.path() });
        std::fs::write(dir.path().join("link/key-adopted.json"), record.to_string()).unwrap();
        let refused = replace_at(dir.path()).unwrap_err();
        assert!(refused.to_string().starts_with("node_key.adopted:"), "{refused}");
        assert_eq!(public_key_at(dir.path()), Some(fresh.public_key));
    }

    /// Review F1 at 9e91bcea: acpmux's transport steps down only for a link that serves this
    /// home's node key, by the home the app recorded for it or its adoption record, and never
    /// for one that keeps a key of its own, is server-enrolled, or refuses a copied home.
    #[test]
    fn the_transport_steps_down_only_for_a_link_that_serves_this_homes_node_key() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("acpmux");
        let link = dir.path().join("link");
        std::fs::create_dir_all(&link).unwrap();
        assert!(!link_serves_node_key(None, &home));
        assert!(!link_serves_node_key(Some(&link), &home), "no link set up");
        std::fs::write(link.join("config.json"), r#"{"install":"inst_a","port":4101}"#).unwrap();
        assert!(!link_serves_node_key(Some(&link), &home), "a link with no home keeps its key");
        record_link_home(&link, Some(&home)).unwrap();
        assert_eq!(recorded_home(&link).as_deref(), Some(home.as_path()));
        assert_eq!(recorded_link_dir(&home).as_deref(), Some(link.as_path()));
        assert!(link_serves_node_key(Some(&link), &home));
        let other = dir.path().join("other");
        assert!(!link_serves_node_key(Some(&link), &other), "another home's link");
        // No home any more (a link on another state directory): the record goes.
        record_link_home(&link, None).unwrap();
        assert_eq!(recorded_home(&link), None);
        assert!(!link_serves_node_key(Some(&link), &home));
        // An adoption record naming this home serves it, recorded or not.
        let record = serde_json::json!({ "key_dir": home });
        std::fs::write(link.join("key-adopted.json"), record.to_string()).unwrap();
        assert!(link_serves_node_key(Some(&link), &home));
        // The link refuses a copied home: the transport does not step down for it.
        std::fs::write(link.join(LINK_COPIED), b"{}").unwrap();
        assert!(!link_serves_node_key(Some(&link), &home));
        std::fs::remove_file(link.join(LINK_COPIED)).unwrap();
        // A server-enrolled link keeps its enrollment's key.
        std::fs::write(
            link.join("config.json"),
            r#"{"install":"inst_a","port":4101,"server_identity":"/s"}"#,
        )
        .unwrap();
        assert!(!link_serves_node_key(Some(&link), &home));
    }

    /// Review F3 at 7837efd1: link L1 adopted this home's key, then link L2 was set up on the
    /// same home without adopting. Both stay recorded, the guard reads both, and a leave (or a
    /// copy's replacement) keeps L1's adopted key; the transport finds L1.
    #[test]
    fn a_second_link_dir_never_hides_the_first_ones_adoption() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("acpmux");
        let kept = load_or_create_at(&home).unwrap();
        let (l1, l2) = (dir.path().join("l1"), dir.path().join("l2"));
        for link in [&l1, &l2] {
            std::fs::create_dir_all(link).unwrap();
            std::fs::write(link.join("config.json"), r#"{"install":"inst_a","port":0}"#).unwrap();
        }
        record_link_home(&l1, Some(&home)).unwrap();
        let adopted = serde_json::json!({ "key_dir": home });
        std::fs::write(l1.join("key-adopted.json"), adopted.to_string()).unwrap();
        record_link_home(&l2, Some(&home)).unwrap();
        assert_eq!(recorded_link_dirs(&home), vec![l1.clone(), l2.clone()]);
        assert!(adoption_depends(&home), "L2 hid L1's adoption");
        assert!(matches!(lock_to_remove(&home).unwrap(), RemoveLock::Adopted));
        let refused = replace_at(&home).unwrap_err();
        assert!(refused.to_string().starts_with("node_key.adopted:"), "{refused}");
        assert_eq!(public_key_at(&home), Some(kept.public_key));
        assert_eq!(recorded_link_dir(&home), Some(l1.clone()), "the adopted link serves");
        // Recording L1 again changes nothing; neither does L2 dropping its home.
        record_link_home(&l1, Some(&home)).unwrap();
        record_link_home(&l2, None).unwrap();
        assert_eq!(recorded_link_dirs(&home), vec![l1, l2]);
        assert!(adoption_depends(&home));
    }

    /// Review F1 and F2 at c1898fca: a sign-out archives the adoption record with its install
    /// (`key-adopted.<install>.json`), and that install's peers still know the link by the node
    /// key. Every change of the key (a leave's delete, a copied home's replacement, a rekey's
    /// promotion) is refused while an archived record names this home, as for a current one.
    #[test]
    fn an_archived_adoption_keeps_the_key_from_every_change() {
        let dir = tempfile::tempdir().unwrap();
        let kept = load_or_create_at(dir.path()).unwrap();
        let kept_bytes = std::fs::read(KeyFile::Node.path_in(dir.path())).unwrap();
        std::fs::create_dir_all(dir.path().join("link")).unwrap();
        let archived = dir.path().join("link/key-adopted.inst_a.json");
        std::fs::write(&archived, serde_json::json!({ "key_dir": dir.path() }).to_string())
            .unwrap();
        assert!(adoption_depends(dir.path()));
        assert!(matches!(lock_to_remove(dir.path()).unwrap(), RemoveLock::Adopted));
        let refused = replace_at(dir.path()).unwrap_err();
        assert!(refused.to_string().starts_with("node_key.adopted:"), "{refused}");
        let holder = KeyHolder::acquire(dir.path()).unwrap();
        write_pending_held(dir.path(), &holder, &[9u8; 32]).unwrap();
        let refused = promote_pending_held(dir.path(), &holder).unwrap_err();
        assert!(refused.to_string().starts_with("node_key.adopted:"), "{refused}");
        assert!(KeyFile::NodePending.path_in(dir.path()).exists(), "the pending key stays");
        drop(holder);
        assert_eq!(std::fs::read(KeyFile::Node.path_in(dir.path())).unwrap(), kept_bytes);
        assert_eq!(public_key_at(dir.path()), Some(kept.public_key));
        // An archive that cannot be read counts as this home's too.
        std::fs::write(&archived, b"not json").unwrap();
        assert!(adoption_depends(dir.path()));
        // Files that are not adoption records (a write's temporary file) do not.
        std::fs::remove_file(&archived).unwrap();
        std::fs::write(dir.path().join("link/.key-adopted.json.1.tmp"), b"{}").unwrap();
        std::fs::write(dir.path().join("link/peers.inst_a.json"), b"{}").unwrap();
        assert!(!adoption_depends(dir.path()));
        // An archive naming another home keeps only that home's key.
        let other = tempfile::tempdir().unwrap();
        std::fs::write(&archived, serde_json::json!({ "key_dir": other.path() }).to_string())
            .unwrap();
        assert!(!adoption_depends(dir.path()));
        let holder = KeyHolder::acquire(dir.path()).unwrap();
        promote_pending_held(dir.path(), &holder).unwrap();
        drop(holder);
        assert_eq!(std::fs::read(KeyFile::Node.path_in(dir.path())).unwrap(), [9u8; 32]);
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
