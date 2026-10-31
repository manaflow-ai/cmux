//! One consent authority per OS account, independent of daemon tags and env.
//!
//! No released build could create pre-marker cloud enrollments. Every supported
//! enrollment writes this authority before redeem. Arbitrary branch-only old
//! ACPMUX_HOME state has no cross-tag upgrade path and must rejoin; inspecting
//! the current daemon's state below is defense in depth, not global discovery.
use super::cloud_join::{Consent, ConsentState, HeldLock};
use anyhow::Result;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

pub(super) struct Authority {
    root: PathBuf,
    legacy: PathBuf,
}

impl Authority {
    pub(super) fn current(legacy: PathBuf) -> Result<Self> {
        Ok(Self { root: account_home()?.join(".acpmux/machine-consent"), legacy })
    }

    fn validate_namespace(&self) -> Result<()> {
        for path in [self.root.parent(), Some(self.root.as_path())].into_iter().flatten() {
            match std::fs::symlink_metadata(path) {
                Ok(metadata) => {
                    anyhow::ensure!(
                        metadata.is_dir() && !metadata.file_type().is_symlink(),
                        "machine consent directory must not be redirected"
                    );
                    crate::config::private_state_dir(path)?;
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(error.into()),
            }
        }
        Ok(())
    }

    fn prepare(&self) -> Result<()> {
        self.validate_namespace()?;
        crate::config::private_state_dir(&self.root)?;
        self.validate_namespace()
    }

    /// Persist before any remote redeem. A failed join keeps conservative gating.
    pub(super) fn enroll(&self) -> Result<()> {
        self.enroll_with_sync(|path| {
            std::fs::File::open(path)?.sync_all()?;
            Ok(())
        })
    }

    fn enroll_with_sync(&self, sync: impl Fn(&Path) -> Result<()>) -> Result<()> {
        self.prepare()?;
        let marker = self.root.join("enrolled.json");
        if exists(&marker)? {
            self.validate_marker()?;
        } else {
            crate::config::write_atomic(&marker, b"{\"schema\":1}")?;
        }
        // Retry all durability barriers even if a previous attempt wrote the
        // marker then failed. The account home persists a newly-created .acpmux;
        // .acpmux persists machine-consent, and machine-consent persists marker.
        sync(&marker)?;
        for path in self.root.ancestors().take(3) {
            sync(path)?;
        }
        Ok(())
    }

    fn validate_marker(&self) -> Result<()> {
        let file = crate::config::private_state_file(&self.root.join("enrolled.json"))?;
        let value: Value = serde_json::from_reader(file)?;
        anyhow::ensure!(value["schema"] == 1, "invalid machine enrollment marker");
        Ok(())
    }

    pub(super) fn retain_own_requirement(&self) -> Result<()> {
        if has_own_requirement(&self.legacy)? {
            self.enroll()?;
        }
        Ok(())
    }

    fn required(&self) -> Result<bool> {
        self.validate_namespace()?;
        self.retain_own_requirement()?;
        super::cloud_join::load_at(&self.legacy)?;
        if exists(&self.root.join("enrolled.json"))? {
            self.validate_marker()?;
        }
        Ok(exists(&self.root.join("enrolled.json"))? || exists(&self.root.join("consent.json"))?)
    }

    fn consent(&self) -> Consent {
        crate::config::private_state_file(&self.root.join("consent.json"))
            .ok()
            .and_then(|file| serde_json::from_reader(file).ok())
            .unwrap_or_default()
    }

    pub(super) fn status(&self) -> Value {
        let required = self.required().and_then(|required| {
            if exists(&self.root)? {
                self.prepare()?;
            }
            Ok(required)
        });
        let consent = if required.is_err() { Consent::default() } else { self.consent() };
        let refusal = required
            .as_ref()
            .ok()
            .and_then(|_| crate::config::private_state_file(&self.root.join("refusal.json")).ok())
            .and_then(|file| serde_json::from_reader::<_, Value>(file).ok());
        json!({"consentRequired":required.unwrap_or(true),"consent":consent,"lastRefusal":refusal})
    }

    pub(super) fn set(&self, surface: &str, granted: bool) -> Result<Consent> {
        self.prepare()?;
        // Serialize read/modify/write across app tags; disjoint grant changes
        // must never resurrect a concurrently revoked surface.
        let _lock = self.lock()?;
        let mut consent = self.consent();
        let state = if granted { ConsentState::Granted } else { ConsentState::None };
        match surface {
            "screen" => consent.screen = state,
            "control" => consent.control = state,
            _ => anyhow::bail!("unknown consent surface"),
        }
        if granted {
            consent.granted_at = Some(crate::store::now_ms().to_string());
        }
        crate::config::write_atomic(
            &self.root.join("consent.json"),
            &serde_json::to_vec(&consent)?,
        )?;
        Ok(consent)
    }

    pub(super) fn refused(&self, surface: &str) -> Result<()> {
        anyhow::ensure!(matches!(surface, "screen" | "control"), "unknown consent surface");
        self.prepare()?;
        crate::config::write_atomic(
            &self.root.join("refusal.json"),
            &serde_json::to_vec(
                &json!({"event":"consent_refused","code":"consent_required","surface":surface,"at":crate::store::now_ms()}),
            )?,
        )
    }

    #[cfg(unix)]
    fn lock(&self) -> Result<HeldLock> {
        use std::os::fd::AsRawFd;
        let file = crate::config::private_state_rw(&self.root.join("write.lock"))?;
        // SAFETY: file is a live owned descriptor. Nonblocking avoids stalling
        // the daemon; the local person may retry a racing settings write.
        anyhow::ensure!(
            unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0,
            "consent update in progress"
        );
        Ok(HeldLock(file))
    }
    #[cfg(not(unix))]
    fn lock(&self) -> Result<HeldLock> {
        anyhow::bail!("consent unavailable")
    }
}

/// Whether this daemon's own state (`legacy`, its `ACPMUX_HOME`) holds a machine join or a
/// consent record, which the account-wide authority must keep requiring.
pub(super) fn has_own_requirement(legacy: &Path) -> Result<bool> {
    Ok(exists(&legacy.join("machine-credential.json"))? || exists(&legacy.join("consent.json"))?)
}

fn exists(path: &Path) -> Result<bool> {
    match std::fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error.into()),
    }
}

#[cfg(unix)]
fn account_home() -> Result<PathBuf> {
    use std::ffi::{CStr, OsStr};
    use std::os::unix::ffi::OsStrExt;
    let mut entry = std::mem::MaybeUninit::<libc::passwd>::uninit();
    let mut result = std::ptr::null_mut();
    let mut buffer = vec![0u8; 64 * 1024];
    // SAFETY: all output pointers refer to live buffers; returned strings remain
    // valid until buffer drops. Use the kernel uid, never HOME or a tag's env.
    let code = unsafe {
        libc::getpwuid_r(
            libc::geteuid(),
            entry.as_mut_ptr(),
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            &mut result,
        )
    };
    anyhow::ensure!(code == 0 && !result.is_null(), "OS account home unavailable");
    // SAFETY: successful lookup populated result and pw_dir is NUL terminated.
    anyhow::ensure!(!unsafe { (*result).pw_dir }.is_null(), "OS account home unavailable");
    let home = unsafe { CStr::from_ptr((*result).pw_dir) };
    let path = PathBuf::from(OsStr::from_bytes(home.to_bytes()));
    anyhow::ensure!(path.is_absolute(), "OS account home unavailable");
    Ok(path)
}
#[cfg(not(unix))]
fn account_home() -> Result<PathBuf> {
    anyhow::bail!("OS account home unavailable")
}

#[cfg(test)]
#[path = "machine_consent_tests.rs"]
mod tests;
