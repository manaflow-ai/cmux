//! The compactor's model over the Anthropic Messages API (`POST /v1/messages`),
//! through the team subrouter by default. Rust has no official Anthropic SDK,
//! so this is raw HTTP with a blocking client.

use serde_json::{json, Value};

use optchat_core::CompactRequest;

use crate::config::Config;
use crate::model::{CompactModel, Followup, ModelError, Reply};

const API_VERSION: &str = "2023-06-01";
/// The team subrouter picks the upstream by client: a request it cannot
/// identify as Claude Code goes to the Codex backend (and fails there), so
/// the request says it is a Claude client. Other endpoints ignore the header.
pub const AGENT_HEADER: (&str, &str) = ("x-subrouter-agent", "claude");
/// How much of an error body a failure report keeps.
const ERROR_BODY: usize = 600;

/// The beta that enables server-side `fallbacks: "default"`.
const SERVER_FALLBACK_BETA: &str = "server-side-fallback-2026-07-01";

pub struct AnthropicModel {
    agent: ureq::Agent,
    url: String,
    key: String,
    model: String,
    effort: Option<String>,
    max_tokens: u32,
    server_fallback: bool,
    tools: Option<Value>,
}

impl AnthropicModel {
    /// The compactor's model (`config.model`).
    pub fn new(config: &Config) -> AnthropicModel {
        AnthropicModel::with_model(config, &config.model)
    }

    /// The same client for another model id (the refusal fallback).
    pub fn with_model(config: &Config, model: &str) -> AnthropicModel {
        AnthropicModel {
            agent: ureq::AgentBuilder::new()
                .timeout(config.http_timeout)
                .build(),
            url: format!("{}/v1/messages", config.base_url.trim_end_matches('/')),
            key: config.api_key.clone(),
            model: model.to_owned(),
            effort: config.effort.clone(),
            max_tokens: config.max_tokens,
            server_fallback: config.server_fallback,
            tools: config.tools.clone(),
        }
    }

    /// The request body (spec 3.3 and 4, gist 3c190e0): the turns' system
    /// prompt and tools (never called: `tool_choice` none), so a compaction
    /// reads them from the turns' cache entry; then its view in blocks of 4
    /// lines, one mark on the last whole block; then the task. The system
    /// prompt carries a mark and the request's end another (the top-level
    /// automatic `cache_control`), so size-loop retries read the call
    /// before them. Three breakpoints of the four allowed. No 1-hour entries:
    /// they cost twice the input to write.
    pub fn body(&self, request: &CompactRequest, followups: &[Followup]) -> Value {
        let pieces = optchat_core::block_pieces(&request.context);
        let whole = pieces.len() - 1;
        let mut content: Vec<Value> = pieces
            .into_iter()
            .enumerate()
            .map(|(k, piece)| {
                if whole > 0 && k + 1 == whole {
                    json!({"type": "text", "text": piece, "cache_control": {"type": "ephemeral"}})
                } else {
                    json!({"type": "text", "text": piece})
                }
            })
            .collect();
        content.push(json!({"type": "text", "text": request.step}));
        let mut messages = vec![json!({"role": "user", "content": content})];
        for f in followups {
            let content = match &f.reply.content {
                Value::Null => json!(f.reply.text),
                raw => raw.clone(),
            };
            messages.push(json!({"role": "assistant", "content": content}));
            messages.push(json!({"role": "user", "content": f.retry}));
        }
        let mut body = json!({
            "model": self.model,
            "max_tokens": self.max_tokens,
            "system": [{"type": "text", "text": request.system, "cache_control": {"type": "ephemeral"}}],
            "messages": messages,
            "cache_control": {"type": "ephemeral"},
        });
        if let Some(tools) = &self.tools {
            body["tools"] = tools.clone();
            body["tool_choice"] = json!({"type": "none"});
        }
        if let Some(effort) = &self.effort {
            body["output_config"] = json!({"effort": effort});
        }
        if self.server_fallback {
            body["fallbacks"] = json!("default");
        }
        body
    }
}

fn clip(s: &str) -> &str {
    optchat_core::cut_at_bytes(s, ERROR_BODY)
}

impl CompactModel for AnthropicModel {
    fn call(&self, request: &CompactRequest, followups: &[Followup]) -> Result<Reply, ModelError> {
        let response = self
            .agent
            .post(&self.url)
            .set("x-api-key", &self.key)
            .set("anthropic-version", API_VERSION)
            .set(AGENT_HEADER.0, AGENT_HEADER.1);
        let response = if self.server_fallback {
            response.set("anthropic-beta", SERVER_FALLBACK_BETA)
        } else {
            response
        }
        .send_json(self.body(request, followups));
        let value: Value = match response {
            Ok(r) => r
                .into_json()
                .map_err(|e| ModelError::new(format!("bad response body: {e}")))?,
            Err(ureq::Error::Status(code, r)) => {
                let wait = r
                    .header("retry-after")
                    .and_then(|v| v.trim().parse::<f64>().ok())
                    .filter(|s| s.is_finite() && *s >= 0.0)
                    .map(std::time::Duration::from_secs_f64);
                let text = r.into_string().unwrap_or_default();
                let error = ModelError::new(format!("HTTP {code}: {}", clip(&text)));
                return Err(match wait {
                    Some(wait) => error.with_retry_after(wait),
                    None => error,
                });
            }
            Err(e) => return Err(ModelError::new(e.to_string())),
        };
        parse(value)
    }
}

/// The reply's text and its raw content. A refusal or a reply cut by
/// `max_tokens` is a failure: a partial line must never become a node.
fn parse(value: Value) -> Result<Reply, ModelError> {
    match value["stop_reason"].as_str() {
        Some("refusal") => {
            return Err(ModelError::refusal(format!(
                "refused: {}",
                value["stop_details"]
            )));
        }
        Some("max_tokens") => return Err(ModelError::new("reply hit max_tokens")),
        _ => {}
    }
    let content = value
        .get("content")
        .cloned()
        .filter(Value::is_array)
        .ok_or_else(|| {
            ModelError::new(format!(
                "no content in response: {}",
                clip(&value.to_string())
            ))
        })?;
    let text: String = content
        .as_array()
        .into_iter()
        .flatten()
        .filter(|b| b["type"] == "text")
        .filter_map(|b| b["text"].as_str())
        .collect();
    Ok(Reply { text, content })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::api_key;
    use optchat_core::NodeId;

    fn request() -> CompactRequest {
        CompactRequest {
            node: NodeId::new(0, 3),
            system: "SYS".into(),
            context: "<chat>\n</chat>".into(),
            step: "STEP".into(),
            cut: None,
        }
    }

    #[test]
    fn body_puts_cached_context_first_and_replays_the_size_loop() {
        let model = AnthropicModel::new(&Config::default());
        let followups = vec![Followup {
            reply: Reply {
                text: "long".into(),
                content: json!([{"type": "text", "text": "long"}]),
            },
            retry: "That line is 600 bytes".into(),
        }];
        let body = model.body(&request(), &followups);
        assert_eq!(body["system"][0]["text"], "SYS");
        assert_eq!(body["system"][0]["cache_control"]["type"], "ephemeral");
        assert_eq!(body["cache_control"]["type"], "ephemeral");
        assert_eq!(body["model"], "claude-haiku-5-5");
        assert_eq!(body["output_config"]["effort"], "high");
        assert!(body.get("tools").is_none());
        let m = body["messages"].as_array().unwrap();
        assert_eq!(m.len(), 3);
        // An empty view has no whole block: no mark in it.
        assert!(m[0]["content"][0].get("cache_control").is_none());
        assert_eq!(m[0]["content"][1]["text"], "STEP");
        assert_eq!(m[1]["role"], "assistant");
        assert_eq!(m[1]["content"][0]["text"], "long");
        assert_eq!(m[2]["content"], "That line is 600 bytes");
    }

    /// Spec 3.3 (gist 3c190e0): the view in blocks of 4 lines, one mark on
    /// the last whole block; the turns' tools when configured, never called.
    #[test]
    fn the_view_goes_in_four_line_blocks_with_one_mark_on_the_last_whole_one() {
        let line = format!("{}\n", "x".repeat(99));
        let mut context = String::from("<chat>\n");
        for _ in 0..30 {
            context.push_str(&line);
        }
        context.push_str("</chat>");
        let request = CompactRequest {
            context: context.clone(),
            ..request()
        };
        let config = Config {
            tools: Some(json!([{"name": "zoom"}])),
            ..Config::default()
        };
        let body = AnthropicModel::new(&config).body(&request, &[]);
        assert_eq!(body["tools"], json!([{"name": "zoom"}]));
        assert_eq!(body["tool_choice"]["type"], "none");
        let blocks = body["messages"][0]["content"].as_array().unwrap().clone();
        // 7 whole blocks of 4 lines, the rest, the task.
        assert_eq!(blocks.len(), 9);
        let joined: String = blocks[..8]
            .iter()
            .map(|b| b["text"].as_str().unwrap())
            .collect();
        assert_eq!(joined, context);
        let marked: Vec<usize> = (0..blocks.len())
            .filter(|k| blocks[*k].get("cache_control").is_some())
            .collect();
        assert_eq!(marked, vec![6]);
        assert_eq!(blocks[8]["text"], "STEP");
    }

    /// Audit round 2: the key was the constant "subrouter", so any other
    /// base URL answered every compactor call with a 401, forever.
    #[test]
    fn the_configured_key_is_sent() {
        use std::io::{BufRead, BufReader, Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let base_url = format!("http://{}", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut key = String::new();
            let mut agent = String::new();
            let mut length = 0usize;
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                let line = line.trim_end();
                if line.is_empty() {
                    break;
                }
                let lower = line.to_ascii_lowercase();
                if let Some(v) = lower.strip_prefix("x-api-key:") {
                    key = line[line.len() - v.trim_start().len()..].to_owned();
                }
                if let Some(v) = lower.strip_prefix("x-subrouter-agent:") {
                    agent = v.trim().to_owned();
                }
                if let Some(v) = lower.strip_prefix("content-length:") {
                    length = v.trim().parse().unwrap();
                }
            }
            let mut body = vec![0; length];
            reader.read_exact(&mut body).unwrap();
            let reply = json!({"stop_reason": "end_turn", "content": [{"type": "text", "text": "user: hi"}]}).to_string();
            write!(
                &stream,
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{reply}",
                reply.len()
            )
            .unwrap();
            (key, agent)
        });
        let config = Config {
            api_key: api_key(&base_url, |k| {
                (k == "ANTHROPIC_API_KEY").then(|| "sk-real".to_string())
            }),
            base_url,
            ..Config::default()
        };
        let reply = AnthropicModel::new(&config).call(&request(), &[]).unwrap();
        assert_eq!(reply.text, "user: hi");
        // The subrouter routes a request it cannot tell from Codex to Codex.
        assert_eq!(
            server.join().unwrap(),
            ("sk-real".to_owned(), "claude".to_owned())
        );
    }

    #[test]
    fn a_real_key_never_goes_to_the_subrouter() {
        let env = |k: &str| (k == "ANTHROPIC_API_KEY").then(|| "sk-real".to_string());
        assert_eq!(api_key(crate::DEFAULT_BASE_URL, env), crate::SUBROUTER_KEY);
        assert_eq!(api_key("https://api.anthropic.com", env), "sk-real");
        let explicit = |k: &str| (k == crate::API_KEY_ENV).then(|| "sk-mine".to_string());
        assert_eq!(api_key(crate::DEFAULT_BASE_URL, explicit), "sk-mine");
        assert_eq!(
            api_key("https://api.anthropic.com", |_| None),
            crate::SUBROUTER_KEY
        );
    }

    #[test]
    fn parse_joins_text_and_rejects_refusals_and_cut_replies() {
        let ok = json!({"stop_reason": "end_turn", "content": [
            {"type": "thinking", "thinking": "", "signature": "s"},
            {"type": "text", "text": "user: hi"}]});
        let reply = parse(ok.clone()).unwrap();
        assert_eq!(reply.text, "user: hi");
        assert_eq!(reply.content, ok["content"]);
        assert!(parse(json!({"stop_reason": "refusal", "content": []})).is_err());
        assert!(parse(json!({"stop_reason": "max_tokens", "content": []})).is_err());
        assert!(parse(json!({"error": "x"})).is_err());
    }
}
