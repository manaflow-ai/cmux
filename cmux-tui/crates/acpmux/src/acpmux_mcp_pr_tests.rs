use super::*;

const HEAD: &str = "4db9066b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f";
const OLD: &str = "1111111b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f";

fn check(name: &str, status: &str, conclusion: &str) -> Value {
    json!({"__typename": "CheckRun", "name": name, "status": status, "conclusion": conclusion})
}

fn open(rollup: Value, comments: Value) -> Value {
    json!({
        "number": 1609,
        "url": "https://github.com/acme/widgets/pull/1609",
        "state": "OPEN",
        "headRefOid": HEAD,
        "baseRefName": "main",
        "mergeable": "MERGEABLE",
        "mergedAt": null,
        "mergeCommit": null,
        "labels": [],
        "body": "Fixes the widget.",
        "comments": comments,
        "statusCheckRollup": rollup,
    })
}

fn comment(by: &str, body: &str) -> Value {
    json!({"author": {"login": by}, "body": body})
}

#[test]
fn a_merged_pr_says_its_merge_commit() {
    let pr = json!({
        "number": 1557, "url": "https://github.com/acme/widgets/pull/1557", "state": "MERGED",
        "headRefOid": HEAD, "baseRefName": "main", "mergeable": "UNKNOWN",
        "mergedAt": "2026-11-03T07:00:00Z", "mergeCommit": {"oid": "f0175fe0aaaabbbbccccddddeeeeffff00001111"},
        "labels": [], "body": "", "comments": [], "statusCheckRollup": [],
    });
    let (text, s) = pr_state(&pr);
    assert_eq!(text.lines().next().unwrap(), "#1557 merged as f0175fe0");
    assert_eq!(s["summary"], "#1557 merged as f0175fe0");
    assert_eq!(s["status"], "ok");
    assert_eq!(s["state"], "merged");
    assert_eq!(s["repo"], "acme/widgets");
    assert_eq!(s["mergeCommit"], "f0175fe0aaaabbbbccccddddeeeeffff00001111");
}

#[test]
fn an_open_green_pr_is_ok() {
    let pr = open(
        json!([check("build", "COMPLETED", "SUCCESS"), check("lint", "COMPLETED", "SKIPPED")]),
        json!([]),
    );
    let (text, s) = pr_state(&pr);
    assert_eq!(
        text.lines().next().unwrap(),
        "#1609 open at 4db9066b: mergeable, checks green, no review"
    );
    assert_eq!(s["status"], "ok");
    assert_eq!(s["passedChecks"], 2);
    assert!(text.contains(&format!("head {HEAD} -> main")), "{text}");
}

#[test]
fn a_failing_check_fails_and_is_named() {
    let pr = open(
        json!([
            check("build", "COMPLETED", "SUCCESS"),
            check("ws-check", "COMPLETED", "FAILURE"),
            {"__typename": "StatusContext", "context": "ci/legacy", "state": "SUCCESS"},
        ]),
        json!([comment(
            "reviewer",
            &format!("Review (codex model high): SHIP at {HEAD}\nFollow-ups: none")
        )]),
    );
    let (text, s) = pr_state(&pr);
    assert_eq!(
        text.lines().next().unwrap(),
        "#1609 open at 4db9066b: mergeable, 1 failing check (ws-check), SHIP at head"
    );
    assert_eq!(s["status"], "failed");
    assert_eq!(s["failingChecks"], json!(["ws-check"]));
    assert_eq!(s["review"]["atHead"], true);
    assert_eq!(s["review"]["author"], "reviewer");
}

#[test]
fn many_failing_checks_are_cut_in_the_first_line_only() {
    let rollup: Vec<Value> =
        ["a", "b", "c", "d", "e"].iter().map(|n| check(n, "COMPLETED", "FAILURE")).collect();
    let (text, s) = pr_state(&open(json!(rollup), json!([])));
    assert!(
        text.starts_with("#1609 open at 4db9066b: mergeable, 5 failing checks (a, b, c, +2 more)"),
        "{text}"
    );
    assert!(text.contains("checks: 0 passed, 5 failing (a, b, c, d, e), 0 pending"), "{text}");
    assert_eq!(s["failingChecks"].as_array().unwrap().len(), 5);
}

#[test]
fn pending_checks_are_running() {
    let pr = open(
        json!([
            check("build", "IN_PROGRESS", ""),
            check("test", "QUEUED", ""),
            {"__typename": "StatusContext", "context": "deploy", "state": "PENDING"},
            check("lint", "COMPLETED", "SUCCESS"),
        ]),
        json!([]),
    );
    let (text, s) = pr_state(&pr);
    assert!(
        text.starts_with("#1609 open at 4db9066b: mergeable, 3 checks pending, no review"),
        "{text}"
    );
    assert_eq!(s["status"], "running");
    assert_eq!(s["pendingChecks"], 3);
}

#[test]
fn a_ship_at_an_old_head_is_not_at_head() {
    let pr = open(
        json!([check("build", "COMPLETED", "SUCCESS")]),
        json!([comment("r", &format!("**Review (claude opus medium): SHIP at {OLD}**"))]),
    );
    let (text, s) = pr_state(&pr);
    assert!(
        text.starts_with(
            "#1609 open at 4db9066b: mergeable, checks green, SHIP at old head 1111111b"
        ),
        "{text}"
    );
    assert!(text.contains("not at head"), "{text}");
    assert_eq!(s["review"]["atHead"], false);
    assert_eq!(s["status"], "ok");
}

#[test]
fn the_newest_receipt_wins_and_a_block_at_head_fails() {
    let pr = open(
        json!([check("build", "COMPLETED", "SUCCESS")]),
        json!([
            comment("a", &format!("Review (x): SHIP at {OLD}")),
            comment("b", "Looks fine to me."),
            comment("c", &format!("Review (y): BLOCK at {}\n- [blocking] loses data", &HEAD[..12])),
        ]),
    );
    let (text, s) = pr_state(&pr);
    assert!(
        text.starts_with("#1609 open at 4db9066b: mergeable, checks green, BLOCK at head"),
        "{text}"
    );
    assert_eq!(s["status"], "failed");
    assert_eq!(s["review"]["author"], "c");
}

#[test]
fn hold_lines_and_labels_are_listed() {
    let mut pr = open(json!([]), json!([]));
    pr["body"] = json!("Summary\nHOLD: waiting on the schema change\nmore");
    pr["labels"] = json!([{"name": "merge-hold"}, {"name": "threshold"}, {"name": "risk:low"}]);
    pr["mergeable"] = json!("CONFLICTING");
    let (text, s) = pr_state(&pr);
    assert!(
        text.starts_with("#1609 open at 4db9066b: conflicts, no checks, no review, held"),
        "{text}"
    );
    assert_eq!(s["holds"], json!(["HOLD: waiting on the schema change", "label merge-hold"]));
    assert!(text.contains("hold: label merge-hold"), "{text}");
}

#[test]
fn receipt_lines_parse_and_others_do_not() {
    let r = receipt("> Review (codex sol xhigh): SHIP at ABCDEF1234").unwrap();
    assert_eq!((r.verdict, r.sha.as_str()), ("SHIP", "abcdef1234"));
    assert!(receipt("Review (x): SHIP at abc").is_none(), "too short a sha");
    assert!(receipt("I think SHIP at 1234567 is fine").is_none());
    assert!(receipt("Review (x): FIX at 1234567").is_none());
}

#[test]
fn targets_take_numbers_and_urls() {
    assert_eq!(target(&json!({"pr": 12})).unwrap(), Target { selector: "12".into(), repo: None });
    assert_eq!(
        target(&json!({"pr": "#12", "repo": "acme/widgets"})).unwrap(),
        Target { selector: "12".into(), repo: Some("acme/widgets".into()) }
    );
    assert_eq!(
        target(&json!({"pr": "https://github.com/acme/widgets/pull/34/files"})).unwrap(),
        Target { selector: "34".into(), repo: Some("acme/widgets".into()) }
    );
    assert!(target(&json!({})).is_err());
    assert!(target(&json!({"pr": "abc"})).is_err());
    assert!(target(&json!({"pr": 1, "repo": "no-slash"})).is_err());
    assert!(target(&json!({"pr": 1, "repo": "a/b; rm -rf"})).is_err());
    let args = gh_args(&Target { selector: "12".into(), repo: Some("acme/widgets".into()) });
    assert_eq!(&args[..5], ["pr", "view", "12", "-R", "acme/widgets"]);
    assert_eq!(args[5], "--json");
    assert!(args[6].contains("statusCheckRollup"));
}

#[test]
fn the_tool_takes_a_description() {
    let t = tool();
    assert_eq!(t["name"], NAME);
    assert_eq!(t["inputSchema"]["required"], json!(["pr"]));
    assert!(t["inputSchema"]["properties"]["description"].is_object());
}
