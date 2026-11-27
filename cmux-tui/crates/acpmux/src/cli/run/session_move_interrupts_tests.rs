use super::*;
use tokio::io::{AsyncBufReadExt as _, AsyncWriteExt as _};

/// A daemon on a unix socket that answers every method `{"ok": true}`, and
/// `_acpmux/transfer_interrupts` with `interrupts` (None: an older acpmux, method not found).
async fn holder(interrupts: Option<Value>) -> (tempfile::TempDir, Client) {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("d.sock");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    tokio::spawn(async move {
        while let Ok((conn, _)) = listener.accept().await {
            let interrupts = interrupts.clone();
            tokio::spawn(async move {
                let (rd, mut wr) = conn.into_split();
                let mut lines = tokio::io::BufReader::new(rd).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    let v: Value = serde_json::from_str(&line).unwrap();
                    let m = v["method"].as_str().unwrap_or_default();
                    let reply = match (m, &interrupts) {
                        ("_acpmux/transfer_interrupts", None) => json!({"jsonrpc": "2.0",
                            "id": v["id"], "error": {"code": -32601,
                            "message": "Method not found: _acpmux/transfer_interrupts"}}),
                        ("_acpmux/transfer_interrupts", Some(a)) => {
                            json!({"jsonrpc": "2.0", "id": v["id"], "result": a})
                        }
                        _ => json!({"jsonrpc": "2.0", "id": v["id"], "result": {"ok": true}}),
                    };
                    if wr.write_all(format!("{reply}\n").as_bytes()).await.is_err() {
                        return;
                    }
                }
            });
        }
    });
    let client = Client::connect(&socket).await.unwrap();
    (dir, client)
}

fn v1() -> Value {
    json!({"schema": SCHEMA, "sessionId": "s1", "nothing": false,
           "lines": ["a running turn: it moves at its next tool call, or is cut with --interrupt",
                     "1 listening port it serves (3000): not reachable at the new home until started there"]})
}

/// Old against new: an older holder has no answer and the move goes on as today (no error,
/// nothing printed); a new holder's v1 answer is kept and said.
#[cfg(unix)]
#[tokio::test]
async fn an_old_holder_has_no_answer_and_a_new_one_says_what_the_move_interrupts() {
    let (_old_dir, old) = holder(None).await;
    let answer = ask(&old, "s1").await.expect("an old holder never fails the move");
    assert_eq!(answer, None);
    assert!(text("chat", answer.as_ref(), true).is_empty());

    let (_new_dir, new) = holder(Some(v1())).await;
    let answer = ask(&new, "s1").await.unwrap().expect("a v1 answer");
    assert_eq!(answer["schema"], SCHEMA);
    let said = text("chat", Some(&answer), true);
    assert_eq!(said[0], "moving chat would interrupt:");
    assert!(said[2].contains("3000"), "{said:?}");
    assert_eq!(text("chat", Some(&answer), false)[0], "moving chat interrupts:");
}

#[test]
fn only_a_move_interrupts_schema_is_an_answer_and_nothing_to_interrupt_says_nothing() {
    assert!(read(json!({"ok": true})).is_none(), "a reply with no schema is not an answer");
    assert!(read(json!({"schema": "acpmux.bundle.v1"})).is_none());
    let later = read(json!({"schema": "acpmux.move-interrupts.v2", "lines": ["x"]}));
    assert!(later.is_some(), "a later version is still said by its lines");
    let none = json!({"schema": SCHEMA, "nothing": true, "lines": []});
    assert!(text("chat", Some(&none), false).is_empty());
}

#[test]
fn a_refusal_other_than_method_not_found_is_not_an_old_peer() {
    let e = |code| {
        anyhow::Error::from(crate::client::DaemonError(crate::rpc::RpcError::new(code, "x")))
    };
    assert!(old_peer(&e(-32601)));
    assert!(!old_peer(&e(-32602)));
    assert!(!old_peer(&anyhow!("ssh failed")));
}
