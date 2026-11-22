//! The screen host's program on a joined Linux machine, kept on the channel's build by
//! `host self-update` (the module doc there). The join line installs `~/.local/bin/cmux-rd`
//! once and nothing replaced it after, so a machine joined weeks ago kept that cmux-rd (one
//! whose virtual display had no desktop, one that signed in again at every daemon restart)
//! while acpmux moved on every 15 minutes. Each run now also compares cmux-rd with the
//! channel's `cmux-tui-rd-<gnu target>` and installs the channel's, checked against its
//! sha256 and moved into place in one step; the daemon notices the new cmux-rd within a minute
//! (`share_host/linux.rs`) and sets the screen host up again. Nobody at the machine does
//! anything.
//!
//! - Only a machine whose join wanted cmux-rd gets it: one with a cmux-rd (a regular file), or
//!   whose join line could not install it ([`INSTALL_FAILED`] in the acpmux home, the
//!   reason it wrote, removed once installed). A cmux-rd that is a symlink was put there on
//!   purpose (a test build) and is kept, as the join line keeps it.
//! - A channel without a cmux-rd build changes nothing.
//! - A new tree can carry a new cmux-rd binary (nothing makes its build reproducible), and
//!   setting the host up again restarts it, which ends a share. So an installed cmux-rd is replaced at most once per
//!   [`REPLACE_EVERY`] (its modification time is when it was installed), unless `--now`, and
//!   never while the on-demand virtual display runs (a share, or a window on it, in its last
//!   ten minutes): the next run after does it.
//! - It never fails the self-update: its outcome is one more line, and `cmuxRd` in `--json`.

use super::Channel;
use super::Fetch;
use super::lower_hex;
use anyhow::{Result, anyhow, bail};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// At most one cmux-rd replacement a day, so a share is cut by an update at most that often.
pub(crate) const REPLACE_EVERY: Duration = Duration::from_secs(24 * 60 * 60);
/// The join line's reason file in the share host's folder (`share_host::linux::INSTALL_FAILED`
/// in `share_host::DIR`; that module is Unix only, this command builds everywhere).
pub(crate) const INSTALL_FAILED: &str = "share-host/cmux-rd-install";
/// cmux-rd under the user's home (`share_host::linux::cmux_rd_path`).
pub(crate) const CMUX_RD: &str = ".local/bin/cmux-rd";
/// The host's on-demand virtual display (cmux-rd-host's `setup::DISPLAY_UNIT`).
const DISPLAY_UNIT: &str = "cmux-screen-display.service";
const RD_MAX_BYTES: usize = 512 * 1024 * 1024;

/// Where cmux-rd is and what decides its replacement; tests point it at a fake home.
pub(crate) struct RdPaths {
    /// `~/.local/bin/cmux-rd`, the path the host's unit runs.
    pub(crate) rd: PathBuf,
    /// `<acpmux home>/share-host/cmux-rd-install`.
    pub(crate) install_failed: PathBuf,
    /// The gnu target cmux-rd is built for (it links glibc).
    pub(crate) target: &'static str,
    /// The youngest installed cmux-rd that may be replaced: [`REPLACE_EVERY`], zero with `--now`.
    pub(crate) min_age: Duration,
    /// Whether a share may be live: the on-demand virtual display runs.
    pub(crate) display_busy: fn() -> bool,
}

impl RdPaths {
    /// This machine's, None off Linux.
    pub(crate) fn here(user: &Path, home: &Path, acpmux_target: &str, now: bool) -> Option<Self> {
        Some(RdPaths {
            rd: user.join(CMUX_RD),
            install_failed: home.join(INSTALL_FAILED),
            target: gnu_target(acpmux_target)?,
            min_age: if now { Duration::ZERO } else { REPLACE_EVERY },
            display_busy: virtual_display_runs,
        })
    }
}

/// The gnu target of a Linux acpmux target: cmux-rd's build for it.
pub(crate) fn gnu_target(acpmux_target: &str) -> Option<&'static str> {
    match acpmux_target {
        "x86_64-unknown-linux-musl" => Some("x86_64-unknown-linux-gnu"),
        "aarch64-unknown-linux-musl" => Some("aarch64-unknown-linux-gnu"),
        _ => None,
    }
}

fn virtual_display_runs() -> bool {
    std::process::Command::new("systemctl")
        .args(["--user", "is-active", "--quiet", DISPLAY_UNIT])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// What one run did with cmux-rd.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum RdOutcome {
    /// This machine's join did not install cmux-rd.
    NotJoined,
    /// cmux-rd is a symlink, kept.
    Symlink,
    /// The channel carries no cmux-rd for this target.
    NoBuild,
    /// cmux-rd is the channel's.
    Current,
    /// The channel's differs, and a share may be live or cmux-rd was installed within
    /// [`REPLACE_EVERY`]: the reason.
    Later(String),
    /// The channel's was installed (its sha256).
    Installed(String),
    Failed(String),
}

impl RdOutcome {
    pub(crate) fn json(&self) -> Value {
        let (outcome, message) = match self {
            RdOutcome::NotJoined => ("notJoined", None),
            RdOutcome::Symlink => ("symlink", None),
            RdOutcome::NoBuild => ("noBuild", None),
            RdOutcome::Current => ("current", None),
            RdOutcome::Later(why) => ("later", Some(why.as_str())),
            RdOutcome::Installed(sha) => ("installed", Some(sha.as_str())),
            RdOutcome::Failed(why) => ("failed", Some(why.as_str())),
        };
        json!({"outcome": outcome, "message": message})
    }

    /// The line `host self-update` prints, None when there is nothing to say.
    pub(crate) fn line(&self) -> Option<String> {
        match self {
            RdOutcome::NotJoined | RdOutcome::Symlink | RdOutcome::Current => None,
            RdOutcome::NoBuild => Some("cmux-rd: the channel has no cmux-rd build".to_owned()),
            RdOutcome::Later(why) => Some(format!("cmux-rd: updated later ({why})")),
            RdOutcome::Installed(sha) => Some(format!("cmux-rd: installed the channel's ({sha})")),
            RdOutcome::Failed(why) => Some(format!("cmux-rd: not updated ({why})")),
        }
    }
}

/// Bring cmux-rd to `feed`'s build (the module doc), at `now`.
pub(crate) async fn refresh(
    paths: &RdPaths,
    fetch: &dyn Fetch,
    feed: &Channel,
    now: SystemTime,
) -> RdOutcome {
    let meta = std::fs::symlink_metadata(&paths.rd).ok();
    if meta.as_ref().is_some_and(|m| m.file_type().is_symlink()) {
        return RdOutcome::Symlink;
    }
    let file = meta.filter(|m| m.file_type().is_file());
    if file.is_none() && !paths.install_failed.is_file() {
        return RdOutcome::NotJoined;
    }
    let name = format!("cmux-tui-rd-{}", paths.target);
    let Some(sha) = feed.binaries.get(&name) else { return RdOutcome::NoBuild };
    if !lower_hex(sha, 64) {
        return RdOutcome::Failed(format!("the channel's sha256 for {name} is not a sha256"));
    }
    if let Some(meta) = &file {
        if std::fs::read(&paths.rd).is_ok_and(|b| crate::sha256::sha256_hex(&b) == *sha) {
            let _ = crate::home_fs::remove_file(&paths.install_failed);
            return RdOutcome::Current;
        }
        let age = meta.modified().ok().and_then(|t| now.duration_since(t).ok());
        if age.is_none_or(|age| age < paths.min_age) {
            return RdOutcome::Later("installed less than a day ago".to_owned());
        }
        if (paths.display_busy)() {
            return RdOutcome::Later("its virtual display is in use".to_owned());
        }
    }
    match install(paths, fetch, feed, &name, sha).await {
        Ok(()) => {
            let _ = crate::home_fs::remove_file(&paths.install_failed);
            RdOutcome::Installed(sha.clone())
        }
        Err(e) => RdOutcome::Failed(format!("{e:#}")),
    }
}

/// Download `name` from `feed`'s tree, check it is `sha`, write it beside cmux-rd and rename
/// it over cmux-rd.
async fn install(
    paths: &RdPaths,
    fetch: &dyn Fetch,
    feed: &Channel,
    name: &str,
    sha: &str,
) -> Result<()> {
    let url = format!("{}/tree/{}/{name}", super::FILES, feed.key);
    let bytes =
        fetch.get(&url, RD_MAX_BYTES).await.map_err(|e| anyhow!("downloading {url}: {e}"))?;
    let got = crate::sha256::sha256_hex(&bytes);
    if got != sha {
        bail!("{url} has sha256 {got}, not the channel's {sha}");
    }
    let dir = paths.rd.parent().ok_or_else(|| anyhow!("{} has no folder", paths.rd.display()))?;
    std::fs::create_dir_all(dir).map_err(|e| anyhow!("creating {}: {e}", dir.display()))?;
    let part = dir.join(".cmux-rd.new");
    std::fs::write(&part, &bytes).map_err(|e| anyhow!("writing {}: {e}", part.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&part, std::fs::Permissions::from_mode(0o755))
            .map_err(|e| anyhow!("{}: {e}", part.display()))?;
    }
    std::fs::rename(&part, &paths.rd).map_err(|e| {
        let _ = std::fs::remove_file(&part);
        anyhow!("installing {}: {e}", paths.rd.display())
    })
}

#[cfg(test)]
#[path = "host_self_update_rd_tests.rs"]
mod tests;
