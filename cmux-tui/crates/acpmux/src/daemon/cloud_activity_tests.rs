use super::*;

#[test]
fn a_running_turn_is_sent_then_renewed_and_its_end_carries_the_end_time() {
    let mut t = Tracker::default();
    // Nothing at work and nothing sent: the agent learns 0 once.
    assert_eq!(t.line(0, true, 0).unwrap(), json!({"acp_activity": {"turns": 0}}));
    assert!(t.line(0, false, 0).is_none(), "an unchanged 0 between renewals");
    assert!(t.line(0, true, 0).is_some(), "every renewal goes, 0 included");

    t.acted(1_000);
    let started = t.line(1, false, 0).unwrap();
    assert_eq!(started, json!({"acp_activity": {"turns": 1, "last_agent_action_at": 1_000}}));
    // A mux record that changes nothing sends nothing; the tick renews.
    t.acted(1_500);
    assert!(t.line(1, false, 0).is_none(), "an action while at work waits for the renewal");
    t.acted(2_000);
    assert_eq!(
        t.line(1, true, 0).unwrap(),
        json!({"acp_activity": {"turns": 1, "last_agent_action_at": 2_000}})
    );

    // The turn ends at 3 000: the count drops and the end is the last action.
    t.acted(3_000);
    assert_eq!(
        t.line(0, false, 0).unwrap(),
        json!({"acp_activity": {"turns": 0, "last_agent_action_at": 3_000}})
    );
    assert!(t.line(0, false, 0).is_none());
}

/// A turn's end can be counted (0 at work) before its `turn_result` is read: the later action
/// still goes at once, so the idle period starts at the turn's end.
#[test]
fn an_action_after_the_count_dropped_to_zero_still_goes() {
    let mut t = Tracker::default();
    t.acted(1_000);
    assert!(t.line(1, false, 0).is_some());
    assert!(t.line(0, false, 0).is_some());
    t.acted(2_000);
    assert_eq!(
        t.line(0, false, 0).unwrap(),
        json!({"acp_activity": {"turns": 0, "last_agent_action_at": 2_000}})
    );
    assert!(t.line(0, false, 0).is_none());
}

#[test]
fn an_unsent_line_goes_again_and_older_times_never_move_back() {
    let mut t = Tracker::default();
    t.acted(5_000);
    t.acted(4_000);
    t.acted(0);
    assert!(t.line(2, false, 0).is_some());
    t.unsent();
    assert_eq!(
        t.line(2, false, 0).unwrap(),
        json!({"acp_activity": {"turns": 2, "last_agent_action_at": 5_000}})
    );
}

#[test]
fn only_turn_edges_permissions_and_tool_calls_are_actions() {
    assert!(Tracker::is_action("mux", "turn_started"));
    assert!(Tracker::is_action("mux", "turn_result"));
    assert!(Tracker::is_action("mux", "permission_request"));
    assert!(Tracker::is_action("in", "tool_call"));
    assert!(Tracker::is_action("in", "tool_call_update"));
    assert!(!Tracker::is_action("in", "agent_message_chunk"));
    assert!(!Tracker::is_action("mux", "status"));
    assert!(!Tracker::is_action("out", "tool_call"));
}

/// cmux#33329: a long turn's last tool call was minutes ago. The first 0 after it is stamped
/// with when it was seen, never the old tool call's time, so the idle period starts at the end.
#[test]
fn the_first_zero_after_work_carries_the_time_it_was_seen() {
    let mut t = Tracker::default();
    t.acted(1_000);
    assert!(t.line(1, false, 1_000).is_some());
    // Quiet for ten minutes, then the count drops before `turn_result` is read.
    assert_eq!(
        t.line(0, false, 601_000).unwrap(),
        json!({"acp_activity": {"turns": 0, "last_agent_action_at": 601_000}})
    );
    // Later zeros keep that time: an idle machine's period is not restarted by renewals.
    assert_eq!(
        t.line(0, true, 900_000).unwrap(),
        json!({"acp_activity": {"turns": 0, "last_agent_action_at": 601_000}})
    );
    // The first line a daemon sends, 0 at work, counts from when it was seen as well.
    let mut fresh = Tracker::default();
    assert_eq!(
        fresh.line(0, true, 5_000).unwrap(),
        json!({"acp_activity": {"turns": 0, "last_agent_action_at": 5_000}})
    );
}

/// cmux#33328: before startup settles (agent hosts not adopted, chat logs not read), a daemon
/// that counts nothing yet reports one session at work, never a known 0.
#[test]
fn an_unsettled_startup_reports_busy() {
    assert_eq!(reported_at_work(0, false), 1);
    assert_eq!(reported_at_work(3, false), 3);
    assert_eq!(reported_at_work(0, true), 0);
    assert_eq!(reported_at_work(2, true), 2);
}

/// cmux#33330: every line names its daemon, so the agent keeps each daemon's count apart.
#[test]
fn each_line_names_its_daemon() {
    let mut t = Tracker::new("/run/acpmux-a.sock".into());
    assert_eq!(
        t.line(2, false, 0).unwrap(),
        json!({"acp_activity": {"turns": 2, "daemon": "/run/acpmux-a.sock"}})
    );
}
