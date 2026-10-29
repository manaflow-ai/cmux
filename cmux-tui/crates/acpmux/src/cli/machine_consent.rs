//! One consent authority per OS account, independent of daemon tags and env.
use super::cloud_join::{Consent, ConsentState};
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
        self.prepare()?;
        if exists(&self.root.join("enrolled.json"))? {
            self.validate_marker()?;
            return Ok(());
        }
        crate::config::write_atomic(&self.root.join("enrolled.json"), b"{\"schema\":1}")?;
        std::fs::File::open(&self.root)?.sync_all()?;
        Ok(())
    }

    fn validate_marker(&self) -> Result<()> {
        let file = crate::config::private_state_file(&self.root.join("enrolled.json"))?;
        let value: Value = serde_json::from_reader(file)?;
        anyhow::ensure!(value["schema"] == 1, "invalid machine enrollment marker");
        Ok(())
    }

    pub(super) fn migrate(&self) -> Result<()> {
        if exists(&self.legacy.join("machine-credential.json"))?
            || exists(&self.legacy.join("consent.json"))?
        {
            self.enroll()?;
        }
        Ok(())
    }

    fn required(&self) -> Result<bool> {
        self.validate_namespace()?;
        self.migrate()?;
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
    fn lock(&self) -> Result<std::fs::File> {
        use std::os::fd::AsRawFd;
        let file = crate::config::private_state_rw(&self.root.join("write.lock"))?;
        // SAFETY: file is a live owned descriptor. Nonblocking avoids stalling
        // the daemon; the local person may retry a racing settings write.
        anyhow::ensure!(
            unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0,
            "consent update in progress"
        );
        Ok(file)
    }
    #[cfg(not(unix))]
    fn lock(&self) -> Result<std::fs::File> {
        anyhow::bail!("consent unavailable")
    }
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
mod tests {
    use super::*;
    fn fixture() -> (tempfile::TempDir, Authority, Authority) {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("os-account/.acpmux/machine-consent");
        let a = Authority { root: root.clone(), legacy: dir.path().join("tag-a") };
        let b = Authority { root, legacy: dir.path().join("tag-b") };
        (dir, a, b)
    }
    #[test]
    fn tags_share_enrollment_and_live_grants_and_revocation() {
        let (_dir, a, b) = fixture();
        assert_eq!(b.status()["consentRequired"], false);
        a.enroll().unwrap();
        assert_eq!(b.status()["consentRequired"], true);
        assert_eq!(b.status()["consent"]["screen"], "none");
        a.set("screen", true).unwrap();
        assert_eq!(b.status()["consent"]["screen"], "granted");
        b.set("screen", false).unwrap();
        assert_eq!(a.status()["consent"]["screen"], "none");
        assert_eq!(a.status()["consentRequired"], true);
    }
    #[test]
    fn legacy_presence_migrates_requirement_never_grants() {
        let (_dir, a, b) = fixture();
        std::fs::create_dir_all(&a.legacy).unwrap();
        std::fs::write(
            a.legacy.join("consent.json"),
            b"{\"screen\":\"granted\",\"control\":\"granted\"}",
        )
        .unwrap();
        assert_eq!(a.status()["consentRequired"], true);
        assert_eq!(b.status()["consentRequired"], true);
        assert_eq!(b.status()["consent"]["screen"], "none");
    }
    #[test]
    fn refusal_is_shared_but_does_not_grant_or_enroll() {
        let (_dir, a, b) = fixture();
        a.refused("screen").unwrap();
        let status = b.status();
        assert_eq!(status["consentRequired"], false);
        assert_eq!(status["lastRefusal"]["surface"], "screen");
        assert_eq!(status["consent"]["screen"], "none");
        assert!(a.refused("anything").is_err());
    }
    #[cfg(unix)]
    #[test]
    fn authority_files_are_private_and_symlink_authority_fails_closed() {
        use std::os::unix::fs::{MetadataExt, symlink};
        let (dir, a, b) = fixture();
        a.enroll().unwrap();
        a.set("control", true).unwrap();
        a.refused("control").unwrap();
        assert_eq!(std::fs::metadata(&a.root).unwrap().mode() & 0o777, 0o700);
        for name in ["enrolled.json", "consent.json", "refusal.json"] {
            assert_eq!(std::fs::metadata(a.root.join(name)).unwrap().mode() & 0o777, 0o600);
        }
        let linked = dir.path().join("link");
        symlink(&a.root, &linked).unwrap();
        let attacker = Authority { root: linked, legacy: b.legacy };
        assert_eq!(attacker.status()["consentRequired"], true);
        assert_eq!(attacker.status()["consent"]["control"], "none");
    }
    #[cfg(unix)]
    #[test]
    fn redirected_parent_is_refused_even_when_authority_does_not_exist() {
        use std::os::unix::fs::symlink;
        let dir = tempfile::tempdir().unwrap();
        let destination = dir.path().join("elsewhere");
        std::fs::create_dir(&destination).unwrap();
        let parent = dir.path().join(".acpmux");
        symlink(destination, &parent).unwrap();
        let authority =
            Authority { root: parent.join("machine-consent"), legacy: dir.path().join("tag") };
        assert!(authority.enroll().is_err());
        assert!(authority.set("screen", true).is_err());
        assert_eq!(authority.status()["consentRequired"], true);
        assert_eq!(authority.status()["consent"]["screen"], "none");
    }
}
