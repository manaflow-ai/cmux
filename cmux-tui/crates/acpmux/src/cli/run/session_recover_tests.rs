use super::*;
use serde_json::json;

fn args() -> RecoverArgs {
    RecoverArgs {
        session: "lane".into(),
        restarts: 0,
        max_restarts: 2,
        network: false,
        move_failed: false,
        dry_run: true,
    }
}

fn place(local_ok: bool) -> Value {
    json!({"hosts": [
        {"name": "lane-1", "local": true, "ok": local_ok, "room": if local_ok { 3.0 } else { 0.0 }},
        {"name": "small", "local": false, "ok": true, "room": 1.0, "live": 2},
        {"name": "big", "local": false, "ok": true, "room": 6.0, "live": 4},
        {"name": "full", "local": false, "ok": false, "room": 0.0, "refused": "no room"},
    ]})
}

#[test]
fn a_host_with_room_restarts_in_place() {
    let f = facts(&place(true), None, &args());
    assert!(f.host_room && !f.on_demand);
    assert_eq!(f.targets, vec!["big", "small"]);
    assert!(matches!(route(&f), Route::Restart { .. }));
}

#[test]
fn a_full_host_moves_to_the_roomiest_admitted_machine() {
    let f = facts(&place(false), None, &args());
    assert!(!f.host_room);
    assert_eq!(route(&f), Route::Move { to: "big".into(), why: route(&f).why().into() });
}

#[test]
fn an_on_demand_host_moves_and_a_person_s_machine_is_never_a_target() {
    let registry = json!({"machines": {
        "lane-1": {"on_demand": true},
        "big": {"interactive": true},
    }});
    let f = facts(&place(true), Some(&registry), &args());
    assert!(f.on_demand);
    assert!(!f.targets.contains(&"big".to_owned()), "{:?}", f.targets);
    assert!(matches!(route(&f), Route::Move { ref to, .. } if to == "small"));
}

#[test]
fn a_network_death_never_restarts_and_used_restarts_need_a_successor() {
    let mut a = args();
    a.network = true;
    assert!(matches!(route(&facts(&place(true), None, &a)), Route::Move { .. }));
    let mut a = args();
    a.restarts = 2;
    assert!(matches!(route(&facts(&place(true), None, &a)), Route::Successor { .. }));
}
