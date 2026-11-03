use super::*;

#[test]
fn a_running_turn_is_sent_then_renewed_and_its_end_carries_the_end_time() {
    let mut t = Tracker::default();
    // Nothing at work and nothing sent: the agent learns 0 once.
    assert_eq!(t.line(0, true).unwrap(), json!({"acp_activity": {"turns": 0}}));
    assert!(t.line(0, false).is_none(), "an unchanged 0 between renewals");
    assert!(t.line(0, true).is_some(), "every renewal goes, 0 included");

    t.acted(1_000);
    let started = t.line(1, false).unwrap();
    assert_eq!(started, json!({"acp_activity": {"turns": 1, "last_agent_action_at": 1_000}}));
    // A mux record that changes nothing sends nothing; the tick renews.
    t.acted(1_500);
    assert!(t.line(1, false).is_none(), "an action while at work waits for the renewal");
    t.acted(2_000);
    assert_eq!(
        t.line(1, true).unwrap(),
        json!({"acp_activity": {"turns": 1, "last_agent_action_at": 2_000}})
    );

    // The turn ends at 3 000: the count drops and the end is the last action.
    t.acted(3_000);
    assert_eq!(
        t.line(0, false).unwrap(),
        json!({"acp_activity": {"turns": 0, "last_agent_action_at": 3_000}})
    );
    assert!(t.line(0, false).is_none());
}

/// A turn's end can be counted (0 at work) before its `turn_result` is read: the later action
/// still goes at once, so the idle period starts at the turn's end.
#[test]
fn an_action_after_the_count_dropped_to_zero_still_goes() {
    let mut t = Tracker::default();
    t.acted(1_000);
    assert!(t.line(1, false).is_some());
    assert!(t.line(0, false).is_some());
    t.acted(2_000);
    assert_eq!(
        t.line(0, false).unwrap(),
        json!({"acp_activity": {"turns": 0, "last_agent_action_at": 2_000}})
    );
    assert!(t.line(0, false).is_none());
}

#[test]
fn an_unsent_line_goes_again_and_older_times_never_move_back() {
    let mut t = Tracker::default();
    t.acted(5_000);
    t.acted(4_000);
    t.acted(0);
    assert!(t.line(2, false).is_some());
    t.unsent();
    assert_eq!(
        t.line(2, false).unwrap(),
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
