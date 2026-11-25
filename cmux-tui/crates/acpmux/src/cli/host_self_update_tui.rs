//! The cmux-tui CLI beside acpmux, kept on the channel's build by `host self-update` (the module
//! doc there). The built-in `chief` harness runs `<acpmux's folder>/cmux-tui chief acp`
//! (`config::discover::add_chief`), so that file has to know the verbs the daemon asks of it. The
//! self-update replaced only `~/.local/bin/acpmux`: on a Linux host (2026-11-24) acpmux was a
//! November build while `~/.local/bin/cmux-tui` was from October and had no `chief` verb, and
//! every wake of the Chief failed (`cmux: unknown resource scope "chief"`) every 30 s for days.
//! Leo, 2026-11-24: "we need to be able to refresh chief like right now".
//!
//! - Only a cmux-tui that is there is replaced (a regular file): none is installed where none
//!   was, and a symlink was put there on purpose (a dev build) and is kept.
//! - It follows acpmux: it runs after acpmux's step, under the same update lease, and only when
//!   that step left the channel's build running (`updated`, or `current` but not
//!   `newerInstalled`, a host on a newer hand-pushed build). An acpmux rolled back, failed or
//!   held by the restart window leaves cmux-tui as it is, so the pair never splits further.
//! - The channel's tree holds `cmux-tui-<target>` and `cmux-tui-<target>.sha256` (CI publishes
//!   both; the channel file's `binaries` names only acpmux builds today, and its entry wins when
//!   it has one). The download is checked against that sha256, written beside and renamed over
//!   cmux-tui in one step; a running Chief keeps its old file, the next start runs the new one.
//! - It never fails the self-update: its outcome is `cmuxTui` in `--json`, and a line.

use super::{CHANNEL_MAX_BYTES, Channel, FILES, Fetch, lower_hex};
use anyhow::{Result, anyhow, bail};
use serde_json::{Value, json};
use std::path::Path;

const TUI_MAX_BYTES: usize = 512 * 1024 * 1024;

/// Where the channel's cmux-tui for this host is: its tree and the sha256 the channel file names
/// for it, if any. Read from the R2 channel in `prepare`, before acpmux's build is chosen.
#[derive(Debug, Clone)]
pub(crate) struct TuiSource {
    key: String,
    listed: Option<String>,
}

impl TuiSource {
    pub(crate) fn of(feed: &Channel, target: &str) -> TuiSource {
        TuiSource { key: feed.key.clone(), listed: feed.binaries.get(&name(target)).cloned() }
    }
}

fn name(target: &str) -> String {
    format!("cmux-tui-{target}")
}

/// What one run did with cmux-tui.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum TuiOutcome {
    /// No cmux-tui beside acpmux: nothing launches it, nothing is installed.
    Absent,
    /// cmux-tui is a symlink, kept.
    Symlink,
    /// acpmux's step did not leave the channel's build running: the reason.
    Skipped(String),
    /// cmux-tui is the channel's.
    Current,
    /// The channel's was installed (its sha256).
    Installed(String),
    Failed(String),
}

impl TuiOutcome {
    pub(crate) fn json(&self) -> Value {
        let (outcome, message) = match self {
            TuiOutcome::Absent => ("absent", None),
            TuiOutcome::Symlink => ("symlink", None),
            TuiOutcome::Skipped(why) => ("skipped", Some(why.as_str())),
            TuiOutcome::Current => ("current", None),
            TuiOutcome::Installed(sha) => ("installed", Some(sha.as_str())),
            TuiOutcome::Failed(why) => ("failed", Some(why.as_str())),
        };
        json!({"outcome": outcome, "message": message})
    }

    /// The line `host self-update` prints, None when there is nothing to say.
    pub(crate) fn line(&self) -> Option<String> {
        match self {
            TuiOutcome::Absent | TuiOutcome::Symlink | TuiOutcome::Current => None,
            TuiOutcome::Skipped(why) => Some(format!("cmux-tui: left as it is ({why})")),
            TuiOutcome::Installed(sha) => {
                Some(format!("cmux-tui: installed the channel's ({sha})"))
            }
            TuiOutcome::Failed(why) => Some(format!("cmux-tui: not updated ({why})")),
        }
    }
}

/// Bring `tui` (the cmux-tui beside acpmux) to the build of `source` (the R2 channel's tree, or
/// why it could not be read) for `target`. The caller decided acpmux's step allows it.
pub(crate) async fn refresh(
    tui: &Path,
    fetch: &dyn Fetch,
    source: &Result<TuiSource, String>,
    target: &str,
) -> TuiOutcome {
    let Ok(meta) = std::fs::symlink_metadata(tui) else { return TuiOutcome::Absent };
    if meta.file_type().is_symlink() {
        return TuiOutcome::Symlink;
    }
    if !meta.file_type().is_file() {
        return TuiOutcome::Absent;
    }
    let source = match source {
        Ok(source) => source,
        Err(why) => return TuiOutcome::Failed(why.clone()),
    };
    match install(tui, fetch, source, target).await {
        Ok(None) => TuiOutcome::Current,
        Ok(Some(sha)) => TuiOutcome::Installed(sha),
        Err(e) => TuiOutcome::Failed(format!("{e:#}")),
    }
}

/// The sha256 of the channel's cmux-tui: the channel file's entry, else the tree's `.sha256`.
async fn sha256(fetch: &dyn Fetch, source: &TuiSource, url: &str) -> Result<String> {
    if let Some(sha) = &source.listed {
        if !lower_hex(sha, 64) {
            bail!("the channel's sha256 for {url} is not a sha256");
        }
        return Ok(sha.clone());
    }
    let sha_url = format!("{url}.sha256");
    let body = fetch
        .get(&sha_url, CHANNEL_MAX_BYTES)
        .await
        .map_err(|e| anyhow!("downloading {sha_url}: {e}"))?;
    let text = String::from_utf8_lossy(&body);
    // `sha256sum` writes `<hex>  <name>`; a bare hex is fine too.
    let sha = text.split_whitespace().next().unwrap_or("").to_ascii_lowercase();
    if !lower_hex(&sha, 64) {
        bail!("{sha_url} holds no sha256");
    }
    Ok(sha)
}

/// Install the channel's cmux-tui over `tui` unless it is that already: None when current, else
/// the installed sha256. Checked, written beside, then renamed.
async fn install(
    tui: &Path,
    fetch: &dyn Fetch,
    source: &TuiSource,
    target: &str,
) -> Result<Option<String>> {
    let url = format!("{FILES}/tree/{}/{}", source.key, name(target));
    let sha = sha256(fetch, source, &url).await?;
    if std::fs::read(tui).is_ok_and(|b| crate::sha256::sha256_hex(&b) == sha) {
        return Ok(None);
    }
    let bytes =
        fetch.get(&url, TUI_MAX_BYTES).await.map_err(|e| anyhow!("downloading {url}: {e}"))?;
    let got = crate::sha256::sha256_hex(&bytes);
    if got != sha {
        bail!("{url} has sha256 {got}, not the tree's {sha}");
    }
    let dir = tui.parent().ok_or_else(|| anyhow!("{} has no folder", tui.display()))?;
    let part = dir.join(".cmux-tui.new");
    std::fs::write(&part, &bytes).map_err(|e| anyhow!("writing {}: {e}", part.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if let Err(e) = std::fs::set_permissions(&part, std::fs::Permissions::from_mode(0o755)) {
            let _ = std::fs::remove_file(&part);
            bail!("{}: {e}", part.display());
        }
    }
    std::fs::rename(&part, tui).map_err(|e| {
        let _ = std::fs::remove_file(&part);
        anyhow!("installing {}: {e}", tui.display())
    })?;
    Ok(Some(sha))
}
