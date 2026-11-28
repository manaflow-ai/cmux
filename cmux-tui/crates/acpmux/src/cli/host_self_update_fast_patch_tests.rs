use super::*;

fn up(outcome: Outcome, error: Option<&str>) -> PeerUpdate {
    let mut up = PeerUpdate::new();
    up.outcome = outcome;
    up.error = error.map(str::to_owned);
    up
}

#[test]
fn outcomes_map_to_the_fast_patch_contract() {
    assert_eq!(outcome(&up(Outcome::Updated, None)), "live");
    assert_eq!(outcome(&up(Outcome::Current, None)), "current");
    assert_eq!(outcome(&up(Outcome::RolledBack, Some("noAnswer"))), "rolled-back");
    let worse = "it did not answer; the rollback failed too: no previous binary";
    assert_eq!(outcome(&up(Outcome::Failed, Some(worse))), "rollback-unhealthy");
    assert_eq!(outcome(&up(Outcome::Failed, Some("pushFailed"))), "refused");
    assert_eq!(outcome(&up(Outcome::Busy, None)), "refused");
    assert_eq!(outcome(&up(Outcome::Held, None)), "refused");
}

#[test]
fn a_run_asking_another_commit_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let mut run = Run::start(Some("abcdef1".into()), &dir.path().join("none"));
    assert!(run.check_commit("abcdef1234567890abcdef1234567890abcdef12").is_ok());
    assert!(run.check_commit("1234567890abcdef1234567890abcdef12345678").is_err());
    let mut any = Run::start(None, &dir.path().join("none"));
    assert!(any.check_commit("1234567890abcdef1234567890abcdef12345678").is_ok());
}

#[test]
fn a_run_appends_one_line_in_the_shared_shape() {
    let dir = tempfile::tempdir().unwrap();
    for outcome in ["live", "rolled-back"] {
        let mut run = Run::start(None, &dir.path().join("none"));
        run.state = dir.path().join("state");
        run.check_commit("abcdef1234567890abcdef1234567890abcdef12").unwrap();
        run.finish(outcome, "updated");
    }
    let text = std::fs::read_to_string(dir.path().join("state").join(RUNS)).unwrap();
    let lines: Vec<Value> = text.lines().map(|l| serde_json::from_str(l).unwrap()).collect();
    assert_eq!(lines.len(), 2);
    assert_eq!(lines[0]["service"], SERVICE);
    assert_eq!(lines[0]["outcome"], "live");
    assert_eq!(lines[1]["outcome"], "rolled-back");
    assert_eq!(lines[0]["commit"], "abcdef1234567890abcdef1234567890abcdef12");
    assert!(lines[0]["seconds"].is_number());
    assert!(lines[0]["at"].as_str().unwrap().ends_with('Z'));
    for key in ["host", "repo", "prev", "detail"] {
        assert!(lines[0].get(key).is_some(), "{key}");
    }
}
