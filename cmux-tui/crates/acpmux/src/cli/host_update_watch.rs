//! The daemon's watch on its channel: a fleet host takes a new feat-cmux-next
//! build within a minute of it being published, not at the next tick of
//! `acpmux-update.timer` (every 15 minutes, plus up to 2 of jitter).
//!
//! Leo, 2026-11-25: "so this is why we need the split-off of the stripped down
//! rust binary or whateevr the transport protocol situatoin. the bundling that
//! we have on vms and stuff".
//!
//! Every [`EVERY`] the daemon reads the build `host self-update` would take,
//! from the same place it reads it (the controller's marker, else the R2
//! channel file, [`prepare`](super::prepare)). When that build's sha256 is
//! not the installed `~/.local/bin/acpmux`'s, it waits up to [`JITTER`] so the
//! hosts of one fleet do not restart together, then starts
//! `acpmux-update.service`: the same unit the timer starts, so the sha256
//! check, rollback, the lock, holds, the restart window and
//! [`NO_AUTO_UPDATE`] all still decide. The timer stays as the fallback.
//!
//! Fleet hosts only: the watch runs where a build controller is configured
//! (`CMUX_CI_CONTROLLER` or the fleet client's `client.json`), acpmux's own
//! update service is installed and [`NO_AUTO_UPDATE`] is absent. Every other
//! host updates as before.

use super::super::super::host_auto_update::{NO_AUTO_UPDATE, UPDATE_SERVICE};
use super::{CHANNEL_MAX_BYTES, CONTROLLER_FETCH, Channel, Controller, Fetch, R2_FETCH};
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

/// What the watch remembers between reads.
#[derive(Debug, Default)]
pub(super) struct Watch {
    /// The sha256 the last start was for, when it was started and how often.
    pending: Option<(String, Instant, u32)>,
}

impl Watch {
    /// Whether to start the update service now: the channel's build `head`
    /// is not `installed`, and no start for it is in flight or out of tries.
    pub(super) fn due(&mut self, head: &str, installed: Option<&str>, now: Instant) -> bool {
        if installed == Some(head) {
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

/// The sha256 of the acpmux build for `target` that a self-update would take:
/// the controller's marker when it is on and has the target, else the R2
/// channel's. None when neither can be read.
pub(super) async fn head(
    r2: &dyn Fetch,
    controller: Option<&Controller<'_>>,
    target: &str,
) -> Option<String> {
    if let Some(ctl) = controller
        && let Ok(marker) = ctl.marker(CHANNEL, target).await
    {
        return Some(marker.sha256);
    }
    let body = r2.get(&super::channel_url(CHANNEL).ok()?, CHANNEL_MAX_BYTES).await.ok()?;
    let channel = Channel::parse(&body).ok()?;
    channel.sha256_for(target).ok().map(str::to_owned)
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
    let url = Controller::configured();
    if !fleet_host(&home, &user, url.is_some()) {
        return;
    }
    let controller = url.map(|url| Controller { url, fetch: &CONTROLLER_FETCH });
    let installed: PathBuf = user.join(".local/bin/acpmux");
    tracing::info!("watching {CHANNEL} for new acpmux builds every {}s", EVERY.as_secs());
    let mut watch = Watch::default();
    loop {
        tokio::time::sleep(EVERY).await;
        if home.join(NO_AUTO_UPDATE).exists() {
            continue;
        }
        let Some(head) = head(&R2_FETCH, controller.as_ref(), target).await else { continue };
        let ours = tokio::fs::read(&installed).await.ok().map(|b| crate::sha256::sha256_hex(&b));
        if !watch.due(&head, ours.as_deref(), Instant::now()) {
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
