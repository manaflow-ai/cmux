//! The app's install key (P8 slice 3b-2, plans/cmux-next/identity.md), the
//! same key, file and format as cmux-next (CmuxNextDaemon
//! `FrontendInstallKey`, `FileFrontendInstallKeyStore`), so cmux2 and
//! cmux-next can prove themselves to one daemon.
//!
//! An unsigned build keeps 32 random bytes and an install id in
//! `<daemon state dir>/frontend-install-key` (mode 0600, one line
//! `cmuxik1 <install_id> <64 hex key>`). The launcher hands it to a daemon it
//! starts on stdin (`server ensure --install-key-stdin`, never argv or env);
//! every app connection then proves itself with `client-hello`
//! ([`crate::AppConnection`]). The key never appears in `Debug` output or a
//! log line.
//!
//! Unix only: on Windows cmux-tui's `server ensure` does not hand the key to
//! the owner it starts (`local_owner.rs` passes the install key pipe only on
//! Unix), so [`InstallKey::load_or_create`] returns `None` there and no
//! connection claims to be the app.

use cmux_local_auth::frontend_proof::{self, INSTALL_KEY_LEN, NONCE_LEN};
use std::path::{Path, PathBuf};

/// The key file's name in the daemon state directory (cmux-next
/// `FrontendInstallKeyStores.forApp`).
pub const FILE_NAME: &str = "frontend-install-key";
const MAGIC: &str = "cmuxik1";
/// Longest key file the store reads (cmux-next reads 512 bytes).
const MAX_FILE: u64 = 512;

/// An install id and its 32-byte key. `Debug` shows only the install id.
#[derive(Clone, PartialEq, Eq)]
pub struct InstallKey {
    install_id: String,
    key: [u8; INSTALL_KEY_LEN],
}

impl std::fmt::Debug for InstallKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("InstallKey").field("install_id", &self.install_id).finish_non_exhaustive()
    }
}

impl InstallKey {
    /// A fresh key and install id (`inst_` + 20 random hex digits, as
    /// cmux-next). `None` when the system has no random source.
    pub fn generate() -> Option<Self> {
        let mut key = [0u8; INSTALL_KEY_LEN];
        let mut suffix = [0u8; 10];
        getrandom::fill(&mut key).ok()?;
        getrandom::fill(&mut suffix).ok()?;
        Self::new(format!("inst_{}", frontend_proof::hex(&suffix)), key)
    }

    /// `None` for an id the daemon refuses or an all-zero key.
    pub fn new(install_id: String, key: [u8; INSTALL_KEY_LEN]) -> Option<Self> {
        (frontend_proof::valid_install_id(&install_id) && key.iter().any(|b| *b != 0))
            .then_some(Self { install_id, key })
    }

    /// Parses `cmuxik1 <install_id> <64 hex key>` (one line).
    pub fn parse(payload: &str) -> Option<Self> {
        let mut words = payload.trim_end_matches(['\n', '\r']).split(' ');
        let (Some(MAGIC), Some(install_id), Some(key), None) =
            (words.next(), words.next(), words.next(), words.next())
        else {
            return None;
        };
        Self::new(install_id.to_string(), frontend_proof::unhex::<INSTALL_KEY_LEN>(key)?)
    }

    pub fn install_id(&self) -> &str {
        &self.install_id
    }

    /// The stdin payload and file contents. A secret: never log it.
    pub(crate) fn payload(&self) -> String {
        format!("{MAGIC} {} {}\n", self.install_id, frontend_proof::hex(&self.key))
    }

    /// The `client-hello` step 2 proof over the daemon's nonce (64 hex
    /// digits); `None` for any other nonce.
    pub fn proof(&self, nonce_hex: &str) -> Option<String> {
        let nonce = frontend_proof::unhex::<NONCE_LEN>(nonce_hex)?;
        Some(frontend_proof::hello_proof(&self.key, &self.install_id, &nonce))
    }

    /// `<state_dir>/frontend-install-key`.
    pub fn file_in(state_dir: &Path) -> PathBuf {
        state_dir.join(FILE_NAME)
    }

    /// The key stored in `file`, created on first use (cmux-next
    /// `FileFrontendInstallKeyStore.loadOrCreate`): read only from a regular
    /// file of this user with mode exactly 0600; else made in one step
    /// (`O_EXCL`, 0600) in a 0700 directory, and a racing creator's file
    /// wins. `None` when it cannot be read or written (the app then proves
    /// nothing), and always on Windows (see the module docs).
    pub fn load_or_create(file: &Path) -> Option<Self> {
        #[cfg(unix)]
        {
            store::load_or_create(file)
        }
        #[cfg(not(unix))]
        {
            let _ = file;
            None
        }
    }
}

#[cfg(unix)]
mod store {
    use super::{InstallKey, MAX_FILE};
    use std::fs::{DirBuilder, OpenOptions};
    use std::io::{Read, Write};
    use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
    use std::path::Path;

    pub(super) fn load_or_create(file: &Path) -> Option<InstallKey> {
        if let Some(key) = read(file) {
            return Some(key);
        }
        // The first launch asks before `server ensure` makes the state
        // directory: make it owner-only now, as ensure does.
        if let Some(dir) = file.parent() {
            let _ = DirBuilder::new().recursive(true).mode(0o700).create(dir);
        }
        let fresh = InstallKey::generate()?;
        let mut created = match OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(file)
        {
            Ok(created) => created,
            // A racing launch created it first: read that one.
            Err(_) => return read(file),
        };
        // A umask may only narrow the mode; anything but 0600 is not ours.
        let mode_ok = created.metadata().is_ok_and(|m| m.permissions().mode() & 0o777 == 0o600);
        if !mode_ok || created.write_all(fresh.payload().as_bytes()).is_err() {
            drop(created);
            let _ = std::fs::remove_file(file);
            return None;
        }
        Some(fresh)
    }

    fn read(file: &Path) -> Option<InstallKey> {
        let handle = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(file)
            .ok()?;
        let meta = handle.metadata().ok()?;
        // SAFETY: geteuid has no preconditions.
        let me = unsafe { libc::geteuid() };
        if !meta.is_file() || meta.uid() != me || meta.mode() & 0o777 != 0o600 {
            return None;
        }
        let mut text = String::new();
        handle.take(MAX_FILE).read_to_string(&mut text).ok()?;
        InstallKey::parse(&text)
    }
}
