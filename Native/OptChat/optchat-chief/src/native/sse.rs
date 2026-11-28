//! Assembles a streamed Messages API response (server-sent events) into the
//! message a non-streaming call returns. The turn streams so that a long
//! reply never meets a total timeout; an idle read timeout catches a stalled
//! connection instead. Blocks are kept verbatim (thinking text and
//! signatures included): section 8 resends every model output as it came.

use serde_json::{Map, Value};

#[derive(Debug, Default)]
pub struct Assembler {
    message: Map<String, Value>,
    blocks: Vec<Value>,
    /// Streamed JSON input of each tool-use block, joined at its stop.
    partial: Vec<String>,
    done: bool,
    error: Option<String>,
}

impl Assembler {
    /// Feeds one SSE `data:` payload.
    pub fn feed(&mut self, data: &Value) {
        match data.get("type").and_then(Value::as_str).unwrap_or("") {
            "message_start" => {
                if let Some(Value::Object(message)) = data.get("message") {
                    self.message = message.clone();
                }
            }
            "content_block_start" => {
                let i = index(data);
                while self.blocks.len() <= i {
                    self.blocks.push(Value::Null);
                    self.partial.push(String::new());
                }
                self.blocks[i] = data.get("content_block").cloned().unwrap_or(Value::Null);
            }
            "content_block_delta" => {
                let i = index(data);
                let (Some(block), Some(delta)) = (self.blocks.get_mut(i), data.get("delta")) else {
                    return;
                };
                let text = |k: &str| delta.get(k).and_then(Value::as_str).unwrap_or("");
                match delta.get("type").and_then(Value::as_str).unwrap_or("") {
                    "text_delta" => append(block, "text", text("text")),
                    "thinking_delta" => append(block, "thinking", text("thinking")),
                    "signature_delta" => {
                        block["signature"] = Value::String(text("signature").into())
                    }
                    "input_json_delta" => self.partial[i].push_str(text("partial_json")),
                    "citations_delta" => {
                        if let Some(citation) = delta.get("citation") {
                            match block.get_mut("citations") {
                                Some(Value::Array(list)) => list.push(citation.clone()),
                                _ => block["citations"] = Value::Array(vec![citation.clone()]),
                            }
                        }
                    }
                    _ => {}
                }
            }
            "content_block_stop" => {
                let i = index(data);
                if let (Some(block), Some(json)) = (self.blocks.get_mut(i), self.partial.get(i))
                    && !json.is_empty()
                {
                    match serde_json::from_str::<Value>(json) {
                        Ok(input) => block["input"] = input,
                        Err(e) => {
                            self.error = Some(format!("a tool call's input is not JSON: {e}"))
                        }
                    }
                }
            }
            "message_delta" => {
                if let Some(Value::Object(delta)) = data.get("delta") {
                    for (k, v) in delta {
                        self.message.insert(k.clone(), v.clone());
                    }
                }
                if let Some(Value::Object(usage)) = data.get("usage") {
                    let entry = self
                        .message
                        .entry("usage")
                        .or_insert_with(|| Value::Object(Map::new()));
                    if let Value::Object(total) = entry {
                        for (k, v) in usage {
                            if !v.is_null() {
                                total.insert(k.clone(), v.clone());
                            }
                        }
                    }
                }
            }
            "message_stop" => self.done = true,
            "error" => {
                let error = data.get("error").unwrap_or(data);
                self.error = Some(
                    error
                        .get("message")
                        .and_then(Value::as_str)
                        .map_or_else(|| error.to_string(), str::to_owned),
                );
            }
            _ => {}
        }
    }

    /// The whole message, or why the stream failed.
    pub fn finish(mut self) -> Result<Value, String> {
        if let Some(e) = self.error {
            return Err(e);
        }
        if !self.done {
            return Err("the response stream ended before message_stop".into());
        }
        self.message
            .insert("content".into(), Value::Array(self.blocks));
        Ok(Value::Object(self.message))
    }
}

fn index(data: &Value) -> usize {
    data.get("index").and_then(Value::as_u64).unwrap_or(0) as usize
}

fn append(block: &mut Value, key: &str, text: &str) {
    let mut joined = block
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    joined.push_str(text);
    block[key] = Value::String(joined);
}

/// `read`, checking `stop` after every event: Ok(None) when it said so (the
/// partial message is dropped; nothing of it is logged or resent).
pub fn read_until(
    body: impl std::io::BufRead,
    stop: &dyn Fn() -> bool,
) -> Result<Option<Value>, String> {
    let mut assembler = Assembler::default();
    for line in body.lines() {
        let line = line.map_err(|e| format!("reading the response stream: {e}"))?;
        if let Some(data) = line.strip_prefix("data:") {
            let data: Value = serde_json::from_str(data.trim())
                .map_err(|e| format!("a response event is not JSON: {e}"))?;
            assembler.feed(&data);
            if stop() {
                return Ok(None);
            }
        }
    }
    assembler.finish().map(Some)
}
