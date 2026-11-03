use super::*;

#[test]
fn a_running_turn_is_sent_then_renewed_and_its_end_carries_the_end_time() {
    let mut t = Tracker::default();
    // Nothing at work and nothing sent: the agent learns 0 once.
    assert_eq!(t.line(0, true).unwrap(), json!({"acp_activity": {"turns": 0}}));
    assert!(t.line(0, true).is_none(), "an unchanged 0 is not renewed");

    t.acted(1_000);
    let started = t.line(1, false).unwrap();
    assert_eq!(started, json!({"acp_activity": {"turns": 1, "last_agent_action_at": 1_000}}));
    // A mux record that changes nothing sends nothing; the tick renews while at work.
    assert!(t.line(1, false).is_none());
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
    assert!(t.line(0, true).is_none());
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
