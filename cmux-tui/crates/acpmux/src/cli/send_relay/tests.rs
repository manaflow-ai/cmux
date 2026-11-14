use super::*;

fn named(name: &str) -> RelaySender {
    RelaySender { name: Some(name.to_owned()), subagent: None }
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
        relay_with_deadline(&config, "refuse", "x", &RelaySender::default(), true, None).unwrap();
    assert_eq!(done.status, 7);
    assert_eq!(std::fs::read_to_string(&seen).unwrap(), "send|refuse|-|unset|x");

    // One that stops reading early and exits 0 did not take the message.
    let early = dir.join("early");
    crate::test_exec::write_executable(&early, "#!/bin/sh\nexec 0<&-\nsleep 1\necho delivery-0\n");
    let early = SendRelay { argv: vec![early.display().to_string()], ls_argv: None };
    let big = "x".repeat(1 << 20);
    let e = relay_with_deadline(&early, "lane-b", &big, &RelaySender::default(), true, None)
        .unwrap_err();
    assert!(e.to_string().contains("did not read the whole message"), "{e}");

    let missing = SendRelay { argv: vec![dir.join("absent").display().to_string()], ls_argv: None };
    assert!(
        relay_with_deadline(&missing, "lane-b", "x", &RelaySender::default(), true, None).is_err()
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_relayed_send_with_attachments_is_refused() {
    let config = SendRelay { argv: vec!["/nonexistent/relay".into()], ls_argv: None };
    let e = send_with_deadline(&config, "lane-b", "x", &RelaySender::default(), true, true, None)
        .unwrap_err();
    assert_eq!(e.downcast_ref::<AppError>().map(|a| a.code), Some(Code::Usage));
    assert!(e.to_string().contains("text only"), "{e}");
}
