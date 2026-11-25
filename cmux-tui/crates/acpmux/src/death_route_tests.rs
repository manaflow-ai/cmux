use super::*;

fn s(v: &[&str]) -> Vec<String> {
    v.iter().map(|x| x.to_string()).collect()
}

/// A session on `vm-a` whose row was read, its host up, with fleet hosts `b` and `c` answering.
fn dead() -> Facts {
    Facts {
        key: "vm-a/lane".into(),
        host: "vm-a".into(),
        has_row: true,
        host_grace_seconds: 1800.0,
        failover_min_seconds: 240.0,
        max_restarts: 2,
        max_failovers: 2,
        hosts: Hosts {
            move_to: s(&["b", "c"]),
            answering: s(&["vm-a", "b", "c"]),
            room_known: true,
            admitted: s(&["b", "c"]),
            none_text: "no host has room".into(),
            ..Hosts::default()
        },
        ..Facts::default()
    }
}

#[test]
fn a_session_dead_on_an_answering_host_restarts_in_place_until_its_restarts_run_out() {
    let mut f = dead();
    assert_eq!(route(&f), Route::Restart { number: 1 });
    f.tried.restarts = 2;
    assert_eq!(route(&f), Route::Successor { to: String::new(), number: 1 });
    f.tried.failovers = 2;
    assert_eq!(
        route(&f),
        Route::Handoff { why: "restarts and failovers used up".into(), after: Ending::UsedUp }
    );
}

#[test]
fn a_finished_route_or_a_live_holder_starts_nothing() {
    let mut f = dead();
    f.tried.done = true;
    assert_eq!(route(&f), Route::None);
    let mut f = dead();
    f.holder = "b/other (prs 12)".into();
    assert_eq!(
        route(&f),
        Route::Wait { why: "a live lane holds its work: b/other (prs 12)".into() }
    );
}

#[test]
fn a_session_that_came_back_gets_one_resume_prompt_and_a_paused_codex_one_none() {
    let mut f = dead();
    f.alive = true;
    assert_eq!(route(&f), Route::Resume);
    f.tried.resumed = true;
    assert_eq!(route(&f), Route::None);
    f.tried.resumed = false;
    f.paused = true;
    assert_eq!(route(&f), Route::None);
}

#[test]
fn a_moved_session_finishes_its_move() {
    let mut f = dead();
    f.tried.moved_to = "b".into();
    assert_eq!(route(&f), Route::FinishMove { to: "b".into() });
}

#[test]
fn a_down_host_within_its_grace_is_started_once_then_waited_on() {
    let mut f = dead();
    f.host_down = true;
    f.dead_seconds = 60.0;
    f.host_startable = true;
    assert_eq!(route(&f), Route::StartHost);
    f.tried.start_asked = true;
    assert_eq!(route(&f), Route::None);
}

#[test]
fn a_down_host_past_its_grace_gets_a_successor_never_a_restart() {
    let mut f = dead();
    f.host_down = true;
    f.dead_seconds = 4000.0;
    assert_eq!(route(&f), Route::Successor { to: String::new(), number: 1 });
}

#[test]
fn a_gone_session_starts_again_on_the_first_admitted_host_else_hands_off() {
    let mut f = dead();
    f.has_row = false;
    assert_eq!(route(&f), Route::Respawn { to: "b".into(), network: false });
    f.tried.respawn_tried = true;
    f.tried.respawn_failed = "name held".into();
    assert_eq!(
        route(&f),
        Route::Handoff {
            why: "a fresh session could not start: name held".into(),
            after: Ending::FreshStart
        }
    );
    let mut f = dead();
    f.has_row = false;
    f.hosts.admitted.clear();
    assert_eq!(
        route(&f),
        Route::Handoff {
            why: "no host would admit a fresh session: no host has room".into(),
            after: Ending::FreshStart,
        }
    );
}

#[test]
fn without_an_admission_read_a_fresh_start_skips_people_last_picks_and_bad_networks() {
    let mut f = dead();
    f.has_row = false;
    f.hosts.room_known = false;
    f.hosts.personal = s(&["b"]);
    assert_eq!(route(&f), Route::Respawn { to: "c".into(), network: false });
}

#[test]
fn a_network_death_starts_again_away_from_its_host_then_fails_over_to_a_healthy_one() {
    let mut f = dead();
    f.network = true;
    f.hosts.avoid = s(&["b"]);
    assert_eq!(route(&f), Route::Respawn { to: "c".into(), network: true });
    f.tried.respawn_tried = true;
    assert_eq!(route(&f), Route::Successor { to: "c".into(), number: 1 });
}

#[test]
fn a_placement_cap_waits_without_spending_a_try() {
    let mut f = dead();
    f.has_row = false;
    f.placement_cap = "cap reached".into();
    assert_eq!(route(&f), Route::Wait { why: "cap reached".into() });
    let mut f = dead();
    f.tried.restarts = 2;
    f.placement_cap = "cap reached".into();
    assert_eq!(route(&f), Route::Wait { why: "failover waits: cap reached".into() });
}

#[test]
fn a_codex_limit_that_resets_soon_waits_then_restarts() {
    let mut f = dead();
    f.reset_in_seconds = Some(600.0);
    assert_eq!(
        route(&f),
        Route::Wait {
            why: "waits for its Codex usage limit to reset in 10 min, then restarts in place"
                .into()
        }
    );
    f.reset_at = "2026-11-13T20:20:00Z".into();
    assert_eq!(
        route(&f),
        Route::Wait {
            why: "waits for its Codex usage limit to reset at 2026-11-13T20:20:00Z, then restarts in place"
                .into()
        }
    );
    f.reset_in_seconds = None;
    assert_eq!(route(&f), Route::Restart { number: 1 });
}

#[test]
fn a_capacity_death_skips_every_in_place_retry() {
    let mut f = dead();
    f.capacity = true;
    f.hosts.admitted.clear();
    assert_eq!(route(&f), Route::Successor { to: String::new(), number: 1 });
}

#[test]
fn an_on_demand_host_moves_its_session_to_a_persistent_one() {
    let mut f = dead();
    f.host_on_demand = true;
    assert_eq!(
        route(&f),
        Route::Move { to: "b".into(), otherwise: "restarting in place instead".into() }
    );
    f.tried.move_failed = "refused".into();
    assert_eq!(route(&f), Route::Restart { number: 1 });
}

#[test]
fn a_full_host_moves_its_session_to_one_with_room_else_hands_off() {
    let mut f = dead();
    f.hosts.own_full = "vm-a is full".into();
    assert_eq!(
        route(&f),
        Route::Move { to: "b".into(), otherwise: "its work goes to a live owner instead".into() }
    );
    f.hosts.admitted.clear();
    assert_eq!(
        route(&f),
        Route::Handoff {
            why: "vm-a is full, so it is not restarted there; no host has room".into(),
            after: Ending::Full,
        }
    );
}

#[test]
fn a_failover_never_starts_onto_a_full_fleet_or_too_late_in_the_pass() {
    let mut f = dead();
    f.tried.restarts = 2;
    f.hosts.admitted.clear();
    assert_eq!(
        route(&f),
        Route::Wait { why: "failover waits: no host has room; the next pass tries again".into() }
    );
    let mut f = dead();
    f.tried.restarts = 2;
    f.pass_seconds_left = Some(100.0);
    assert!(matches!(route(&f), Route::Wait { .. }));
}

#[test]
fn facts_read_from_partial_json_and_the_route_prints_its_step() {
    let f: Facts =
        serde_json::from_str(r#"{"host":"vm-a","has_row":true,"max_restarts":1}"#).unwrap();
    let v = serde_json::to_value(route(&f)).unwrap();
    assert_eq!(v, serde_json::json!({"step": "restart", "number": 1}));
}
