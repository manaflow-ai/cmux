//! The move client's pre-copy against two daemons on local stores behind real Unix sockets.

use super::*;
use crate::config::{Config, HarnessProfile, PermissionPolicy, StoreMode};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// A daemon with the fake agent on a local store in `store`, behind a socket in `socket_dir`, and
/// a client of it with the receiving daemon's own `initialize` reply (as `connect_target` has it).
async fn daemon(store: &Path, socket_dir: &Path, name: &str) -> (Arc<Client>, Value) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let profile = HarnessProfile {
        kind: Default::default(),
        argv: vec!["python3".into(), fake.into()],
        env: BTreeMap::new(),
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let harnesses = BTreeMap::from([("fake".to_owned(), profile)]);
    let mut cfg = Config { harnesses, default_harness: Some("fake".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Local;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    let hub = crate::hub::Hub::new(cfg.clone(), crate::store::open(&cfg.store, store).unwrap());
    let path = socket_dir.join(format!("{name}.sock"));
    let listener = crate::server::bind_unix(&path).await.unwrap();
    tokio::spawn(crate::server::serve_unix(hub, listener));
    let client = Client::connect(&path).await.unwrap();
    let init = json!({"protocolVersion": 1, "clientInfo": {"name": "acpmux-move-test"}});
    let reply = client.request(method::INITIALIZE, init).await.unwrap();
    (client, reply)
}

/// Fresh owner-only store folders for two daemons, whatever the umask.
fn stores(tag: &str) -> (PathBuf, [PathBuf; 2]) {
    let root = std::env::temp_dir().join(format!("acpmux-{tag}-{}", uuid::Uuid::now_v7()));
    let dirs = [root.join("a"), root.join("b")];
    for dir in [&root, &dirs[0], &dirs[1]] {
        use std::os::unix::fs::PermissionsExt as _;
        std::fs::create_dir_all(dir).unwrap();
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    }
    (root, dirs)
}

async fn new_chat(c: &Client, said: &str) -> String {
    let s = c
        .request(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": []}))
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    say(c, &id, said).await;
    id
}

async fn say(c: &Client, id: &str, text: &str) {
    let p = json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});
    c.request(method::SESSION_PROMPT, p).await.unwrap();
}

async fn said(c: &Client, id: &str) -> Vec<String> {
    let kinds = json!({"sessionId": id, "afterSeq": 0, "kinds": ["user_message"]});
    let page = c.request(method::MUX_EVENTS, kinds).await.unwrap();
    let events = page["events"].as_array().cloned().unwrap_or_default();
    events.iter().map(|e| e["msg"]["text"].as_str().unwrap_or_default().to_owned()).collect()
}

/// The stage folder `in-<stageId>` on the target.
fn stage_dir(staged: &Staged) -> PathBuf {
    crate::config::home().join("transfers").join(format!("in-{}", staged.stage_id))
}

/// A target that lost its stage between the stage and the freeze (swept, or its daemon restarted)
/// refuses the pre-copied bundle `transfer.unstaged`; the move is made again in full, once, and
/// the chat arrives whole (review of cmux#48630, F1: `session move` returned the refusal).
#[tokio::test]
async fn a_move_whose_stage_is_gone_is_made_again_in_full() {
    let (root, [a, b]) = stores("unstaged");
    let sockets = cmux_unix_socket::short_test_dir("acpmux-unstaged");
    let (src, _) = daemon(&a, sockets.path(), "a").await;
    let (dst, dst_init) = daemon(&b, sockets.path(), "b").await;
    let id = new_chat(&src, "hi").await;
    let staged = precopy(&src, &dst, &dst_init, &id).await.expect("both daemons pre-copy");
    say(&src, &id, "more").await;
    crate::home_fs::remove_dir_all(stage_dir(&staged)).unwrap();

    let begun = begin_staged(&src, &id, None, false, Some(&staged)).await.unwrap();
    assert!(begun.stage_id.is_some(), "the begin took the prefix: {}", begun.begin);
    let to = json!({"socket": "test"});
    let moved = finish_staged(&src, &dst, &dst_init, &id, begun, None, false, None, None, to).await;
    let moved = moved.expect("the move is made again in full");
    assert_eq!(moved["sessionId"], id, "{moved}");
    assert_eq!(said(&dst, &id).await, ["hi", "more"], "the whole history arrived");
    let info = src.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert_eq!(info["moving"], false, "{info}");
    let _ = std::fs::remove_dir_all(root);
}

/// Under umask 002 (a lane VM's) the stage still builds its staged kind index: the folders a
/// store refuses when group-writable are made owner-only (`transfer_precopy.rs` `private_stage`).
/// The umask is the process's, so the stage runs in a child process of this test binary that
/// runs this test alone, in its own acpmux home.
#[test]
fn a_stage_builds_its_staged_index_under_a_group_writable_umask() {
    const CHILD: &str = "ACPMUX_TEST_STAGE_UMASK_CHILD";
    let name =
        "cli::run::transfer::tests::a_stage_builds_its_staged_index_under_a_group_writable_umask";
    if std::env::var_os(CHILD).is_none() {
        let (root, _) = stores("stage-umask");
        let home = root.join("home");
        std::fs::create_dir_all(&home).unwrap();
        use std::os::unix::fs::PermissionsExt as _;
        std::fs::set_permissions(&home, std::fs::Permissions::from_mode(0o700)).unwrap();
        let out = std::process::Command::new(std::env::current_exe().unwrap())
            .args([name, "--exact", "--nocapture", "--test-threads=1"])
            .env(CHILD, &root)
            .env("ACPMUX_HOME", &home)
            .stdin(std::process::Stdio::null())
            .output()
            .unwrap();
        let _ = std::fs::remove_dir_all(&root);
        let text = String::from_utf8_lossy(&out.stdout);
        let err = String::from_utf8_lossy(&out.stderr);
        assert!(out.status.success() && text.contains("1 passed"), "{text}\n{err}");
        return;
    }
    let root = PathBuf::from(std::env::var_os(CHILD).unwrap());
    // SAFETY: umask has no preconditions; this process runs this test only.
    unsafe { libc::umask(0o002) };
    let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap();
    runtime.block_on(async {
        let sockets = cmux_unix_socket::short_test_dir("acpmux-umask");
        let (src, _) = daemon(&root.join("a"), sockets.path(), "a").await;
        let (dst, dst_init) = daemon(&root.join("b"), sockets.path(), "b").await;
        let id = new_chat(&src, "hi").await;
        let staged = precopy(&src, &dst, &dst_init, &id).await.expect("both daemons pre-copy");
        let chat = stage_dir(&staged).join("store").join(&id);
        assert!(chat.join("events").join("000000.ndjson").is_file(), "the staged segment");
        let index = chat.join(crate::store::KIND_INDEX_DIR).join("000000.ndjson");
        assert!(index.is_file(), "the staged segment's kind index: {}", index.display());
    });
}
