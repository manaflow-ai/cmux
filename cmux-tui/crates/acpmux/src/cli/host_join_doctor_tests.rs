use super::*;

/// 2026-10-29T03:00:00Z.
const NOW: u64 = 1_793_242_800_000;

fn status(extra: Value) -> Value {
    let mut v = json!({
        "credentialPresent": true,
        "machineId": "m_1",
        "teamId": "team_1",
        "hubOrigin": "https://platform.example",
        "hubReachable": true,
        "lastHeartbeat": NOW - 10_000,
        "revoked": false,
        "consent": {"screen": "none", "control": "none"},
    });
    for (key, value) in extra.as_object().unwrap() {
        v[key] = value.clone();
    }
    v
}

fn healthy() -> Facts {
    Facts {
        linux: true,
        binary: Binary::Ok("/home/u/.local/bin/acpmux".into()),
        service: Service::Active { linger: Some(true) },
        daemon_running: true,
        daemon_binary: DaemonBinary {
            path: Some("/home/u/.local/bin/acpmux".into()),
            build: Some("9d9419a91".into()),
            version: Some("1.0.0".into()),
        },
        path_binary: None,
        capabilities: Some(vec!["machine.join.stdin.v1".into(), CONSENT_GATE.into()]),
        status: Status::Json(status(json!({}))),
    }
}

fn step<'a>(steps: &'a [JoinStep], name: &str) -> &'a JoinStep {
    steps.iter().find(|s| s.step == name).unwrap_or_else(|| panic!("no {name} in {steps:?}"))
}

fn with_status(extra: Value) -> Vec<JoinStep> {
    steps(&Facts { status: Status::Json(status(extra)), ..healthy() }, NOW)
}

#[test]
fn a_healthy_join_is_all_ok_in_order() {
    let checked = steps(&healthy(), NOW);
    let names: Vec<&str> = checked.iter().map(|s| s.step).collect();
    assert_eq!(
        names,
        [
            "binary",
            "service",
            "daemon",
            "credential",
            "team",
            "revoked",
            "hub",
            "heartbeat",
            "consent"
        ]
    );
    assert!(checked.iter().all(|s| s.state == StepState::Ok), "{checked:?}");
    assert_eq!(step(&checked, "credential").detail, "joined as m_1");
    assert_eq!(step(&checked, "hub").detail, "reaches https://platform.example");
    assert!(
        step(&checked, "consent").detail.starts_with("screen sharing off, control off; to allow")
    );
}

const APP: &str = "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux";
const ON_PATH: &str = "/Users/x/.local/bin/acpmux";

#[test]
fn app_daemon_and_stale_path_copy_have_distinct_steps() {
    let daemon = DaemonBinary::from_status(
        &json!({"exe": APP, "pid": 41, "build": "9d9419a91", "version": "1.0.0"}),
        |_| panic!("the daemon reported its executable"),
    );
    for stale in ["a1143d5cc", "75d22c950"] {
        let facts = Facts {
            linux: false,
            daemon_binary: daemon.clone(),
            path_binary: Some((ON_PATH.into(), stale.into())),
            service: Service::AppManaged,
            ..healthy()
        };
        let checked = steps(&facts, NOW);
        assert_eq!(step(&checked, "binary").detail, format!("running daemon at {APP} (9d9419a91)"));
        let warnings: Vec<_> = checked.iter().filter(|s| s.state == StepState::Warn).collect();
        assert_eq!(warnings.len(), 1);
        let warn = warnings[0];
        for expected in [APP, ON_PATH, "9d9419a91", stale] {
            assert!(warn.detail.contains(expected), "{}", warn.detail);
        }
        assert_eq!(warn.fix, Some(format!("Remove or update the stale acpmux at {ON_PATH}")));
        let service = step(&checked, "service");
        assert_eq!(service.state, StepState::Ok);
        assert_eq!(service.detail, "the cmux app runs the daemon");
        assert!(service.fix.is_none());
    }
}

#[test]
fn only_a_different_path_with_a_known_different_build_warns() {
    let daemon = healthy().daemon_binary;
    let same_path = daemon.path.clone().unwrap();
    assert!(path_warning(&daemon, None).is_none());
    assert!(path_warning(&daemon, Some(&(same_path, "older".into()))).is_none());
    let copy = (PathBuf::from(ON_PATH), "9d9419a91".to_owned());
    assert!(path_warning(&daemon, Some(&copy)).is_none());
    let unknown = DaemonBinary { build: None, ..daemon };
    assert!(path_warning(&unknown, Some(&copy)).is_none());
}

#[cfg(target_os = "linux")]
#[test]
fn a_replaced_running_executable_is_still_the_same_install_path() {
    let daemon = DaemonBinary::from_status(
        &json!({"exe": "/bin/acpmux (deleted)", "build": "before-update"}),
        |_| unreachable!(),
    );
    assert_eq!(daemon.path.as_deref(), Some(Path::new("/bin/acpmux")));
    let installed = (PathBuf::from("/bin/acpmux"), "after-update".to_owned());
    assert!(path_warning(&daemon, Some(&installed)).is_none());
}

#[test]
fn older_daemon_uses_its_pid_and_keeps_its_own_version() {
    let daemon =
        DaemonBinary::from_status(&json!({"exe": null, "pid": 41, "version": "0.9.0"}), |pid| {
            assert_eq!(pid, 41);
            Some(APP.into())
        });
    let facts = Facts { daemon_binary: daemon, ..healthy() };
    assert_eq!(binary_step(&facts).detail, format!("running daemon at {APP} (0.9.0)"));
    let unknown = Facts { daemon_binary: DaemonBinary::default(), ..facts };
    assert_eq!(binary_step(&unknown).state, StepState::Warn);
    assert!(!binary_step(&unknown).detail.contains(".local/bin"));
}

#[test]
fn a_fresh_home_with_no_credential_fails_credential_with_the_machine_add_fix() {
    let checked = with_status(json!({"credentialPresent": false, "machineId": null}));
    let credential = step(&checked, "credential");
    assert_eq!(credential.state, StepState::Fail);
    assert_eq!(
        credential.fix.as_deref(),
        Some("Make a new line on your Mac: cmux machine add, and paste it here")
    );
    for later in ["team", "revoked", "hub", "heartbeat"] {
        assert_eq!(step(&checked, later).state, StepState::Skip, "{later}");
    }
}

/// The user of the live report (cmux16, 2026-11-22): its personal team, as the hub derives it.
const USER: &str = "user_5921af13aa39138f191d";
const PERSONAL: &str = "team_760c83ddd31c6360c927";

#[test]
fn the_personal_team_id_is_the_hubs() {
    assert_eq!(personal_team_of(USER), PERSONAL);
}

#[test]
fn a_join_in_the_personal_team_says_so() {
    let checked = with_status(json!({"teamId": PERSONAL, "userId": USER}));
    let team = step(&checked, "team");
    assert_eq!(team.state, StepState::Ok);
    assert_eq!(team.detail, format!("joined in your personal team {PERSONAL} as {USER}"));
    assert_eq!(team.data.as_ref().unwrap()["personalTeam"], PERSONAL);
}

/// A join in a shared team heartbeats and reads healthy everywhere else, yet the person's
/// personal-team machines get `machine.not_found` for a ticket to it and its vault pull is
/// `vault.forbidden`: the step warns with both codes and how to move it.
#[test]
fn a_join_outside_the_personal_team_warns_with_the_codes_and_the_move() {
    let shared = "team_a104498f37e7f4a3327d";
    let checked = with_status(json!({"teamId": shared, "userId": USER}));
    let team = step(&checked, "team");
    assert_eq!(team.state, StepState::Warn);
    assert!(team.detail.contains(shared) && team.detail.contains(PERSONAL), "{}", team.detail);
    assert!(team.detail.contains("machine.not_found"), "{}", team.detail);
    assert!(team.detail.contains("vault.forbidden"), "{}", team.detail);
    let fix = team.fix.as_deref().unwrap();
    assert!(fix.contains("acpmux machine leave") && fix.contains("personal team"), "{fix}");
    assert_eq!(team.data.as_ref().unwrap()["teamId"], shared);
    // A warning, never a failed join: a shared team may be the one meant.
    assert!(team.healthy());
}

#[test]
fn a_join_that_names_no_account_reports_its_team_only() {
    let team = step(&with_status(json!({"teamId": "team_1", "userId": null})), "team").clone();
    assert_eq!(team.state, StepState::Ok);
    assert!(team.detail.starts_with("joined in team team_1;"), "{}", team.detail);
    let team = step(&with_status(json!({"teamId": null})), "team").clone();
    assert_eq!(team.state, StepState::Skip);
}

#[test]
fn a_revoked_machine_fails_revoked_with_the_same_fix() {
    let checked = with_status(json!({"revoked": true}));
    let revoked = step(&checked, "revoked");
    assert_eq!(revoked.state, StepState::Fail);
    assert_eq!(
        revoked.fix,
        step(&with_status(json!({"credentialPresent": false})), "credential").fix
    );
    assert_eq!(step(&checked, "heartbeat").state, StepState::Skip);
}

#[test]
fn an_unreachable_hub_and_a_stale_heartbeat_fail_with_their_fixes() {
    let checked = with_status(json!({"hubReachable": false}));
    assert_eq!(
        step(&checked, "hub").fix.as_deref(),
        Some(
            "This machine cannot reach https://platform.example on 443: check its outbound HTTPS or proxy"
        )
    );
    for stale in [json!(NOW - 91_000), json!("2026-10-29T02:50:00Z"), Value::Null] {
        let heartbeat = step(&with_status(json!({"lastHeartbeat": stale})), "heartbeat").clone();
        assert_eq!(heartbeat.state, StepState::Fail, "{stale}");
        assert_eq!(
            heartbeat.fix.as_deref(),
            Some("acpmux daemon restart; if it persists, acpmux config must name meshRelay")
        );
    }
    assert_eq!(
        step(&with_status(json!({"lastHeartbeat": "2026-10-29T02:50:00Z"})), "heartbeat").detail,
        "last heartbeat 10 min ago"
    );
    assert_eq!(
        step(&with_status(json!({"lastHeartbeat": (NOW - 5_000) / 1000})), "heartbeat").state,
        StepState::Ok
    );
}

#[test]
fn missing_optional_status_fields_skip_instead_of_failing() {
    let bare = json!({"credentialPresent": true});
    let checked = steps(&Facts { status: Status::Json(bare), ..healthy() }, NOW);
    assert_eq!(step(&checked, "credential").detail, "joined as this machine");
    assert_eq!(step(&checked, "hub").state, StepState::Skip);
    assert_eq!(step(&checked, "consent").state, StepState::Skip);
    // No hub origin: the fixes name the development platform.
    let checked = steps(
        &Facts {
            daemon_running: false,
            binary: Binary::Missing("/h/.local/bin/acpmux".into()),
            status: Status::NotRun,
            ..healthy()
        },
        NOW,
    );
    assert_eq!(
        step(&checked, "binary").fix.as_deref(),
        Some(
            "Re-run the join line without a token: curl -fsSL https://cmux-platform-production.debussy.workers.dev/v1/machines/join.sh | sh"
        )
    );
    assert_eq!(step(&checked, "credential").state, StepState::Skip);
}

#[test]
fn an_old_acpmux_a_failed_status_and_a_loose_credential_file_fail_credential() {
    let old = steps(&Facts { status: Status::Unsupported, ..healthy() }, NOW);
    assert_eq!(step(&old, "credential").state, StepState::Fail);
    assert!(step(&old, "credential").fix.as_deref().unwrap().starts_with("Re-run the join line"));
    let failed = steps(&Facts { status: Status::Failed("exit 5".into()), ..healthy() }, NOW);
    assert_eq!(step(&failed, "credential").detail, "acpmux host join --status failed (exit 5)");
    let loose =
        with_status(json!({"credentialMode": "0644", "credentialPath": "/h/.acpmux/machine.json"}));
    assert_eq!(
        step(&loose, "credential").fix.as_deref(),
        Some("chmod 600 /h/.acpmux/machine.json")
    );
    let tight =
        with_status(json!({"credentialMode": "0600", "credentialPath": "/h/.acpmux/machine.json"}));
    assert_eq!(step(&tight, "credential").state, StepState::Ok);
}

#[test]
fn service_and_daemon_failures_name_local_commands() {
    let off = steps(
        &Facts {
            service: Service::Inactive { installed: true },
            daemon_running: false,
            ..healthy()
        },
        NOW,
    );
    assert_eq!(
        step(&off, "service").fix.as_deref(),
        Some("systemctl --user enable --now acpmux.service")
    );
    assert_eq!(step(&off, "daemon").fix.as_deref(), Some("acpmux daemon start"));
    let mac = steps(
        &Facts { linux: false, service: Service::Inactive { installed: true }, ..healthy() },
        NOW,
    );
    assert_eq!(
        step(&mac, "service").fix.as_deref(),
        Some("launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.acpmux.daemon.plist")
    );
    let linger =
        steps(&Facts { service: Service::Active { linger: Some(false) }, ..healthy() }, NOW);
    assert_eq!(step(&linger, "service").state, StepState::Warn);
    assert_eq!(step(&linger, "service").fix.as_deref(), Some("loginctl enable-linger $USER"));
    let none = steps(&Facts { service: Service::NoManager, ..healthy() }, NOW);
    assert_eq!(step(&none, "service").state, StepState::Warn);
}

#[test]
fn a_daemon_that_answers_without_its_service_warns_instead_of_failing() {
    // A headless Linux user with no systemd user session: `systemctl --user` prints nothing.
    assert_eq!(systemd_state("", true), Service::NoManager);
    assert_eq!(systemd_state("\n", false), Service::NoManager);
    assert_eq!(systemd_state("active\n", true), Service::Active { linger: None });
    assert_eq!(systemd_state("inactive\n", true), Service::Inactive { installed: true });
    assert_eq!(systemd_state("failed\n", false), Service::Inactive { installed: false });
    for installed in [true, false] {
        let checked = steps(&Facts { service: Service::Inactive { installed }, ..healthy() }, NOW);
        let service = step(&checked, "service");
        assert_eq!(service.state, StepState::Warn, "{service:?}");
        assert!(service.healthy() && service.fix.is_some());
        assert!(service.detail.contains("the daemon runs without it"), "{}", service.detail);
        let (_, ok) = render("box", "host", &checked, Print::Quiet);
        assert!(ok, "a join whose daemon answers is healthy: {checked:?}");
    }
    let none = steps(&Facts { service: Service::NoManager, ..healthy() }, NOW);
    assert!(render("box", "host", &none, Print::Quiet).1, "{none:?}");
}

#[test]
fn consent_is_informational_and_reports_grants() {
    let granted = with_status(json!({"consent": {"screen": "granted", "control": true}}));
    let consent = step(&granted, "consent");
    assert_eq!(consent.state, StepState::Ok);
    assert_eq!(consent.detail, "screen sharing on, control on");
}

#[test]
fn the_output_parses_as_host_step_lines_then_a_report() {
    let checked = with_status(json!({"revoked": true}));
    let (text, ok) = render("lane-vm-3", "this machine", &checked, Print::Lines);
    assert!(!ok);
    let lines: Vec<Value> = text.lines().map(|l| serde_json::from_str(l).unwrap()).collect();
    assert_eq!(lines.len(), checked.len() + 1);
    for line in &lines[..checked.len()] {
        // `data` is optional structured readiness data (the agents and team steps).
        let mut keys: Vec<&str> =
            line.as_object().unwrap().keys().map(String::as_str).filter(|k| *k != "data").collect();
        keys.sort_unstable();
        assert_eq!(keys, ["detail", "fix", "state", "step"]);
        assert!(matches!(line["state"].as_str(), Some("ok" | "fixed" | "fail" | "warn" | "skip")));
    }
    let report = &lines[checked.len()]["report"];
    assert_eq!(report["ok"], false);
    assert_eq!(report["name"], "lane-vm-3");
    assert_eq!(report["steps"].as_array().unwrap().len(), checked.len());
    let (human, _) = render("lane-vm-3", "this machine", &checked, Print::Human);
    assert!(human.contains("fail   revoked    your team revoked this machine\n"), "{human}");
    assert!(human.ends_with("lane-vm-3 (this machine): needs attention\n"), "{human}");
    let (quiet, ok) = render("lane-vm-3", "this machine", &steps(&healthy(), NOW), Print::Quiet);
    assert!(quiet.is_empty());
    assert!(ok);
}

#[test]
fn a_repaired_failure_shows_fixed() {
    let before = steps(&Facts { daemon_running: false, ..healthy() }, NOW);
    let after = mark_fixed(&before, steps(&healthy(), NOW));
    assert_eq!(step(&after, "daemon").state, StepState::Fixed);
    assert_eq!(step(&after, "binary").state, StepState::Ok);
}

#[test]
fn absent_fields_skip_and_a_null_heartbeat_fails() {
    let mut v = status(json!({}));
    let object = v.as_object_mut().unwrap();
    object.remove("revoked");
    object.remove("lastHeartbeat");
    let checked = steps(&Facts { status: Status::Json(v), ..healthy() }, NOW);
    assert_eq!(step(&checked, "revoked").state, StepState::Skip);
    assert_eq!(step(&checked, "heartbeat").state, StepState::Skip);
    let checked = with_status(json!({"lastHeartbeat": null}));
    assert_eq!(step(&checked, "heartbeat").state, StepState::Fail);
    let unsaid =
        steps(&Facts { status: Status::Json(json!({"hubReachable": true})), ..healthy() }, NOW);
    assert_eq!(step(&unsaid, "credential").state, StepState::Skip);
}

#[test]
fn an_unsafe_hub_origin_or_path_is_never_printed() {
    for hub in [
        "https://platform.example/?t=cmj_0123456789abcdef",
        "https://user:cmm_x@platform.example",
        "https://platform.example/path",
        "https://platform.example#frag",
        "http://platform.example",
    ] {
        let checked = with_status(json!({"hubOrigin": hub, "hubReachable": false}));
        let text = format!("{checked:?}");
        assert!(!text.contains("cmj_") && !text.contains("cmm_"), "{text}");
        assert!(step(&checked, "hub").detail.contains(JOIN_ORIGIN), "{hub}");
    }
    let loose = with_status(json!({"credentialMode": "0644", "credentialPath": "/h/cmm_secret"}));
    let credential = step(&loose, "credential");
    assert_eq!(credential.state, StepState::Fail, "a loose file still fails");
    assert!(!format!("{credential:?}").contains("cmm_"), "{credential:?}");
    let spaced =
        with_status(json!({"credentialMode": "0644", "credentialPath": "/h/my dir/m.json"}));
    assert_eq!(step(&spaced, "credential").fix.as_deref(), Some("chmod 600 '/h/my dir/m.json'"));
    let secret_id = with_status(json!({"machineId": "cmm_leak"}));
    assert_eq!(step(&secret_id, "credential").detail, "joined as this machine");
}

#[test]
fn a_daemon_without_the_consent_gate_fails_consent_with_update_acpmux() {
    let old = Facts { capabilities: Some(vec!["machine.join.stdin.v1".into()]), ..healthy() };
    let checked = steps(&old, NOW);
    let consent = step(&checked, "consent");
    assert_eq!(consent.state, StepState::Fail);
    assert_eq!(consent.detail, "this acpmux daemon has no consent gate (machine-consent-v1)");
    let fix = consent.fix.as_deref().unwrap();
    assert!(fix.starts_with("Update acpmux. Re-run the join line without a token:"), "{fix}");
    assert!(fix.contains("https://platform.example/v1/machines/join.sh | sh"), "{fix}");
    assert!(!render("vm", "this machine", &checked, Print::Human).1, "it is a failing check");
    // A daemon that predates capabilities reports none: the same failure, joined or not.
    let none = Facts { capabilities: Some(capability_ids(&json!({"pid": 1}))), ..healthy() };
    assert_eq!(step(&steps(&none, NOW), "consent").state, StepState::Fail);
    let unjoined = Facts { capabilities: Some(vec![]), status: Status::Unsupported, ..healthy() };
    assert_eq!(step(&steps(&unjoined, NOW), "consent").state, StepState::Fail);
}

#[test]
fn unread_capabilities_or_a_stopped_daemon_leave_consent_informational() {
    let unread = steps(&Facts { capabilities: None, ..healthy() }, NOW);
    assert_eq!(step(&unread, "consent").state, StepState::Ok);
    let stopped = Facts { daemon_running: false, capabilities: Some(vec![]), ..healthy() };
    let checked = steps(&stopped, NOW);
    assert_eq!(step(&checked, "consent").state, StepState::Ok);
    assert_eq!(step(&checked, "daemon").state, StepState::Fail);
}

#[test]
fn capability_ids_reads_the_status_list() {
    let v = json!({"capabilities": ["a", 7, CONSENT_GATE]});
    assert_eq!(capability_ids(&v), ["a", CONSENT_GATE]);
    assert!(capability_ids(&json!({"capabilities": "x"})).is_empty());
}

#[test]
fn the_daemon_consent_view_and_its_last_refusal_are_read() {
    let view = with_status(json!({"consent": {
        "consent": {"screen": "granted", "control": "none"},
        "lastRefusal": {"event": "consent_refused", "surface": "control", "at": NOW},
    }}));
    let consent = step(&view, "consent");
    assert_eq!(consent.state, StepState::Ok);
    assert!(
        consent.detail.starts_with(
            "screen sharing on, control off; a control request was last refused here; to allow"
        ),
        "{}",
        consent.detail
    );
    let top = with_status(json!({"lastRefusal": {"surface": "screen\u{1b}"}}));
    assert!(!step(&top, "consent").detail.contains("refused"), "only a known surface is named");
}

#[test]
fn the_heartbeat_acpmux_stores_as_milliseconds_in_text_reads_as_a_time() {
    // `cloud_join::record_auth_result` stores `now_ms().to_string()`, and `host join --status`
    // reports it as that string: the Mac-1793734633586 join (2026-11-03) failed its heartbeat
    // with heartbeats on record because only a number or RFC 3339 text was read.
    let fresh = with_status(json!({"lastHeartbeat": (NOW - 4_000).to_string()}));
    assert_eq!(step(&fresh, "heartbeat").state, StepState::Ok);
    assert_eq!(step(&fresh, "heartbeat").detail, "last heartbeat 4s ago");
    let stale = with_status(json!({"lastHeartbeat": (NOW - 600_000).to_string()}));
    assert_eq!(step(&stale, "heartbeat").state, StepState::Fail);
    assert_eq!(step(&stale, "heartbeat").detail, "last heartbeat 10 min ago");
    for junk in ["", "12a", "-5"] {
        assert_eq!(
            step(&with_status(json!({"lastHeartbeat": junk})), "heartbeat").state,
            StepState::Fail,
            "{junk:?}"
        );
    }
}

#[test]
fn a_join_seconds_old_waits_for_its_first_heartbeat_then_passes() {
    let fresh = Facts { status: Status::Json(status(json!({"lastHeartbeat": null}))), ..healthy() };
    assert!(awaits_first_heartbeat(&fresh));
    let mut asks = 0;
    let mut pauses = 0;
    let waited = wait_first_heartbeat(
        fresh,
        FIRST_HEARTBEAT_POLLS,
        || {
            asks += 1;
            let at = if asks < 3 { Value::Null } else { json!((NOW - 1_000).to_string()) };
            Status::Json(status(json!({"lastHeartbeat": at})))
        },
        || pauses += 1,
    );
    assert_eq!((asks, pauses), (3, 3));
    assert_eq!(step(&steps(&waited, NOW), "heartbeat").state, StepState::Ok);
}

#[test]
fn a_heartbeat_that_never_comes_still_fails_after_a_bounded_wait() {
    let fresh = Facts { status: Status::Json(status(json!({"lastHeartbeat": null}))), ..healthy() };
    let mut asks = 0;
    let waited = wait_first_heartbeat(
        fresh,
        FIRST_HEARTBEAT_POLLS,
        || {
            asks += 1;
            Status::Json(status(json!({"lastHeartbeat": null})))
        },
        || {},
    );
    assert_eq!(asks, FIRST_HEARTBEAT_POLLS);
    let heartbeat = step(&steps(&waited, NOW), "heartbeat").clone();
    assert_eq!(heartbeat.state, StepState::Fail);
    assert_eq!(heartbeat.detail, "no heartbeat reached the hub yet");
}

#[test]
fn only_a_sound_join_with_no_heartbeat_yet_is_waited_on() {
    let null = json!({"lastHeartbeat": null});
    let with = |extra: Value, daemon_running: bool| Facts {
        status: Status::Json(status(Value::Object(
            null.as_object()
                .unwrap()
                .clone()
                .into_iter()
                .chain(extra.as_object().unwrap().clone())
                .collect(),
        ))),
        daemon_running,
        ..healthy()
    };
    assert!(awaits_first_heartbeat(&with(json!({}), true)));
    assert!(awaits_first_heartbeat(&with(json!({"meshRelayConfigured": true}), true)));
    assert!(!awaits_first_heartbeat(&with(json!({}), false)), "no daemon to heartbeat");
    assert!(!awaits_first_heartbeat(&with(json!({"revoked": true}), true)));
    assert!(!awaits_first_heartbeat(&with(json!({"credentialPresent": false}), true)));
    assert!(!awaits_first_heartbeat(&with(json!({"meshRelayConfigured": false}), true)));
    assert!(!awaits_first_heartbeat(&with(json!({"lastHeartbeat": NOW - 200_000}), true)));
    assert!(!awaits_first_heartbeat(&healthy()));
    let mut asks = 0;
    wait_first_heartbeat(
        healthy(),
        FIRST_HEARTBEAT_POLLS,
        || {
            asks += 1;
            Status::NotRun
        },
        || {},
    );
    assert_eq!(asks, 0, "a heartbeat on record is not asked again");
}

#[test]
fn a_launch_agent_waiting_for_a_screen_login_warns_instead_of_failing() {
    assert_eq!(launchd_state(true, false), Service::AtNextLogin);
    assert_eq!(launchd_state(true, true), Service::Inactive { installed: true });
    assert_eq!(launchd_state(false, false), Service::Inactive { installed: false });
    let checked = steps(&Facts { linux: false, service: Service::AtNextLogin, ..healthy() }, NOW);
    let service = step(&checked, "service");
    assert_eq!(service.state, StepState::Warn);
    assert!(service.healthy());
    assert!(service.detail.contains("loads at the next login"), "{}", service.detail);
}
