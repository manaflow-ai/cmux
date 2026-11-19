use super::*;

/// A health reading: GB of RAM free (of 4x that total), cores, 1-minute load, GB disk free, live
/// agents, and the OS.
fn health(ram_gb: f64, cores: u64, load: f64, disk_gb: f64, live: u64, os: &str) -> Value {
    json!({
        "os": os, "cpus": cores, "load": [load, load, load],
        "ram": {"freeBytes": (ram_gb * GB) as u64, "totalBytes": (ram_gb * 4.0 * GB) as u64},
        "swap": {"usedBytes": 0, "totalBytes": (8.0 * GB) as u64},
        "disk": {"freeBytes": (disk_gb * GB) as u64}, "liveSessions": live,
        "pressure": {"ok": true, "over": [], "cores": cores}
    })
}

/// A 36 GB, 12-core Mac with 20 GB free, idle.
fn idle_mac() -> Value {
    health(20.0, 12, 1.0, 300.0, 1, "macos")
}

/// The same Mac over its budget: little RAM free, every core busy, the meter says over.
fn loaded_mac() -> Value {
    let mut h = health(3.0, 12, 14.0, 300.0, 6, "macos");
    h["pressure"] = json!({"ok": false, "over": ["cpu", "ram"], "cores": 12});
    h
}

fn local(h: Value) -> Candidate {
    Candidate { name: "leos-mac".into(), local: true, health: h, health_at: None, via_hub: false }
}

fn peer(name: &str, h: Value) -> Candidate {
    Candidate { name: name.into(), local: false, health: h, health_at: None, via_hub: false }
}

fn input(local_h: Value, peers: Vec<Candidate>) -> Input {
    let power = Power::from_health(&local_h);
    Input {
        local: local(local_h),
        peers,
        registry: None,
        power,
        folder: Folder { bytes: Some(40 * 1024 * 1024), peers_with_copy: vec![] },
        needs: Needs::default(),
        cloud: Cloud { available: true, ..Cloud::default() },
    }
}

fn big_box() -> Candidate {
    peer("big-box", health(100.0, 32, 2.0, 800.0, 3, "linux"))
}

#[test]
fn a_small_local_repo_stays_on_this_mac() {
    let v = decide(&input(idle_mac(), vec![big_box()]));
    assert_eq!(v.place, Place::Local, "{v:#?}");
    assert!(v.why.starts_with("This Mac: room for"), "{}", v.why);
    assert!(!v.overloaded);
}

#[test]
fn a_mac_under_load_goes_to_a_joined_machine() {
    let v = decide(&input(loaded_mac(), vec![big_box()]));
    assert_eq!(v.place, Place::Peer("big-box".into()), "{v:#?}");
    assert!(v.why.starts_with("big-box: This Mac is busy (over its budget"), "{}", v.why);
}

#[test]
fn a_mac_under_load_with_no_joined_machine_goes_to_cloud() {
    let v = decide(&input(loaded_mac(), vec![]));
    assert_eq!(v.place, Place::Cloud, "{v:#?}");
    assert!(v.why.starts_with("Cloud: This Mac is busy"), "{}", v.why);
}

#[test]
fn a_joined_machine_with_room_beats_cloud_and_a_full_one_does_not() {
    let mut full = health(3.0, 8, 9.0, 800.0, 3, "linux");
    full["pressure"] = json!({"ok": false, "over": ["ram"], "cores": 8});
    let v = decide(&input(loaded_mac(), vec![peer("full-box", full)]));
    assert_eq!(v.place, Place::Cloud, "{v:#?}");
    assert!(v.reasons.iter().any(|r| r == "no joined machine has room"), "{:?}", v.reasons);
}

#[test]
fn with_nowhere_else_this_mac_takes_it_and_says_so() {
    let mut i = input(loaded_mac(), vec![]);
    i.cloud.available = false;
    let v = decide(&i);
    assert_eq!(v.place, Place::Local);
    assert!(v.overloaded);
    assert!(v.why.contains("no other place takes it"), "{}", v.why);
}

#[test]
fn a_closed_lid_starts_the_chat_in_cloud() {
    let mut h = idle_mac();
    h["power"] = json!({"lidClosed": true, "onAc": true, "batteryPercent": 90});
    let v = decide(&input(h, vec![]));
    assert_eq!(v.place, Place::Cloud, "{v:#?}");
    assert!(v.why.contains("away (the lid is closed)"), "{}", v.why);
}

#[test]
fn with_the_network_down_the_chat_stays_on_this_mac() {
    let mut h = loaded_mac();
    h["network"] = json!({"up": false});
    let v = decide(&input(h, vec![big_box()]));
    assert_eq!(v.place, Place::Local);
    assert_eq!(v.why, "This Mac: the network is down");
}

#[test]
fn low_battery_counts_as_load_and_ac_power_does_not() {
    let mut h = idle_mac();
    h["power"] = json!({"batteryPercent": 12, "onAc": false});
    assert_eq!(decide(&input(h.clone(), vec![big_box()])).place, Place::Peer("big-box".into()));
    h["power"]["onAc"] = json!(true);
    assert_eq!(decide(&input(h, vec![big_box()])).place, Place::Local);
}

#[test]
fn macos_work_never_goes_to_cloud_or_a_linux_machine() {
    let mut i = input(loaded_mac(), vec![big_box()]);
    i.needs.macos = true;
    let v = decide(&i);
    assert_eq!(v.place, Place::Local, "{v:#?}");
    assert!(v.overloaded);
    let mac_mini = peer("mini", health(30.0, 10, 1.0, 400.0, 0, "macos"));
    i.peers.push(mac_mini);
    assert_eq!(decide(&i).place, Place::Peer("mini".into()));
}

#[test]
fn gpu_work_goes_only_where_there_is_a_gpu() {
    let mut i = input(idle_mac(), vec![big_box()]);
    i.needs.gpu = true;
    assert_eq!(decide(&i).place, Place::Local, "the Mac has no gpu field, Cloud has no GPU");
    i.cloud.gpu = true;
    assert_eq!(decide(&i).place, Place::Cloud);
    let mut g = health(60.0, 16, 1.0, 500.0, 0, "linux");
    g["gpu"] = json!({"name": "L4"});
    i.peers.push(peer("gpu-box", g));
    assert_eq!(decide(&i).place, Place::Peer("gpu-box".into()));
}

#[test]
fn a_long_build_needs_two_lanes_of_room_here() {
    // 7 GB free, defaults reserve 4 and take 2 a lane: room for 1.
    let h = health(7.0, 12, 1.0, 300.0, 0, "macos");
    assert_eq!(decide(&input(h.clone(), vec![big_box()])).place, Place::Local);
    let mut i = input(h, vec![big_box()]);
    i.needs.long_build = true;
    assert_eq!(decide(&i).place, Place::Peer("big-box".into()));
}

#[test]
fn a_big_folder_prefers_a_machine_that_already_has_it() {
    let mut i = input(
        loaded_mac(),
        vec![big_box(), peer("has-it", health(30.0, 8, 1.0, 300.0, 0, "linux"))],
    );
    i.folder =
        Folder { bytes: Some(9 * 1024 * 1024 * 1024), peers_with_copy: vec!["has-it".into()] };
    assert_eq!(decide(&i).place, Place::Peer("has-it".into()));
    i.folder.bytes = Some(100 * 1024 * 1024);
    assert_eq!(
        decide(&i).place,
        Place::Peer("big-box".into()),
        "a small folder takes placement's pick"
    );
}

#[test]
fn a_used_up_cloud_allowance_keeps_the_chat_off_cloud() {
    let mut i = input(loaded_mac(), vec![]);
    i.cloud.budget_left = Some(0.0);
    let v = decide(&i);
    assert_eq!(v.place, Place::Local);
    assert!(v.reasons.iter().any(|r| r.contains("allowance is used up")));
}

fn running_here() -> Running {
    Running {
        place: Place::Local,
        home: Place::Local,
        pinned: false,
        turn_active: true,
        local_over_secs: 0,
    }
}

#[test]
fn closing_the_lid_moves_a_running_chat_to_cloud_and_opening_it_brings_it_back() {
    let mut closed = idle_mac();
    closed["power"] = json!({"lidClosed": true, "onAc": false, "batteryPercent": 80});
    let m = rejudge(&running_here(), &input(closed, vec![])).expect("moves");
    assert_eq!(m.to, Place::Cloud);
    assert!(!m.back);

    let away = Running { place: Place::Cloud, turn_active: false, ..running_here() };
    let mut open = idle_mac();
    open["power"] = json!({"lidClosed": false, "onAc": false, "batteryPercent": 80});
    let m = rejudge(&away, &input(open.clone(), vec![])).expect("comes back");
    assert_eq!(m.to, Place::Local);
    assert!(m.back);
    assert!(m.why.starts_with("This Mac is back: room for"), "{}", m.why);

    // Not mid-turn: it waits for the turn to end.
    let busy = Running { turn_active: true, ..away };
    assert_eq!(rejudge(&busy, &input(open, vec![])), None);
}

#[test]
fn going_to_sleep_moves_a_chat_like_a_closed_lid() {
    let mut i = input(idle_mac(), vec![big_box()]);
    i.power.sleeping = true;
    let m = rejudge(&running_here(), &i).expect("moves");
    assert_eq!(m.to, Place::Peer("big-box".into()));
}

#[test]
fn load_moves_a_running_chat_only_after_it_held() {
    let i = input(loaded_mac(), vec![big_box()]);
    let brief = Running { local_over_secs: HOLD_SECS - 1, ..running_here() };
    assert_eq!(rejudge(&brief, &i), None, "a burst of load moves nothing");
    let held = Running { local_over_secs: HOLD_SECS, ..running_here() };
    assert_eq!(rejudge(&held, &i).map(|m| m.to), Some(Place::Peer("big-box".into())));
    // An idle Mac never moves its chats, however long the counter says.
    let calm = input(idle_mac(), vec![big_box()]);
    assert_eq!(rejudge(&held, &calm), None);
}

#[test]
fn a_pinned_chat_never_moves_and_nothing_moves_offline() {
    let mut closed = idle_mac();
    closed["power"] = json!({"lidClosed": true});
    let pinned = Running { pinned: true, ..running_here() };
    assert_eq!(rejudge(&pinned, &input(closed.clone(), vec![])), None);
    closed["network"] = json!({"up": false});
    assert_eq!(rejudge(&running_here(), &input(closed, vec![])), None);
}

#[test]
fn a_chat_comes_back_only_with_room_for_two_and_battery_to_spare() {
    let away = Running { place: Place::Cloud, turn_active: false, ..running_here() };
    // 7 GB free: room for 1 (defaults reserve 4, 2 a lane), under BACK_ROOM_LANES.
    let tight = health(7.0, 12, 1.0, 300.0, 0, "macos");
    assert_eq!(rejudge(&away, &input(tight, vec![])), None);
    let mut low = idle_mac();
    low["power"] = json!({"batteryPercent": 25, "onAc": false});
    assert_eq!(rejudge(&away, &input(low.clone(), vec![])), None);
    low["power"]["onAc"] = json!(true);
    assert!(rejudge(&away, &input(low, vec![])).is_some());
}

#[test]
fn a_chat_that_started_elsewhere_is_not_brought_here() {
    let started_in_cloud =
        Running { place: Place::Cloud, home: Place::Cloud, turn_active: false, ..running_here() };
    assert_eq!(rejudge(&started_in_cloud, &input(idle_mac(), vec![])), None);
}

#[test]
fn a_mac_in_the_fleet_without_a_lanes_entry_is_weighed_with_defaults() {
    let mut i = input(idle_mac(), vec![big_box()]);
    i.registry = Some(json!({"machines": {"big-box": {"lanes": {"rank": 1, "build": true}}}}));
    let v = decide(&i);
    assert_eq!(v.place, Place::Local, "{v:#?}");
    assert_eq!(v.local["ok"], true);
}

#[test]
fn the_verdict_json_is_what_the_app_reads() {
    let v = decide(&input(loaded_mac(), vec![big_box()])).to_json();
    assert_eq!(v["place"], "peer");
    assert_eq!(v["peer"], "big-box");
    assert!(v["why"].is_string() && v["reasons"].is_array() && v["overloaded"] == false);
    assert_eq!(Place::parse("peer", Some("big-box")), Some(Place::Peer("big-box".into())));
    assert_eq!(Place::parse("peer", None), None);
}
