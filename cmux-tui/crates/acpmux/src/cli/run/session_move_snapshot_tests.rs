use super::*;
use crate::config::{Config, StoreMode};
use crate::hub::Hub;
use tokio::io::{AsyncBufReadExt as _, AsyncWriteExt as _, BufReader};

/// A `_acpmux/peer_snapshot` reply of chat `old` on the dead machine `vm-1`, its records out of
/// order and one twice, as a client could get them.
fn snapshot(cwd: &str) -> Value {
    let rec = |seq: u64, kind: &str, text: &str| {
        json!({"sessionId": "old", "seq": seq, "at": 1000 + seq, "dir": "mux", "kind": kind,
               "msg": {"text": text}})
    };
    json!({
        "peer": "vm-1", "sessionId": "old", "qualifiedSessionId": "vm-1/old",
        "events": [rec(12, "agent_message", "the answer"), rec(11, "user_message", "the question"),
                   rec(12, "agent_message", "the answer"), json!({"not": "a record"})],
        "lastSeq": 12, "generation": 5, "capturedAt": 2000, "hostLastSeq": 12,
        "hasMore": true, "stale": true,
        "summary": {"sessionId": "old", "name": "fix-the-login", "nameGiven": true,
                    "harness": "claude", "cwd": cwd, "status": "idle", "title": "Fix the login",
                    "agentSessionId": "native-1", "turnCount": 1, "createdAt": 5, "stale": true},
    })
}

#[test]
fn a_chat_is_named_by_its_machine_or_by_from() {
    assert_eq!(qualified("vm-1/old", None).unwrap(), "vm-1/old");
    assert_eq!(qualified("old", Some("vm-1")).unwrap(), "vm-1/old");
    assert!(qualified("old", None).is_err(), "a bare chat names no machine to read the copy of");
}

/// The bundle made from the copy is one the target reads: the row's name, harness, folder, title
/// and agent session in its `session.json`, the records once each and in seq order, and a
/// manifest that lists every file at its size.
#[test]
fn the_copy_makes_a_bundle_with_its_transcript_and_name() {
    let b = bundle_from_snapshot(&snapshot("/srv/app"), "new-1", None, 7).unwrap();
    let file = |p: &str| &b.files.iter().find(|(path, _)| path == p).unwrap().1;
    let meta: crate::store::SessionMeta = serde_json::from_slice(file("session.json")).unwrap();
    assert_eq!(meta.id, "new-1");
    assert_eq!(meta.name, "fix-the-login");
    assert!(meta.name_given);
    assert_eq!(meta.harness, "claude");
    assert_eq!(meta.cwd, PathBuf::from("/srv/app"));
    assert_eq!(meta.title.as_deref(), Some("Fix the login"));
    assert_eq!(meta.agent_session_id.as_deref(), Some("native-1"));
    assert_eq!(meta.last_seq, 12);
    let seqs: Vec<u64> = String::from_utf8(file("events/000001.ndjson").clone())
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str::<crate::store::EventRecord>(l).unwrap().seq)
        .collect();
    assert_eq!(seqs, [11, 12]);
    assert_eq!((b.records, b.first_seq, b.whole), (2, Some(11), false));
    assert_eq!(b.manifest["schema"], "acpmux.transfer.v1");
    assert_eq!(b.manifest["sessionId"], "new-1");
    assert_eq!(b.manifest["session"]["harness"], "claude");
    for listed in b.manifest["files"].as_array().unwrap() {
        let bytes = file(listed["path"].as_str().unwrap());
        assert_eq!(listed["size"], bytes.len() as u64, "{listed}");
    }
    // `--cwd` names the folder there outright.
    let b = bundle_from_snapshot(&snapshot("/srv/app"), "new-2", Some("/home/me/app"), 7).unwrap();
    assert_eq!(b.manifest["session"]["cwd"], "/home/me/app");
}

#[test]
fn no_kept_row_is_no_move() {
    // What `_acpmux/peer_snapshot` answers for a chat this machine never kept.
    let none = json!({"events": [], "lastSeq": 0, "summary": null, "stale": true});
    let e = bundle_from_snapshot(&none, "new-1", None, 7).unwrap_err();
    assert!(format!("{e:#}").contains("keeps no row"), "{e:#}");
}

/// The whole path on the receiving side: the bundle made from the copy, paged over a socket into
/// a real hub's `transfer_receive`, `transfer_write` and `transfer_finish`, is a chat there with
/// the copy's name and transcript, under its new id.
#[tokio::test]
async fn a_move_from_the_copy_lands_as_a_chat_with_its_transcript_and_name() {
    let dir = tempfile::tempdir().unwrap();
    let cwd = dir.path().join("app");
    std::fs::create_dir_all(&cwd).unwrap();
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"claude": {"argv": ["true"]}}, "defaultHarness": "claude"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Local;
    let hub = Hub::new(cfg.clone(), crate::store::open(&cfg.store, dir.path()).unwrap());
    let socket = dir.path().join("target.sock");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let served = hub.clone();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (read, mut write) = stream.into_split();
        let mut lines = BufReader::new(read).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            let msg: Value = serde_json::from_str(&line).unwrap();
            let Some(id) = msg.get("id").cloned() else { continue };
            let m = msg["method"].as_str().unwrap_or_default();
            // `Client::connect` says hello first; the transfer steps follow.
            let answer = match m {
                "initialize" => Ok(json!({"protocolVersion": 1})),
                _ => served.transfer_request(m, &msg["params"]).await,
            };
            let reply = match answer {
                Ok(result) => json!({"jsonrpc": "2.0", "id": id, "result": result}),
                Err(e) => json!({"jsonrpc": "2.0", "id": id,
                                 "error": {"code": e.code, "message": e.message}}),
            };
            write.write_all(format!("{reply}\n").as_bytes()).await.unwrap();
        }
    });
    let client = Client::connect(&socket).await.unwrap();
    let cwd_text = cwd.to_string_lossy().into_owned();
    let new_id = uuid::Uuid::now_v7().to_string();
    let bundle = bundle_from_snapshot(&snapshot(&cwd_text), &new_id, None, 7).unwrap();
    let from = json!({"sessionId": "vm-1/old", "snapshot": true});
    let moved = send_bundle(&client, &bundle, from).await.unwrap();
    assert_eq!(moved["sessionId"], new_id.as_str(), "{moved}");
    assert_eq!(moved["name"], "fix-the-login", "{moved}");
    let session = hub.resolve(&new_id).unwrap();
    assert_eq!(session.meta().cwd, cwd);
    let events = hub.events(&new_id, 0, 100).unwrap();
    let texts: Vec<&str> = events.iter().filter_map(|e| e.msg["text"].as_str()).collect();
    assert_eq!(texts, ["the question", "the answer"], "{events:?}");
    let landed = events.iter().find(|e| e.kind == "transferred_in").expect("its own receipt");
    assert_eq!(landed.msg["from"]["sessionId"], "vm-1/old");
    server.abort();
    hub.shutdown_all().await;
}
