//! The Chief host's cloud checks cost no wakeup while they have nothing to do
//! (perf-lead.md row 9, 2026-11-21): a ticker thread woke the host every 5 s
//! for as long as cloud VMs or agent keys were set up, with no cloud subagent
//! at all. The brain now runs the checks at their next due deadline, and has
//! none while nothing waits.

mod common;

use std::sync::Arc;
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::brain::Input;

#[derive(Default)]
struct Vms {
    calls: std::sync::Mutex<Vec<String>>,
}

impl optchat_chief::cloud_vms::CloudVms for Vms {
    fn resume(&self, peer: &str) -> Result<(), String> {
        self.calls.lock().unwrap().push(format!("resume {peer}"));
        Ok(())
    }
    fn pause(&self, peer: &str) -> Result<(), String> {
        self.calls.lock().unwrap().push(format!("pause {peer}"));
        Ok(())
    }
}

#[test]
fn cloud_vms_with_no_cloud_subagent_need_no_tick() {
    let mut h = Harness::new(default_script());
    h.brain.set_setting("cloud.autoPause", "true").unwrap();
    h.brain
        .set_cloud_vms(Some(Arc::new(Vms::default())), Duration::from_secs(60));
    assert_eq!(
        h.brain.next_cloud_tick(),
        None,
        "nothing to pause, delete, revoke or poll"
    );
    h.brain.step(Input::CloudTick);
    assert_eq!(h.brain.next_cloud_tick(), None, "a tick leaves nothing due");
}

#[test]
fn no_cloud_setup_needs_no_tick() {
    let h = Harness::new(default_script());
    assert_eq!(h.brain.next_cloud_tick(), None);
    assert!(
        h.brain
            .next_timer()
            .is_none_or(|at| at > Instant::now() + Duration::from_secs(30)),
        "an idle brain with no cloud setup has no near timer"
    );
}
