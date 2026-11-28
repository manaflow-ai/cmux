use super::*;

#[test]
fn nothing_named_in_a_session_asks_for_that_session_not_the_shells_folder() {
    let args = WhoElseArgs::default();
    let p = params(&args, std::path::Path::new("/w"), Some("s1".into())).unwrap();
    assert_eq!(p, json!({"sessionId": "s1"}));
    let files = WhoElseArgs { files: vec!["a.rs".into()], local: true, ..Default::default() };
    let p = params(&files, std::path::Path::new("/w"), Some("s1".into())).unwrap();
    assert_eq!(p, json!({"cwd": "/w", "files": ["a.rs"], "sessionId": "s1", "peers": false}));
    let p = params(&args, std::path::Path::new("/w"), None).unwrap();
    assert_eq!(p, json!({"cwd": "/w"}));
}

#[test]
fn since_reads_minutes_hours_and_days() {
    assert_eq!(duration_ms("30m").unwrap(), 30 * 60_000);
    assert_eq!(duration_ms("2d").unwrap(), 2 * 86_400_000);
    assert!(duration_ms("soon").is_err());
}

#[test]
fn a_since_too_long_to_count_is_refused_not_wrapped() {
    assert!(duration_ms("999999999999999999d").is_err());
    assert!(duration_ms("18446744073709551615").is_err());
}

#[test]
fn an_empty_answer_says_so_and_names_unreached_peers() {
    let a = json!({"sessions": [], "unreached": [{"host": "my-vm", "error": "no answer in 5 s"}]});
    assert_eq!(
        text(&a),
        "No other session works on these.\n(not asked: my-vm: no answer in 5 s)\n"
    );
}
