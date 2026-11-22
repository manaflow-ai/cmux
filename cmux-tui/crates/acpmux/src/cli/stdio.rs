//! `acpmux stdio` (and `cmux acp stdio`): an ACP agent on stdin and stdout
//! for editors such as Zed. The daemon already speaks plain ACP on its
//! socket, so this relays newline-delimited JSON-RPC both ways and only adds
//! the agent defaults from its flags to each `session/new` that does not
//! choose them itself. Sessions the editor creates are ordinary acpmux
//! sessions: the TUI, the dashboard and the app see them, and `session/list`
//! plus `session/load` reach sessions started anywhere else.

use crate::rpc::method;
use anyhow::{Context, Result};
use serde_json::{Map, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

/// Defaults applied to `session/new` (`_meta.acpmux.<key>`).
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Defaults {
    pub harness: Option<String>,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub policy: Option<String>,
    pub preset: Option<String>,
}

impl Defaults {
    fn entries(&self) -> [(&'static str, Option<&String>); 5] {
        [
            ("harness", self.harness.as_ref()),
            ("model", self.model.as_ref()),
            ("effort", self.effort.as_ref()),
            ("policy", self.policy.as_ref()),
            ("preset", self.preset.as_ref()),
        ]
    }
}

pub async fn run(defaults: Defaults) -> Result<()> {
    let stream = crate::daemon::connect_stream().await?;
    let (daemon_read, mut daemon_write) = stream.into_split();
    // Requests the editor sent that the daemon has not answered. When stdin
    // ends, the relay still delivers these answers, then stops.
    let pending = std::sync::Mutex::new(std::collections::HashSet::<String>::new());
    let answered = tokio::sync::Notify::new();
    let to_daemon = async {
        let mut lines = BufReader::new(tokio::io::stdin()).lines();
        while let Some(line) = lines.next_line().await.context("read stdin")? {
            if let Some(id) = request_id(&line) {
                pending.lock().unwrap_or_else(|e| e.into_inner()).insert(id);
            }
            let line = apply_defaults(&line, &defaults);
            daemon_write.write_all(line.as_bytes()).await.context("write to acpmux")?;
            daemon_write.write_all(b"\n").await.context("write to acpmux")?;
        }
        // The editor closed stdin: finish once every request is answered.
        loop {
            let wait = answered.notified();
            if pending.lock().unwrap_or_else(|e| e.into_inner()).is_empty() {
                return anyhow::Ok(());
            }
            wait.await;
        }
    };
    let to_editor = async {
        let mut stdout = tokio::io::stdout();
        let mut lines = BufReader::new(daemon_read).lines();
        while let Some(line) = lines.next_line().await.context("read from acpmux")? {
            stdout.write_all(line.as_bytes()).await.context("write stdout")?;
            stdout.write_all(b"\n").await.context("write stdout")?;
            stdout.flush().await.context("write stdout")?;
            if let Some(id) = response_id(&line)
                && pending.lock().unwrap_or_else(|e| e.into_inner()).remove(&id)
            {
                answered.notify_one();
            }
        }
        anyhow::Ok(())
    };
    // Either side ending ends the relay; sessions keep running in the daemon.
    tokio::select! {
        result = to_daemon => result,
        result = to_editor => result,
    }
}

/// The id of a JSON-RPC request (a message with `method` and `id`).
fn request_id(line: &str) -> Option<String> {
    let message: Value = serde_json::from_str(line).ok()?;
    message.get("method")?;
    message.get("id").filter(|id| !id.is_null()).map(Value::to_string)
}

/// The id of a JSON-RPC response (`id` with `result` or `error`, no `method`).
fn response_id(line: &str) -> Option<String> {
    let message: Value = serde_json::from_str(line).ok()?;
    if message.get("method").is_some()
        || (message.get("result").is_none() && message.get("error").is_none())
    {
        return None;
    }
    message.get("id").map(Value::to_string)
}

/// Adds the defaults to a `session/new` request. Every other line, and any
/// line that is not JSON, passes through byte for byte.
pub fn apply_defaults(line: &str, defaults: &Defaults) -> String {
    if defaults.entries().iter().all(|(_, value)| value.is_none()) {
        return line.to_owned();
    }
    let Ok(mut message) = serde_json::from_str::<Value>(line) else { return line.to_owned() };
    if message.get("method").and_then(Value::as_str) != Some(method::SESSION_NEW) {
        return line.to_owned();
    }
    let Some(object) = message.as_object_mut() else { return line.to_owned() };
    let params = object.entry("params").or_insert_with(|| Value::Object(Map::new()));
    let Some(params) = params.as_object_mut() else { return line.to_owned() };
    // A top-level choice (`params.model`) is the editor's too, and the
    // daemon reads `_meta.acpmux` first, so no default may shadow it.
    let chosen: Vec<&str> = defaults
        .entries()
        .iter()
        .map(|(key, _)| *key)
        .filter(|key| params.get(*key).and_then(Value::as_str).is_some())
        .collect();
    let meta = params.entry("_meta").or_insert_with(|| Value::Object(Map::new()));
    let Some(meta) = meta.as_object_mut() else { return line.to_owned() };
    let mux = meta.entry("acpmux").or_insert_with(|| Value::Object(Map::new()));
    let Some(mux) = mux.as_object_mut() else { return line.to_owned() };
    for (key, value) in defaults.entries() {
        if let Some(value) = value
            && !mux.contains_key(key)
            && !chosen.contains(&key)
        {
            mux.insert(key.into(), Value::String(value.clone()));
        }
    }
    serde_json::to_string(&message).unwrap_or_else(|_| line.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn claude() -> Defaults {
        Defaults {
            harness: Some("claude".into()),
            policy: Some("approve-edits".into()),
            ..Default::default()
        }
    }

    #[test]
    fn session_new_gets_the_defaults() {
        let line = r#"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/w","mcpServers":[]}}"#;
        let out: Value = serde_json::from_str(&apply_defaults(line, &claude())).unwrap();
        assert_eq!(
            out["params"]["_meta"]["acpmux"],
            json!({"harness":"claude","policy":"approve-edits"})
        );
        assert_eq!(out["params"]["cwd"], "/w");
    }

    #[test]
    fn the_editor_choice_wins() {
        let line = r#"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"_meta":{"acpmux":{"harness":"codex"}}}}"#;
        let out: Value = serde_json::from_str(&apply_defaults(line, &claude())).unwrap();
        assert_eq!(out["params"]["_meta"]["acpmux"]["harness"], "codex");
        assert_eq!(out["params"]["_meta"]["acpmux"]["policy"], "approve-edits");
    }

    #[test]
    fn a_top_level_choice_wins_too() {
        let line =
            r#"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"harness":"codex"}}"#;
        let out: Value = serde_json::from_str(&apply_defaults(line, &claude())).unwrap();
        assert_eq!(out["params"]["_meta"]["acpmux"], json!({"policy":"approve-edits"}));
        assert_eq!(out["params"]["harness"], "codex");
    }

    #[test]
    fn requests_and_their_responses_pair_by_id() {
        let request = r#"{"jsonrpc":"2.0","id":7,"method":"session/prompt","params":{}}"#;
        let notification = r#"{"jsonrpc":"2.0","method":"session/cancel","params":{}}"#;
        let response = r#"{"jsonrpc":"2.0","id":7,"result":{}}"#;
        let server_request =
            r#"{"jsonrpc":"2.0","id":7,"method":"session/request_permission","params":{}}"#;
        assert_eq!(request_id(request), response_id(response));
        assert_eq!(request_id(request).as_deref(), Some("7"));
        assert_eq!(request_id(notification), None);
        assert_eq!(response_id(server_request), None);
    }

    #[test]
    fn other_lines_pass_through_unchanged() {
        for line in [
            r#"{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"s"}}"#,
            "not json",
            r#"{"jsonrpc":"2.0","id":3,"result":{}}"#,
        ] {
            assert_eq!(apply_defaults(line, &claude()), line);
        }
        let line = r#"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{}}"#;
        assert_eq!(apply_defaults(line, &Defaults::default()), line);
    }
}
