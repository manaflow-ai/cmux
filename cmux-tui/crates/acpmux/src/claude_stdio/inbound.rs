//! claude stdout → ACP: stream-json lines become session updates and replies.

use super::*;

impl Translator {
    /// Translate one line from claude's stdout into ACP messages for the hub.
    pub async fn inbound(&self, line: &Value) -> Vec<Message> {
        let kind = line.get("type").and_then(Value::as_str).unwrap_or("");
        let sub = line.get("subtype").and_then(Value::as_str).unwrap_or("");
        let sid = self.acp_session_id.clone();
        let upd = |u: Value| {
            Message::notification(method::SESSION_UPDATE, json!({"sessionId": sid, "update": u}))
        };
        let mut out = Vec::new();
        match kind {
            "system" if sub == "init" => {
                if let Some(s) = line.get("session_id").and_then(Value::as_str) {
                    *self.session_id.lock().await = Some(s.to_owned());
                }
                if let Some(m) = line.get("model").and_then(Value::as_str) {
                    *self.model.lock().await = m.to_owned();
                }
                if let Some(m) = line.get("permissionMode").and_then(Value::as_str) {
                    *self.mode.lock().await = m.to_owned();
                }
                // Answer a pending session/new or session/load now that we have the id.
                let waiting: Vec<String> = self
                    .pending
                    .lock()
                    .await
                    .iter()
                    .filter(|(_, p)| matches!(p, Pending::NewOrLoad))
                    .map(|(k, _)| k.clone())
                    .collect();
                for k in waiting {
                    self.pending.lock().await.remove(&k);
                    let id: Id = serde_json::from_str(&k).unwrap_or(Value::String(k.clone()));
                    out.push(Message::ok(
                        id,
                        json!({
                            "sessionId": self.session_id.lock().await.clone(),
                            "modes": self.modes_value().await,
                            "configOptions": self.config_options_value().await,
                        }),
                    ));
                }
                out.push(upd(json!({"sessionUpdate": "session_info_update", "title": Value::Null, "_meta": {"claude": {"tools": line.get("tools"), "mcp_servers": line.get("mcp_servers"), "model": line.get("model")}}})));
                out.push(upd(json!({"sessionUpdate": "config_option_update", "configOptions": self.config_options_value().await})));
            }
            "stream_event" => {
                let ev = line.get("event").cloned().unwrap_or(Value::Null);
                match ev.get("type").and_then(Value::as_str) {
                    Some("content_block_delta") => {
                        let d = ev.get("delta").cloned().unwrap_or(Value::Null);
                        match d.get("type").and_then(Value::as_str) {
                            Some("text_delta") => out.push(upd(json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": d.get("text").and_then(Value::as_str).unwrap_or("")}}))),
                            Some("thinking_delta") => {
                                let t = d.get("thinking").and_then(Value::as_str).unwrap_or("");
                                if !t.is_empty() {
                                    out.push(upd(json!({"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": t}})));
                                }
                            }
                            _ => {}
                        }
                    }
                    Some("message_delta") => {
                        if let Some(u) = ev.get("usage") {
                            let used = u.get("input_tokens").and_then(Value::as_u64).unwrap_or(0)
                                + u.get("cache_read_input_tokens")
                                    .and_then(Value::as_u64)
                                    .unwrap_or(0)
                                + u.get("cache_creation_input_tokens")
                                    .and_then(Value::as_u64)
                                    .unwrap_or(0)
                                + u.get("output_tokens").and_then(Value::as_u64).unwrap_or(0);
                            out.push(upd(
                                json!({"sessionUpdate": "usage_update", "used": used, "size": 0}),
                            ));
                        }
                    }
                    _ => {}
                }
            }
            "assistant" => {
                for c in line
                    .pointer("/message/content")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default()
                {
                    if c.get("type").and_then(Value::as_str) == Some("tool_use") {
                        let name = c.get("name").and_then(Value::as_str).unwrap_or("tool");
                        let input = c.get("input").cloned().unwrap_or(Value::Null);
                        out.push(upd(json!({
                            "sessionUpdate": "tool_call",
                            "toolCallId": c.get("id"),
                            "title": tool_title(name, &input),
                            "kind": tool_kind(name),
                            "status": "in_progress",
                            "rawInput": input,
                            "_meta": {"claude": {"tool": name}}
                        })));
                    }
                }
            }
            "user" => {
                for c in line
                    .pointer("/message/content")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default()
                {
                    if c.get("type").and_then(Value::as_str) == Some("tool_result") {
                        let text = match c.get("content") {
                            Some(Value::String(s)) => s.clone(),
                            Some(Value::Array(a)) => a
                                .iter()
                                .filter_map(|x| x.get("text").and_then(Value::as_str))
                                .collect::<Vec<_>>()
                                .join("\n"),
                            _ => String::new(),
                        };
                        let is_err = c.get("is_error").and_then(Value::as_bool).unwrap_or(false);
                        out.push(upd(json!({
                            "sessionUpdate": "tool_call_update",
                            "toolCallId": c.get("tool_use_id"),
                            "status": if is_err { "failed" } else { "completed" },
                            "content": [{"type": "content", "content": {"type": "text", "text": text}}],
                        })));
                    }
                }
            }
            "control_request" => {
                let req = line.get("request").cloned().unwrap_or(Value::Null);
                let rid = line.get("request_id").and_then(Value::as_str).unwrap_or("").to_owned();
                match req.get("subtype").and_then(Value::as_str) {
                    Some("can_use_tool") => {
                        let name = req.get("tool_name").and_then(Value::as_str).unwrap_or("tool");
                        let input = req.get("input").cloned().unwrap_or(Value::Null);
                        let n = self.next_control.fetch_add(1, Ordering::SeqCst);
                        let acp_id = Value::from(1_000_000 + n);
                        self.control_out.lock().await.insert(rid.clone(), acp_id.clone());
                        let interactive = req
                            .get("requires_user_interaction")
                            .and_then(Value::as_bool)
                            .unwrap_or(false);
                        let mut options = vec![
                            json!({"optionId": "allow_once", "name": if interactive { "Answer" } else { "Allow" }, "kind": "allow_once"}),
                        ];
                        if !interactive {
                            options.push(json!({"optionId": "allow_always", "name": "Allow for this session", "kind": "allow_always"}));
                        }
                        options.push(json!({"optionId": "reject_once", "name": "Reject", "kind": "reject_once"}));
                        out.push(Message::request(acp_id, method::SESSION_REQUEST_PERMISSION, json!({
                            "sessionId": sid,
                            "toolCall": {
                                "toolCallId": req.get("tool_use_id"),
                                "title": tool_title(name, &input),
                                "kind": tool_kind(name),
                                "status": "pending",
                                "rawInput": input,
                                "_meta": {"claude": {"tool": name, "interactive": interactive, "suggestions": req.get("permission_suggestions"), "description": req.get("description")}}
                            },
                            "options": options,
                        })));
                    }
                    other => {
                        // Anything else (hook_callback, mcp_message) is declined
                        // with an error response, so claude does not wait on it.
                        let other = other.unwrap_or("?");
                        tracing::debug!("claude control_request {other} declined");
                        self.stdin_replies.lock().await.push(json!({
                            "type": "control_response",
                            "response": {
                                "subtype": "error",
                                "request_id": rid,
                                "error": format!("acpmux does not support control request {other}"),
                            }
                        }));
                    }
                }
            }
            "control_response" => {
                let resp = line.get("response").cloned().unwrap_or(Value::Null);
                let rid = resp.get("request_id").and_then(Value::as_str).unwrap_or("");
                let ok = resp.get("subtype").and_then(Value::as_str) == Some("success");
                let inner = resp.get("response").cloned().unwrap_or(Value::Null);
                if let Some(acp) = rid.strip_prefix("init-") {
                    let id: Id = serde_json::from_str(acp).unwrap_or(Value::String(acp.to_owned()));
                    self.pending.lock().await.remove(&id.to_string());
                    if !ok {
                        out.push(Message::err(
                            id,
                            RpcError::internal(
                                resp.get("error")
                                    .and_then(Value::as_str)
                                    .unwrap_or("claude initialize failed"),
                            ),
                        ));
                        return out;
                    }
                    if let Some(cmds) = inner.get("commands").and_then(Value::as_array) {
                        *self.slash_commands.lock().await = cmds.clone();
                    }
                    out.push(Message::ok(id, json!({
                        "protocolVersion": 1,
                        "agentInfo": {"name": AGENT_NAME, "title": "Claude Code", "version": inner.get("version").cloned().unwrap_or(Value::Null)},
                        "agentCapabilities": {"loadSession": true, "promptCapabilities": {"image": true, "embeddedContext": true}, "sessionCapabilities": {"fork": {}, "list": {}, "close": {}}},
                        "authMethods": [],
                        "_meta": {"steering": {"supported": false}, "claude": {"commands": inner.get("commands"), "capabilities": inner.get("capabilities")}}
                    })));
                    if let Some(cmds) = inner.get("commands").and_then(Value::as_array) {
                        let list: Vec<Value> = cmds.iter().map(|c| json!({"name": c.get("name"), "description": c.get("description")})).collect();
                        out.push(upd(json!({"sessionUpdate": "available_commands_update", "availableCommands": list})));
                    }
                } else if let Some(acp) = rid.strip_prefix("ctl-") {
                    let id: Id = serde_json::from_str(acp).unwrap_or(Value::String(acp.to_owned()));
                    let change = self.pending.lock().await.remove(&id.to_string());
                    if ok {
                        // The cached value changes only once claude accepted it.
                        if let Some(Pending::Control(setting, value)) = change {
                            match setting {
                                Setting::Mode => *self.mode.lock().await = value,
                                Setting::Model => *self.model.lock().await = value,
                                Setting::Effort => *self.effort.lock().await = value,
                            }
                        }
                        let mode = self.mode.lock().await.clone();
                        out.push(upd(
                            json!({"sessionUpdate": "current_mode_update", "currentModeId": mode}),
                        ));
                        out.push(Message::ok(id, json!({"configOptions": self.config_options_value().await, "currentModeId": mode})));
                    } else {
                        out.push(Message::err(
                            id,
                            RpcError::internal(
                                resp.get("error")
                                    .and_then(Value::as_str)
                                    .unwrap_or("control request failed"),
                            ),
                        ));
                    }
                }
                // "int-*" acks need no reply; the result message ends the turn.
            }
            "result" => {
                // `is_error` with a success subtype is how Claude reports a
                // usage limit or an API refusal: a failed turn, not a reply.
                let is_error = line.get("is_error").and_then(Value::as_bool).unwrap_or(false);
                // A resumed process emits one empty result (num_turns 0, no
                // API time) right after its system/init, before the real
                // turn. That is startup noise, not the end of our prompt; a
                // failed result is never noise.
                let startup_noise = sub == "success"
                    && !is_error
                    && line.get("num_turns").and_then(Value::as_u64) == Some(0)
                    && line.get("duration_api_ms").and_then(Value::as_u64) == Some(0)
                    && !self.cancelled.load(Ordering::SeqCst);
                if startup_noise {
                    return out;
                }
                self.in_turn.store(false, Ordering::SeqCst);
                let waiting: Vec<String> = self
                    .pending
                    .lock()
                    .await
                    .iter()
                    .filter(|(_, p)| matches!(p, Pending::Prompt))
                    .map(|(k, _)| k.clone())
                    .collect();
                let cancelled = self.cancelled.swap(false, Ordering::SeqCst);
                let stop = if cancelled
                    || (sub == "error_during_execution"
                        && line.get("result").map(Value::is_null).unwrap_or(true))
                {
                    "cancelled"
                } else if sub == "error_max_turns" {
                    "max_turn_requests"
                } else if sub.starts_with("error") {
                    "refusal"
                } else {
                    "end_turn"
                };
                for k in waiting {
                    self.pending.lock().await.remove(&k);
                    let id: Id = serde_json::from_str(&k).unwrap_or(Value::String(k.clone()));
                    // Hitting the turn limit is a normal stop, not a failure.
                    if (sub.starts_with("error") || is_error)
                        && !cancelled
                        && stop != "cancelled"
                        && stop != "max_turn_requests"
                    {
                        out.push(Message::err(
                            id,
                            RpcError::internal(
                                line.get("result").and_then(Value::as_str).unwrap_or(sub),
                            ),
                        ));
                    } else {
                        out.push(Message::ok(id, json!({"stopReason": stop, "_meta": {"claude": {"subtype": sub, "cost_usd": line.get("total_cost_usd"), "usage": line.get("usage"), "num_turns": line.get("num_turns")}}})));
                    }
                }
            }
            _ => {}
        }
        out
    }
}
