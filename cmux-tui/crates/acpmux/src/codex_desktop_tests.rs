use super::*;
use std::sync::{Arc, Mutex};

const T1: &str = "01a1bf30-e092-7232-aca1-16444234c40f";
const T2: &str = "01a1bf2f-23da-7010-9b8c-6c20c052be11";

#[test]
fn a_send_is_the_thread_whose_codex_started_a_process_of_its_tree() {
    // acpmux (50) < bash (45) < codex-linux-sandbox (44, thread env) < codex app-server (40).
    let env = |pid: u32| match pid {
        50 | 45 | 44 => Some(T1.to_owned()),
        _ => None,
    };
    let codex = |pid: u32| pid == 40;
    assert_eq!(thread_in(&[50, 45, 44, 40, 1], env, codex).as_deref(), Some(T1));
    // A process tree no Codex started: nothing, though a process names a thread itself.
    assert_eq!(thread_in(&[50, 45, 7, 1], env, |_| false), None);
    // Unreadable processes in between (a sandbox's) are passed.
    let sandboxed = |pid: u32| (pid == 44).then(|| T1.to_owned());
    assert_eq!(thread_in(&[50, 45, 44, 40], sandboxed, codex).as_deref(), Some(T1));
}

#[test]
fn a_thread_named_by_a_process_of_another_thread_is_not_taken() {
    // Thread T2's shell (45) runs `env CODEX_THREAD_ID=T1 acpmux send` (50): its parent is no
    // Codex, so the send is T2's, the thread whose Codex started 44.
    let env = |pid: u32| match pid {
        50 => Some(T1.to_owned()),
        45 | 44 => Some(T2.to_owned()),
        _ => None,
    };
    assert_eq!(thread_in(&[50, 45, 44, 40], env, |pid| pid == 40).as_deref(), Some(T2));
    // A copy of a process named like Codex that names the thread itself is not the thread's Codex.
    let inherited = |pid: u32| (pid != 1).then(|| T1.to_owned());
    assert_eq!(thread_in(&[50, 40, 1], inherited, |pid| pid == 40), None);
}

#[test]
fn codex_binaries_are_known_by_name() {
    assert!(is_codex_binary("codex"));
    assert!(is_codex_binary("codex-aarch64-apple-darwin"));
    assert!(!is_codex_binary("codex-linux-sandbox"));
    assert!(!is_codex_binary("bash"));
    assert!(is_thread_id(T1));
    assert!(!is_thread_id(".coordination"));
    assert!(!is_thread_id("../x"));
}

#[test]
fn an_answer_is_found_among_notifications_and_server_requests() {
    let note = json!({"method": "thread/queue/changed", "params": {}});
    assert_eq!(answer_to(2, &note), None);
    let request = json!({"id": 2, "method": "item/tool/requestUserInput", "params": {}});
    assert_eq!(answer_to(2, &request), None, "a request of the server's is no answer");
    assert_eq!(answer_to(2, &json!({"id": 1, "result": {}})), None);
    assert_eq!(answer_to(2, &json!({"id": 2, "result": {"x": 1}})), Some(Ok(json!({"x": 1}))));
    let err = json!({"id": 2, "error": {"code": -32600, "message": "thread not found"}});
    assert_eq!(answer_to(2, &err), Some(Err("thread not found".to_owned())));
}

#[test]
fn the_queue_call_is_codex_queues() {
    let add = queue_add(2, T1, "hi", "u-1");
    assert_eq!(add["method"], "thread/queue/add");
    assert_eq!(add["params"]["threadId"], T1);
    assert_eq!(add["params"]["clientUserMessageId"], "u-1");
    assert_eq!(add["params"]["input"][0], json!({"type": "text", "text": "hi", "text_elements": []}));
    assert_eq!(initialize(1)["params"]["capabilities"]["experimentalApi"], true);
}

/// A Codex home in a short path (the control socket must fit a socket address).
pub(crate) fn home() -> tempfile::TempDir {
    tempfile::tempdir_in("/tmp").unwrap()
}

/// Writes `state_5.sqlite` with `rows` of `(id, originator, cwd, archived)`.
pub(crate) fn state_db(home: &Path, rows: &[(&str, &str, &str, bool)]) {
    let conn = rusqlite::Connection::open(home.join("state_5.sqlite")).unwrap();
    conn.execute_batch(
        "CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT NOT NULL, title TEXT NOT NULL,
            archived INTEGER NOT NULL DEFAULT 0, cli_version TEXT NOT NULL DEFAULT '',
            name TEXT, originator TEXT);",
    )
    .unwrap();
    for (id, originator, cwd, archived) in rows {
        conn.execute(
            "INSERT INTO threads VALUES (?1, ?2, 'title', ?3, '0.164.0', NULL, ?4)",
            rusqlite::params![id, cwd, *archived as i64, originator],
        )
        .unwrap();
    }
}

/// Holds thread `id`'s writer lock, as a running Codex does, until the file is dropped.
#[cfg(unix)]
pub(crate) fn hold(home: &Path, id: &str) -> std::fs::File {
    use std::os::fd::AsRawFd;
    std::fs::create_dir_all(lock_dir(home)).unwrap();
    let file = std::fs::File::create(lock_dir(home).join(format!("{id}.lock"))).unwrap();
    // SAFETY: flock on the descriptor just opened.
    assert_eq!(unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) }, 0);
    file
}

#[cfg(unix)]
#[test]
fn live_threads_are_the_held_ones_a_listed_client_started() {
    let dir = home();
    let home = dir.path();
    state_db(
        home,
        &[
            (T1, "codex_desktop", "/w/cmux", false),
            (T2, "codex_desktop", "/w", false),
            ("01a1bf2f-0000-7000-8000-000000000003", "codex_exec", "/w", false),
            ("01a1bf2f-0000-7000-8000-000000000004", "codex_desktop", "/w", true),
        ],
    );
    let _t1 = hold(home, T1);
    let _t3 = hold(home, "01a1bf2f-0000-7000-8000-000000000003");
    let _t4 = hold(home, "01a1bf2f-0000-7000-8000-000000000004");
    // T2's lock file stays after its Codex ended: not held, not live.
    std::fs::File::create(lock_dir(home).join(format!("{T2}.lock"))).unwrap();
    let listed = vec![DESKTOP_ORIGINATOR.to_owned()];
    let live = live(home, &listed);
    assert_eq!(live.iter().map(|t| t.id.as_str()).collect::<Vec<_>>(), vec![T1]);
    assert_eq!(live[0].cwd.as_deref(), Some(Path::new("/w/cmux")));
    assert_eq!(live[0].version.as_deref(), Some("0.164.0"));
    assert!(find(home, T1, &listed).is_some());
    assert!(find(home, T2, &listed).is_none(), "no running Codex holds it");
    // A setting that does not list the desktop app lists none of its threads.
    assert!(live(home, &["claude-desktop".to_owned()]).is_empty());
    assert!(find(home, T1, &["claude-desktop".to_owned()]).is_none());
}

/// A stand-in for the Codex app-server daemon on `home`'s control socket: it answers
/// `initialize` and `thread/queue/add` (after a notification each), keeps every queued
/// call's params, and hands each to `on_add`.
#[cfg(unix)]
pub(crate) fn fake_daemon(
    home: &Path,
    on_add: impl Fn(&Value) + Send + Sync + 'static,
) -> Arc<Mutex<Vec<Value>>> {
    use futures_util::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::Message;
    let socket = control_socket(home);
    std::fs::create_dir_all(socket.parent().unwrap()).unwrap();
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let added = Arc::new(Mutex::new(Vec::new()));
    let kept = added.clone();
    let on_add = Arc::new(on_add);
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            let (kept, on_add) = (kept.clone(), on_add.clone());
            tokio::spawn(async move {
                let mut ws = tokio_tungstenite::accept_async(stream).await.unwrap();
                while let Some(Ok(Message::Text(text))) = ws.next().await {
                    let msg: Value = serde_json::from_str(text.as_str()).unwrap();
                    let result = match msg["method"].as_str() {
                        Some("initialize") => json!({"userAgent": "fake"}),
                        Some("thread/queue/add") => {
                            kept.lock().unwrap().push(msg["params"].clone());
                            on_add(&msg["params"]);
                            json!({"queuedSubmission": {"id": "q-1", "input": msg["params"]["input"]}})
                        }
                        _ => continue,
                    };
                    let note = json!({"method": "thread/queue/changed", "params": {"threadId": "x"}});
                    let answer = json!({"id": msg["id"], "result": result});
                    for out in [note, answer] {
                        ws.send(Message::Text(out.to_string().into())).await.unwrap();
                    }
                }
            });
        }
    });
    added
}

#[cfg(unix)]
#[tokio::test]
async fn a_message_is_queued_through_the_daemons_control_socket() {
    let dir = home();
    let added = fake_daemon(dir.path(), |_| {});
    let queued = deliver(dir.path(), T1, "ping", "u-7").await.unwrap();
    assert_eq!(queued, "q-1");
    let added = added.lock().unwrap().clone();
    assert_eq!(added.len(), 1);
    assert_eq!(added[0]["threadId"], T1);
    assert_eq!(added[0]["clientUserMessageId"], "u-7");
    assert_eq!(added[0]["input"][0]["text"], "ping");
}
