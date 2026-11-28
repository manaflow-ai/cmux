use super::*;
use crate::client::DaemonError;
use crate::rpc::RpcError;

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|w| (*w).to_owned()).collect()
}

fn refused(e: RpcError) -> anyhow::Error {
    DaemonError(e).into()
}

#[test]
fn a_promptless_relayed_new_detaches_once() {
    let mut args = words(&["--machine", "far", "-n", "x"]);
    add_detach(&mut args);
    assert_eq!(args, words(&["--machine", "far", "-n", "x", "-d"]));
    add_detach(&mut args);
    assert_eq!(args.iter().filter(|w| *w == "-d").count(), 1);
    let mut long = words(&["--machine", "far", "--detach"]);
    add_detach(&mut long);
    assert_eq!(long, words(&["--machine", "far", "--detach"]));
    // Words after `--` are the caller's, so the flag goes before them.
    let mut literal = words(&["--machine", "far", "--", "-d"]);
    add_detach(&mut literal);
    assert_eq!(literal, words(&["--machine", "far", "-d", "--", "-d"]));
}

#[test]
fn only_a_machine_no_peer_names_relays_and_never_from_a_relay() {
    let own = ["lane-vm", "lane-vm"];
    let no_peer = refused(RpcError::no_peer("far"));
    assert!(should_relay("far", &no_peer, &own, None));
    assert!(should_relay("far", &no_peer, &own, Some("")));
    // A relay's own `new` never relays again.
    assert!(!should_relay("far", &no_peer, &own, Some("1")));
    // Placement words and this machine are never relayed.
    for host in ["auto", "auto-build", "local", "lane-vm", "LANE-VM", ""] {
        let e = refused(RpcError::no_peer(host));
        assert!(!should_relay(host, &e, &own, None), "{host}");
    }
    // The refusal must name this host.
    assert!(!should_relay("other", &no_peer, &own, None));
    // A peer that is known but down, or any other failure, is not relayed.
    let down = refused(RpcError::internal("peer \"far\" is not connected"));
    assert!(!should_relay("far", &down, &own, None));
    let unreachable = refused(
        RpcError::new(-32000, "far is unreachable")
            .with_data(json!({"reason": "peer_unreachable", "peer": "far"})),
    );
    assert!(!should_relay("far", &unreachable, &own, None));
    assert!(!should_relay("far", &anyhow!("no peer \"far\""), &own, None));
    // An older daemon's refusal, with no reason: the exact words.
    assert!(should_relay("far", &refused(RpcError::not_found("no peer \"far\"")), &own, None));
    assert!(!should_relay(
        "far",
        &refused(RpcError::not_found("no peer \"far\"; connect it")),
        &own,
        None
    ));
}

#[test]
fn the_relay_gets_the_machine_then_the_callers_other_new_words_in_order() {
    let original =
        words(&["--json", "new", "-n", "x", "--machine", "far", "-d", "fix the bug", "--reuse"]);
    assert_eq!(
        relay_args(&original, "far"),
        words(&["--machine", "far", "-n", "x", "-d", "fix the bug", "--reuse"])
    );
    let original = words(&["new", "--host=far", "-m", "codex", "--", "--machine", "far"]);
    assert_eq!(
        relay_args(&original, "far"),
        words(&["--machine", "far", "-m", "codex", "--", "--machine", "far"])
    );
}

fn scratch(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("acpmux-new-relay-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn the_relay_is_read_from_config_json_and_absent_means_none() {
    let dir = scratch("config");
    let path = dir.join("config.json");
    assert_eq!(configured_in(&path), None);
    std::fs::write(&path, r#"{"sendRelay": {"argv": ["relay", "send"]}}"#).unwrap();
    assert_eq!(configured_in(&path), None);
    std::fs::write(&path, r#"{"newRelay": {"argv": ["placer", "new"]}}"#).unwrap();
    assert_eq!(configured_in(&path), Some(NewRelay { argv: vec!["placer".into(), "new".into()] }));
    std::fs::write(&path, r#"{"newRelay": {"argv": []}}"#).unwrap();
    assert_eq!(configured_in(&path), None);
    std::fs::write(&path, r#"{"newRelay": "placer new"}"#).unwrap();
    assert_eq!(configured_in(&path), None);
    let _ = std::fs::remove_dir_all(&dir);
}

#[cfg(unix)]
#[test]
fn the_relay_gets_its_args_and_the_guard_and_its_status_is_ours() {
    let dir = scratch("run");
    let script = dir.join("placer");
    let seen = dir.join("seen");
    crate::test_exec::write_executable(
        &script,
        format!(
            "#!/bin/sh\nprintf '%s|' \"$@\" \"${{{env}-unset}}\" > {seen}\n[ \"$3\" = refuse ] && exit 5\necho started\n",
            env = RELAYED_ENV,
            seen = seen.display()
        ),
    );
    let relay = NewRelay { argv: vec![script.display().to_string(), "new".into()] };
    let done =
        relay_with_deadline(&relay, &words(&["--machine", "far", "-d", "hi"]), true, None).unwrap();
    assert_eq!(done.status, 0);
    assert_eq!(done.output.as_deref(), Some("started"));
    assert_eq!(std::fs::read_to_string(&seen).unwrap(), "new|--machine|far|-d|hi|1|");
    let done = relay_with_deadline(&relay, &words(&["--machine", "refuse"]), true, None).unwrap();
    assert_eq!(done.status, 5);
    let missing = NewRelay { argv: vec![dir.join("absent").display().to_string()] };
    assert!(relay_with_deadline(&missing, &[], true, None).is_err());
    let _ = std::fs::remove_dir_all(&dir);
}
