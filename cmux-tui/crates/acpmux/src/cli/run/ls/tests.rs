use super::*;
use serde_json::json;

fn rows() -> Vec<Value> {
    vec![
        json!({"name": "hb/old", "peer": "hb", "status": "closed"}),
        json!({"name": "claude-sr2/mac-ci-3", "status": "running"}),
        json!({"name": "hb/review-1", "peer": "hb", "status": "ready"}),
        json!({"name": "done", "status": "closed"}),
        json!({"name": "idle-one", "status": "idle"}),
    ]
}

fn kept(filter: &RowFilter) -> Vec<String> {
    rows().iter().filter(|r| filter.keeps(r)).map(|r| r["name"].as_str().unwrap().into()).collect()
}

#[test]
fn projected_listings_only_refresh_usage_when_they_show_it() {
    let plain = vec!["sessionId".to_owned(), "name".to_owned(), "status".to_owned()];
    assert!(!shows_usage(false, true, Some(&plain)));
    assert!(!shows_usage(true, false, Some(&plain)));
    assert!(shows_usage(false, false, Some(&["usageStats.cost".to_owned()])));
    assert!(shows_usage(false, true, None));
    assert!(shows_usage(true, false, None));
    assert!(!shows_usage(false, false, None));
}

#[test]
fn ls_selection_parses_duration_and_projects_fields() {
    assert_eq!(parse_duration_ms("1h30m").unwrap(), 5_400_000);
    assert!(parse_duration_ms("oops").is_err());
    let fields = parse_fields("name, status").unwrap();
    assert_eq!(fields, ["name", "status"]);
    assert_eq!(
        project_fields(&json!({"name": "one", "status": "idle", "cwd": "/tmp"}), &fields),
        json!({"name": "one", "status": "idle"})
    );
}

#[test]
fn live_and_host_filter_the_rows() {
    let own = || "this-mac".to_owned();
    let live = RowFilter::new(true, None, own()).unwrap();
    assert_eq!(kept(&live), ["claude-sr2/mac-ci-3", "hb/review-1", "idle-one"]);
    let peer = RowFilter::new(true, Some("HB"), own()).unwrap();
    assert_eq!(kept(&peer), ["hb/review-1"]);
    let here = RowFilter::new(false, Some("this-mac"), own()).unwrap();
    assert_eq!(kept(&here), ["claude-sr2/mac-ci-3", "done", "idle-one"]);
    let local = RowFilter::new(false, Some("local"), own()).unwrap();
    assert_eq!(kept(&local), kept(&here));
    assert!(!RowFilter::new(false, None, own()).unwrap().narrows());
    assert!(live.narrows() && peer.narrows());
}
