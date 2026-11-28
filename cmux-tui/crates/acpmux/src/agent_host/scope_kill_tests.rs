use super::*;

const SLICE: &str = "/user.slice/user-1001.slice/user@1001.service/acpmuxsessions.slice/\
                         acpmuxsessions-01a2.slice";

#[test]
fn only_the_scope_named_for_this_host_is_ended() {
    let own = format!("0::{SLICE}/acpmux-agent-host-4242-f91d17ad.scope\n");
    assert_eq!(
        own_scope_dir(&own, 4242).as_deref(),
        Some(format!("/sys/fs/cgroup{SLICE}/acpmux-agent-host-4242-f91d17ad.scope").as_str())
    );
    // Another host's scope, a pid that only shares a prefix, the daemon's unit.
    assert_eq!(own_scope_dir(&own, 424), None);
    assert_eq!(own_scope_dir(&own, 42421), None);
    let daemon = "0::/user.slice/user-1001.slice/user@1001.service/app.slice/acpmux.service\n";
    assert_eq!(own_scope_dir(daemon, 4242), None);
    let untagged = format!("0::{SLICE}/acpmux-agent-host-4242-.scope\n");
    assert_eq!(own_scope_dir(&untagged, 4242), None);
    assert_eq!(own_scope_dir("", 4242), None);
}

#[test]
fn the_kill_is_off_unless_switched_on() {
    assert!(!switched_on(None));
    assert!(!switched_on(Some("0")));
    assert!(!switched_on(Some("")));
    assert!(switched_on(Some("1")));
}
