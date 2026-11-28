use super::{Done, verdicts_for, warning_due, warning_text};

#[test]
fn machine_verdict_judges_one_object_or_an_array() {
    let one = r#"{"host":"h","health_at_ms":100000,"cores":32,"load1":205.0,
            "previous":{"sample_at_ms":40000,"cpu":{"state":"pressured","hot":1}}}"#;
    let v = verdicts_for(one, 101_000).expect("judged");
    assert_eq!(v["reason"], "saturated:cpu");
    assert_eq!(v["would_defer"], true);
    assert_eq!(v["health_age_s"], 1);
    let many = format!("[{one}, {{\"host\":\"g\"}}]");
    let v = verdicts_for(&many, 101_000).expect("judged");
    assert_eq!(v[0]["host"], "h");
    assert_eq!(v[1]["reason"], "unknown:stale");
    assert!(verdicts_for("{\"lod1\": 1}", 0).is_err());
    assert!(verdicts_for("not json", 0).is_err());
}

/// W5-S, bench round 4 friction 9 (2026-11-08): the over-budget line came on every send, in
/// agents' tool output too. One caller hears it once per host per 10 minutes.
#[test]
fn w5s_a_host_warning_comes_once_per_caller_and_host_per_ten_minutes() {
    let dir = std::env::temp_dir().join(format!("w5s-host-warning-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let over = |host: &str| format!("host-budget: {host} over its CPU/RAM budget: load1 190 >= 18");
    let t0 = 1_800_000_000_000;
    assert!(warning_due(&dir, "person", &over("gray"), t0));
    // The numbers change from send to send; the host is what counts.
    let again = "host-budget: gray over its CPU/RAM budget: load1 191 >= 18";
    assert!(!warning_due(&dir, "person", again, t0 + 60_000));
    assert!(warning_due(&dir, "session-a", &over("gray"), t0 + 60_000), "another caller");
    assert!(warning_due(&dir, "person", &over("cmux16"), t0 + 60_000), "another host");
    assert!(!warning_due(&dir, "person", &over("gray"), t0 + 9 * 60_000));
    assert!(warning_due(&dir, "person", &over("gray"), t0 + 10 * 60_000 + 1));
    let _ = std::fs::remove_dir_all(&dir);
}

/// Review of #39057: the warning never creates a missing acpmux home (`ACPMUX_HOME` named
/// but not made yet, or a typo); it makes only its own folder inside an existing one. The
/// line is still due.
#[test]
fn w5s_a_host_warning_does_not_create_a_missing_acpmux_home() {
    let base = std::env::temp_dir().join(format!("w5s-host-home-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&base);
    std::fs::create_dir_all(&base).unwrap();
    let home = base.join("not-made");
    let line = "host-budget: gray over its CPU/RAM budget: load1 190 >= 18";
    assert!(warning_due(&home.join("host-warnings"), "person", line, 1));
    assert!(!home.exists(), "the warning made the missing home {}", home.display());
    let _ = std::fs::remove_dir_all(&base);
}

#[test]
fn an_over_budget_line_after_new_says_the_session_started_and_nothing_was_refused() {
    // 2026-11-25: the bare line read as a refusal, the coordinator ran `acpmux new` again,
    // and fs-agent-lane-2 and gcp-agent-lane-6 each got a duplicate lane.
    let line = "host-budget: fs-agent-lane-2 over its CPU/RAM budget: load1 9.1 >= 2 (2 cores)";
    let started = warning_text(line, Done::Started);
    assert!(started.starts_with(line), "{started}");
    assert!(started.contains("nothing refused"), "{started}");
    assert!(started.contains("do not start it again"), "{started}");
    let queued = warning_text(line, Done::Queued);
    assert!(queued.contains("nothing refused") && queued.contains("queued anyway"), "{queued}");
}
