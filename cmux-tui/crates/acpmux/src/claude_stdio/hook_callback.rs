//! Claude's synchronous PreToolUse callback waits for an existing repo sync.
//! Unknown callbacks retain the empty success output Claude expects.
use super::*;

#[cfg(unix)]
pub(super) const SYNC_CALLBACK: &str = "cmux-repo-sync";

impl Translator {
    pub(super) async fn answer_hook_callback(&self, rid: &str, req: &Value) {
        let output = Self::hook_callback_output(req).await;
        self.stdin_replies.lock().await.push(json!({
            "type": "control_response",
            "response": {"subtype": "success", "request_id": rid, "response": output}
        }));
    }

    async fn hook_callback_output(req: &Value) -> Value {
        #[cfg(not(unix))]
        let output = {
            let _ = req;
            json!({})
        };
        #[cfg(unix)]
        let mut output = json!({});
        #[cfg(unix)]
        if req.get("callback_id").and_then(Value::as_str) == Some(SYNC_CALLBACK) {
            let input = req.get("input").cloned().unwrap_or(Value::Null);
            let result = tokio::task::spawn_blocking(move || {
                cmux_git::native_hook::wait(
                    "claude",
                    "PreToolUse",
                    &input,
                    cmux_git::native_hook::WAIT,
                )
            })
            .await;
            output = match result {
                Ok(Ok(())) => json!({}),
                Ok(Err(error)) => cmux_git::native_hook::denial(&error.to_string()),
                Err(error) => cmux_git::native_hook::denial(&error.to_string()),
            };
        }
        output
    }
}
