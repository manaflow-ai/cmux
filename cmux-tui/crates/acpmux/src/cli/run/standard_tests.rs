#[test]
fn a_named_start_on_another_machine_keeps_its_name_when_taken() {
    // `--machine HOST` and `--machine auto` keep a taken name, suffixed, never the agent's.
    assert!(super::keeps_name_suffixed(false, Some("far-host"), false));
    assert!(super::keeps_name_suffixed(true, None, false));
    assert!(super::keeps_name_suffixed(true, Some("far-host"), false));
    // `--reuse` finds the running session by that name; a start here is refused as before.
    assert!(!super::keeps_name_suffixed(true, Some("far-host"), true));
    assert!(!super::keeps_name_suffixed(false, None, false));
}

/// Only an agent's plain start here asks a full lane host to place it on a peer.
#[test]
fn only_a_plain_agent_start_here_asks_to_be_placed() {
    use super::asks_place_redirect as asks;
    assert!(asks(None, false, false, false, false, false));
    assert!(!asks(Some("far"), false, false, false, false, false), "a machine named");
    assert!(!asks(None, true, false, false, false, false), "already placed (--machine auto)");
    assert!(!asks(None, false, true, false, false, false), "a person at a terminal");
    assert!(!asks(None, false, false, true, false, false), "a folder or worktree named");
    assert!(!asks(None, false, false, false, true, false), "an ephemeral run or probe");
    assert!(!asks(None, false, false, false, false, true), "--reuse finds it here");
}

/// An old daemon's answer (no `placedOn`) runs here; a new one's runs on its `peer`.
#[test]
fn an_answer_runs_where_it_says_and_an_old_one_here() {
    use serde_json::json;
    let old = json!({"sessionId": "s1", "_meta": {"acpmux": {"admission": {
        "warning": "at its cap", "suggestedHost": "far"}}}});
    assert_eq!(super::placed_on(&old), None);
    let peer = json!({"sessionId": "s1", "peer": "far"});
    assert_eq!(super::placed_on(&peer), None, "a --host start says so itself");
    let placed = json!({"sessionId": "s1", "peer": "far", "_meta": {"acpmux": {
        "placedOn": "far", "placement": {"version": 1, "reason": "over-cap"}}}});
    assert_eq!(super::placed_on(&placed).as_deref(), Some("far"));
    assert_eq!(crate::cli::resolve::routed_id(&placed).unwrap(), "far/s1");
}

#[test]
fn relay_flags_are_the_relay_record_the_daemon_reads() {
    use crate::cli::command::{Cli, Command};
    use clap::Parser;
    let args = [
        "acpmux",
        "send",
        "--relay",
        "lane-gh",
        "--relayed-from",
        "vm-1/lane",
        "--relayed-harness",
        "codex",
        "coord",
        "-",
    ];
    let Ok(Cli { command: Some(Command::Send { relay, .. }), .. }) = Cli::try_parse_from(args)
    else {
        panic!("did not parse")
    };
    let fields = super::relay_fields(relay).unwrap();
    assert_eq!(
        fields,
        json!({"fromRelay": {"by": "lane-gh", "machine": "vm-1", "session": "lane"}, "fromHarness": "codex"})
    );
    // A relay names where the message came from, or it is no relay.
    assert!(Cli::try_parse_from(["acpmux", "send", "--relay", "lane-gh", "coord", "-"]).is_err());
}

#[test]
fn team_receipt_shows_the_hubs_canonical_resolution() {
    let receipt = serde_json::json!({"to":{"teamAddress":"@user_42/coordinator"},"startWork":"information","state":"queued","messageId":"message-1"});
    let line = super::team_receipt_line(&receipt);
    assert!(line.contains("@user_42/coordinator"));
    assert!(line.contains("startWork=information"));
}
use super::{new_requires_tty, new_without_prompt_requires_tty, send_steers};
use serde_json::json;

/// The send never waits on its fan-out note: an unanswered note yields nothing at once, an
/// answered one its warning.
#[tokio::test]
async fn a_fanout_note_is_read_only_if_already_answered() {
    let (tx, rx) = tokio::sync::oneshot::channel::<()>();
    let pending = super::FANOUT_NOTES.spawn(async move {
        let _ = rx.await;
        Some("late".to_owned())
    });
    let started = std::time::Instant::now();
    assert_eq!(super::fanout_warning_if_known(pending), None);
    assert!(started.elapsed() < std::time::Duration::from_millis(50));
    drop(tx);
    let done = super::FANOUT_NOTES.spawn(async { Some("warned".to_owned()) });
    while !done.is_finished() {
        tokio::task::yield_now().await;
    }
    assert_eq!(super::fanout_warning_if_known(done).as_deref(), Some("warned"));
}

#[test]
fn an_agents_or_classed_send_is_queued_unless_it_waits_for_the_reply() {
    use super::{SendWait, send_queues};
    let w = |no_wait, wait, classed, agent| send_queues(SendWait { no_wait, wait, classed, agent });
    assert!(!w(false, false, false, false), "the person's plain send streams the reply");
    assert!(w(true, false, false, false), "--no-wait queues");
    assert!(w(false, false, true, false), "--class queues");
    assert!(w(false, false, false, true), "an agent's send queues");
    assert!(!w(false, true, true, true), "--wait (or --quiet, --timeout) waits");
    assert!(w(true, true, false, false), "--no-wait wins where clap lets both through");
}

#[test]
fn send_steers_messages_by_default_and_queues_the_persons_waiting_sends() {
    assert!(send_steers(false, false, true, false), "--no-wait steers by default");
    assert!(!send_steers(false, true, true, false), "--no-steer opts out");
    assert!(!send_steers(false, false, false, false), "the person's send that waits queues");
    assert!(send_steers(true, false, false, false), "--steer steers a waiting send");
}

/// Leo, 2026-10-25: "I don't know why these things are queued up." An agent's send steers
/// whether or not it waits for the reply; `--no-steer` still queues it.
#[test]
fn an_agents_send_steers_by_default_even_when_it_waits() {
    assert!(send_steers(false, false, false, true), "an agent's waiting send steers");
    assert!(send_steers(false, false, true, true), "and so does its --no-wait send");
    assert!(!send_steers(false, true, false, true), "--no-steer opts out");
    assert!(!send_steers(false, true, true, true), "--no-steer opts out with --no-wait too");
}

/// A waiting send to a session only the hub reaches is sent through the hub, never run as
/// a local turn on the id its read named (own-machines e2e run 42071975275).
#[test]
fn a_session_read_through_the_hub_is_sent_through_the_hub() {
    use super::read_through_hub;
    assert!(read_through_hub(&json!({"sessionId": "s", "peer": "machine-b", "via": "hub"})));
    assert!(!read_through_hub(&json!({"sessionId": "s", "peer": "machine-b"})));
    assert!(!read_through_hub(&json!({"sessionId": "s"})));
}

/// A waiting send to a chat the hub reaches goes through the hub even where a send relay is
/// configured (a lane VM's lane-gh): the prompt runs in that chat, as `last` reads it, not
/// as relay mail for a name nothing resolves (session-move-gcp, 2026-11-26).
#[test]
fn a_hub_reached_send_goes_through_the_hub_ahead_of_the_send_relay() {
    use super::hub_send_first as first;
    assert!(first(true, false, false));
    assert!(!first(false, false, false), "a name nothing resolves keeps the relay");
    assert!(!first(true, true, false), "--no-wait queues before the hub check");
    assert!(!first(true, false, true), "--attach goes to the relay as before");
}

#[test]
fn a_promptless_new_requires_a_terminal_unless_detached() {
    assert!(new_without_prompt_requires_tty(true, false, false, true));
    assert!(new_without_prompt_requires_tty(true, false, true, false));
    assert!(!new_without_prompt_requires_tty(true, true, false, false));
    assert!(!new_without_prompt_requires_tty(false, false, false, false));
    assert!(!new_without_prompt_requires_tty(true, false, true, true));
    assert!(!new_requires_tty(true, true, false, false, false));
    assert!(new_requires_tty(false, true, false, false, true));
}
