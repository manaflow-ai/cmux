//! ACP → claude stdin: requests from the hub become stream-json lines.

use super::*;
use crate::no_panic::JsonExt;

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
                        let mut lines = vec![json!({
                            "type": "control_request",
                            "request_id": format!("init-{}", id),
                            "request": initialize_request()
                        })];
                        // Ultracode and fast mode survive a respawn on the live channel
                        // (no CLI flag); the answer ("boot-*") needs no reply.
                        let effort = self.effort.lock().await.clone();
                        if let Some(settings) = startup_settings(&effort, *self.fast.lock().await) {
                            lines.push(json!({"type": "control_request", "request_id": format!("boot-{}", id), "request": {"subtype": "apply_flag_settings", "settings": settings}}));
                        }
                        Outbound::Lines(lines)
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
                        let steer =
                            p.pointer("/_meta/steer").and_then(Value::as_bool) == Some(true);
                        if steer && !self.in_turn.load(Ordering::SeqCst) {
                            return Outbound::Reply(Message::err(
                                id.clone(),
                                RpcError::invalid_params(super::STEER_NO_TURN),
                            ));
                        }
                        // The hub's prompt for the turn Claude Code runs on steers it read after
                        // its turn ended: nothing to write (`carry.rs`).
                        if p.pointer("/_meta/carried").and_then(Value::as_bool) == Some(true) {
                            return self.adopt_carried(id).await;
                        }
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
                                        text.set("cache_control", marker.clone());
                                    }
                                    text
                                }
                                Some("image") => json!({"type": "image", "source": {"type": "base64", "media_type": b.get("mimeType").and_then(Value::as_str).unwrap_or("image/png"), "data": b.get("data").and_then(Value::as_str).unwrap_or("")}}),
                                Some("document") => {
                                    let mut document = json!({"type": "document", "source": {"type": "base64", "media_type": b.get("mimeType").and_then(Value::as_str).unwrap_or("application/pdf"), "data": b.get("data").and_then(Value::as_str).unwrap_or("")}});
                                    if let Some(name) = b.get("name").and_then(Value::as_str).filter(|name| !name.is_empty()) {
                                        document.set("title", json!(name));
                                    }
                                    document
                                }
                                Some("resource") => {
                                    let resource = b.get("resource").unwrap_or(b);
                                    let mime = resource.get("mimeType").and_then(Value::as_str).unwrap_or("");
                                    if mime == "application/pdf" {
                                        let mut document = json!({"type": "document", "source": {"type": "base64", "media_type": mime, "data": resource.get("blob").and_then(Value::as_str).unwrap_or("")}});
                                        if let Some(uri) = resource.get("uri").and_then(Value::as_str).filter(|uri| !uri.is_empty()) {
                                            document.set("title", json!(uri.strip_prefix("attachment://").unwrap_or(uri)));
                                        }
                                        document
                                    } else {
                                        json!({"type": "text", "text": resource_text(b)})
                                    }
                                }
                                Some("resource_link") => json!({"type": "text", "text": resource_text(b)}),
                                _ => json!({"type": "text", "text": b.get("text").and_then(Value::as_str).unwrap_or("")}),
                            })
                            .collect();
                        if steer {
                            // Claude Code reads it at its next tool boundary and echoes it; the
                            // echo answers this request. Another session's message may join the
                            // waiting line of others' (`steer_batch.rs`).
                            return self.write_steer(id, &p, content).await;
                        }
                        // Claude Code echoes the line with this uuid when it reads it.
                        let uuid = uuid::Uuid::now_v7().to_string();
                        let line = json!({"type": "user", "uuid": uuid, "message": {"role": "user", "content": content}});
                        // A new prompt of the hub's: no carried turn waits for one any more.
                        self.clear_carry().await;
                        self.in_turn.store(true, Ordering::SeqCst);
                        // A new prompt starts a fresh logical turn. A cancelled compaction may
                        // never emit its boundary/result, so clear its live compaction state here
                        // while retaining the separate late-result attribution marker.
                        self.compacting.store(false, Ordering::SeqCst);
                        self.turn_output.store(false, Ordering::SeqCst);
                        *self.prompt_echo.lock().await = Some(uuid);
                        self.cancelled.store(false, Ordering::SeqCst);
                        let mut pending = self.pending.lock().await;
                        *self.abandoned.lock().await = pending
                            .iter()
                            .filter(|(_, p)| matches!(p, Pending::Prompt))
                            .map(|(k, _)| k.clone())
                            .collect();
                        pending.insert(id.to_string(), Pending::Prompt);
                        Outbound::Lines(vec![line])
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
                                let val = super::model_id(&val);
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
                            "fast-mode" => {
                                let on = match val.as_str() {
                                    "on" => true,
                                    "off" => false,
                                    _ => {
                                        return Outbound::Reply(Message::err(
                                            id.clone(),
                                            RpcError::invalid_params("fast-mode must be on or off"),
                                        ));
                                    }
                                };
                                self.pending.lock().await.insert(
                                    id.to_string(),
                                    Pending::Control(Setting::Fast, val.clone()),
                                );
                                Outbound::Lines(vec![
                                    json!({"type": "control_request", "request_id": format!("ctl-{}", id), "request": {"subtype": "apply_flag_settings", "settings": {"fastMode": on}}}),
                                ])
                            }
                            "effort" => {
                                // Ultracode and Ultrathink were Reasoning choices once; a
                                // remembered pick of either still applies.
                                let legacy = matches!(val.as_str(), "ultracode" | "ultrathink");
                                if !legacy && !EFFORTS.iter().any(|(v, _)| *v == val) {
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
                                let effort = effort_value(&val).to_owned();
                                let settings = effort_settings(&effort);
                                self.pending.lock().await.insert(
                                    id.to_string(),
                                    Pending::Control(Setting::Effort, effort),
                                );
                                // Claude Code's live effort switch is the flag-settings channel.
                                Outbound::Lines(vec![
                                    json!({"type": "control_request", "request_id": format!("ctl-{}", id), "request": {"subtype": "apply_flag_settings", "settings": settings}}),
                                ])
                            }
                            ULTRACODE_OPTION => {
                                // On runs Ultracode (xhigh plus the setting); Off keeps xhigh.
                                let effort = match val.as_str() {
                                    "on" => ULTRACODE,
                                    "off" => "xhigh",
                                    _ => {
                                        return Outbound::Reply(Message::err(
                                            id.clone(),
                                            RpcError::invalid_params("ultracode must be on or off"),
                                        ));
                                    }
                                };
                                self.pending.lock().await.insert(
                                    id.to_string(),
                                    Pending::Control(Setting::Effort, effort.to_owned()),
                                );
                                Outbound::Lines(vec![
                                    json!({"type": "control_request", "request_id": format!("ctl-{}", id), "request": {"subtype": "apply_flag_settings", "settings": effort_settings(effort)}}),
                                ])
                            }
                            other => Outbound::Reply(Message::err(
                                id.clone(),
                                RpcError::invalid_params(format!("unknown config option {other}")),
                            )),
                        }
                    }
                    method::SESSION_SET_MODEL => {
                        let val = p.get("modelId").and_then(Value::as_str).unwrap_or("default");
                        let val = super::model_id(val);
                        self.pending
                            .lock()
                            .await
                            .insert(id.to_string(), Pending::Control(Setting::Model, val.clone()));
                        Outbound::Lines(vec![
                            json!({"type": "control_request", "request_id": format!("ctl-{}", id), "request": {"subtype": "set_model", "model": val}}),
                        ])
                    }
                    STOP_TASK => {
                        let task = p.get("taskId").and_then(Value::as_str).unwrap_or("");
                        if task.is_empty() {
                            return Outbound::Reply(Message::err(
                                id.clone(),
                                RpcError::invalid_params("taskId is required"),
                            ));
                        }
                        self.pending.lock().await.insert(id.to_string(), Pending::StopTask);
                        Outbound::Lines(vec![
                            json!({"type": "control_request", "request_id": format!("stop-{}", id), "request": {"subtype": "stop_task", "task_id": task}}),
                        ])
                    }
                    BACKGROUND_TASKS => {
                        let tool = p.get("toolCallId").and_then(Value::as_str);
                        let tool = tool.filter(|t| !t.is_empty());
                        // The foreground shells it may move are the person's once they
                        // move (`inbound.rs` `origin`).
                        let mut asked = Vec::new();
                        for (call, shell) in self.background_shells.lock().await.iter_mut() {
                            if !shell.background && tool.is_none_or(|t| t == call) {
                                shell.asked = true;
                                asked.push(call.clone());
                            }
                        }
                        // The hub stops waiting after `timeoutMs`, and the marks go then
                        // (`end_background_asks`); without one, at the turn's end.
                        let wait = p.get("timeoutMs").and_then(Value::as_u64);
                        let deadline = wait.and_then(|ms| {
                            std::time::Instant::now()
                                .checked_add(std::time::Duration::from_millis(ms))
                        });
                        self.pending
                            .lock()
                            .await
                            .insert(id.to_string(), Pending::Background(asked, deadline));
                        let mut request = json!({"subtype": "background_tasks"});
                        if let Some(tool) = tool {
                            request.set("tool_use_id", json!(tool));
                        }
                        Outbound::Lines(vec![
                            json!({"type": "control_request", "request_id": format!("bg-{}", id), "request": request}),
                        ])
                    }
                    MCP_RECONNECT => {
                        let server = p.get("server").and_then(Value::as_str).unwrap_or("");
                        if server.is_empty() {
                            return Outbound::Reply(Message::err(
                                id.clone(),
                                RpcError::invalid_params("server is required"),
                            ));
                        }
                        // Nothing kept here: its answer carries the ACP id (`mcp-<id>`), so an
                        // answer that never comes leaves nothing behind (the hub gives up on it).
                        Outbound::Lines(vec![
                            json!({"type": "control_request", "request_id": format!("mcp-{}", id), "request": {"subtype": "mcp_reconnect", "serverName": server}}),
                        ])
                    }
                    SIDE_QUESTION => {
                        // Check at the writer as well as the hub: the main turn
                        // may have ended after the hub selected the native path.
                        if !self.in_turn.load(Ordering::SeqCst) {
                            return Outbound::Reply(Message::err(
                                id.clone(),
                                RpcError::method_not_found(SIDE_QUESTION),
                            ));
                        }
                        let Some(question) = p
                            .get("question")
                            .and_then(Value::as_str)
                            .filter(|q| !q.trim().is_empty())
                        else {
                            return Outbound::Reply(Message::err(
                                id.clone(),
                                RpcError::invalid_params("question is required"),
                            ));
                        };
                        let history = match p.get("history") {
                            None | Some(Value::Null) => Value::Null,
                            Some(Value::Array(history)) => Value::Array(history.clone()),
                            Some(_) => {
                                return Outbound::Reply(Message::err(
                                    id.clone(),
                                    RpcError::invalid_params("history must be an array"),
                                ));
                            }
                        };
                        self.pending.lock().await.insert(id.to_string(), Pending::SideQuestion);
                        let mut request = json!({"subtype": "side_question", "question": question});
                        if !history.is_null() {
                            request.set("history", history);
                        }
                        Outbound::Lines(vec![json!({
                            "type": "control_request",
                            "request_id": format!("side-{}", id),
                            "request": request,
                        })])
                    }
                    method::MUX_SUBAGENT_STOP => self.subagent_stop(id, &p).await,
                    method::MUX_STEER_WITHDRAW => self.withdraw_steer(id, &p).await,
                    // Send now on a steer Claude Code has not read: its step stops, so it
                    // reads the steer; with none waiting, or while a subagent or a background
                    // shell runs (`interrupt_ends_work`), nothing stops.
                    method::MUX_STEP_NOW => {
                        if !self.in_turn.load(Ordering::SeqCst)
                            || self.steers.lock().await.is_empty()
                            || self.interrupt_ends_work().await
                        {
                            return Outbound::Reply(Message::ok(
                                id.clone(),
                                json!({"interrupted": false}),
                            ));
                        }
                        Outbound::Lines(vec![self.step_interrupt(Some(id))])
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
            Message::Notification { method: m, params, .. } => {
                if m == method::SESSION_CANCEL {
                    self.cancelled.store(true, Ordering::SeqCst);
                    if self.is_compacting()
                        || params
                            .as_ref()
                            .and_then(|p| p.pointer("/_meta/acpmux/compactionCancelled"))
                            == Some(&Value::Bool(true))
                    {
                        self.cancelled_compaction.store(true, Ordering::SeqCst);
                        self.fence_compaction_metadata();
                    }
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
                // The request and its form (an elicitation's) are taken under
                // the request map's lock, as a withdrawal takes them
                // (`elicitation.rs` cancel_control_request): one of the two wins,
                // and a withdrawn form never falls through to a tool reply.
                let (ctl_id, form) = {
                    let mut out = self.control_out.lock().await;
                    let ctl = out.iter().find(|(_, v)| **v == *id).map(|(k, _)| k.clone());
                    let Some(ctl_id) = ctl else { return Outbound::Lines(vec![]) };
                    out.remove(&ctl_id);
                    let form = self.elicitations.lock().await.remove(&ctl_id);
                    (ctl_id, form)
                };
                if let Some(form) = form {
                    let reply =
                        super::elicitation::reply(&ctl_id, &form, result.as_ref(), error.is_some());
                    return Outbound::Lines(vec![reply]);
                }
                let suggested = self.suggestions.lock().await.remove(&ctl_id);
                let asked = self.inputs.lock().await.remove(&ctl_id);
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
                    // allow / allow_always: pass the input back, as the hub
                    // answered it (AskUserQuestion) or else as Claude sent it.
                    // Claude Code refuses an allow without `updatedInput`
                    // (its reply schema: allow + updatedInput, or deny +
                    // message), so it is always there.
                    let updated = result
                        .as_ref()
                        .and_then(|r| r.pointer("/_meta/updatedInput"))
                        .filter(|v| v.is_object())
                        .cloned()
                        .or(asked.filter(Value::is_object))
                        .unwrap_or_else(|| json!({}));
                    let mut allow = json!({"behavior": "allow", "updatedInput": updated});
                    // "Allow for this session": Claude keeps the rules it
                    // suggested, for this session only (a suggestion may
                    // name a settings file; the option promises no more
                    // than the session), so it stops asking for the same
                    // call. Without this it asked again, like Allow once.
                    if selected == "allow_always"
                        && let Some(rules) = suggested
                    {
                        allow.set("updatedPermissions", rules);
                    }
                    allow
                };
                Outbound::Lines(vec![
                    json!({"type": "control_response", "response": {"subtype": "success", "request_id": ctl_id, "response": response}}),
                ])
            }
        }
    }

    /// Whether Claude Code's `interrupt` would end more than the current step: it kills every
    /// running subagent (background ones too) and every background shell, so Send now never
    /// writes it while one runs (cosmic-gray, 2026-10-21: a Send now killed two background
    /// subagents). The steer is then read at the next tool boundary instead.
    pub(super) async fn interrupt_ends_work(&self) -> bool {
        !self.subagents.lock().await.is_empty()
            || self.background_shells.lock().await.values().any(|shell| shell.background)
    }

    /// The interrupt that stops Claude Code's current step for a steer sent now: unlike a Stop
    /// it leaves `cancelled` unset, so the steer Claude Code reads after the step runs on in the
    /// same turn. Its ack answers `answer` (`MUX_STEP_NOW`), when one waits for it.
    pub(super) fn step_interrupt(&self, answer: Option<&Id>) -> Value {
        let request_id = match answer {
            Some(id) => format!("now-{id}"),
            None => format!("int-{}", self.next_control.fetch_add(1, Ordering::SeqCst)),
        };
        json!({"type": "control_request", "request_id": request_id, "request": {"subtype": "interrupt"}})
    }
}

/// An ACP `resource` or `resource_link` block as prompt text, so embedded
/// context reaches Claude instead of an empty string. A `file://` URI also
/// names its decoded path: the URI is percent-encoded (`Application%20Support`),
/// and Claude's tools open paths.
fn resource_text(b: &Value) -> String {
    let r = b.get("resource").unwrap_or(b);
    let uri = r.get("uri").and_then(Value::as_str).unwrap_or("");
    let path = reqwest::Url::parse(uri)
        .ok()
        .filter(|url| url.scheme() == "file")
        .and_then(|url| url.to_file_path().ok())
        .map(|path| format!(" path=\"{}\"", path.display().to_string().replace('"', "&quot;")))
        .unwrap_or_default();
    match r.get("text").and_then(Value::as_str) {
        Some(text) => format!("<resource uri=\"{uri}\"{path}>\n{text}\n</resource>"),
        None => format!("<resource uri=\"{uri}\"{path} />"),
    }
}

/// Claude Code's `initialize` control request.
///
/// `perTaskStopAffordance` says this client stops background tasks one by one (a background
/// process's kill, `_acpmux/process/kill`, and a subagent's stop, `_acpmux/subagent_stop`, both
/// Claude Code's `stop_task`). Without it Claude Code's headless `interrupt` (what Stop sends)
/// also kills every running background shell and background subagent, and marks each subagent
/// stopped by the user so it is never resumed. With it the interrupt stops only the turn, as Esc
/// does in the CLI, and background work runs on and reports when it ends (Leo, 2026-10-31:
/// "WELL THAT STOP BUTTON STOPPED LITERALLY EVERYTHING").
pub(super) fn initialize_request() -> Value {
    json!({
        "subtype": "initialize",
        "hooks": {},
        "supportedDialogKinds": ["ask_user_question", "exit_plan_mode", "permission"],
        "perTaskStopAffordance": true,
    })
}
