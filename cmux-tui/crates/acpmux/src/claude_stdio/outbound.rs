//! ACP → claude stdin: requests from the hub become stream-json lines.

use super::*;

impl Translator {
    /// Translate one ACP request from the hub into zero or more lines for
    /// claude's stdin, and optionally an immediate ACP response.
    pub async fn outbound(&self, msg: &Message) -> Outbound {
        match msg {
            Message::Request { id, method: m, params } => {
                let p = params.clone().unwrap_or(Value::Null);
                match m.as_str() {
                    method::INITIALIZE => {
                        self.pending.lock().await.insert(id.to_string(), Pending::Initialize);
                        Outbound::Lines(vec![json!({
                            "type": "control_request",
                            "request_id": format!("init-{}", id),
                            "request": {"subtype": "initialize", "hooks": {}, "supportedDialogKinds": ["ask_user_question", "exit_plan_mode", "permission"]}
                        })])
                    }
                    method::SESSION_NEW | method::SESSION_LOAD => {
                        // The claude process already carries the session.
                        // Its id arrives in system/init on the first turn; for
                        // a resumed process we already know it.
                        let sid = self.session_id.lock().await.clone();
                        match sid {
                            Some(sid) => Outbound::Reply(Message::ok(
                                id.clone(),
                                json!({
                                    "sessionId": sid,
                                    "modes": self.modes_value().await,
                                    "configOptions": self.config_options_value().await,
                                }),
                            )),
                            None => {
                                // Ask claude for its init by sending initialize; system/init
                                // only appears on first prompt, so we synthesize the id
                                // lazily: reply with a placeholder that is corrected on init.
                                self.pending
                                    .lock()
                                    .await
                                    .insert(id.to_string(), Pending::NewOrLoad);
                                Outbound::Lines(vec![])
                            }
                        }
                    }
                    method::SESSION_PROMPT => {
                        let blocks =
                            p.get("prompt").and_then(Value::as_array).cloned().unwrap_or_default();
                        let content: Vec<Value> = blocks
                            .iter()
                            .map(|b| match b.get("type").and_then(Value::as_str) {
                                // `cache_control` passes through unchanged: Claude
                                // Code copies user blocks into the API request, so
                                // a client can place its own cache breakpoint.
                                Some("text") => {
                                    let mut text = json!({"type": "text", "text": b.get("text").and_then(Value::as_str).unwrap_or("")});
                                    if let Some(marker) = b.get("cache_control").filter(|m| !m.is_null()) {
                                        text["cache_control"] = marker.clone();
                                    }
                                    text
                                }
                                Some("image") => json!({"type": "image", "source": {"type": "base64", "media_type": b.get("mimeType").and_then(Value::as_str).unwrap_or("image/png"), "data": b.get("data").and_then(Value::as_str).unwrap_or("")}}),
                                Some("resource") | Some("resource_link") => {
                                    json!({"type": "text", "text": resource_text(b)})
                                }
                                _ => json!({"type": "text", "text": b.get("text").and_then(Value::as_str).unwrap_or("")}),
                            })
                            .collect();
                        self.in_turn.store(true, Ordering::SeqCst);
                        self.cancelled.store(false, Ordering::SeqCst);
                        self.pending.lock().await.insert(id.to_string(), Pending::Prompt);
                        Outbound::Lines(vec![
                            json!({"type": "user", "message": {"role": "user", "content": content}}),
                        ])
                    }
                    method::SESSION_SET_MODE => {
                        let mode =
                            p.get("modeId").and_then(Value::as_str).unwrap_or("default").to_owned();
                        self.pending
                            .lock()
                            .await
                            .insert(id.to_string(), Pending::Control(Setting::Mode, mode.clone()));
                        Outbound::Lines(vec![
                            json!({"type": "control_request", "request_id": format!("ctl-{}", id), "request": {"subtype": "set_permission_mode", "mode": mode}}),
                        ])
                    }
                    method::SESSION_SET_CONFIG_OPTION => {
                        let cid = p.get("configId").and_then(Value::as_str).unwrap_or("");
                        let val = p.get("value").and_then(Value::as_str).unwrap_or("").to_owned();
                        match cid {
                            "model" => {
                                self.pending.lock().await.insert(
                                    id.to_string(),
                                    Pending::Control(Setting::Model, val.clone()),
                                );
                                Outbound::Lines(vec![
                                    json!({"type": "control_request", "request_id": format!("ctl-{}", id), "request": {"subtype": "set_model", "model": val}}),
                                ])
                            }
                            "mode" => {
                                self.pending.lock().await.insert(
                                    id.to_string(),
                                    Pending::Control(Setting::Mode, val.clone()),
                                );
                                Outbound::Lines(vec![
                                    json!({"type": "control_request", "request_id": format!("ctl-{}", id), "request": {"subtype": "set_permission_mode", "mode": val}}),
                                ])
                            }
                            "effort" => {
                                if !EFFORTS.iter().any(|(v, _)| *v == val) {
                                    return Outbound::Reply(Message::err(
                                        id.clone(),
                                        RpcError::invalid_params(format!(
                                            "effort must be one of {}",
                                            EFFORTS
                                                .iter()
                                                .map(|(v, _)| *v)
                                                .collect::<Vec<_>>()
                                                .join(", ")
                                        )),
                                    ));
                                }
                                self.pending.lock().await.insert(
                                    id.to_string(),
                                    Pending::Control(Setting::Effort, val.clone()),
                                );
                                // Claude Code's live effort switch is the flag-settings channel.
                                let level = if val == "default" { "auto".to_owned() } else { val };
                                Outbound::Lines(vec![
                                    json!({"type": "control_request", "request_id": format!("ctl-{}", id), "request": {"subtype": "apply_flag_settings", "settings": {"effortLevel": level}}}),
                                ])
                            }
                            other => Outbound::Reply(Message::err(
                                id.clone(),
                                RpcError::invalid_params(format!("unknown config option {other}")),
                            )),
                        }
                    }
                    method::SESSION_SET_MODEL => {
                        let val = p
                            .get("modelId")
                            .and_then(Value::as_str)
                            .unwrap_or("default")
                            .to_owned();
                        self.pending
                            .lock()
                            .await
                            .insert(id.to_string(), Pending::Control(Setting::Model, val.clone()));
                        Outbound::Lines(vec![
                            json!({"type": "control_request", "request_id": format!("ctl-{}", id), "request": {"subtype": "set_model", "model": val}}),
                        ])
                    }
                    method::SESSION_FORK => {
                        // Forking needs a new process (--fork-session); the hub does that.
                        Outbound::Reply(Message::err(
                            id.clone(),
                            RpcError::new(-32002, "fork is handled by respawn"),
                        ))
                    }
                    other => {
                        Outbound::Reply(Message::err(id.clone(), RpcError::method_not_found(other)))
                    }
                }
            }
            Message::Notification { method: m, .. } => {
                if m == method::SESSION_CANCEL {
                    self.cancelled.store(true, Ordering::SeqCst);
                    let n = self.next_control.fetch_add(1, Ordering::SeqCst);
                    Outbound::Lines(vec![
                        json!({"type": "control_request", "request_id": format!("int-{n}"), "request": {"subtype": "interrupt"}}),
                    ])
                } else {
                    Outbound::Lines(vec![])
                }
            }
            Message::Response { id, result, error } => {
                // The hub answered a permission request we raised.
                let ctl = self
                    .control_out
                    .lock()
                    .await
                    .iter()
                    .find(|(_, v)| **v == *id)
                    .map(|(k, _)| k.clone());
                let Some(ctl_id) = ctl else { return Outbound::Lines(vec![]) };
                self.control_out.lock().await.remove(&ctl_id);
                let outcome =
                    result.as_ref().and_then(|r| r.get("outcome")).cloned().unwrap_or(Value::Null);
                let selected = outcome.get("optionId").and_then(Value::as_str).unwrap_or("");
                // Only the allow options we advertised grant the tool; a
                // missing, rejected, or unknown option denies it.
                let allowed = error.is_none()
                    && outcome.get("outcome").and_then(Value::as_str) != Some("cancelled")
                    && matches!(selected, "allow_once" | "allow_always");
                let response = if !allowed {
                    json!({"behavior": "deny", "message": "The user rejected this action."})
                } else {
                    // allow / allow_always: pass the (possibly answered) input back.
                    let updated =
                        result.as_ref().and_then(|r| r.pointer("/_meta/updatedInput")).cloned();
                    match updated {
                        Some(u) => json!({"behavior": "allow", "updatedInput": u}),
                        None => json!({"behavior": "allow"}),
                    }
                };
                Outbound::Lines(vec![
                    json!({"type": "control_response", "response": {"subtype": "success", "request_id": ctl_id, "response": response}}),
                ])
            }
        }
    }
}

/// An ACP `resource` or `resource_link` block as prompt text, so embedded
/// context reaches Claude instead of an empty string.
fn resource_text(b: &Value) -> String {
    let r = b.get("resource").unwrap_or(b);
    let uri = r.get("uri").and_then(Value::as_str).unwrap_or("");
    match r.get("text").and_then(Value::as_str) {
        Some(text) => format!("<resource uri=\"{uri}\">\n{text}\n</resource>"),
        None => format!("<resource uri=\"{uri}\" />"),
    }
}
