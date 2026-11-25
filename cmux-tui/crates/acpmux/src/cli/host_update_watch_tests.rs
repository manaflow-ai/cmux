//! The channel watch: when it starts the update service, which build it reads,
//! and which hosts it runs on.

use super::super::Fetch;
use super::*;
use futures::future::BoxFuture;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};

const TARGET: &str = "x86_64-unknown-linux-musl";
const OLD: &str = "1111111111111111111111111111111111111111111111111111111111111111";
const NEW: &str = "2222222222222222222222222222222222222222222222222222222222222222";
const R2: &str = "3333333333333333333333333333333333333333333333333333333333333333";
const COMMIT: &str = "89abcdef0123456789abcdef0123456789abcdef";
const CTL: &str = "http://controller.test";

#[derive(Default)]
struct Files(HashMap<String, Vec<u8>>);

impl Fetch for Files {
    fn get<'a>(&'a self, url: &'a str, _max: usize) -> BoxFuture<'a, Result<Vec<u8>, String>> {
        let body = self.0.get(url).cloned().ok_or_else(|| "the server answered 404".to_owned());
        Box::pin(async move { body })
    }
}

/// A controller whose first `drops` reads fail as a dropped connection does.
struct Flaky {
    files: Files,
    drops: u32,
    reads: AtomicU32,
}

impl Fetch for Flaky {
    fn get<'a>(&'a self, url: &'a str, max: usize) -> BoxFuture<'a, Result<Vec<u8>, String>> {
        if self.reads.fetch_add(1, Ordering::SeqCst) < self.drops {
            return Box::pin(async { Err("error sending request: connection reset".to_owned()) });
        }
        self.files.get(url, max)
    }
}

fn stamped(secs: u64) -> Vec<u8> {
    format!("\x7fELF...acpmux-commit-time={secs};...").into_bytes()
}

fn marker(sha: &str, mode: &str) -> (String, Vec<u8>) {
    let body = serde_json::json!({
        "schema": "ci-channel/v1",
        "channel": CHANNEL,
        "commit": COMMIT,
        "mode": mode,
        "binaries": { "acpmux": { TARGET: format!("sha256:{sha}") } },
    });
    (format!("{CTL}/v1/channels/{CHANNEL}"), body.to_string().into_bytes())
}

#[test]
fn a_new_build_starts_the_service_once_then_retries_until_installed() {
    let mut watch = Watch::default();
    let t0 = Instant::now();
    assert!(!watch.due(OLD, Some(OLD), false, t0), "the installed build is the channel's");
    assert!(watch.due(NEW, Some(OLD), false, t0), "a new build starts the service at once");
    assert!(
        !watch.due(NEW, Some(OLD), false, t0 + EVERY),
        "not again while the start is in flight"
    );
    assert!(
        watch.due(NEW, Some(OLD), false, t0 + RETRY),
        "again after RETRY (a restart window, a lock)"
    );
    assert!(!watch.due(NEW, Some(NEW), false, t0 + RETRY * 2), "installed: nothing to do");
    assert!(
        watch.due(OLD, Some(NEW), false, t0 + RETRY * 3),
        "the channel moving again starts it again"
    );
}

#[test]
fn a_build_that_never_installs_is_left_to_the_timer_after_its_tries() {
    let mut watch = Watch::default();
    let t0 = Instant::now();
    let starts =
        (0..TRIES * 3).filter(|i| watch.due(NEW, Some(OLD), false, t0 + RETRY * *i)).count();
    assert_eq!(starts, TRIES as usize);
    assert!(
        watch.due(R2, Some(OLD), false, t0 + RETRY * TRIES * 3),
        "a newer build gets its own tries"
    );
}

#[test]
fn no_installed_binary_still_starts_the_service() {
    assert!(Watch::default().due(NEW, None, false, Instant::now()));
}

#[test]
fn a_build_no_newer_than_the_installed_one_never_starts_the_service() {
    let mut watch = Watch::default();
    let t0 = Instant::now();
    // A lane VM, 2026-11-25: the marker named 22b26281 (07:34:53Z) with
    // d3f59cc48 (07:55:49Z) installed; the old watch started the service on
    // every RETRY for a build the install step refused as newerInstalled.
    let starts =
        (0..TRIES * 3).filter(|i| watch.due(NEW, Some(OLD), true, t0 + RETRY * *i)).count();
    assert_eq!(starts, 0);
    assert!(watch.due(NEW, Some(OLD), false, t0 + RETRY * TRIES * 3), "once newer, it starts");
}

#[test]
fn not_newer_follows_the_install_steps_downgrade_rule() {
    let installed = stamped(1_795_593_349);
    assert!(not_newer(&stamped(1_795_592_093), &installed), "older commit");
    assert!(not_newer(&stamped(1_795_593_349), &installed), "the same commit");
    assert!(!not_newer(&stamped(1_795_593_350), &installed), "newer commit");
    assert!(not_newer(b"no stamp", &installed), "from before the stamp: older");
    assert!(!not_newer(&stamped(0), &installed), "a 0 stamp is never refused");
    assert!(!not_newer(&stamped(1), b"no stamp"), "an unstamped install is never protected");
    assert!(!not_newer(&stamped(1), &stamped(0)));
}

#[test]
fn a_downloaded_build_is_judged_by_its_stamp_and_an_absent_one_is_not() {
    let dir = tempfile::tempdir().unwrap();
    let installed = stamped(200);
    let at = |sha: &str| dir.path().join(sha);
    std::fs::create_dir_all(at(OLD)).unwrap();
    std::fs::write(at(OLD).join(format!("acpmux-{TARGET}")), stamped(100)).unwrap();
    std::fs::create_dir_all(at(NEW)).unwrap();
    std::fs::write(at(NEW).join(format!("acpmux-{TARGET}")), stamped(300)).unwrap();
    assert!(not_newer_cached(dir.path(), OLD, TARGET, &installed));
    assert!(!not_newer_cached(dir.path(), NEW, TARGET, &installed));
    assert!(!not_newer_cached(dir.path(), R2, TARGET, &installed), "not downloaded yet");
}

#[tokio::test(start_paused = true)]
async fn the_head_is_the_controllers_marker_when_it_is_on() {
    let ctl_files = Files([marker(NEW, "on")].into_iter().collect());
    let ctl = Controller { url: CTL.to_owned(), fetch: &ctl_files };
    assert_eq!(head(&ctl, TARGET).await.as_deref(), Ok(NEW));
}

#[tokio::test(start_paused = true)]
async fn a_controller_miss_names_no_build_and_never_r2s() {
    // The old watch fell back to R2 here, whose hourly channel named an older
    // build (8a9cc34c on a lane VM), and started the service for it.
    let report = Files([marker(NEW, "report")].into_iter().collect());
    let down = Files::default();
    for ctl_files in [&report, &down] {
        let ctl = Controller { url: CTL.to_owned(), fetch: ctl_files };
        assert!(head(&ctl, TARGET).await.is_err());
    }
}

#[tokio::test(start_paused = true)]
async fn one_dropped_read_is_retried_within_the_pass() {
    let once = Flaky {
        files: Files([marker(NEW, "on")].into_iter().collect()),
        drops: 1,
        reads: 0.into(),
    };
    let ctl = Controller { url: CTL.to_owned(), fetch: &once };
    let t0 = tokio::time::Instant::now();
    assert_eq!(head(&ctl, TARGET).await.as_deref(), Ok(NEW));
    assert!(t0.elapsed() >= MISS_RETRY);
    let twice = Flaky {
        files: Files([marker(NEW, "on")].into_iter().collect()),
        drops: 2,
        reads: 0.into(),
    };
    let ctl = Controller { url: CTL.to_owned(), fetch: &twice };
    assert!(head(&ctl, TARGET).await.unwrap_err().contains("connection reset"));
    assert_eq!(twice.reads.load(Ordering::SeqCst), 2, "one retry, not a loop");
}

#[test]
fn only_fleet_hosts_with_acpmuxs_own_update_unit_and_no_opt_out_watch() {
    let dir = tempfile::tempdir().unwrap();
    let user = dir.path();
    let home = user.join(".acpmux");
    let units = user.join(".config/systemd/user");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(&units).unwrap();
    let unit = units.join("acpmux-update.service");
    assert!(!fleet_host(&home, user, true), "no update unit");
    std::fs::write(&unit, "[Service]\nExecStart=/bin/true\n").unwrap();
    assert!(!fleet_host(&home, user, true), "someone else's unit");
    std::fs::write(&unit, UPDATE_SERVICE).unwrap();
    assert!(fleet_host(&home, user, true));
    assert!(!fleet_host(&home, user, false), "no build controller: not a fleet host");
    std::fs::write(home.join(NO_AUTO_UPDATE), "").unwrap();
    assert!(!fleet_host(&home, user, true), "host setup --no-auto-update");
}

#[test]
fn jitter_stays_under_its_bound() {
    for _ in 0..100 {
        assert!(jitter(JITTER) < JITTER);
    }
    assert_eq!(jitter(Duration::ZERO), Duration::ZERO);
}
