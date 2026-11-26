//! A resumed Codex chat runs on the model provider codex is configured for now, as `codex` in a
//! terminal does (cmux#48354).
//!
//! Codex records a thread's model provider in its rollout and `thread/resume` (and `thread/fork`)
//! goes back to that one unless the request names another. A chat created while its provider was
//! wrong (a launcher's `-c model_provider=…` dropped, cmux#48354) or before the person changed
//! provider stayed on the old one for good: every Retry and every later message failed the same
//! way (400 `model_not_found`) while a new chat worked. Before the first such request of a process
//! the translator asks codex for its effective config (`config/read`, which includes the command
//! line's overrides), holds the request until the answer comes, and names that provider on it. A
//! codex that cannot answer, or names none, gets the request as it was.

use cmux_codex_acp::Out;
use serde_json::Value;

/// The id prefix of the `config/read` requests acpmux sends on its own.
const ID_PREFIX: &str = "cmux.provider.";

#[derive(Default)]
pub(super) struct ProviderPin {
    /// The answer: `Some(None)` once codex answered without a provider (or with an error).
    provider: Option<Option<String>>,
    /// The id of the `config/read` in flight.
    asked: Option<Value>,
    /// Lines for codex held until it is answered: the first resume or fork and every line for
    /// codex after it, in order. Messages for the hub never wait (a turn's result, an approval).
    held: Vec<Out>,
}

fn reopens_thread(out: &Out) -> bool {
    matches!(out, Out::Server(v) if v.get("id").is_some()
        && matches!(v.get("method").and_then(Value::as_str), Some("thread/resume" | "thread/fork")))
}

impl ProviderPin {
    /// `outs` as they go out: a resume or fork names the provider, once known; the first one
    /// asks for it and holds itself and what follows it until the answer.
    pub(super) fn outgoing(&mut self, outs: Vec<Out>) -> Vec<Out> {
        let mut sent = Vec::new();
        for out in outs {
            if matches!(out, Out::Client(_)) {
                sent.push(out);
                continue;
            }
            if !self.held.is_empty() {
                self.held.push(out);
                continue;
            }
            if !reopens_thread(&out) {
                sent.push(out);
                continue;
            }
            match &self.provider {
                Some(provider) => sent.push(name(out, provider.as_deref())),
                None => {
                    if self.asked.is_none() {
                        let id = Value::String(format!("{ID_PREFIX}{}", uuid::Uuid::now_v7()));
                        sent.push(Out::Server(serde_json::json!({
                            "jsonrpc": "2.0", "id": id, "method": "config/read",
                            "params": {"includeLayers": false}
                        })));
                        self.asked = Some(id);
                    }
                    self.held.push(out);
                }
            }
        }
        sent
    }

    /// The answer to acpmux's own `config/read`: the held requests, now naming the provider.
    /// None for any other line from the app-server.
    pub(super) fn answer(&mut self, raw: &Value) -> Option<Vec<Out>> {
        let id = raw.get("id")?;
        if self.asked.as_ref() != Some(id) || raw.get("method").is_some() {
            return None;
        }
        self.asked = None;
        let provider = raw
            .pointer("/result/config/model_provider")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|p| !p.is_empty())
            .map(str::to_owned);
        if provider.is_none() {
            tracing::debug!(reply = %raw, "codex named no model provider; resuming as recorded");
        }
        self.provider = Some(provider);
        let held = std::mem::take(&mut self.held);
        Some(self.outgoing(held))
    }

    /// The app-server is gone: the lines held for it go nowhere (the inner translator answers
    /// the hub for the requests still pending, the held resume or fork among them).
    pub(super) fn closed(&mut self) {
        self.asked = None;
        self.held.clear();
    }
}

/// `out` (a resume or fork) naming `provider`, unless it names one already.
fn name(mut out: Out, provider: Option<&str>) -> Out {
    if let (Out::Server(v), Some(provider)) = (&mut out, provider)
        && let Some(params) = v.get_mut("params").and_then(Value::as_object_mut)
        && !params.contains_key("modelProvider")
    {
        params.insert("modelProvider".into(), Value::String(provider.to_owned()));
    }
    out
}

#[cfg(test)]
#[path = "provider_tests.rs"]
mod tests;
