use super::*;
use std::time::{Duration, SystemTime};

const P: &str = "'/x/acpmux' 'ci-log-cache' '--'";

fn w(s: &str) -> Vec<String> {
    s.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn a_log_read_is_prefixed_and_the_rest_of_the_call_kept() {
    let c =
        "gh run view 45905874375 -R manaflow-ai/cmux --log-failed 2>&1 | grep -E 'FAIL|x' | head";
    assert_eq!(rewrite(c, P).unwrap(), format!("{P} {c}"));
    let c = "cd /a && gh run view 1 --repo o/r --log | tail; gh run view 2 -R o/r --log";
    assert_eq!(
        rewrite(c, P).unwrap(),
        format!(
            "cd /a && {P} gh run view 1 --repo o/r --log | tail; {P} gh run view 2 -R o/r --log"
        )
    );
    let c = "timeout 120 gh run view 1 -R o/r --log-failed";
    assert_eq!(
        rewrite(c, P).unwrap(),
        format!("timeout 120 {P} gh run view 1 -R o/r --log-failed")
    );
}

#[test]
fn anything_but_a_log_read_at_a_command_start_is_left_alone() {
    // No log asked for.
    assert_eq!(rewrite("gh run view 1 -R o/r --json jobs", P), None);
    // Inside quotes, or an argument of another program.
    assert_eq!(rewrite("echo 'gh run view 1 -R o/r --log'", P), None);
    assert_eq!(rewrite("bash -c \"gh run view 1 -R o/r --log\"", P), None);
    assert_eq!(rewrite("xargs gh run view 1 -R o/r --log", P), None);
    // The flag belongs to the next command, not this one.
    assert_eq!(rewrite("gh run view 1 -R o/r | grep --log", P), None);
    // Already rewritten.
    assert_eq!(rewrite(&format!("{P} gh run view 1 -R o/r --log"), P), None);
}

#[test]
fn only_a_named_run_or_job_in_a_plain_repo_with_known_flags_is_asked() {
    let a = ask_of(&w("run view 7 -R o/r --log-failed"), None).unwrap();
    assert_eq!(a, Ask { repo: "o/r".into(), of: LogOf::Run(7), attempt: None, failed_only: true });
    let a = ask_of(&w("run view --job=9 --log"), Some("o/r")).unwrap();
    assert_eq!((a.of, a.failed_only, a.repo.as_str()), (LogOf::Job(9), false, "o/r"));
    let a = ask_of(&w("run view 7 --repo o/r --attempt 2 --log"), None).unwrap();
    assert_eq!(a.attempt, Some(2));
    for no in [
        "run view 7 --log",                   // no repo
        "run view 7 -R o/r",                  // no log
        "run view 7 -R o/r --log --verbose",  // unknown flag
        "run view -R o/r --log",              // no run or job
        "run view 7 -R github.com/o/r --log", // not OWNER/REPO
        "run view abc -R o/r --log",          // not a run id
        "run list -R o/r --log",
    ] {
        assert_eq!(ask_of(&w(no), None), None, "{no}");
    }
}

#[test]
fn a_run_key_carries_its_attempt_and_a_job_key_its_id() {
    let run = ask_of(&w("run view 7 -R o/r --log-failed"), None).unwrap();
    assert_ne!(run.key(Some(1)), run.key(Some(2)), "a rerun is another log");
    assert_ne!(
        run.key(Some(1)),
        ask_of(&w("run view 7 -R o/r --log"), None).unwrap().key(Some(1)),
        "a full log is not the failed steps'"
    );
    let pinned = ask_of(&w("run view 7 -R o/r --attempt 3 --log-failed"), None).unwrap();
    assert_eq!(pinned.key(Some(5)), run.key(Some(3)), "an asked attempt wins");
    let job = ask_of(&w("run view --job 9 -R o/r --log"), None).unwrap();
    assert_eq!(job.key(Some(4)), job.key(None));
}

/// A stand-in `gh`: `api` prints `$dir/status.json`; `run view` counts itself in `$dir/runs`,
/// prints `$dir/log` and exits with `$dir/code` (0 when missing).
#[cfg(unix)]
fn fake_gh(dir: &Path) -> String {
    use std::os::unix::fs::PermissionsExt;
    let bin = dir.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let gh = bin.join("gh");
    let d = dir.display();
    std::fs::write(
        &gh,
        format!(
            "#!/bin/sh\nif [ \"$1\" = api ]; then cat '{d}/status.json'; exit 0; fi\n\
             echo x >> '{d}/runs'\ncat '{d}/log'\nexit $(cat '{d}/code' 2>/dev/null || echo 0)\n"
        ),
    )
    .unwrap();
    std::fs::set_permissions(&gh, std::fs::Permissions::from_mode(0o755)).unwrap();
    gh.display().to_string()
}

#[cfg(unix)]
fn runs(dir: &Path) -> usize {
    std::fs::read_to_string(dir.join("runs")).map(|s| s.lines().count()).unwrap_or(0)
}

#[cfg(unix)]
#[test]
fn a_finished_log_is_fetched_once_and_then_served() {
    let tmp = tempfile::tempdir().unwrap();
    let (d, cache) = (tmp.path(), tmp.path().join("cache"));
    let gh = fake_gh(d);
    std::fs::write(d.join("log"), "job\tstep\tFAIL boom\n").unwrap();
    std::fs::write(d.join("status.json"), r#"{"status":"completed","run_attempt":1}"#).unwrap();
    let mut call = vec![gh];
    call.extend(w("run view 7 -R o/r --log-failed"));
    assert_eq!(run_in(&call, &cache, None), 0);
    assert_eq!(runs(d), 1);
    let ask = ask_of(&call[1..], None).unwrap();
    let kept = path_for(&cache, &ask.key(Some(1)));
    assert_eq!(std::fs::read_to_string(&kept).unwrap(), "job\tstep\tFAIL boom\n");
    assert_eq!(run_in(&call, &cache, None), 0);
    assert_eq!(runs(d), 1, "the second read is served from the cache");

    // A rerun is a new attempt: fetched again, kept apart.
    std::fs::write(d.join("status.json"), r#"{"status":"completed","run_attempt":2}"#).unwrap();
    assert_eq!(run_in(&call, &cache, None), 0);
    assert_eq!(runs(d), 2);
    assert!(path_for(&cache, &ask.key(Some(2))).exists());
}

#[cfg(unix)]
#[test]
fn a_run_in_progress_or_a_failed_fetch_is_never_kept() {
    let tmp = tempfile::tempdir().unwrap();
    let (d, cache) = (tmp.path(), tmp.path().join("cache"));
    let gh = fake_gh(d);
    std::fs::write(d.join("log"), "partial\n").unwrap();
    std::fs::write(d.join("status.json"), r#"{"status":"in_progress","run_attempt":1}"#).unwrap();
    let mut call = vec![gh];
    call.extend(w("run view 7 -R o/r --log"));
    assert_eq!(run_in(&call, &cache, None), 0);
    assert_eq!(run_in(&call, &cache, None), 0);
    assert_eq!(runs(d), 2, "in progress: every call runs");
    assert!(!cache.exists() || std::fs::read_dir(&cache).unwrap().next().is_none());

    std::fs::write(d.join("status.json"), r#"{"status":"completed","run_attempt":1}"#).unwrap();
    std::fs::write(d.join("code"), "1").unwrap();
    assert_eq!(run_in(&call, &cache, None), 1, "gh's own exit code");
    let left: Vec<_> = std::fs::read_dir(&cache).unwrap().flatten().collect();
    assert!(left.is_empty(), "no log and no temp file kept: {left:?}");
}

#[cfg(unix)]
#[test]
fn a_cache_stays_in_the_held_home_after_replacement() {
    crate::lost_home_race_tests::isolated(
        module_path!(),
        "a_cache_stays_in_the_held_home_after_replacement",
        |home| {
            let tmp = tempfile::tempdir().unwrap();
            let d = tmp.path();
            let cache = home.join(".cache/acpmux/ci-logs");
            let gh = fake_gh(d);
            std::fs::write(d.join("log"), "first\n").unwrap();
            std::fs::write(d.join("status.json"), r#"{"status":"completed","run_attempt":1}"#)
                .unwrap();
            let mut call = vec![gh];
            call.extend(w("run view 7 -R o/r --log"));
            assert_eq!(run_in(&call, &cache, None), 0);
            let ask = ask_of(&call[1..], None).unwrap();
            let first = path_for(&cache, &ask.key(Some(1)));
            assert!(first.exists());

            crate::config::hold_home();
            crate::lost_home_race_tests::replace(home);
            std::fs::write(d.join("log"), "second\n").unwrap();
            std::fs::write(d.join("status.json"), r#"{"status":"completed","run_attempt":2}"#)
                .unwrap();

            assert_eq!(run_in(&call, &cache, None), 0);
            assert_eq!(runs(d), 2);
            assert!(home.with_extension("old").join(first.strip_prefix(home).unwrap()).exists());
            assert!(
                home.with_extension("old")
                    .join(path_for(&cache, &ask.key(Some(2))).strip_prefix(home).unwrap())
                    .exists()
            );
            assert!(!cache.exists(), "the replacement home stays untouched");
        },
        |_, _| {},
    );
}

#[test]
fn eviction_drops_the_old_and_the_oldest_past_the_size_bound() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    let now = SystemTime::now();
    let put = |name: &str, len: usize, age_s: u64| {
        let p = dir.join(name);
        std::fs::write(&p, vec![b'x'; len]).unwrap();
        let f = std::fs::File::options().write(true).open(&p).unwrap();
        f.set_modified(now - Duration::from_secs(age_s)).unwrap();
    };
    put("old.log", 1, 10_000);
    put("a.log", 10, 1);
    put("b.log", 10, 2);
    put("c.log", 10, 3);
    put(".tmp-stale", 1, 7200);
    put(".tmp-live", 1, 1);
    put("other", 1, 10_000);
    evict(dir, now, Duration::from_secs(5000), 20);
    let mut left: Vec<String> = std::fs::read_dir(dir)
        .unwrap()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    left.sort();
    assert_eq!(left, [".tmp-live", "a.log", "b.log", "other"]);
}

#[test]
fn off_unless_switched_on() {
    let on = serde_json::json!({"agents": {"harnessMagic": {"sharedCache": {"enabled": true}}}});
    assert!(!enabled_with(None, None));
    assert!(enabled_with(Some(&on), None));
    assert!(!enabled_with(Some(&on), Some("0")));
    assert!(enabled_with(None, Some("1")));
    // The harness-magic seam names the switch from the feature (`hub/harness_magic.rs`).
    assert_eq!(KILL_ENV, "ACPMUX_HM_SHAREDCACHE");
}
