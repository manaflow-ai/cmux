use super::*;

fn named(name: &str) -> RelayMetadata {
    RelayMetadata { name: Some(name.to_owned()), ..Default::default() }
}

#[test]
fn the_audit_keeps_only_a_plain_delivery_id_of_the_relays_output() {
    assert_eq!(delivery_id(Some(r#"{"deliveryId":"del-1"}"#)).as_deref(), Some("del-1"));
    assert_eq!(delivery_id(Some(r#"{"data":{"deliveryId":"d_2"}}"#)).as_deref(), Some("d_2"));
    assert_eq!(delivery_id(Some("sent: hello across")), None);
    assert_eq!(delivery_id(Some(r#"{"deliveryId":"hello across"}"#)), None);
    assert_eq!(delivery_id(Some(r#"{"echo":"hello","deliveryId":"x"}"#)).as_deref(), Some("x"));
    assert_eq!(delivery_id(None), None);
}

#[test]
fn a_slow_relay_lookup_is_unknown_not_no_such_session() {
    let dir = tempfile::tempdir().unwrap();
    let cache = dir.path().join(crate::cli::ls_far::CACHE_FILE);
    let row = json!({"peer": "far", "sessionId": "s1", "name": "far/worker"});
    // No kept listing and a relay that runs out: unknown, with the reason.
    let slow = lookup("far/worker", &cache, "lane-gh", 1_000, || {
        Err(anyhow!("the relay listing \"lane-gh\": timed out after 5s"))
    });
    let Lookup::Unknown(why) = slow else { panic!("{slow:?}") };
    assert!(why.contains("timed out"), "{why}");
    // A relay that answers is read, its rows kept, and a key it lacks is not listed.
    let read = lookup("far/worker", &cache, "lane-gh", 2_000, || Ok(Some(vec![row.clone()])));
    assert_eq!(read, Lookup::Listed(row.clone()));
    assert_eq!(
        lookup("far/other", &cache, "lane-gh", 2_000, || Ok(Some(vec![row.clone()]))),
        Lookup::NotListed
    );
    // The kept listing answers at once, with the relay never read.
    let kept = lookup("far/worker", &cache, "lane-gh", 3_000, || panic!("relay read"));
    let Lookup::Listed(kept) = kept else { panic!("{kept:?}") };
    assert_eq!(kept["sessionId"], "s1");
    assert_eq!(kept["asOfMs"], 2_000);
    // A key the kept listing lacks with the relay failing is unknown, not "no session".
    let failed = lookup("far/new", &cache, "lane-gh", 4_000, || Err(anyhow!("exited 1")));
    assert!(matches!(failed, Lookup::Unknown(_)), "{failed:?}");
}

#[test]
fn a_relay_that_missed_before_is_not_waited_on_again() {
    let dir = tempfile::tempdir().unwrap();
    let cache = dir.path().join(crate::cli::ls_far::CACHE_FILE);
    std::fs::write(cache.with_file_name("relay-ls-cache.missed"), "1000").unwrap();
    let answer = lookup("far/worker", &cache, "lane-gh", 2_000, || panic!("relay read"));
    assert!(matches!(answer, Lookup::Unknown(_)), "{answer:?}");
}

#[test]
fn an_unknown_refusal_still_relays_and_says_why() {
    let e: anyhow::Error = AppError::no_session("far/worker").into();
    let e = unknown_refusal("far/worker", e, "timed out after 5s");
    assert!(no_such_session(&e), "a send still hands it to the relay");
    let app = e.downcast_ref::<AppError>().unwrap();
    assert!(app.message.contains("unknown"), "{}", app.message);
    assert!(!app.message.starts_with("no session matches \"far/worker\";"));
    assert!(app.retryable);
    assert_eq!(app.data.as_ref().unwrap()["relayListing"]["state"], "unknown");
}

#[test]
fn a_key_finds_the_one_relay_row_it_names() {
    let rows = vec![
        json!({"peer": "far", "sessionId": "01a", "name": "flap", "qualifiedSessionId": "far/01a"}),
        json!({"peer": "lane-2", "sessionId": "01b", "name": "lane-2/goal"}),
        json!({"peer": "lane-4", "sessionId": "01c", "name": "flap"}),
    ];
    let id = |key: &str| find_row(&rows, key).and_then(|r| r["sessionId"].as_str());
    assert_eq!(id("far/flap"), Some("01a"));
    assert_eq!(id("far/01a"), Some("01a"));
    assert_eq!(id("01a"), Some("01a"));
    assert_eq!(id("lane-2/goal"), Some("01b"));
    assert_eq!(id("goal"), Some("01b"));
    assert_eq!(id("lane-4/flap"), Some("01c"));
    // A bare name two hosts carry, another host's name, or nothing: no row.
    assert_eq!(id("flap"), None);
    assert_eq!(id("far/goal"), None);
    assert_eq!(id("nothing"), None);
}

#[test]
fn a_relay_row_given_handle_names_it_and_a_derived_one_still_matches() {
    let id = "0198f2a4-0000-7000-8000-0000000000e1";
    let mut given = json!({"peer": "far", "sessionId": id, "name": "old", "displayName": "Mango"});
    given_handle(given.as_object_mut().unwrap());
    assert_eq!(given["handle"], "Mango");
    let mut bad = json!({"peer": "far", "sessionId": "01z", "displayName": "not a handle"});
    given_handle(bad.as_object_mut().unwrap());
    assert!(bad.get("handle").is_none());
    let rows = vec![given, bad];
    let found = |key: &str| find_row(&rows, key).and_then(|r| r["sessionId"].as_str());
    assert_eq!(found("Mango"), Some(id));
    assert_eq!(found("mango"), Some(id));
    assert_eq!(found("far/Mango"), Some(id));
    assert_eq!(found("old"), Some(id));
    assert_eq!(found("other/Mango"), None);
    // A row with no given handle is still found by its derived one, never put on the row.
    let derived = crate::session_handle::default_handle("01z");
    assert_eq!(found(&derived), Some("01z"));
    assert_eq!(found(&format!("far/{derived}")), Some("01z"));
}

#[test]
fn merged_rows_are_each_listed_once_by_machine_and_id() {
    let row = |peer: &str, id: &str| json!({"peer": peer, "sessionId": id});
    let mut rows = vec![row("hostb", "a")];
    let far = vec![row("hostb", "a"), row("hostb", "b"), row("hostb", "b"), row("hostc", "b")];
    assert_eq!(merge_rows(&mut rows, far), 2);
    assert_eq!(rows, vec![row("hostb", "a"), row("hostb", "b"), row("hostc", "b")]);
}

fn scratch(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("acpmux-send-relay-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn the_relay_is_read_from_config_json_and_absent_means_none() {
    let dir = scratch("config");
    let path = dir.join("config.json");
    assert_eq!(configured_in(&path), None);
    std::fs::write(&path, r#"{"harnesses": {}}"#).unwrap();
    assert_eq!(configured_in(&path), None);
    std::fs::write(&path, r#"{"sendRelay": {"argv": ["relay", "send"]}}"#).unwrap();
    assert_eq!(
        configured_in(&path),
        Some(SendRelay { argv: vec!["relay".into(), "send".into()], ls_argv: None })
    );
    std::fs::write(&path, r#"{"sendRelay": {"argv": []}}"#).unwrap();
    assert_eq!(configured_in(&path), None);
    std::fs::write(&path, r#"{"sendRelay": "relay send"}"#).unwrap();
    assert_eq!(configured_in(&path), None);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn only_the_clis_no_session_refusal_relays() {
    assert!(no_such_session(&AppError::no_session("lane").into()));
    // `@` outside a session, and a delivery that failed later with the same words.
    let current = AppError::new(Code::NoSession, "no_current_session", "no current session");
    assert!(!no_such_session(&current.into()));
    assert!(!no_such_session(&anyhow!("unknown session lane")));
    assert!(!no_such_session(&AppError::timeout("timed out").into()));
}

#[test]
fn the_sender_is_the_named_one_else_the_session_this_runs_in() {
    let env = |pairs: &'static [(&'static str, &'static str)]| {
        move |key: &str| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| (*v).to_owned())
    };
    let in_session = env(&[("ACPMUX_SESSION_ID", "s-1"), ("ACPMUX_SESSION_NAME", "lane-a")]);
    assert_eq!(sender(Some("vm/lane"), in_session).as_deref(), Some("vm/lane"));
    assert_eq!(sender(None, in_session).as_deref(), Some("lane-a"));
    assert_eq!(sender(None, env(&[("ACPMUX_SESSION_NAME", "lane-a")])), None);
    let named_in_session = env(&[
        (FROM_ENV, "vm/lane"),
        ("ACPMUX_SESSION_ID", "s-1"),
        ("ACPMUX_SESSION_NAME", "lane-a"),
    ]);
    assert_eq!(sender(None, named_in_session).as_deref(), Some("vm/lane"));
    assert_eq!(sender(None, env(&[])), None);
}

#[cfg(unix)]
#[test]
fn the_relay_gets_the_session_the_text_and_the_sender_and_its_status_is_ours() {
    let dir = scratch("run");
    let script = dir.join("relay");
    let seen = dir.join("seen");
    crate::test_exec::write_executable(
        &script,
        format!(
            "#!/bin/sh\n{{ printf '%s|' \"$1\" \"$2\" \"$3\" \"${{ACPMUX_FROM-unset}}\"; cat; }} > {}\n[ \"$2\" = refuse ] && {{ echo refused >&2; exit 7; }}\necho delivery-42\n",
            seen.display()
        ),
    );
    let config =
        SendRelay { argv: vec![script.display().to_string(), "send".into()], ls_argv: None };

    let done =
        relay_with_deadline(&config, "lane-b", "hello\nthere", &named("vm/lane"), true, None)
            .unwrap();
    assert_eq!(done.status, 0);
    assert_eq!(done.output.as_deref(), Some("delivery-42"));
    assert_eq!(std::fs::read_to_string(&seen).unwrap(), "send|lane-b|-|vm/lane|hello\nthere");

    let done =
        relay_with_deadline(&config, "refuse", "x", &RelayMetadata::default(), true, None).unwrap();
    assert_eq!(done.status, 7);
    assert_eq!(std::fs::read_to_string(&seen).unwrap(), "send|refuse|-|unset|x");

    // One that stops reading early and exits 0 did not take the message.
    let early = dir.join("early");
    crate::test_exec::write_executable(&early, "#!/bin/sh\nexec 0<&-\nsleep 1\necho delivery-0\n");
    let early = SendRelay { argv: vec![early.display().to_string()], ls_argv: None };
    let big = "x".repeat(1 << 20);
    let e = relay_with_deadline(&early, "lane-b", &big, &RelayMetadata::default(), true, None)
        .unwrap_err();
    assert!(e.to_string().contains("did not read the whole message"), "{e}");

    let missing = SendRelay { argv: vec![dir.join("absent").display().to_string()], ls_argv: None };
    assert!(
        relay_with_deadline(&missing, "lane-b", "x", &RelayMetadata::default(), true, None)
            .is_err()
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// A bare relay name the PATH lacks is found in `$HOME/.local/bin` and run by its absolute
/// path; one found nowhere names every place looked (lane VMs, 2026-11-21).
#[cfg(unix)]
#[test]
fn a_bare_relay_name_is_found_in_home_local_bin_when_path_lacks_it() {
    let dir = scratch("home-bin");
    let home = dir.join("home");
    let empty = dir.join("empty-path");
    std::fs::create_dir_all(home.join(".local/bin")).unwrap();
    std::fs::create_dir_all(&empty).unwrap();
    let relay = home.join(".local/bin/acpmux-test-relay");
    crate::test_exec::write_executable(&relay, "#!/bin/sh\ncat >/dev/null\necho delivery-7\n");
    let paths = [empty.clone().into_os_string()];
    assert_eq!(relay_program("acpmux-test-relay", &paths, Some(&home)).unwrap(), relay);
    // A path is run as it is.
    assert_eq!(
        relay_program("./x/relay", &paths, Some(&home)).unwrap(),
        std::path::PathBuf::from("./x/relay")
    );
    let e = relay_program("acpmux-test-absent", &paths, Some(&home)).unwrap_err().to_string();
    let local = home.join(".local/bin/acpmux-test-absent");
    let on_path = empty.join("acpmux-test-absent");
    assert!(e.contains(&local.display().to_string()), "{e}");
    assert!(e.contains(&on_path.display().to_string()), "{e}");
    assert!(e.contains("/usr/local/bin/acpmux-test-absent"), "{e}");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_relayed_send_with_attachments_is_refused() {
    let config = SendRelay { argv: vec!["/nonexistent/relay".into()], ls_argv: None };
    let e = send_with_deadline(&config, "lane-b", "x", &RelayMetadata::default(), true, true, None)
        .unwrap_err();
    assert_eq!(e.downcast_ref::<AppError>().map(|a| a.code), Some(Code::Usage));
    assert!(e.to_string().contains("text only"), "{e}");
}
