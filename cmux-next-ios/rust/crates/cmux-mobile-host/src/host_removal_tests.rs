//! Only the owner's removal stops hostd. The service closes the signaling socket with 4002
//! for two reasons (backend `team-hub.ts`): `removed` (`DELETE /v1/devices/:id`, account
//! deletion) and `silent` (the Mac stopped pinging for 90 s: asleep, a network change). On
//! 2026-11-27 a NIGHTLY hostd took a `4002 silent` for a removal, stopped for good (exit 78),
//! and the app's `removed` record kept it off after every relaunch. These run hostd against
//! the fake backend.
use super::recovery_tests::rig_config;
use super::*;
use crate::config::RecordedRemoval;
use cmux_mobile_link::api::MyDevice;
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use serde_json::json;
use tokio::sync::watch;

const WAIT: Duration = Duration::from_secs(15);

async fn connects_reach(backend: &FakeSignaling, device: &str, count: u64) {
    tokio::time::timeout(WAIT, async {
        while backend.signal_connects(device) < count {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .unwrap_or_else(|_| {
        panic!("{device} reached {} signaling connects, not {count}", backend.signal_connects(device))
    });
}

#[test]
fn only_4002_removed_is_a_removal() {
    assert!(removed("signaling closed by server: 4002 removed"));
    // The presence reaper's close (team-hub.ts `ws.close(4002, "silent")`): the Mac comes back.
    assert!(!removed("signaling closed by server: 4002 silent"));
    assert!(!removed("signaling closed by server: 4002 "));
    assert!(!removed("signaling closed by server: 4002 removed-ish"));
    assert!(!removed("signaling closed by server: 4000 replaced"));
}

/// The 2026-11-27 failure, end to end: a `4002 silent` close reconnects (before the fix hostd
/// returned `Stopped::Removed` here and never connected again); then the owner's real removal
/// (4002 `removed`) stops it.
#[tokio::test]
async fn a_silent_4002_close_reconnects_and_only_the_owners_removal_stops_hostd() {
    let backend = FakeSignaling::start(FakeOptions::default()).await;
    let dir = tempfile::tempdir().unwrap();
    let (_changes, receiver) = watch::channel(0);
    let host = tokio::spawn(run_with_changes(rig_config(backend.base_url.clone(), dir.path()), receiver));
    connects_reach(&backend, "mac", 1).await;

    backend.close_device("mac", 4002, "silent");
    connects_reach(&backend, "mac", 2).await;
    assert!(!host.is_finished(), "a silent close must not stop hostd");

    backend.remove_device("mac");
    let stopped = tokio::time::timeout(WAIT, host).await.expect("the removal stops hostd").unwrap().unwrap();
    assert_eq!(stopped, Stopped::Removed);
    assert_eq!(backend.signal_connects("mac"), 2, "a removed Mac does not register again");
}

/// A removal an older hostd recorded for a `4002 silent` close: the service still lists the
/// Mac, so the record is stale, hostd says so (`removal_cleared`) and connects.
#[tokio::test]
async fn a_stale_recorded_removal_is_cleared_and_hostd_connects() {
    let backend = FakeSignaling::start(FakeOptions::default()).await;
    backend.seed_device("owner", "mac", json!({"deviceId": "mac", "kind": "mac", "name": "Test Mac"}));
    let dir = tempfile::tempdir().unwrap();
    let mut config = rig_config(backend.base_url.clone(), dir.path());
    config.recorded_removal = Some(RecordedRemoval { device_id: Some("mac".into()) });
    let (_changes, receiver) = watch::channel(0);
    let host = tokio::spawn(run_with_changes(config, receiver));
    connects_reach(&backend, "mac", 1).await;
    assert!(!host.is_finished());
    host.abort();
}

/// A real removal the app recorded: the service no longer lists the Mac, so hostd stays
/// stopped and registers nothing (registering would undo the owner's removal).
#[tokio::test]
async fn a_real_recorded_removal_keeps_hostd_stopped() {
    let backend = FakeSignaling::start(FakeOptions::default()).await;
    let dir = tempfile::tempdir().unwrap();
    let mut config = rig_config(backend.base_url.clone(), dir.path());
    config.recorded_removal = Some(RecordedRemoval { device_id: Some("mac".into()) });
    let (_changes, receiver) = watch::channel(0);
    let stopped =
        tokio::time::timeout(WAIT, run_with_changes(config, receiver)).await.expect("stops").unwrap();
    assert_eq!(stopped, Stopped::Removed);
    assert_eq!(backend.signal_connects("mac"), 0);
}

fn mac(id: &str, machine: Option<&str>, created: &str) -> MyDevice {
    serde_json::from_value(json!({"deviceId": id, "kind": "mac", "machineId": machine, "createdAt": created}))
        .unwrap()
}

#[test]
fn a_recorded_removal_is_checked_by_its_device_id() {
    let listed = [mac("a", Some("m1"), "2026-01-01"), mac("b", Some("m1"), "2026-02-01")];
    assert_eq!(
        verify_removal(&listed, Some("A"), Some("m1"), &[]),
        RemovalCheck::StillListed { device_id: "a".into() }
    );
    assert_eq!(verify_removal(&listed, Some("gone"), Some("m1"), &[]), RemovalCheck::Removed);
    let phone: MyDevice = serde_json::from_value(json!({"deviceId": "gone", "kind": "phone"})).unwrap();
    assert_eq!(verify_removal(&[phone], Some("gone"), None, &[]), RemovalCheck::Removed, "only a Mac counts");
}

/// A record from before ids were kept (the 2026-11-27 NIGHTLY's: it forgot the id it removed): this
/// build's record is the newest Mac on this machine that is not another build's.
#[test]
fn a_legacy_recorded_removal_is_checked_by_machine_without_other_builds() {
    let listed = [
        mac("nightly", Some("m1"), "2026-10-21"),
        mac("stable", Some("m1"), "2026-11-01"),
        mac("elsewhere", Some("m2"), "2026-11-20"),
    ];
    let siblings = vec!["stable".to_owned()];
    assert_eq!(
        verify_removal(&listed, None, Some("m1"), &siblings),
        RemovalCheck::StillListed { device_id: "nightly".into() }
    );
    assert_eq!(verify_removal(&listed[1..], None, Some("m1"), &siblings), RemovalCheck::Removed);
    assert_eq!(
        verify_removal(&listed, None, None, &[]),
        RemovalCheck::Removed,
        "no machine id: nothing to match"
    );
}
