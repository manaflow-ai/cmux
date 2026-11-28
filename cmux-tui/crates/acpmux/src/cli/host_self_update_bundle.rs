//! The patch bundle tick (RFD 0224 phase 5): each self-update run reads this host's signed
//! patch bundle (`bundles/<channel>/<target>.json` on the R2 tree, `cmux-patch-bundle.yml`
//! publishes it), verifies it against the web update keys and the installed build, writes its
//! files under `~/.acpmux/patches/<target>/files`, and keeps them only when the daemon's own
//! `--json daemon status` still answers within [`patch_bundle::HEALTH_BOUND`] and shares a wire
//! ABI with this build; else every file goes back and the id is never tried again here.
//! A missing bundle (404) is the usual case and says nothing.

use std::path::{Path, PathBuf};

use cmux_process::{Command, Stdio};
use cmux_signed_envelope::Key;
use cmux_signed_envelope::patch_bundle::{self, MAX_BUNDLE_BYTES, Outcome};
use serde_json::{Value, json};

use super::{FILES, Fetch};

/// Where `channel`'s bundle for `target` lives.
pub(crate) fn bundle_url(channel: &str, target: &str) -> String {
    format!("{FILES}/bundles/{channel}/{target}.json")
}

/// The directory a target's bundles write into, under the acpmux home.
pub(crate) fn root(home: &Path, target: &str) -> PathBuf {
    home.join("patches").join(target).join("files")
}

/// The rollback copies, the applied record and the bad ids.
pub(crate) fn state(home: &Path, target: &str) -> PathBuf {
    home.join("patches").join(target).join("state")
}

/// What one tick did.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum BundleOutcome {
    /// No bundle was read (none published: a 404), or no installed build to check it against.
    NotRead(String),
    /// Read but refused: a bad signature, another target or build, expired, a bad path.
    Refused(String),
    /// Marked bad on this host by an earlier rollback; not tried again.
    Bad {
        id: String,
    },
    Applied {
        id: String,
        files: usize,
    },
    AlreadyApplied {
        id: String,
    },
    RolledBack {
        id: String,
        why: String,
    },
}

impl BundleOutcome {
    pub(crate) fn json(&self) -> Value {
        match self {
            BundleOutcome::NotRead(why) => json!({"outcome": "not-read", "reason": why}),
            BundleOutcome::Refused(why) => json!({"outcome": "refused", "reason": why}),
            BundleOutcome::Bad { id } => json!({"outcome": "bad", "id": id}),
            BundleOutcome::Applied { id, files } => {
                json!({"outcome": "applied", "id": id, "files": files})
            }
            BundleOutcome::AlreadyApplied { id } => json!({"outcome": "already-applied", "id": id}),
            BundleOutcome::RolledBack { id, why } => {
                json!({"outcome": "rolled-back", "id": id, "reason": why})
            }
        }
    }

    /// The line a run prints, when it did something worth a line.
    pub(crate) fn line(&self) -> Option<String> {
        match self {
            BundleOutcome::Applied { id, files } => {
                Some(format!("patch bundle {id}: applied {files} file(s); the daemon answers"))
            }
            BundleOutcome::RolledBack { id, why } => {
                Some(format!("patch bundle {id}: rolled back ({why}); not tried again here"))
            }
            BundleOutcome::Refused(why) => Some(format!("patch bundle: refused: {why}")),
            BundleOutcome::NotRead(_) | BundleOutcome::Bad { .. } => None,
            BundleOutcome::AlreadyApplied { .. } => None,
        }
    }
}

/// Read, verify and apply `channel`'s bundle for `target` onto the build `base` (the installed
/// build's commit, short or full), keeping it only when `probe` passes.
#[allow(clippy::too_many_arguments)]
pub(super) async fn tick(
    home: &Path,
    fetch: &dyn Fetch,
    keys: &[Key],
    channel: &str,
    target: &str,
    base: Option<&str>,
    now: u64,
    probe: &mut dyn FnMut() -> Result<(), String>,
) -> BundleOutcome {
    let Some(base) = base else {
        return BundleOutcome::NotRead("the installed build names no commit".to_owned());
    };
    let body = match fetch.get(&bundle_url(channel, target), MAX_BUNDLE_BYTES).await {
        Ok(body) => body,
        Err(why) => return BundleOutcome::NotRead(why),
    };
    let bundle = match patch_bundle::verify(&body, keys, target, base, now) {
        Ok(bundle) => bundle,
        Err(why) => return BundleOutcome::Refused(why),
    };
    let state = state(home, target);
    if patch_bundle::bad(&state, &bundle.id).is_some() {
        return BundleOutcome::Bad { id: bundle.id };
    }
    let root = root(home, target);
    if let Err(e) = std::fs::create_dir_all(&root) {
        return BundleOutcome::Refused(format!("making {}: {e}", root.display()));
    }
    // A one-shot CLI run: the probe blocks this run (bounded by HEALTH_BOUND), nothing else.
    match patch_bundle::apply(&bundle, &root, &state, probe) {
        Ok(Outcome::Applied { id, files }) => BundleOutcome::Applied { id, files },
        Ok(Outcome::AlreadyApplied { id }) => BundleOutcome::AlreadyApplied { id },
        Ok(Outcome::RolledBack { id, why }) => BundleOutcome::RolledBack { id, why },
        Err(why) => BundleOutcome::Refused(why),
    }
}

/// Why a `--json daemon status` reply is not a healthy daemon, or None: it names a live pid
/// and shares a wire ABI with this build (the update's own health rule).
pub(crate) fn status_gap(status: &str) -> Option<String> {
    let v: Value = match serde_json::from_str(status.trim()) {
        Ok(v) => v,
        Err(_) => return Some("the daemon status is not JSON".to_owned()),
    };
    if v.get("pid").is_none_or(Value::is_null) {
        return Some("the daemon does not answer (no pid)".to_owned());
    }
    super::super::abi_gap(status)
}

/// The health probe: `<installed> --json daemon status` within `bound`, its reply kept in a
/// file under `state` (it runs to hundreds of KB, more than a pipe holds unread).
pub(crate) fn daemon_probe(
    installed: &Path,
    state: &Path,
    bound: std::time::Duration,
) -> Result<(), String> {
    std::fs::create_dir_all(state).map_err(|e| format!("making {}: {e}", state.display()))?;
    let out_path = state.join("probe-status.json");
    let out = std::fs::File::create(&out_path)
        .map_err(|e| format!("making {}: {e}", out_path.display()))?;
    let mut child = Command::new(installed)
        .args(["--json", "daemon", "status"])
        .stdin(Stdio::null())
        .stdout(out)
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("starting {} daemon status: {e}", installed.display()))?;
    // The probe's Child ends with this call: killed at the bound, reaped either way.
    match child.wait_timeout(bound) {
        Ok(Some(_)) => {}
        Ok(None) => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(format!("the daemon status did not answer within {bound:?}"));
        }
        Err(e) => return Err(format!("waiting on the daemon status: {e}")),
    }
    let status = std::fs::read_to_string(&out_path)
        .map_err(|e| format!("reading {}: {e}", out_path.display()))?;
    status_gap(&status).map_or(Ok(()), Err)
}

#[cfg(test)]
#[path = "host_self_update_bundle_tests.rs"]
mod tests;
