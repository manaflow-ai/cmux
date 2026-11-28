use super::*;

fn answer(state: &str, head: &str, checks: Value) -> Value {
    json!({
        "number": 7, "url": "https://github.com/octo/app/pull/7", "state": state,
        "headRefOid": head, "baseRefName": "main", "statusCheckRollup": checks,
    })
}

fn run_check(status: &str, conclusion: &str) -> Value {
    json!({"__typename": "CheckRun", "name": "test", "status": status, "conclusion": conclusion})
}

fn code(outcome: Option<Outcome>) -> Option<i32> {
    match outcome? {
        Outcome::Done { code, .. } => Some(code),
        Outcome::HeadMoved { .. } => Some(4),
    }
}

#[test]
fn interval_grows_with_the_wait_and_stops_at_ninety_seconds() {
    assert_eq!(interval(0), 15);
    assert_eq!(interval(600), 45);
    assert_eq!(interval(7200), 90);
}

#[test]
fn judge_waits_for_pending_checks_and_ends_on_green_or_red() {
    let pending = answer("OPEN", "abc123", json!([run_check("IN_PROGRESS", "")]));
    assert_eq!(code(judge(&pending, Until::Checks, None, 0)), None);
    let green = answer("OPEN", "abc123", json!([run_check("COMPLETED", "SUCCESS")]));
    assert_eq!(code(judge(&green, Until::Checks, None, 0)), Some(0));
    let red = answer("OPEN", "abc123", json!([run_check("COMPLETED", "FAILURE")]));
    assert_eq!(code(judge(&red, Until::Checks, None, 0)), Some(1));
    // --until merged keeps waiting past green checks, and ends on a merge or a close.
    assert_eq!(code(judge(&green, Until::Merged, None, 0)), None);
    assert_eq!(
        code(judge(&answer("MERGED", "abc123", json!([])), Until::Merged, None, 0)),
        Some(0)
    );
    assert_eq!(
        code(judge(&answer("CLOSED", "abc123", json!([])), Until::Merged, None, 0)),
        Some(1)
    );
}

#[test]
fn judge_gives_a_fresh_push_time_for_its_checks_and_its_head() {
    let none = answer("OPEN", "abc123", json!([]));
    assert_eq!(code(judge(&none, Until::Checks, None, 10)), None);
    assert_eq!(code(judge(&none, Until::Checks, None, NO_CHECKS_GRACE_S)), Some(0));
    let old = answer("OPEN", "old999", json!([run_check("COMPLETED", "SUCCESS")]));
    assert_eq!(code(judge(&old, Until::Checks, Some("abc123"), 5)), None);
    assert_eq!(code(judge(&old, Until::Checks, Some("abc123"), HEAD_GRACE_S)), Some(4));
    let ours = answer("OPEN", "abc123", json!([run_check("COMPLETED", "SUCCESS")]));
    assert_eq!(code(judge(&ours, Until::Checks, Some("ABC1"), 0)), Some(0));
}

#[test]
fn rate_limits_are_told_apart_from_other_failures() {
    assert_eq!(rate_limited("GraphQL: API rate limit exceeded for user ID 1."), Some(false));
    assert_eq!(rate_limited("You have exceeded a secondary rate limit"), Some(true));
    assert_eq!(rate_limited("HTTP 502: Bad Gateway"), None);
}

#[test]
fn keys_and_remotes() {
    assert_eq!(key("octo/app", "7"), "octo__app__7");
    assert_eq!(key("a/b c", "1/2"), "a__b_c__1_2");
    for url in [
        "https://github.com/octo/app.git",
        "git@github.com:octo/app.git",
        "ssh://git@github.com/octo/app",
        "https://github.com/octo/app/\n",
    ] {
        assert_eq!(repo_of_remote(url).as_deref(), Some("octo/app"), "{url}");
    }
    assert_eq!(repo_of_remote("https://gitlab.com/octo/app.git"), None);
}

/// Several waiters on one pull request on one machine spend one GitHub call between them.
#[cfg(unix)]
#[test]
fn waiters_on_one_pull_request_share_one_poll() {
    use std::os::unix::fs::PermissionsExt as _;
    let tmp = tempfile::tempdir().unwrap();
    let calls = tmp.path().join("calls");
    let fixture = tmp.path().join("answer.json");
    std::fs::write(
        &fixture,
        answer("OPEN", "abc123", json!([run_check("COMPLETED", "SUCCESS")])).to_string(),
    )
    .unwrap();
    let gh = tmp.path().join("gh");
    std::fs::write(
        &gh,
        format!(
            "#!/bin/sh\necho \"$*\" >> '{}'\nsleep 0.3\ncat '{}'\n",
            calls.display(),
            fixture.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&gh, std::fs::Permissions::from_mode(0o755)).unwrap();
    let dir = tmp.path().join("state");
    std::fs::create_dir_all(&dir).unwrap();
    let waiters: Vec<_> = (0..6)
        .map(|_| {
            let ctx = Ctx { dir: dir.clone(), gh: gh.clone().into_os_string(), land: None };
            std::thread::spawn(move || {
                let args = PrWaitArgs {
                    pr: "7".into(),
                    repo: Some("octo/app".into()),
                    sha: Some("abc123".into()),
                    until: Some(Until::Checks),
                    timeout: 60,
                };
                wait_blocking(&ctx, &args, true).is_ok()
            })
        })
        .collect();
    for w in waiters {
        assert!(w.join().unwrap());
    }
    let made = std::fs::read_to_string(&calls).unwrap();
    assert_eq!(made.lines().count(), 1, "{made}");
    assert!(made.starts_with("pr view 7 -R octo/app --json "), "{made}");
}

/// A rate-limited poll makes every waiter sleep to the reset instead of asking again.
#[cfg(unix)]
#[test]
fn a_rate_limit_holds_the_next_poll_until_its_reset() {
    use std::os::unix::fs::PermissionsExt as _;
    let tmp = tempfile::tempdir().unwrap();
    let gh = tmp.path().join("gh");
    let reset = now_s() + 900;
    std::fs::write(
        &gh,
        format!(
            "#!/bin/sh\nif [ \"$1\" = api ]; then echo {reset}; exit 0; fi\n\
             echo 'GraphQL: API rate limit exceeded for user ID 1.' >&2\nexit 1\n"
        ),
    )
    .unwrap();
    std::fs::set_permissions(&gh, std::fs::Permissions::from_mode(0o755)).unwrap();
    let ctx = Ctx { dir: tmp.path().to_owned(), gh: gh.into_os_string(), land: None };
    let target = Target { selector: "7".into(), repo: Some("octo/app".into()) };
    let mut shared = Shared::default();
    let deadline = Instant::now() + Duration::from_secs(30);
    poll(&ctx, &target, "octo/app", &mut shared, deadline).unwrap();
    assert_eq!(shared.retry_at, reset + 5);
    assert_eq!(shared.errors, 0, "a rate limit is no failure of the wait");
    assert!(shared.error.as_deref().unwrap_or_default().contains("rate limit"));
}

/// One run of a check as `gh pr view --json statusCheckRollup` gives it: its job in its
/// `detailsUrl`, so a higher job is a newer run.
fn run_of(name: &str, job: u64, status: &str, conclusion: &str) -> Value {
    json!({
        "__typename": "CheckRun", "name": name, "workflowName": "ci", "status": status,
        "conclusion": conclusion, "startedAt": "2026-11-24T15:00:00Z",
        "detailsUrl": format!("https://github.com/octo/app/actions/runs/{job}/job/{job}"),
    })
}

/// manaflow-ai/cmux#54403: "risk evidence" cancelled in run 45437464016 and passed in
/// 45437534352. pr-wait reported it failing; judged by its newest run it is green.
#[test]
fn judge_takes_each_check_by_its_newest_run_and_a_lone_cancel_is_cancelled() {
    let rollup = |newer: Option<Value>| {
        let mut runs = vec![run_of("risk evidence", 45437464016, "COMPLETED", "CANCELLED")];
        runs.extend(newer);
        runs.push(run_of("build", 45437464017, "COMPLETED", "SUCCESS"));
        answer("OPEN", "abc123", Value::Array(runs))
    };
    // Cancelled, then a newer run passed: green.
    let passed = rollup(Some(run_of("risk evidence", 45437534352, "COMPLETED", "SUCCESS")));
    let Some(Outcome::Done { code: 0, structured, .. }) = judge(&passed, Until::Checks, None, 0)
    else {
        panic!("cancelled then pass should be green");
    };
    assert_eq!(structured["failingChecks"], json!([]));
    assert_eq!(structured["cancelledChecks"], json!([]));
    assert_eq!(structured["passedChecks"], 2);
    // The newer run listed first changes nothing: the job id orders them, not the list.
    let mut reversed = passed.clone();
    reversed["statusCheckRollup"].as_array_mut().unwrap().reverse();
    assert_eq!(code(judge(&reversed, Until::Checks, None, 0)), Some(0));
    // Cancelled, then a newer run queued (no start time yet): still pending.
    let mut queued = run_of("risk evidence", 45437534352, "QUEUED", "");
    queued["startedAt"] = json!("0001-01-01T00:00:00Z");
    assert_eq!(code(judge(&rollup(Some(queued)), Until::Checks, None, 0)), None);
    let running = run_of("risk evidence", 45437534352, "IN_PROGRESS", "");
    assert_eq!(code(judge(&rollup(Some(running)), Until::Checks, None, 0)), None);
    // Cancelled with nothing newer: reported as cancelled, in its own list, not as failing.
    let Some(Outcome::Done { code: 1, summary, structured }) =
        judge(&rollup(None), Until::Checks, None, 0)
    else {
        panic!("a lone cancel ends the wait");
    };
    assert_eq!(structured["status"], "cancelled");
    assert_eq!(structured["failingChecks"], json!([]));
    assert_eq!(structured["cancelledChecks"], json!(["risk evidence"]));
    assert!(summary.contains("1 cancelled check with no newer run (risk evidence)"), "{summary}");
    assert!(!summary.contains("failing"), "{summary}");
    // A newer run that failed is failing: a rerun never hides a red.
    let red = rollup(Some(run_of("risk evidence", 45437534352, "COMPLETED", "FAILURE")));
    let Some(Outcome::Done { code: 1, structured, .. }) = judge(&red, Until::Checks, None, 0)
    else {
        panic!("a newer red fails");
    };
    assert_eq!(structured["failingChecks"], json!(["risk evidence"]));
    // An older pass does not hide a newer cancel.
    let old_pass = answer(
        "OPEN",
        "abc123",
        json!([
            run_of("lint", 10, "COMPLETED", "SUCCESS"),
            run_of("lint", 11, "COMPLETED", "CANCELLED"),
        ]),
    );
    assert_eq!(code(judge(&old_pass, Until::Checks, None, 0)), Some(1));
}

/// The REST rollup the machine's poller builds (no detailsUrl): `databaseId` and `startedAt`
/// order the runs, and with neither the list order does.
#[test]
fn newest_runs_orders_by_job_id_then_start_time_then_place() {
    let by_id = json!([
        {"__typename": "CheckRun", "name": "t", "status": "COMPLETED", "conclusion": "CANCELLED", "databaseId": 5},
        {"__typename": "CheckRun", "name": "t", "status": "COMPLETED", "conclusion": "SUCCESS", "databaseId": 9},
    ]);
    let rollup = by_id.as_array().unwrap();
    assert_eq!(pr::newest_runs(rollup), vec![&rollup[1]]);
    let by_place = json!([run_check("COMPLETED", "CANCELLED"), run_check("COMPLETED", "SUCCESS")]);
    let rollup = by_place.as_array().unwrap();
    assert_eq!(pr::newest_runs(rollup), vec![&rollup[1]]);
    // A cancel replaced by a newer same-named run of another workflow (a shared concurrency
    // group, manaflow-ai/cmux#50693) is that run's.
    let twin = json!([
        {"__typename": "CheckRun", "name": "comment", "workflowName": "CI", "status": "COMPLETED", "conclusion": "CANCELLED", "databaseId": 5},
        {"__typename": "CheckRun", "name": "comment", "workflowName": "pr-red-checks", "status": "COMPLETED", "conclusion": "SUCCESS", "databaseId": 9},
    ]);
    let rollup = twin.as_array().unwrap();
    assert_eq!(pr::newest_runs(rollup), vec![&rollup[1]]);
    // Same job name in two workflows: two checks, both judged.
    let two = json!([
        {"__typename": "CheckRun", "name": "build", "workflowName": "a", "status": "COMPLETED", "conclusion": "FAILURE"},
        {"__typename": "CheckRun", "name": "build", "workflowName": "b", "status": "COMPLETED", "conclusion": "SUCCESS"},
    ]);
    assert_eq!(pr::newest_runs(two.as_array().unwrap()).len(), 2);
}

#[test]
fn timeout_takes_seconds_or_a_duration() {
    use super::timeout_secs;
    assert_eq!(timeout_secs("3600"), Ok(3600));
    assert_eq!(timeout_secs("90s"), Ok(90));
    assert_eq!(timeout_secs("45m"), Ok(2700));
    assert_eq!(timeout_secs("2h"), Ok(7200));
    assert_eq!(timeout_secs("1h30m"), Ok(5400));
    assert!(timeout_secs("").is_err());
    assert!(timeout_secs("1x").is_err());
    assert!(timeout_secs("m").is_err());
    assert!(timeout_secs("30m5").is_err());
}

/// A fake land client: `land status` answers ROW_STATE for octo/app#7 at head abc123, and
/// `wait pr` exits WAIT_EXIT. Every call is logged to `calls`.
#[cfg(unix)]
fn fake_land(dir: &Path, row_state: &str, wait_exit: i32) -> (std::ffi::OsString, PathBuf) {
    use std::os::unix::fs::PermissionsExt as _;
    let calls = dir.join("land-calls");
    let land = dir.join("glaeda-gh");
    std::fs::write(
        &land,
        format!(
            "#!/bin/sh\necho \"$*\" >> '{calls}'\n\
             if [ \"$1\" = land ]; then echo '{{\"entries\": [{{\"key\": \"pr:octo/app#7\", \"state\": \"{row_state}\", \"head\": \"abc123def\"}}], \"ok\": true}}'; exit 0; fi\n\
             exit {wait_exit}\n",
            calls = calls.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&land, std::fs::Permissions::from_mode(0o755)).unwrap();
    (land.into_os_string(), calls)
}

#[cfg(unix)]
fn green_gh(dir: &Path) -> (std::ffi::OsString, PathBuf) {
    use std::os::unix::fs::PermissionsExt as _;
    let calls = dir.join("gh-calls");
    let fixture = dir.join("answer.json");
    std::fs::write(
        &fixture,
        answer("OPEN", "abc123def", json!([run_check("COMPLETED", "SUCCESS")])).to_string(),
    )
    .unwrap();
    let gh = dir.join("gh");
    std::fs::write(
        &gh,
        format!("#!/bin/sh\necho \"$*\" >> '{}'\ncat '{}'\n", calls.display(), fixture.display()),
    )
    .unwrap();
    std::fs::set_permissions(&gh, std::fs::Permissions::from_mode(0o755)).unwrap();
    (gh.into_os_string(), calls)
}

fn args(until: Option<Until>) -> PrWaitArgs {
    PrWaitArgs {
        pr: "7".into(),
        repo: Some("octo/app".into()),
        sha: Some("abc123".into()),
        until,
        timeout: 60,
    }
}

/// Goal wakes-per-landed-pr: a wait that ended on green a few minutes before the land queue's
/// merge notice woke the same session twice for one landing. With no --until, a PR the land
/// queue holds is waited on through its row (one wake, the merge or the stop), and no GitHub poll.
#[cfg(unix)]
#[test]
fn a_pr_the_land_queue_holds_is_waited_on_through_its_row_until_merged() {
    let tmp = tempfile::tempdir().unwrap();
    let (gh, gh_calls) = green_gh(tmp.path());
    let (land, land_calls) = fake_land(tmp.path(), "waiting", 0);
    let ctx = Ctx { dir: tmp.path().join("state"), gh, land: Some(land) };
    assert!(wait_blocking(&ctx, &args(None), true).is_ok());
    let made = std::fs::read_to_string(&land_calls).unwrap();
    assert!(made.contains("land status octo/app#7 --json"), "{made}");
    assert!(
        made.contains("wait pr octo/app#7 --until merged --timeout 60 --sha abc123 --json"),
        "{made}"
    );
    assert!(!gh_calls.exists(), "the row's wait polls no GitHub itself");

    // The land stopped: exit 1, said as the land's stop.
    let (land, _) = fake_land(tmp.path(), "judging", 1);
    let ctx = Ctx { dir: tmp.path().join("state"), gh: ctx.gh.clone(), land: Some(land) };
    let err = wait_blocking(&ctx, &args(None), true).unwrap_err();
    assert!(format!("{err:#}").contains("stopped"), "{err:#}");
}

#[cfg(unix)]
#[test]
fn an_ended_row_a_typed_until_or_a_failed_land_wait_keeps_the_checks_wait() {
    for (state, until, wait_exit) in [
        ("merged", None, 0),
        ("stopped", None, 0),
        ("waiting", Some(Until::Checks), 0),
        ("waiting", None, 3),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let (gh, gh_calls) = green_gh(tmp.path());
        let (land, _) = fake_land(tmp.path(), state, wait_exit);
        let ctx = Ctx { dir: tmp.path().join("state"), gh, land: Some(land) };
        assert!(wait_blocking(&ctx, &args(until), true).is_ok(), "{state} {until:?}");
        assert!(gh_calls.exists(), "{state} {until:?}: the checks wait ran");
    }
    // A row pinned to another head is not this wait's.
    let tmp = tempfile::tempdir().unwrap();
    let (land, _) = fake_land(tmp.path(), "waiting", 0);
    let ctx = Ctx { dir: tmp.path().join("state"), gh: "gh".into(), land: Some(land) };
    assert_eq!(land_row(&ctx, "octo/app", "7", Some("fff000")), None);
    assert_eq!(land_row(&ctx, "octo/app", "7", Some("ABC123")).as_deref(), Some("waiting"));
    assert_eq!(land_row(&ctx, "octo/app", "8", None), None);
}
