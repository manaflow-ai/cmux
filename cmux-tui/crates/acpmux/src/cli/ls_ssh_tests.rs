use super::*;

#[test]
fn only_down_ssh_peers_are_read() {
    let peers = json!([
        {"name": "a", "url": "ssh://a", "state": "reconnecting"},
        {"name": "b", "url": "ssh://me@b:2222", "state": "offline"},
        {"name": "c", "url": "ssh://c", "state": "connected"},
        {"name": "d", "url": "ssh://d", "state": "degraded"},
        {"name": "joined", "url": "ssh://10.0.0.8", "state": "offline", "via": "hub"},
        {"name": "e", "url": "ws://e:1", "state": "offline"},
        {"name": "f", "url": "ssh://-oProxyCommand=x", "state": "offline"},
    ]);
    assert_eq!(
        down_ssh_peers(peers.as_array().unwrap()),
        [("a".to_owned(), "a".to_owned()), ("b".to_owned(), "me@b".to_owned())]
    );
}

#[test]
fn ssh_listing_reads_once_per_destination_and_keeps_aliases_and_users_separate() {
    let peers = json!([
        {"name":"a","url":"ssh://u@host:1"}, {"name":"b","url":"ssh://u@host:2"},
        {"name":"a","url":"ssh://u@host:1"}, {"name":"c","url":"ssh://v@host"},
    ]);
    let groups = destinations(peers.as_array().unwrap());
    assert_eq!(groups.len(), 2);
    assert_eq!(groups["u@host"], ["a".to_owned(), "b".to_owned()].into());
    let socket = Path::new("/daemon/a");
    assert_ne!(cache_path(socket, "u@host"), cache_path(socket, "v@host"));
    assert_ne!(cache_path(socket, "u@host"), cache_path(Path::new("/daemon/b"), "u@host"));
}

#[test]
fn ssh_listing_shares_one_read_across_callers_then_expires_it() {
    use std::sync::Barrier;
    use std::sync::atomic::{AtomicUsize, Ordering};

    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("cache").join("source");
    let deadline = Instant::now() + LS_DEADLINE;
    let readers = Barrier::new(8);
    let reads = AtomicUsize::new(0);
    std::thread::scope(|scope| {
        let tasks: Vec<_> = (0..8)
            .map(|_| {
                scope.spawn(|| {
                    readers.wait();
                    cached_read(&path, deadline, || {
                        reads.fetch_add(1, Ordering::Relaxed);
                        std::thread::sleep(Duration::from_millis(50));
                        Ok(vec![json!({"sessionId":"far"})])
                    })
                })
            })
            .collect();
        for task in tasks {
            assert_eq!(task.join().unwrap().unwrap()[0]["sessionId"], "far");
        }
    });
    assert_eq!(reads.load(Ordering::Relaxed), 1);
    assert!(cached_read(&path, deadline, || panic!("fresh cache")).unwrap()[0]["asOfMs"].is_u64());
    let old = (0_u64, Ok::<_, String>(vec![json!({"sessionId":"expired"})]));
    std::fs::write(&path, serde_json::to_vec(&old).unwrap()).unwrap();
    assert_eq!(cached_read(&path, deadline, || Err("miss".into())), Err("miss".into()));
    assert_eq!(
        cached_read(&path, deadline, || panic!("duplicate failed read")),
        Err("miss".into())
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
