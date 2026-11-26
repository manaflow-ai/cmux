//! The daemon's watch on its channel: a fleet host takes a new feat-cmux-next
//! build within a minute of it being published, not at the next tick of
//! `acpmux-update.timer` (every 15 minutes, plus up to 2 of jitter).
//!
//! Leo, 2026-11-25: "so this is why we need the split-off of the stripped down
//! rust binary or whateevr the transport protocol situatoin. the bundling that
//! we have on vms and stuff".
//!
//! Every [`EVERY`] the daemon reads the build controller's marker, the
//! build `host self-update` takes first ([`prepare`](super::prepare)). When
//! that build's sha256 is not the installed `~/.local/bin/acpmux`'s, it waits
//! up to [`JITTER`] so the hosts of one fleet do not restart together, then
//! starts `acpmux-update.service`: the same unit the timer starts, so the
//! sha256 check, rollback, the lock, holds, the restart window and
//! [`NO_AUTO_UPDATE`] all still decide. The timer stays as the fallback.
//!
//! The watch reads only the controller, never the R2 channel self-update
//! falls back to. R2 is the Actions channel, which moves about once an hour,
//! so a controller read that missed used to name R2's older build. That
//! started the service for a build the install step then refused, and reset
//! the retry count of the new build. a lane VM saw 6 such starts in
//! 35 minutes on 2026-11-25. A miss is retried once after [`MISS_RETRY`];
//! when that misses too, the pass is skipped and the reason is logged when it
//! changes. Nor does the watch start for a build no newer than the installed
//! one: once a self-update has downloaded a build (`~/.acpmux/update/<sha>`),
//! its commit-time stamp is compared with the installed binary's, the same
//! rule the install step's `newerInstalled` refusal keeps. The controller's
//! marker can name an older commit after a newer one was installed (22b26281
//! after d3f59cc48, 2026-11-25), and the watch then started the service on
//! every retry, for a build it would never take.
//!
//! Fleet hosts only: the watch runs where a build controller is configured
//! (`CMUX_CI_CONTROLLER` or the fleet client's `client.json`), acpmux's own
//! update service is installed and [`NO_AUTO_UPDATE`] is absent. Every other
//! host updates as before.

use super::super::super::host_auto_update::{NO_AUTO_UPDATE, UPDATE_SERVICE};
use super::{CONTROLLER_FETCH, Controller};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// The channel the update service follows (`host self-update`'s default).
const CHANNEL: &str = "feat-cmux-next";

/// How often the watch reads the channel: a ~600 byte marker over the tailnet.
pub(super) const EVERY: Duration = Duration::from_secs(30);

/// The most a start of the update service is put off after a new build is seen.
pub(super) const JITTER: Duration = Duration::from_secs(30);

/// How long after a start the watch starts the service again while the build
/// is still not installed (a restart window, a busy daemon, a lock).
pub(super) const RETRY: Duration = Duration::from_secs(120);

/// Starts of the service for one build before the watch leaves it to the timer.
pub(super) const TRIES: u32 = 10;

/// How long the watch waits before reading the controller again after a read
/// that missed (a dropped connection, a timeout), within the same pass.
pub(super) const MISS_RETRY: Duration = Duration::from_secs(3);

/// What the watch remembers between reads.
#[derive(Debug, Default)]
pub(super) struct Watch {
    /// The sha256 the last start was for, when it was started and how often.
    pending: Option<(String, Instant, u32)>,
}

impl Watch {
    /// Whether to start the update service now: the channel's build `head`
    /// is not `installed`, is not known to be built from a commit no newer
    /// than the installed one (`not_newer`, [`not_newer_cached`]), and no
    /// start for it is in flight or out of tries.
    pub(super) fn due(
        &mut self,
        head: &str,
        installed: Option<&str>,
        not_newer: bool,
        now: Instant,
    ) -> bool {
        if installed == Some(head) || not_newer {
            self.pending = None;
            return false;
        }
        match &mut self.pending {
            Some((sha, at, tries)) if sha == head => {
                if *tries >= TRIES || now.duration_since(*at) < RETRY {
                    return false;
                }
                *at = now;
                *tries += 1;
                true
            }
            _ => {
                self.pending = Some((head.to_owned(), now, 1));
                true
            }
        }
    }
}

/// The sha256 of the acpmux build for `target` the controller's marker
/// names, read again once after [`MISS_RETRY`] when the first read fails; the
/// reason when neither read gives a marker that is on and has the target.
pub(super) async fn head(controller: &Controller<'_>, target: &str) -> Result<String, String> {
    match controller.marker(CHANNEL, target).await {
        Ok(marker) => Ok(marker.sha256),
        Err(_) => {
            tokio::time::sleep(MISS_RETRY).await;
            controller.marker(CHANNEL, target).await.map(|marker| marker.sha256)
        }
    }
}

/// Whether `candidate` is built from a commit no newer than `installed`'s, by
/// the `acpmux-commit-time=<secs>;` stamp each carries. The rule matches the
/// install step's `acpmux_downgrade`, which refuses a strictly older one: an
/// installed binary with no stamp (or 0) never counts as newer, and a
/// candidate with no stamp is from before the stamp, so older. An equal
/// commit time is the same commit, which the watch does not start for either.
pub(super) fn not_newer(candidate: &[u8], installed: &[u8]) -> bool {
    use crate::daemon::start_exe::embedded_commit_time;
    let Some(ours) = embedded_commit_time(installed).filter(|t| *t > 0) else { return false };
    match embedded_commit_time(candidate) {
        None => true,
        Some(0) => false,
        Some(theirs) => theirs <= ours,
    }
}

/// Whether the build `sha` that a self-update already downloaded to
/// `downloads` (`<sha>/acpmux-<target>`) is built from a commit no newer
/// than `installed`; false when it has not been downloaded.
pub(super) fn not_newer_cached(
    downloads: &Path,
    sha: &str,
    target: &str,
    installed: &[u8],
) -> bool {
    std::fs::read(downloads.join(sha).join(format!("acpmux-{target}")))
        .is_ok_and(|candidate| not_newer(&candidate, installed))
}

/// Whether this host is a fleet host whose daemon the watch keeps current.
pub(super) fn fleet_host(home: &Path, user: &Path, controller: bool) -> bool {
    controller
        && !home.join(NO_AUTO_UPDATE).exists()
        && std::fs::read(user.join(".config/systemd/user/acpmux-update.service"))
            .is_ok_and(|text| text == UPDATE_SERVICE.as_bytes())
}

/// A number in `0..max`, different across hosts and runs.
fn jitter(max: Duration) -> Duration {
    use std::hash::{BuildHasher, Hasher};
    let mut h = std::collections::hash_map::RandomState::new().build_hasher();
    h.write_u32(std::process::id());
    let ms = max.as_millis().max(1) as u64;
    Duration::from_millis(h.finish() % ms)
}

/// Run the watch for the daemon's life, on a fleet host ([`fleet_host`]);
/// elsewhere it returns at once.
pub(crate) async fn run() {
    if !cfg!(target_os = "linux") {
        return;
    }
    let Some(target) = super::local_target() else { return };
    let Some(user) = dirs::home_dir() else { return };
    let home = crate::config::default_home();
    let Some(url) = Controller::configured() else { return };
    if !fleet_host(&home, &user, true) {
        return;
    }
    let controller = Controller { url, fetch: &CONTROLLER_FETCH };
    let installed: PathBuf = user.join(".local/bin/acpmux");
    tracing::info!("watching {CHANNEL} for new acpmux builds every {}s", EVERY.as_secs());
    let downloads = home.join("update");
    let mut watch = Watch::default();
    // The last miss's reason, so a run of misses logs once and the recovery once.
    let mut missed: Option<(String, u32)> = None;
    // The build last found no newer than the installed one, so that is logged once.
    let mut older: Option<String> = None;
    loop {
        tokio::time::sleep(EVERY).await;
        if home.join(NO_AUTO_UPDATE).exists() {
            continue;
        }
        let head = match head(&controller, target).await {
            Ok(head) => head,
            Err(why) => {
                match &mut missed {
                    Some((last, n)) if *last == why => *n += 1,
                    _ => {
                        tracing::warn!(
                            "{CHANNEL} watch: no marker this pass, nothing started: {why}"
                        );
                        missed = Some((why, 1));
                    }
                }
                continue;
            }
        };
        if let Some((why, n)) = missed.take() {
            tracing::info!(
                "{CHANNEL} watch: the controller answers again after {n} missed passes ({why})"
            );
        }
        let bytes = tokio::fs::read(&installed).await.ok();
        let ours = bytes.as_deref().map(crate::sha256::sha256_hex);
        let not_newer = ours.as_deref() != Some(head.as_str())
            && bytes.as_deref().is_some_and(|b| not_newer_cached(&downloads, &head, target, b));
        if not_newer && older.as_deref() != Some(head.as_str()) {
            tracing::info!(
                "{CHANNEL} names acpmux {head}, built from a commit no newer than the installed one; not starting acpmux-update.service"
            );
            older = Some(head.clone());
        }
        if !watch.due(&head, ours.as_deref(), not_newer, Instant::now()) {
            continue;
        }
        let wait = jitter(JITTER);
        tracing::info!(
            "{CHANNEL} names acpmux {head}; starting acpmux-update.service in {}s",
            wait.as_secs()
        );
        tokio::time::sleep(wait).await;
        let started = tokio::process::Command::new("systemctl")
            .args(["--user", "start", "--no-block", "acpmux-update.service"])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::piped())
            .output()
            .await;
        match started {
            Ok(out) if out.status.success() => {}
            Ok(out) => tracing::warn!(
                "starting acpmux-update.service failed: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            ),
            Err(e) => tracing::warn!("starting acpmux-update.service failed: {e}"),
        }
    }
}

#[cfg(test)]
#[path = "host_update_watch_tests.rs"]
mod tests;
