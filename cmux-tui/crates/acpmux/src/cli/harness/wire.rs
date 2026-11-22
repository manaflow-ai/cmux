//! Owns the harness doctor JSON-RPC wire and private temporary folder.

use super::*;

pub(crate) struct Wire {
    pub(crate) stdin: tokio::process::ChildStdin,
    pub(crate) lines: tokio::io::Lines<BufReader<tokio::process::ChildStdout>>,
    pub(crate) next: i64,
    pub(crate) reply: String,
    pub(crate) noise: usize,
}

impl Wire {
    pub(crate) async fn send(&mut self, msg: Value) -> Result<(), String> {
        let mut line = msg.to_string();
        line.push('\n');
        self.stdin
            .write_all(line.as_bytes())
            .await
            .map_err(|e| format!("write to the harness: {e}"))?;
        self.stdin.flush().await.map_err(|e| format!("write to the harness: {e}"))
    }

    /// One request; answers the harness's own requests (permission asks are
    /// cancelled, anything else is refused) and collects reply text.
    pub(crate) async fn call(
        &mut self,
        method: &str,
        params: Value,
        limit: Duration,
    ) -> Result<Value, String> {
        let id = self.next;
        self.next += 1;
        self.send(json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params})).await?;
        let deadline = tokio::time::Instant::now() + limit;
        loop {
            let line = match tokio::time::timeout_at(deadline, self.lines.next_line()).await {
                Err(_) => return Err(format!("no answer to {method} in {} s", limit.as_secs())),
                Ok(Err(e)) => return Err(format!("read from the harness: {e}")),
                Ok(Ok(None)) => {
                    return Err(format!("the harness exited before it answered {method}"));
                }
                Ok(Ok(Some(line))) => line,
            };
            if line.trim().is_empty() {
                continue;
            }
            let Ok(msg) = serde_json::from_str::<Value>(line.trim()) else {
                self.noise += 1;
                continue;
            };
            let incoming = msg.get("method").and_then(Value::as_str).map(str::to_owned);
            match (msg.get("id").cloned(), incoming.as_deref()) {
                (Some(rid), Some("session/request_permission")) => {
                    let answer = json!({"outcome": {"outcome": "cancelled"}});
                    self.send(json!({"jsonrpc": "2.0", "id": rid, "result": answer})).await?;
                }
                (Some(rid), Some(_)) => {
                    let error = json!({"code": -32601, "message": "cmux harness doctor and login do not serve this method"});
                    self.send(json!({"jsonrpc": "2.0", "id": rid, "error": error})).await?;
                }
                (None, Some("session/update")) => {
                    let update = msg.pointer("/params/update");
                    let kind = update.and_then(|u| u.get("sessionUpdate")).and_then(Value::as_str);
                    if kind == Some("agent_message_chunk")
                        && let Some(text) =
                            update.and_then(|u| u.pointer("/content/text")).and_then(Value::as_str)
                    {
                        self.reply.push_str(text);
                    }
                }
                (Some(rid), None) if rid == json!(id) => {
                    if let Some(e) = msg.get("error") {
                        let code = e.get("code").and_then(Value::as_i64).unwrap_or(0);
                        let message = e.get("message").and_then(Value::as_str).unwrap_or("error");
                        return Err(format!("{method} failed ({code}): {message}"));
                    }
                    return Ok(msg.get("result").cloned().unwrap_or(Value::Null));
                }
                _ => {}
            }
        }
    }
}

/// A private temp folder, removed on drop.
pub(crate) struct TempFolder {
    pub(crate) path: PathBuf,
}

impl TempFolder {
    pub(crate) fn new(id: &str) -> std::io::Result<Self> {
        use std::os::unix::fs::DirBuilderExt;
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.subsec_nanos())
            .unwrap_or(0);
        let path = std::env::temp_dir()
            .join(format!("cmux-harness-doctor-{id}-{}-{nanos}", std::process::id()));
        std::fs::DirBuilder::new().mode(0o700).create(&path)?;
        // One folder key for the trust record and the agent: /tmp vs /private/tmp.
        let path = std::fs::canonicalize(&path).unwrap_or(path);
        Ok(Self { path })
    }
}

impl Drop for TempFolder {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}
