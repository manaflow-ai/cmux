//! The channel watch: when it starts the update service, which build it reads,
//! and which hosts it runs on.

use super::*;
use futures::future::BoxFuture;
use std::collections::HashMap;
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

fn r2_file(sha: &str) -> (String, Vec<u8>) {
    let body = serde_json::json!({
        "key": "0123456789abcdef0123456789abcdef01234567",
        "commit": COMMIT,
        "binaries": { format!("cmux-tui-acpmux-{TARGET}"): sha },
    });
    (super::super::channel_url(CHANNEL).unwrap(), body.to_string().into_bytes())
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
    assert!(!watch.due(OLD, Some(OLD), t0), "the installed build is the channel's");
    assert!(watch.due(NEW, Some(OLD), t0), "a new build starts the service at once");
    assert!(!watch.due(NEW, Some(OLD), t0 + EVERY), "not again while the start is in flight");
    assert!(watch.due(NEW, Some(OLD), t0 + RETRY), "again after RETRY (a restart window, a lock)");
    assert!(!watch.due(NEW, Some(NEW), t0 + RETRY * 2), "installed: nothing to do");
    assert!(watch.due(OLD, Some(NEW), t0 + RETRY * 3), "the channel moving again starts it again");
}

#[test]
fn a_build_that_never_installs_is_left_to_the_timer_after_its_tries() {
    let mut watch = Watch::default();
    let t0 = Instant::now();
    let starts = (0..TRIES * 3).filter(|i| watch.due(NEW, Some(OLD), t0 + RETRY * *i)).count();
    assert_eq!(starts, TRIES as usize);
    assert!(watch.due(R2, Some(OLD), t0 + RETRY * TRIES * 3), "a newer build gets its own tries");
}

#[test]
fn no_installed_binary_still_starts_the_service() {
    assert!(Watch::default().due(NEW, None, Instant::now()));
}

#[tokio::test]
async fn the_head_is_the_controllers_marker_when_it_is_on() {
    let ctl_files = Files([marker(NEW, "on")].into_iter().collect());
    let r2 = Files([r2_file(R2)].into_iter().collect());
    let ctl = Controller { url: CTL.to_owned(), fetch: &ctl_files };
    assert_eq!(head(&r2, Some(&ctl), TARGET).await.as_deref(), Some(NEW));
}

#[tokio::test]
async fn the_head_falls_back_to_r2_as_self_update_does() {
    let r2 = Files([r2_file(R2)].into_iter().collect());
    let report = Files([marker(NEW, "report")].into_iter().collect());
    let down = Files::default();
    for ctl_files in [&report, &down] {
        let ctl = Controller { url: CTL.to_owned(), fetch: ctl_files };
        assert_eq!(head(&r2, Some(&ctl), TARGET).await.as_deref(), Some(R2));
    }
    assert_eq!(head(&r2, None, TARGET).await.as_deref(), Some(R2));
    assert_eq!(head(&down, None, TARGET).await, None, "nothing readable: no start");
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
