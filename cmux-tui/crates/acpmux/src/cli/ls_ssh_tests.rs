use super::*;

#[test]
fn only_down_ssh_peers_are_read() {
    let peers = json!([
        {"name": "a", "url": "ssh://a", "state": "reconnecting"},
        {"name": "b", "url": "ssh://me@b:2222", "state": "offline"},
        {"name": "c", "url": "ssh://c", "state": "connected"},
        {"name": "d", "url": "ssh://d", "state": "degraded"},
        {"name": "e", "url": "ws://e:1", "state": "offline"},
        {"name": "f", "url": "ssh://-oProxyCommand=x", "state": "offline"},
    ]);
    assert_eq!(
        down_ssh_peers(peers.as_array().unwrap()),
        [("a".to_owned(), "a".to_owned()), ("b".to_owned(), "me@b".to_owned())]
    );
}

#[test]
fn a_far_row_is_named_on_its_host_and_replaces_the_stale_ones() {
    let far = parse(br#"{"sessions": [{"sessionId": "s1", "name": "lane"}, {"name": "no id"}]}"#)
        .unwrap();
    let far: Vec<Value> = far.into_iter().map(|r| tag("box", r)).collect();
    assert_eq!(far.len(), 1);
    assert_eq!(
        (&far[0]["peer"], &far[0]["name"], &far[0]["via"]),
        (&json!("box"), &json!("box/lane"), &json!("ssh"))
    );
    let mut rows = vec![
        json!({"sessionId": "here", "name": "mine"}),
        json!({"sessionId": "old", "name": "box/stale", "peer": "box"}),
        json!({"sessionId": "o", "name": "other/x", "peer": "other"}),
    ];
    assert_eq!(replace_rows(&mut rows, &["box".to_owned()], far), 1);
    let ids: Vec<&str> = rows.iter().filter_map(|r| r["sessionId"].as_str()).collect();
    assert_eq!(ids, ["here", "o", "s1"]);
    assert!(parse(b"nope").is_err());
}
