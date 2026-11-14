use super::*;

/// A stand-in daemon on a socket: answers `initialize`, `_acpmux/resolve`, `_acpmux/info`
/// (one agent message queued) and `_acpmux/queue_remove` as an older acpmux does (no
/// `fromAgentsOnly` echo, and it removes what it is asked), recording each removal's id.
#[cfg(unix)]
async fn older_daemon(
    socket: &std::path::Path,
) -> (tokio::task::JoinHandle<()>, std::sync::Arc<std::sync::Mutex<Vec<String>>>) {
    use crate::rpc::Message;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    let listener = tokio::net::UnixListener::bind(socket).unwrap();
    let removals = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let seen = removals.clone();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (rd, mut wr) = stream.into_split();
        let mut lines = BufReader::new(rd).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            let Ok(Message::Request { id, method, params }) = Message::parse(&line) else {
                continue;
            };
            let params = params.unwrap_or_default();
            let result = match method.as_str() {
                method::MUX_RESOLVE => json!({"matches": [{"sessionId": "s", "name": "c"}]}),
                method::MUX_INFO => json!({"queue": [{"promptId": "p-a", "fromAgent": "lane-a",
                        "prompt": "hi", "queuedAt": 0, "held": false}]}),
                method::MUX_QUEUE_REMOVE => {
                    let prompt_id = params["promptId"].as_str().unwrap_or_default();
                    seen.lock().unwrap().push(prompt_id.to_owned());
                    json!({"sessionId": "s", "promptId": prompt_id, "removed": prompt_id == "p-a"})
                }
                _ => json!({}),
            };
            wr.write_all(Message::ok(id, result).to_line().as_bytes()).await.unwrap();
        }
    });
    (server, removals)
}

/// On a daemon that does not check `fromAgentsOnly`, clear removes nothing: an agent
/// message the person edited after the list was read would otherwise go.
#[cfg(unix)]
#[tokio::test]
async fn clear_on_an_older_daemon_removes_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("d.sock");
    let (server, removals) = older_daemon(&socket).await;
    let client = Client::connect(&socket).await.unwrap();
    let cmd = QueueCmd::Clear { session: "c".into(), from_agents: true, dry_run: false };
    let e = run(&client, cmd, true).await.unwrap_err();
    drop(client);
    server.await.unwrap();
    assert!(e.to_string().contains("nothing was removed"), "{e}");
    let removals = removals.lock().unwrap().clone();
    assert_eq!(removals.len(), 1, "only the probe: {removals:?}");
    assert!(removals[0].starts_with("acpmux-cli-probe-"), "{removals:?}");
}

fn item(id: &str, from: Option<&str>, text: &str) -> Value {
    json!({"promptId": id, "fromAgent": from, "prompt": text, "queuedAt": 0, "held": false})
}

#[test]
fn only_another_agents_message_is_from_an_agent() {
    assert!(is_from_agent(&item("a", Some("lane-a"), "x")));
    assert!(!is_from_agent(&item("p", None, "x")));
    assert!(!is_from_agent(&item("e", Some(""), "x")));
    let teammate =
        json!({"promptId": "t", "fromAgent": null, "author": {"id": "u", "name": "Ana"}});
    assert!(!is_from_agent(&teammate));
    assert_eq!(sender(&teammate), "person:Ana");
    let bound = json!({"fromAgent": "lane-a", "fromSessionId": "0193f1a2-b3c4-7d5e"});
    assert_eq!(sender(&bound), "lane-a (0193f1a2)");
}

#[test]
fn list_names_each_sender_on_one_line_and_counts_the_agents() {
    let lines =
        list_lines(&[item("p-1", None, "mine\nsecond line"), item("p-2", Some("lane-a"), "hi")]);
    assert!(lines[0].starts_with("PROMPT ID"), "{lines:?}");
    assert!(
        lines[1].contains("p-1")
            && lines[1].contains("person")
            && lines[1].contains("mine second line")
    );
    assert!(lines[2].contains("p-2") && lines[2].contains("lane-a"));
    assert_eq!(lines[3], "2 queued (1 from agents)");
    assert_eq!(list_lines(&[]), vec!["queue is empty".to_owned()]);
}

#[test]
fn remove_fails_on_an_unknown_id_and_clear_does_not() {
    let results = [
        json!({"promptId": "a", "status": "removed"}),
        json!({"promptId": "b", "status": "not_found"}),
    ];
    assert!(report("s", &results, true, false).is_err());
    assert!(report("s", &results, true, true).is_ok());
    let refused = [json!({"promptId": "a", "status": "refused", "error": "moving"})];
    assert!(report("s", &refused, true, true).is_err());
    assert!(report("s", &[json!({"promptId": "a", "status": "kept"})], true, true).is_ok());
}

/// Only `queue.not_found` (the prompt left the queue after the list) is no failure of the
/// full-text read; any other error is.
#[test]
fn only_a_prompt_that_left_the_queue_is_no_text_failure() {
    let daemon = |e: crate::rpc::RpcError| anyhow::Error::from(crate::client::DaemonError(e));
    let gone = crate::rpc::RpcError::not_found("no prompt q waits")
        .with_data(json!({"reason": "queue.not_found", "promptId": "q"}));
    assert!(left_queue(&daemon(gone)));
    assert!(!left_queue(&daemon(crate::rpc::RpcError::not_found("no session"))));
    assert!(!left_queue(&anyhow::anyhow!("the daemon closed the connection")));
}

/// Only a daemon that echoes `fromAgentsOnly` checked it; one that does not (an older
/// acpmux) is `checked: false`, and an edited prompt it kept reads `kept`.
#[test]
fn an_agents_only_removal_says_whether_the_daemon_checked_it() {
    let new = json!({"removed": true, "fromAgentsOnly": true, "notFromAgent": false});
    assert_eq!(
        outcome("a", &new, true),
        json!({"promptId": "a", "status": "removed", "checked": true})
    );
    let old = json!({"removed": true});
    assert_eq!(outcome("a", &old, true)["checked"], false);
    let kept = json!({"removed": false, "fromAgentsOnly": true, "notFromAgent": true});
    assert_eq!(outcome("a", &kept, true)["status"], "kept");
    assert_eq!(
        outcome("a", &json!({"removed": false}), false),
        json!({"promptId": "a", "status": "not_found"})
    );
}
