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
            let ctx = Ctx { dir: dir.clone(), gh: gh.clone().into_os_string() };
            std::thread::spawn(move || {
                let args = PrWaitArgs {
                    pr: "7".into(),
                    repo: Some("octo/app".into()),
                    sha: Some("abc123".into()),
                    until: Until::Checks,
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
    let ctx = Ctx { dir: tmp.path().to_owned(), gh: gh.into_os_string() };
    let target = Target { selector: "7".into(), repo: Some("octo/app".into()) };
    let mut shared = Shared::default();
    let deadline = Instant::now() + Duration::from_secs(30);
    poll(&ctx, &target, "octo/app", &mut shared, deadline).unwrap();
    assert_eq!(shared.retry_at, reset + 5);
    assert_eq!(shared.errors, 0, "a rate limit is no failure of the wait");
    assert!(shared.error.as_deref().unwrap_or_default().contains("rate limit"));
}
