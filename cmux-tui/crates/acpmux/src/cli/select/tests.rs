use super::*;
use serde_json::json;

#[test]
fn dotted_fields_reach_into_nested_records() {
    let info = json!({"name": "lane", "turn": {"activity": "Bash"}, "pullRequests": [{"number": 7}],
                          "a.b": 1, "tags": {"lane.reportsTo": "x", "area": "acpmux"}});
    assert_eq!(field(&info, "turn.activity"), Some(&json!("Bash")));
    assert_eq!(field(&info, "pullRequests.0.number"), Some(&json!(7)));
    assert_eq!(field(&info, "a.b"), Some(&json!(1)), "a dotted key wins over the path");
    assert_eq!(field(&info, "turn.missing"), None);
    assert_eq!(field(&info, "tags.lane.reportsTo"), Some(&json!("x")), "a dotted tag key");
    assert_eq!(field(&info, "tags.area"), Some(&json!("acpmux")));
    let wide = json!({"名前": {"子": 1}});
    assert_eq!(field(&wide, "名前.子"), Some(&json!(1)), "a dotted path through multibyte keys");
    assert_eq!(field(&wide, "名前."), None);
    let fields = parse_fields("name, turn.activity,nope").unwrap();
    // W5-S, bench round 4 friction 10 (2026-11-08): a selected field the record lacks is
    // null, so every row has every selected key (it was dropped).
    assert_eq!(
        project_fields(&info, &fields),
        json!({"name": "lane", "turn.activity": "Bash", "nope": null})
    );
    let idle = json!({"name": "idle", "turn": {}});
    assert_eq!(
        project_fields(&idle, &fields),
        json!({"name": "idle", "turn.activity": null, "nope": null})
    );
    assert!(parse_fields(" , ").is_err());
}

#[test]
fn tags_match_by_key_or_key_and_value() {
    let s = json!({"tags": {"area": {"value": "acpmux"}, "role": "review"}});
    assert!(tag_matches(&s, "area"));
    assert!(tag_matches(&s, "area=acpmux"));
    assert!(tag_matches(&s, "role=review"));
    assert!(!tag_matches(&s, "area=cloud"));
    assert!(!tag_matches(&s, "task"));
}

#[test]
fn names_match_globs_bare_or_host_qualified_and_ids() {
    let local = json!({"name": "review-27899", "sessionId": "01a1"});
    let peer = json!({"name": "huge-blue/review-27800-b", "peer": "huge-blue", "sessionId": "01b2",
                          "qualifiedSessionId": "huge-blue/01b2"});
    let p = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    assert!(name_matches(&local, &p(&["review-27*"])));
    assert!(name_matches(&peer, &p(&["review-27*"])), "a bare pattern matches on any host");
    assert!(name_matches(&peer, &p(&["huge-blue/*"])));
    assert!(!name_matches(&local, &p(&["huge-blue/*"])));
    let slashed = json!({"name": "huge-blue/notes", "sessionId": "01c3"});
    assert!(!name_matches(&slashed, &p(&["huge-blue/*"])), "a local name with a / is not a peer's");
    assert!(name_matches(&slashed, &p(&["01c3"])));
    assert!(name_matches(&local, &p(&["review-2789?"])));
    assert!(!name_matches(&local, &p(&["review"])), "a glob matches the whole name");
    // Multibyte names and patterns: `?` is one char, and a trailing `*` matches nothing.
    let wide = json!({"name": "レビュー-27", "sessionId": "01d4"});
    assert!(name_matches(&wide, &p(&["レビュー-2?"])));
    assert!(name_matches(&wide, &p(&["レ*"])));
    assert!(name_matches(&wide, &p(&["レビュー-27*"])));
    assert!(!name_matches(&wide, &p(&["レビ"])));
    assert!(name_matches(&local, &p(&["nope", "01a1"])), "an id matches exactly");
    assert!(name_matches(&peer, &p(&["huge-blue/01b2"])), "a peer's host/id matches");
    assert!(!name_matches(&peer, &p(&["other/01b2"])));
    assert!(glob("*", ""));
    assert!(glob("a*b*c", "axxbyyc"));
    assert!(!glob("a*b*c", "axxbyy"));
}
