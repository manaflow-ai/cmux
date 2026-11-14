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
use super::{new_requires_tty, new_without_prompt_requires_tty, send_steers, started_by};
use serde_json::json;

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

#[test]
fn a_sub_session_names_the_parent_that_started_it() {
    let child = json!({"sessionId": "child", "startedBy": "p"});
    assert_eq!(started_by(&child).as_deref(), Some("p"));
    assert_eq!(started_by(&json!({"sessionId": "root", "startedBy": null})), None);
    assert_eq!(started_by(&json!({"sessionId": "old"})), None);
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
