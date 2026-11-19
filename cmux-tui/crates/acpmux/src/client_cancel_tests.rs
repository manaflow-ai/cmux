//! A cancelled read releases its reply slot even if the daemon never answers it.

use super::*;
use tokio::net::UnixListener;

#[tokio::test]
async fn cancelled_requests_leave_no_waiters_and_late_replies_do_not_close_the_client() {
    let dir = tempfile::tempdir_in("/tmp").unwrap();
    let socket = dir.path().join("client.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let (seen, mut requests) = mpsc::channel::<Value>(1);
    let (answer, mut answers) = mpsc::channel::<Value>(1);
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (rd, mut wr) = stream.into_split();
        let mut lines = BufReader::new(rd).lines();
        loop {
            tokio::select! {
                line = lines.next_line() => {
                    let Some(line) = line.unwrap() else { break };
                    let request: Value = serde_json::from_str(&line).unwrap();
                    if request["method"] == method::INITIALIZE {
                        let reply = json!({"jsonrpc": "2.0", "id": request["id"], "result": {}});
                        wr.write_all(format!("{reply}\n").as_bytes()).await.unwrap();
                    } else {
                        seen.send(request).await.unwrap();
                    }
                }
                reply = answers.recv() => {
                    let Some(reply) = reply else { break };
                    wr.write_all(format!("{reply}\n").as_bytes()).await.unwrap();
                }
            }
        }
    });
    let client = Client::connect_without_caller(&socket).await.unwrap();
    let mut cancelled_id = Value::Null;
    for _ in 0..256 {
        let client = client.clone();
        let task = tokio::spawn(async move { client.request(method::MUX_INFO, json!({})).await });
        cancelled_id = requests.recv().await.unwrap()["id"].clone();
        task.abort();
        assert!(task.await.unwrap_err().is_cancelled());
    }
    assert_eq!(
        client.pending.lock().await.len(),
        0,
        "no reply and no disconnect: all 256 callers left"
    );

    // A late reply belongs only to the abandoned request; the next request still gets its own.
    answer.send(json!({"jsonrpc": "2.0", "id": cancelled_id, "result": "late"})).await.unwrap();
    let next_client = client.clone();
    let next = tokio::spawn(async move { next_client.request(method::MUX_INFO, json!({})).await });
    let request = requests.recv().await.unwrap();
    answer.send(json!({"jsonrpc": "2.0", "id": request["id"], "result": "current"})).await.unwrap();
    assert_eq!(next.await.unwrap().unwrap(), json!("current"));
    assert_eq!(client.pending.lock().await.len(), 0);
    assert!(!client.is_closed());
    drop(answer);
    server.await.unwrap();
}
