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

fn turn(id: &str) -> SessionAtWork {
    SessionAtWork { id: id.into(), turn: true, ..SessionAtWork::default() }
}

fn call(id: &str, status: &str) -> Value {
    json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s",
        "update": {"sessionUpdate": "tool_call_update", "toolCallId": id, "status": status}}})
}

fn phases(line: &Value) -> Vec<(String, u64)> {
    line["acp_activity"]["phases"]["turns"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| (t["phase"].as_str().unwrap().to_owned(), t["since"].as_u64().unwrap()))
        .collect()
}

/// cmux#34298: a running turn waits on the model until a tool call runs (`in_progress`), runs
/// the tool until the call is `completed` or `failed`, then waits on the model again; each
/// change goes at once, with the time it was seen.
#[test]
fn a_turn_moves_between_model_wait_and_tool_and_each_change_goes() {
    let mut t = Tracker::default();
    t.observe(&[turn("a")], 1_000);
    let line = t.line(1, false, 1_000).unwrap();
    assert_eq!(line["acp_activity"]["phases"]["relayed"], false);
    assert_eq!(phases(&line), [("model-wait".to_owned(), 1_000)]);
    assert_eq!(
        line["acp_activity"]["phases"]["turns"][0],
        json!({"phase": "model-wait", "since": 1_000, "processes": 0, "attached": false})
    );

    // A call named early streams its input: a tool is about to run (the early wake).
    assert!(t.tool_event("a", "tool_call", &call("t1", "pending")));
    t.observe(&[turn("a")], 2_000);
    assert_eq!(phases(&t.line(1, false, 2_000).unwrap()), [("tool-starting".to_owned(), 2_000)]);
    assert!(!t.tool_event("a", "tool_call_update", &call("t1", "pending")), "an update alone");

    // The whole call: the tool runs in the guest.
    assert!(t.tool_event("a", "tool_call_update", &call("t1", "in_progress")));
    t.observe(&[turn("a")], 3_000);
    assert_eq!(phases(&t.line(1, false, 3_000).unwrap()), [("tool".to_owned(), 3_000)]);
    // A second call alongside, then the first ends: still a tool.
    assert!(!t.tool_event("a", "tool_call", &call("t2", "in_progress")));
    assert!(!t.tool_event("a", "tool_call_update", &call("t1", "completed")));
    t.observe(&[turn("a")], 4_000);
    assert!(t.line(1, false, 4_000).is_none(), "the tool phase holds, since unchanged");
    assert!(t.tool_event("a", "tool_call_update", &call("t2", "failed")));
    t.observe(&[turn("a")], 5_000);
    assert_eq!(phases(&t.line(1, false, 5_000).unwrap()), [("model-wait".to_owned(), 5_000)]);
    // A renewal keeps the since.
    t.observe(&[turn("a")], 25_000);
    assert_eq!(phases(&t.line(1, true, 25_000).unwrap()), [("model-wait".to_owned(), 5_000)]);
}

/// A session at work with processes left running, a background subagent, or no turn at all is
/// pinned; a turn waiting on a permission waits on the person. Entries go in id order, one per
/// session at work, with its process count and whether a client shows it.
#[test]
fn processes_pin_a_session_and_a_permission_waits_on_the_person() {
    let mut t = Tracker::default();
    let busy = SessionAtWork { processes: 2, shown: true, ..turn("b") };
    let asking = SessionAtWork { person: true, ..turn("a") };
    let below = SessionAtWork { below: true, ..turn("c") };
    let no_turn = SessionAtWork { id: "d".into(), processes: 1, ..SessionAtWork::default() };
    t.observe(&[busy, asking, below, no_turn], 7);
    let line = t.line(4, false, 7).unwrap();
    let turns = &line["acp_activity"]["phases"]["turns"];
    assert_eq!(turns.as_array().unwrap().len(), 4, "one entry per session at work");
    assert_eq!(turns[0]["phase"], "person");
    assert_eq!(turns[1], json!({"phase": "pinned", "since": 7, "processes": 2, "attached": true}));
    assert_eq!(turns[2]["phase"], "pinned");
    assert_eq!(turns[3]["phase"], "pinned");
    // A tool call outranks the pin.
    assert!(t.tool_event("b", "tool_call", &call("x", "in_progress")));
    t.observe(&[SessionAtWork { processes: 2, ..turn("b") }], 9);
    assert_eq!(phases(&t.line(1, false, 9).unwrap()), [("tool".to_owned(), 9)]);
}

/// A call whose `completed` never came (a lagged event stream, a cancelled turn) is forgotten at
/// the turn's end and once its session is no longer at work, so it never holds `tool` on.
#[test]
fn an_open_call_is_forgotten_at_the_turns_end() {
    let mut t = Tracker::default();
    assert!(t.tool_event("a", "tool_call", &call("t1", "in_progress")));
    assert!(t.turn_ended("a"));
    assert!(!t.turn_ended("a"), "nothing left open");
    t.observe(&[turn("a")], 1);
    assert_eq!(phases(&t.line(1, false, 1).unwrap()), [("model-wait".to_owned(), 1)]);

    assert!(t.tool_event("b", "tool_call", &call("t2", "in_progress")));
    t.observe(&[], 2);
    t.observe(&[turn("b")], 3);
    assert_eq!(phases(&t.line(1, false, 3).unwrap()), [("model-wait".to_owned(), 3)]);
    assert!(!t.tool_event("b", "agent_message_chunk", &call("t3", "in_progress")));
    assert!(!t.tool_event(
        "b",
        "tool_call",
        &json!({"params": {"update": {"status": "in_progress"}}})
    ));
}

/// An unsent line's phases go again with the next chance.
#[test]
fn unsent_phases_go_again() {
    let mut t = Tracker::default();
    t.observe(&[turn("a")], 1);
    assert!(t.line(1, false, 1).is_some());
    t.unsent();
    assert!(t.line(1, false, 1).is_some());
}

/// cmux#34298 (early wake): a call named as its block starts makes its session `tool-starting`
/// at once, before its input is in; a call that never runs (the turn ended while its input
/// streamed) leaves it.
#[test]
fn a_named_call_is_tool_starting_until_it_runs_or_its_turn_ends() {
    let mut t = Tracker::default();
    t.observe(&[turn("a")], 1);
    assert!(t.line(1, false, 1).is_some());
    let named = json!({"params": {"update": {"sessionUpdate": "tool_call", "toolCallId": "t1"}}});
    assert!(t.tool_event("a", "tool_call", &named), "no status is ACP's pending");
    t.observe(&[turn("a")], 2);
    assert_eq!(phases(&t.line(1, false, 2).unwrap()), [("tool-starting".to_owned(), 2)]);
    assert!(t.turn_ended("a"));
    t.observe(&[turn("a")], 3);
    assert_eq!(phases(&t.line(1, false, 3).unwrap()), [("model-wait".to_owned(), 3)]);
    // A named call that fails before it runs leaves it as well.
    assert!(t.tool_event("a", "tool_call", &call("t2", "pending")));
    assert!(t.tool_event("a", "tool_call_update", &call("t2", "failed")));
}

/// A lagged event stream may have dropped a tool's start: every session then at work reports
/// `unknown` (awake to the Cloud) until its turn ends or it is no longer at work; one that
/// starts at work later is read as usual.
#[test]
fn after_a_lag_a_session_at_work_is_unknown_until_its_turn_ends() {
    let mut t = Tracker::default();
    t.observe(&[turn("a")], 1);
    assert!(t.line(1, false, 1).is_some());
    t.lagged();
    t.observe(&[turn("a")], 2);
    assert_eq!(phases(&t.line(1, true, 2).unwrap()), [("unknown".to_owned(), 2)]);
    t.observe(&[turn("a"), turn("b")], 3);
    assert_eq!(
        phases(&t.line(2, false, 3).unwrap()),
        [("unknown".to_owned(), 2), ("model-wait".to_owned(), 3)]
    );
    assert!(t.turn_ended("a"));
    t.observe(&[turn("a"), turn("b")], 4);
    assert_eq!(
        phases(&t.line(2, false, 4).unwrap()),
        [("model-wait".to_owned(), 4), ("model-wait".to_owned(), 3)]
    );
    // Leaving work clears it too.
    t.lagged();
    t.observe(&[turn("b")], 5);
    t.observe(&[], 6);
    t.observe(&[turn("b")], 7);
    assert_eq!(phases(&t.line(1, false, 7).unwrap()), [("model-wait".to_owned(), 7)]);
}

/// A person's prompt (cmux-platform's post-chat warm window) goes at once, rides along on every
/// line after, and never moves backwards; a line the agent did not take carries it again.
#[test]
fn a_persons_prompt_time_goes_at_once_and_never_moves_back() {
    let mut t = Tracker::default();
    assert_eq!(t.line(0, true, 0).unwrap(), json!({"acp_activity": {"turns": 0}}));
    assert!(t.line(0, false, 0).is_none());

    t.person_prompted(7_000);
    assert_eq!(
        t.line(0, false, 0).unwrap(),
        json!({"acp_activity": {"turns": 0, "last_person_prompt_at": 7_000}}),
        "a new prompt time goes without waiting for the renewal"
    );
    assert!(t.line(0, false, 0).is_none(), "an unchanged time sends nothing");

    t.person_prompted(6_000);
    t.person_prompted(0);
    assert!(t.line(0, false, 0).is_none(), "an older time changes nothing");
    assert_eq!(t.line(0, true, 0).unwrap()["acp_activity"]["last_person_prompt_at"], 7_000);

    t.person_prompted(9_000);
    assert!(t.line(0, false, 0).is_some());
    t.unsent();
    assert_eq!(t.line(0, false, 0).unwrap()["acp_activity"]["last_person_prompt_at"], 9_000);
}

/// An agent's action alone never sets the person's prompt time.
#[test]
fn an_agents_action_is_no_persons_prompt() {
    let mut t = Tracker::default();
    t.acted(1_000);
    let line = t.line(1, false, 0).unwrap();
    assert!(line["acp_activity"].get("last_person_prompt_at").is_none(), "{line}");
}
