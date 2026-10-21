//! Codex over `codex app-server`, presented to the hub as an ACP agent, in
//! process (the cmux-codex-acp library).
//!
//! A profile whose command line is `codex app-server` (kind ACP) is bridged
//! here: acpmux spawns the app-server, and the translator turns the hub's
//! ACP into app-server JSON-RPC and back, in the agent host (durable
//! sessions) or beside a direct child. `codex app-server` never speaks ACP
//! itself, so the command line names the bridge without a new harness kind,
//! and the hub sees a plain ACP agent: sessions, modes, config options,
//! permission requests and native subagent sessions. Nothing outside this
//! file and the library knows the app-server wire format.

use crate::rpc::{Message, RpcError};
use cmux_codex_acp::{Options, Out};
use serde_json::Value;
use std::path::Path;
use std::sync::{Arc, Mutex};

mod background;
pub use background::TERMINATE;

/// The cmux-codex-acp translator, with Codex's background terminals beside
/// it (`background.rs`).
pub struct Translator {
    inner: cmux_codex_acp::Translator,
    background: Mutex<background::Background>,
}

impl Translator {
    fn background(&self) -> std::sync::MutexGuard<'_, background::Background> {
        self.background.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// The first lines for the app-server.
    pub fn start(&self) -> Vec<Out> {
        self.inner.start()
    }

    /// One message from the hub.
    pub fn from_client(&self, msg: &Value) -> Vec<Out> {
        if let Some(out) = self.background().request(msg) {
            return out;
        }
        self.inner.from_client(msg)
    }

    /// One line from the app-server.
    pub fn from_server(&self, raw: &Value) -> Vec<Out> {
        let mut out = {
            let mut background = self.background();
            if let Some(out) = background.response(raw) {
                return out;
            }
            background.observe(raw)
        };
        out.extend(self.inner.from_server(raw));
        out
    }

    /// The app-server exited or its pipe closed.
    pub fn server_closed(&self, why: &str) -> Vec<Out> {
        let mut out = self.inner.server_closed(why);
        out.extend(self.background().closed(why));
        out
    }
}

/// Whether `program args...` runs `codex app-server`: a program named `codex`,
/// `codex-<x>` or `<x>-codex` (a renamed build such as `cmux-codex`; any
/// extension) and whose first argument that is not a global
/// option is `app-server`, with no app-server subcommand after it. Global
/// options before the subcommand (`-c key=value`, `--enable x`, `-p profile`)
/// take one value each.
pub fn is_launch(program: &str, args: &[String]) -> bool {
    let name = Path::new(program).file_stem().and_then(|n| n.to_str()).unwrap_or("");
    if !(name == "codex" || name.starts_with("codex-") || name.ends_with("-codex")) {
        return false;
    }
    let mut i = 0;
    while let Some(a) = args.get(i) {
        if a == "app-server" {
            // `codex app-server <subcommand>` (generate-json-schema, proxy,
            // daemon) is not the server; options after it are.
            return args.get(i + 1).is_none_or(|next| next.starts_with('-'));
        }
        if !a.starts_with('-') {
            return false;
        }
        // `--flag=value` carries its value; `-c value` and `--flag value` do not.
        i += if a.contains('=') { 1 } else { 2 };
    }
    false
}

/// `is_launch` for a profile's argv.
pub fn is_profile_launch(argv: &[String]) -> bool {
    argv.split_first().is_some_and(|(program, args)| is_launch(program, args))
}

/// A translator for one app-server process. It takes one-shot audio prompts
/// (the composer's mic) from any app-server that accepts them: the library
/// advertises `promptCapabilities.audio` only to Codex 0.145.0 or later, so
/// an older `codex` keeps `audio: false` and the pane falls back to dictation.
pub fn translator() -> Arc<Translator> {
    Arc::new(Translator {
        inner: cmux_codex_acp::Translator::new(Options {
            client_name: "acpmux".into(),
            client_title: "cmux".into(),
            client_version: env!("CARGO_PKG_VERSION").into(),
            audio_input: true,
            ..Options::default()
        }),
        background: Mutex::default(),
    })
}

/// What the translator produced: lines for the app-server's stdin and ACP
/// messages for the hub.
#[derive(Default)]
pub struct Split {
    pub server: Vec<Value>,
    pub hub: Vec<Message>,
}

pub fn split(outs: Vec<Out>) -> Split {
    let mut s = Split::default();
    for o in outs {
        match o {
            Out::Server(v) => s.server.push(v),
            Out::Client(v) => match into_message(v) {
                Ok(m) => s.hub.push(m),
                Err(e) => {
                    tracing::warn!("cmux-codex-acp produced a message acpmux cannot parse: {e}")
                }
            },
        }
    }
    s
}

/// `Message::from_value`, moving the fields out of the translator's value
/// instead of copying them: each streamed delta is one `session/update`, and
/// the copy of its params was most of the bridge's work per delta.
fn into_message(v: Value) -> Result<Message, RpcError> {
    let Value::Object(mut obj) = v else { return Message::from_value(v) };
    let method = match obj.remove("method") {
        Some(Value::String(m)) => Some(m),
        _ => None,
    };
    let id = obj.remove("id").filter(|v| !v.is_null());
    match (method, id) {
        (Some(method), Some(id)) => {
            Ok(Message::Request { id, method, params: obj.remove("params") })
        }
        (Some(method), None) => Ok(Message::Notification { method, params: obj.remove("params") }),
        (None, Some(id)) => {
            let error = match obj.remove("error") {
                Some(e) if !e.is_null() => Some(
                    serde_json::from_value::<RpcError>(e.clone())
                        .unwrap_or_else(|_| RpcError::internal(e.to_string())),
                ),
                _ => None,
            };
            Ok(Message::Response { id, result: obj.remove("result"), error })
        }
        (None, None) => Err(RpcError::new(-32600, "Invalid request: no method or id")),
    }
}

/// `Message::to_value`, moving the params instead of copying them.
pub fn into_value(m: Message) -> Value {
    let mut obj = serde_json::Map::new();
    obj.insert("jsonrpc".into(), Value::from("2.0"));
    match m {
        Message::Request { id, method, params } => {
            obj.insert("id".into(), id);
            obj.insert("method".into(), Value::String(method));
            if let Some(p) = params {
                obj.insert("params".into(), p);
            }
        }
        Message::Notification { method, params } => {
            obj.insert("method".into(), Value::String(method));
            if let Some(p) = params {
                obj.insert("params".into(), p);
            }
        }
        Message::Response { id, result, error } => {
            obj.insert("id".into(), id);
            match error {
                Some(e) => {
                    obj.insert("error".into(), serde_json::to_value(e).unwrap_or(Value::Null));
                }
                None => {
                    obj.insert("result".into(), result.unwrap_or(Value::Null));
                }
            }
        }
    }
    Value::Object(obj)
}

/// The session-log kind of a raw app-server line (`codex.<method>`, or
/// `codex.response`), or None for item notifications and streaming deltas.
pub fn tap_kind(raw: &Value) -> Option<String> {
    match raw.get("method").and_then(Value::as_str) {
        // Item notifications become session updates that carry what they
        // say; logging the raw line too would double the busiest records.
        Some(m) if cmux_codex_acp::is_delta(m) || m.starts_with("item/") => None,
        Some(m) => Some(format!("codex.{m}")),
        None => Some("codex.response".into()),
    }
}

/// The session-log kind of a line written to the app-server.
pub const STDIN_KIND: &str = "codex.stdin";

/// One line for the app-server's stdin.
pub fn line(v: &Value) -> String {
    let mut s = v.to_string();
    s.push('\n');
    s
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// What `translator()` tells the hub about audio once an app-server that
    /// reports `user_agent` answered its `initialize`.
    fn advertises_audio(user_agent: &str) -> bool {
        let tr = translator();
        let start = split(tr.start());
        let id = start.server[0]["id"].clone();
        split(tr.from_server(
            &json!({"jsonrpc": "2.0", "id": id, "result": {"userAgent": user_agent}}),
        ));
        let reply = split(tr.from_client(&json!({
            "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": 1},
        })));
        let result = reply
            .hub
            .iter()
            .find_map(|m| m.to_value().get("result").cloned())
            .expect("initialize result");
        result["agentCapabilities"]["promptCapabilities"]["audio"] == json!(true)
    }

    #[test]
    fn a_current_codex_takes_audio_prompts() {
        assert!(advertises_audio("acpmux/0.163.0 (Mac OS 27.0.1; arm64) unknown (acpmux; 1)"));
    }

    #[test]
    fn an_older_or_unknown_codex_does_not() {
        assert!(!advertises_audio("acpmux/0.144.0 (Mac OS 27.0.1; arm64) unknown (acpmux; 1)"));
        assert!(!advertises_audio("fake"));
    }
}
