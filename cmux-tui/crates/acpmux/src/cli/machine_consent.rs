//! One consent authority per OS account, independent of daemon tags and env.
//!
//! No released build could create pre-marker cloud enrollments. Every supported
//! enrollment writes this authority before redeem. Arbitrary branch-only old
//! ACPMUX_HOME state has no cross-tag upgrade path and must rejoin; inspecting
//! the current daemon's state below is defense in depth, not global discovery.
use crate::machine_record::{Consent, ConsentState, HeldLock};
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

    /// Persist before any remote redeem. A failed join keeps conservative gating. A join that
    /// is not a sign-in's ([`Self::enroll_as`] is what the joins call).
    #[cfg(test)]
    pub(super) fn enroll(&self) -> Result<()> {
        self.enroll_as(false)
    }

    /// [`Self::enroll`], saying whether signing in made this join (`enroll.rs`). Consent is as
    /// mandatory either way for what reaches this Mac from elsewhere (`hand/requests.rs`); a
    /// requirement that only sign-in joins made leaves the Mac's own sessions their computer use
    /// ([`Self::required_only_by_sign_in`]): signing in never takes local tools away. Any other
    /// join makes it the requirement it always was, for good.
    pub(super) fn enroll_as(&self, sign_in: bool) -> Result<()> {
        self.enroll_with_sync(sign_in, |path| {
            // Windows opens no folder as a file to flush it; NTFS journals the names.
            if cfg!(windows) && path.is_dir() {
                return Ok(());
            }
            std::fs::File::open(path)?.sync_all()?;
            Ok(())
        })
    }

    fn enroll_with_sync(&self, sign_in: bool, sync: impl Fn(&Path) -> Result<()>) -> Result<()> {
        self.prepare()?;
        let marker = self.root.join("enrolled.json");
        if exists(&marker)? {
            self.validate_marker()?;
            if !sign_in && self.marker_by_sign_in() {
                crate::config::write_atomic(&marker, MARKER)?;
            }
        } else {
            crate::config::write_atomic(&marker, if sign_in { MARKER_SIGN_IN } else { MARKER })?;
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

    /// Whether the marker says only sign-in joins made it.
    fn marker_by_sign_in(&self) -> bool {
        crate::config::private_state_file(&self.root.join("enrolled.json"))
            .ok()
            .and_then(|file| serde_json::from_reader::<_, Value>(file).ok())
            .is_some_and(|marker| {
                marker.get("by").and_then(Value::as_str)
                    == Some(crate::machine_record::JOINED_BY_SIGN_IN)
            })
    }

    /// Whether the account's consent requirement comes only from joins signing in made, and the
    /// person never set a consent here: the Mac's own sessions keep their computer use.
    pub(super) fn required_only_by_sign_in(&self) -> bool {
        self.validate_namespace().is_ok()
            && self.marker_by_sign_in()
            && !exists(&self.root.join("consent.json")).unwrap_or(true)
            && !exists(&self.legacy.join("consent.json")).unwrap_or(true)
    }

    /// [`Self::status`], as the Mac's own Computer Use is gated (`local_computer_use`: the app's
    /// helper, which serves only this Mac's own sessions) or as what reaches the Mac from
    /// elsewhere is. A requirement only sign-in joins made ([`Self::required_only_by_sign_in`])
    /// never gates the Mac's own use: its answer says no consent is required, and why. What
    /// reaches the Mac from elsewhere is gated as it always was.
    pub(super) fn status_for(&self, local_computer_use: bool) -> Value {
        let mut status = self.status();
        if local_computer_use
            && self.required_only_by_sign_in()
            && let Some(fields) = status.as_object_mut()
        {
            fields.insert("consentRequired".to_owned(), Value::Bool(false));
            fields.insert("localComputerUse".to_owned(), json!("keptBySignIn"));
        }
        status
    }

    fn validate_marker(&self) -> Result<()> {
        let file = crate::config::private_state_file(&self.root.join("enrolled.json"))?;
        let value: Value = serde_json::from_reader(file)?;
        anyhow::ensure!(value["schema"] == 1, "invalid machine enrollment marker");
        Ok(())
    }

    pub(super) fn retain_own_requirement(&self) -> Result<()> {
        if has_own_requirement(&self.legacy)? {
            let sign_in = !exists(&self.legacy.join("consent.json"))?
                && crate::machine_record::load_at(&self.legacy)?.is_some_and(|record| {
                    record.joined_by.as_deref() == Some(crate::machine_record::JOINED_BY_SIGN_IN)
                });
            self.enroll_as(sign_in)?;
        }
        Ok(())
    }

    fn required(&self) -> Result<bool> {
        self.validate_namespace()?;
        self.retain_own_requirement()?;
        crate::machine_record::load_at(&self.legacy)?;
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
        let user = if surface == crate::machine_record::SIGNED_IN_MACHINES {
            crate::machine_record::machine_user_id()
        } else {
            None
        };
        self.set_as(surface, granted, user)
    }

    /// [`Self::set`], with the account (hub user id) this machine is joined as: what a
    /// `signedInMachines` answer is for.
    pub(super) fn set_as(
        &self,
        surface: &str,
        granted: bool,
        user: Option<String>,
    ) -> Result<Consent> {
        self.prepare()?;
        // Serialize read/modify/write across app tags; disjoint grant changes
        // must never resurrect a concurrently revoked surface.
        let _lock = self.lock()?;
        let mut consent = self.consent();
        let state = if granted { ConsentState::Granted } else { ConsentState::None };
        match surface {
            "screen" => {
                consent.screen = state;
                consent.screen_local = Some(granted);
            }
            "control" => {
                consent.control = state;
                consent.control_local = Some(granted);
            }
            crate::machine_record::SIGNED_IN_MACHINES => {
                anyhow::ensure!(
                    !granted || user.is_some(),
                    "this machine is not joined to an account"
                );
                consent.signed_in_machines = state;
                // Any answer (Allow, Not now, a later Off) is the one ask this machine gets, for
                // the account it is joined as.
                consent.signed_in_machines_answered_at = Some(crate::store::now_ms().to_string());
                consent.signed_in_machines_user = user;
            }
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
        self.refused_from(surface, None)
    }

    /// [`Self::refused`], naming the machine that asked (`from`, a host the hub lists) when one
    /// is known, so the app's ask says which of the person's machines wants in.
    pub(super) fn refused_from(&self, surface: &str, from: Option<&str>) -> Result<()> {
        self.refused_by(surface, from, None)
    }

    /// [`Self::refused_from`], naming the account (hub user id) the ask was made for, which
    /// [`for_account`] keeps it to.
    pub(super) fn refused_by(
        &self,
        surface: &str,
        from: Option<&str>,
        user: Option<&str>,
    ) -> Result<()> {
        anyhow::ensure!(
            crate::machine_record::is_consent_surface(surface),
            "unknown consent surface"
        );
        self.prepare()?;
        let mut record = serde_json::Map::new();
        record.insert("event".into(), json!("consent_refused"));
        record.insert("code".into(), json!("consent_required"));
        record.insert("surface".into(), json!(surface));
        record.insert("at".into(), json!(crate::store::now_ms()));
        if let Some(from) = from.filter(|from| !from.is_empty()) {
            // A host name from the hub's book, bounded so the record stays small.
            record.insert("from".into(), json!(from.chars().take(128).collect::<String>()));
        }
        if let Some(user) = user {
            record.insert("user".into(), json!(user));
        }
        crate::config::write_atomic(&self.root.join("refusal.json"), &serde_json::to_vec(&record)?)
    }

    fn lock(&self) -> Result<HeldLock> {
        let file = crate::config::private_state_rw(&self.root.join("write.lock"))?;
        // Nonblocking avoids stalling the daemon; the local person may retry a racing settings
        // write.
        HeldLock::take(file, "consent update in progress")
    }
}

/// A consent status as it holds for `account`, the account (hub user id) this machine is joined
/// as now: a `signedInMachines` grant or answer given for another account (or for none) reads as
/// not given, and a `signedInMachines` ask made for another account is dropped, so after a
/// switch nothing is granted, the app shows no old ask, and the next request is asked again.
/// `signedInMachinesUser` is left as written. Screen and control are unchanged.
pub(crate) fn for_account(mut status: Value, account: Option<&str>) -> Value {
    let sim = crate::machine_record::SIGNED_IN_MACHINES;
    let mine = |user: Option<&Value>| account.is_some() && user.and_then(Value::as_str) == account;
    if let Some(consent) = status.get_mut("consent").and_then(Value::as_object_mut)
        && !mine(consent.get("signedInMachinesUser"))
    {
        consent.insert(sim.into(), json!("none"));
        consent.insert("signedInMachinesAnsweredAt".into(), Value::Null);
    }
    let refusal = status.get("lastRefusal");
    if refusal.and_then(|r| r.get("surface")).and_then(Value::as_str) == Some(sim)
        && !mine(refusal.and_then(|r| r.get("user")))
        && let Some(status) = status.as_object_mut()
    {
        status.insert("lastRefusal".into(), Value::Null);
    }
    status
}

/// The enrollment marker; with `by`, only sign-in joins made it.
const MARKER: &[u8] = b"{\"schema\":1}";
const MARKER_SIGN_IN: &[u8] = b"{\"schema\":1,\"by\":\"sign-in\"}";

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
    // The kernel uid, never HOME or a tag's env.
    // SAFETY: geteuid has no preconditions.
    home_of_uid(unsafe { libc::geteuid() })
}

/// The OS account home of `uid`, from the account database.
#[cfg(unix)]
pub(super) fn home_of_uid(uid: libc::uid_t) -> Result<PathBuf> {
    use std::ffi::{CStr, OsStr};
    use std::os::unix::ffi::OsStrExt;
    let mut entry = std::mem::MaybeUninit::<libc::passwd>::uninit();
    let mut result = std::ptr::null_mut();
    let mut buffer = vec![0u8; 64 * 1024];
    // SAFETY: all output pointers refer to live buffers; returned strings remain
    // valid until buffer drops.
    let code = unsafe {
        libc::getpwuid_r(
            uid,
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
/// The OS account's profile folder, from the shell's known folder for this process's token
/// (`SHGetKnownFolderPath(FOLDERID_Profile)`, what `dirs::home_dir` reads on Windows), never
/// `USERPROFILE` or a tag's env.
#[cfg(windows)]
fn account_home() -> Result<PathBuf> {
    let path = dirs::home_dir().ok_or_else(|| anyhow::anyhow!("OS account home unavailable"))?;
    anyhow::ensure!(path.is_absolute(), "OS account home unavailable");
    Ok(path)
}

#[cfg(test)]
#[path = "machine_consent_tests.rs"]
mod tests;
