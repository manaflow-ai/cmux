use serde_json::json;

use super::*;

#[test]
fn a_page_is_one_line_per_entry_with_its_resume_cursor() {
    let page = json!({
        "entries": [{"seq": 4, "kind": "approval"}, {"seq": 5, "kind": "review"}],
        "next": 5,
        "writeErrors": 0,
    });
    let (lines, last, next) = page_lines(&page);
    assert_eq!(lines.len(), 2);
    for line in &lines {
        assert!(!line.contains('\n'));
        serde_json::from_str::<Value>(line).unwrap();
    }
    assert_eq!((last, next), (Some(5), Some(5)));
    let (lines, last, next) = page_lines(&json!({"entries": [], "writeErrors": 0}));
    assert!(lines.is_empty());
    assert_eq!((last, next), (None, None));
}

#[test]
fn the_params_name_the_range_and_verify_only_when_asked() {
    let args =
        ExportArgs { since: Some(10), session_id: Some("s".into()), ..ExportArgs::default() };
    let p = params(&args, Some(7), false);
    assert_eq!(p["since"], 10);
    assert_eq!(p["sessionId"], "s");
    assert_eq!(p["cursor"], 7);
    assert_eq!(p["verify"], false);
    assert_eq!(p["limit"], PAGE);
}

#[test]
fn a_broken_chain_is_named_and_a_whole_one_is_not() {
    assert_eq!(broken(&json!({"verify": {"ok": true, "entries": 3}})), None);
    assert!(broken(&json!({"verify": {"ok": false, "brokenAt": 2}})).unwrap().contains("brokenAt"));
    assert_eq!(broken(&json!({"entries": []})), None);
}
