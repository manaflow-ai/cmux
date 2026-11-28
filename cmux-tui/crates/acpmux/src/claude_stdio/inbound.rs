//! claude stdout → ACP: stream-json lines become session updates and replies.

use super::*;

impl Translator {
    /// Translate one line from claude's stdout into ACP messages for the hub.
    pub async fn inbound(&self, line: &Value) -> Vec<Message> {
        let kind = line.get("type").and_then(Value::as_str).unwrap_or("");
        let sub = line.get("subtype").and_then(Value::as_str).unwrap_or("");
        // A subagent's lines carry its Agent tool call's id and stream under
        // its own session (ACP draft #1992).
        let parent = line.get("parent_tool_use_id").and_then(Value::as_str);
        let mut sid = self.acp_session_id.clone();
        if let Some(p) = parent
            && let Some(child) = self.subagents.lock().await.get(p)
        {
            sid = child.clone();
        }
        let upd = |u: Value| {
            Message::notification(method::SESSION_UPDATE, json!({"sessionId": sid, "update": u}))
        };
        let mut out = Vec::new();
        // A local slash command answers with a synthetic assistant line, or
        // `/clear` with its reset, before its result (Claude Code 2.1.299).
        if kind == "assistant" || (kind == "system" && sub == "conversation_reset") {
            self.turn_output.store(true, Ordering::SeqCst);
        }
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
                out.push(upd(json!({"sessionUpdate": "session_info_update", "title": Value::Null, "_meta": {"claude": {"tools": line.get("tools"), "mcp_servers": line.get("mcp_servers"), "plugins": line.get("plugins"), "skills": line.get("skills"), "model": line.get("model"), "version": line.get("claude_code_version")}}})));
                out.push(upd(json!({"sessionUpdate": "config_option_update", "configOptions": self.config_options_value().await})));
                // Claude Code names its skills only here (every turn): their
                // commands are sent again, tagged, when that changes the list.
                if let Some(skills) = line.get("skills").and_then(Value::as_array) {
                    *self.skills.lock().await =
                        skills.iter().filter_map(Value::as_str).map(str::to_owned).collect();
                    if let Some(u) = self.commands_update(false).await {
                        out.push(upd(u));
                    }
                }
            }
            // Claude Code's whole command list after a change mid-session
            // (skills found in a subdirectory, a reload): it replaces ours.
            "system" if sub == "commands_changed" => {
                if let Some(cmds) = line.get("commands").and_then(Value::as_array) {
                    *self.slash_commands.lock().await = cmds.clone();
                    if let Some(u) = self.commands_update(false).await {
                        out.push(upd(u));
                    }
                }
            }
            "stream_event" => {
                let ev = line.get("event").cloned().unwrap_or(Value::Null);
                match ev.get("type").and_then(Value::as_str) {
                    Some("message_start") => {
                        if let Some(id) = ev.pointer("/message/id").and_then(Value::as_str) {
                            self.message_ids
                                .lock()
                                .await
                                .insert(parent.unwrap_or("").to_owned(), id.to_owned());
                        }
                        if parent.is_none()
                            && let Some(m) = ev.pointer("/message/model").and_then(Value::as_str)
                        {
                            *self.loop_model.lock().await = m.to_owned();
                        }
                    }
                    Some("content_block_delta") => {
                        let d = ev.get("delta").cloned().unwrap_or(Value::Null);
                        match d.get("type").and_then(Value::as_str) {
                            Some("text_delta") => {
                                let mut chunk = json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": d.get("text").and_then(Value::as_str).unwrap_or("")}});
                                if let Some(id) =
                                    self.message_ids.lock().await.get(parent.unwrap_or(""))
                                {
                                    chunk["messageId"] = json!(id);
                                }
                                out.push(upd(chunk));
                            }
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
                            // A subagent's usage is its own context, not the chat's.
                            if parent.is_none() {
                                self.context_used.store(used, Ordering::SeqCst);
                            }
                            let size = self.context_window.load(Ordering::SeqCst);
                            out.push(upd(
                                json!({"sessionUpdate": "usage_update", "used": used, "size": size}),
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
                        // A subagent comes before its Agent tool call, so a client
                        // that draws subagents can leave the call out.
                        if let ("Task" | "Agent" | "Workflow", Some(id)) =
                            (name, c.get("id").and_then(Value::as_str))
                        {
                            out.push(upd(self.spawn_subagent(id, name, &input).await));
                        }
                        // The todo list is the turn's ACP plan (cx-ncc.80): clients
                        // draw it as a checklist.
                        if name == "TodoWrite"
                            && let Some(plan) = todo_plan(&input)
                        {
                            out.push(upd(plan));
                        }
                        // Every shell, so one moved to the background later
                        // keeps its command (cx-ncc.84).
                        if name == "Bash"
                            && let Some(id) = c.get("id").and_then(Value::as_str)
                        {
                            let command =
                                input.get("command").and_then(Value::as_str).unwrap_or("");
                            let shell = BackgroundShell {
                                sid: sid.clone(),
                                command: command.to_owned(),
                                task: None,
                                background: input.get("run_in_background")
                                    == Some(&Value::Bool(true)),
                                launched: input.get("run_in_background")
                                    == Some(&Value::Bool(true)),
                                announced: false,
                                output: None,
                            };
                            self.background_shells.lock().await.insert(id.to_owned(), shell);
                        }
                        let mut call = json!({
                            "sessionUpdate": "tool_call",
                            "toolCallId": c.get("id"),
                            "title": tool_title(name, &input),
                            "kind": tool_kind(name),
                            "status": "in_progress",
                            "rawInput": input,
                            "_meta": {"claude": {"tool": name}}
                        });
                        with_edit(&mut call, name, &input);
                        if let (Some(diffs), Some(id)) =
                            (call.get("content"), c.get("id").and_then(Value::as_str))
                        {
                            self.edits.lock().await.insert(id.to_owned(), diffs.clone());
                        }
                        out.push(upd(call));
                    }
                }
            }
            // Claude Code's echo of a user line it read (`--replay-user-messages`):
            // first the turn's prompt, then each steered line in order.
            // Matched by the line's uuid; an echo of anything else is ignored.
            "user" if line.get("isReplay").and_then(Value::as_bool) == Some(true) => {
                let uuid = line.get("uuid").and_then(Value::as_str).unwrap_or("");
                let mut prompt = self.prompt_echo.lock().await;
                if !uuid.is_empty() && prompt.as_deref() == Some(uuid) {
                    *prompt = None;
                    // What follows is this prompt's output, not a stopped turn's tail.
                    self.turn_output.store(false, Ordering::SeqCst);
                    return out;
                }
                drop(prompt);
                let mut steers = self.steers.lock().await;
                if let Some(at) = steers.iter().position(|(u, _)| !uuid.is_empty() && u == uuid)
                    && let Some((_, k)) = steers.remove(at)
                {
                    drop(steers);
                    let id: Id = serde_json::from_str(&k).unwrap_or(Value::String(k));
                    out.push(Message::ok(id, json!({"stopReason": "steered"})));
                    // A turn the client stopped: Claude Code runs a line it
                    // read after the stop as one more turn, so that turn is
                    // stopped too, and the prompt ends cancelled.
                    if self.cancelled.load(Ordering::SeqCst) {
                        let n = self.next_control.fetch_add(1, Ordering::SeqCst);
                        self.stdin_replies.lock().await.push(json!({"type": "control_request", "request_id": format!("int-{n}"), "request": {"subtype": "interrupt"}}));
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
                        let tool = c.get("tool_use_id").and_then(Value::as_str).unwrap_or("");
                        // A failed launch never ran; a foreground shell no task
                        // named is done.
                        {
                            let mut shells = self.background_shells.lock().await;
                            if shells
                                .get(tool)
                                .is_some_and(|s| is_err || (!s.background && s.task.is_none()))
                            {
                                shells.remove(tool);
                            }
                        }
                        // ACP content replaces the call's content: a finished edit
                        // keeps its diff, and a failed one says why.
                        let content = match self.edits.lock().await.remove(tool) {
                            Some(diffs) if !is_err => diffs,
                            _ => {
                                json!([{"type": "content", "content": {"type": "text", "text": text}}])
                            }
                        };
                        out.push(upd(json!({
                            "sessionUpdate": "tool_call_update",
                            "toolCallId": c.get("tool_use_id"),
                            "status": if is_err { "failed" } else { "completed" },
                            "content": content,
                        })));
                        if let Some(update) = self.workflow_launched(tool, is_err, line).await {
                            out.push(upd(update));
                        }
                        // A background subagent's result is only its launch.
                        if self.background_subagents.lock().await.contains(tool) {
                            continue;
                        }
                        if let Some(child) = self.subagents.lock().await.remove(tool) {
                            self.subagent_tasks.lock().await.retain(|_, t| *t != tool);
                            out.push(upd(json!({
                                "sessionUpdate": "subagent_state_update",
                                "subagentSessionId": child,
                                "state": if is_err { "failed" } else { "completed" },
                            })));
                        }
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
                        self.inputs.lock().await.insert(rid.clone(), input.clone());
                        // "Allow for this session" is offered only with a
                        // rule Claude can keep (with #20407): without one it
                        // would be Allow once under another name.
                        let lasting = req.get("permission_suggestions").and_then(session_rules);
                        let interactive = req
                            .get("requires_user_interaction")
                            .and_then(Value::as_bool)
                            .unwrap_or(false);
                        let mut options = vec![
                            json!({"optionId": "allow_once", "name": if interactive { "Answer" } else { "Allow" }, "kind": "allow_once"}),
                        ];
                        if !interactive && let Some(rules) = lasting {
                            self.suggestions.lock().await.insert(rid.clone(), rules);
                            options.push(json!({"optionId": "allow_always", "name": "Allow for this session", "kind": "allow_always"}));
                        }
                        options.push(json!({"optionId": "reject_once", "name": "Reject", "kind": "reject_once"}));
                        let mut call = json!({
                            "toolCallId": req.get("tool_use_id"),
                            "title": tool_title(name, &input),
                            "kind": tool_kind(name),
                            "status": "pending",
                            "rawInput": input,
                            "_meta": {"claude": {"tool": name, "interactive": interactive, "suggestions": req.get("permission_suggestions"), "description": req.get("description")}}
                        });
                        with_edit(&mut call, name, &input);
                        out.push(Message::request(
                            acp_id,
                            method::SESSION_REQUEST_PERMISSION,
                            json!({
                                "sessionId": sid,
                                "toolCall": call,
                                "options": options,
                            }),
                        ));
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
                        "_meta": {"steering": {"supported": true}, "claude": {"commands": inner.get("commands"), "capabilities": inner.get("capabilities")}}
                    })));
                    if inner.get("commands").is_some_and(Value::is_array)
                        && let Some(u) = self.commands_update(true).await
                    {
                        out.push(upd(u));
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
                                Setting::Fast => *self.fast.lock().await = value == "on",
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
                } else if let Some(acp) = rid.strip_prefix("stop-") {
                    // A stop_task's answer (`subagent_stop`, `STOP_TASK`); the
                    // task's end is its own event.
                    let id: Id = serde_json::from_str(acp).unwrap_or(Value::String(acp.to_owned()));
                    self.pending.lock().await.remove(&id.to_string());
                    out.push(super::workflows::stop_reply(acp, ok, &resp));
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
                // failed result is never noise. A local slash command's result
                // looks the same but follows its output, and ends the prompt.
                let startup_noise = sub == "success"
                    && !is_error
                    && !self.turn_output.load(Ordering::SeqCst)
                    && line.get("num_turns").and_then(Value::as_u64) == Some(0)
                    && line.get("duration_api_ms").and_then(Value::as_u64) == Some(0)
                    && !self.cancelled.load(Ordering::SeqCst);
                if startup_noise {
                    return out;
                }
                // The window Claude Code reports for the chat's model: the pane's
                // context ring fills by used over it (cx-ncc.79).
                if let Some(window) = self.result_context_window(line).await {
                    self.context_window.store(window, Ordering::SeqCst);
                    let used = self.context_used.load(Ordering::SeqCst);
                    if used > 0 && parent.is_none() {
                        out.push(upd(
                            json!({"sessionUpdate": "usage_update", "used": used, "size": window}),
                        ));
                    }
                }
                // The result of a turn acpmux already ended (a Stop Claude Code
                // answered late): it ends only the abandoned prompts. It comes
                // before Claude Code read the next prompt, or after its echo but
                // before any of its output (cx-he737). A result after the next
                // prompt's own output is that prompt's: the stopped turn never
                // had one, and it ends them all.
                let abandoned = std::mem::take(&mut *self.abandoned.lock().await);
                let next_unread = self.prompt_echo.lock().await.is_some();
                if !abandoned.is_empty()
                    && (next_unread || !self.turn_output.load(Ordering::SeqCst))
                {
                    for k in abandoned {
                        self.pending.lock().await.remove(&k);
                        let id: Id = serde_json::from_str(&k).unwrap_or(Value::String(k));
                        out.push(Message::ok(id, json!({"stopReason": "cancelled"})));
                    }
                    return out;
                }
                // A steered line Claude Code has not read yet: it runs it as
                // one more turn of this prompt, whose result ends it (when
                // echoes come at all; without them the steer fails below).
                // A stop stays in force for that turn (`cancelled` is kept).
                let unread = !self.steers.lock().await.is_empty();
                if unread && self.prompt_echo.lock().await.is_none() {
                    return out;
                }
                out.extend(self.fail_steers().await);
                *self.prompt_echo.lock().await = None;
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
                // An interrupted turn stops its foreground subagents;
                // background ones run on until their task_notification.
                if stop == "cancelled" {
                    let background = self.background_subagents.lock().await;
                    let mut subagents = self.subagents.lock().await;
                    let mut ended: Vec<String> = subagents
                        .iter()
                        .filter(|(tool, _)| !background.contains(*tool))
                        .map(|(_, child)| child.clone())
                        .collect();
                    subagents.retain(|tool, _| background.contains(tool));
                    drop((subagents, background));
                    ended.sort();
                    for child in ended {
                        out.push(upd(json!({
                            "sessionUpdate": "subagent_state_update",
                            "subagentSessionId": child,
                            "state": "cancelled",
                        })));
                    }
                }
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
            // A compaction left the context smaller than the last message held:
            // the ring waits for the next message rather than refill (cx-ncc.79).
            "system" if sub == "compact_boundary" && parent.is_none() => {
                let after = line.pointer("/compact_metadata/post_tokens").and_then(Value::as_u64);
                self.context_used.store(after.unwrap_or(0), Ordering::SeqCst);
            }
            "system" if sub.starts_with("task_") => {
                if let Some(update) = self.background_shell_task(sub, line, &sid).await {
                    out.push(update);
                }
                if let Some(progress) = self.subagent_progress(sub, line).await {
                    out.push(upd(progress));
                }
                if let Some(ended) = self.subagent_task(sub, line).await {
                    out.push(upd(ended));
                }
            }
            _ => {}
        }
        out
    }

    /// A result's context window for the chat's model (`modelUsage`, keyed by
    /// model id and cumulative over the session): the entry of the model the
    /// main loop last ran, else of the configured one. None keeps the last
    /// window: another entry may be a subagent's or an earlier model's.
    async fn result_context_window(&self, line: &Value) -> Option<u64> {
        let usage = line.get("modelUsage")?.as_object()?;
        let window =
            |entry: &Value| entry.get("contextWindow").and_then(Value::as_u64).filter(|w| *w > 0);
        let looped = self.loop_model.lock().await.clone();
        let configured = self.model.lock().await.clone();
        usage.get(&looped).and_then(window).or_else(|| usage.get(&configured).and_then(window))
    }

    /// Claude's task events for a shell (cx-ncc.84): a `local_bash`
    /// task_started names its task and says whether it runs in the background,
    /// a task_updated may move it there (either way a `running`
    /// `background_task_update` goes out once), and a background one's
    /// `task_notification`, or a task_updated whose patch says it was stopped
    /// (Claude Code may send no notification after `stop_task`), returns a
    /// `background_task_update` saying how it ended (`completed`, `failed`
    /// or `stopped`), with Claude's reason or summary when it gave one. The
    /// update goes to the session the shell's Bash call ran in, a
    /// subagent's too. A shell ends once: a later end finds no shell.
    async fn background_shell_task(&self, sub: &str, line: &Value, sid: &str) -> Option<Message> {
        let text = |key: &str| line.get(key).and_then(Value::as_str).filter(|v| !v.is_empty());
        let task = text("task_id");
        let mut shells = self.background_shells.lock().await;
        // A task_updated or notification may name only the task.
        let tool = match text("tool_use_id") {
            Some(tool) => tool.to_owned(),
            None => {
                let task = task?;
                shells.iter().find(|(_, s)| s.task.as_deref() == Some(task))?.0.clone()
            }
        };
        let backgrounded = |at: Option<&Value>| at == Some(&Value::Bool(true));
        // How it ended: a notification's status, or a task_updated patch's.
        let status = match sub {
            "task_updated" => line.pointer("/patch/status").and_then(Value::as_str),
            _ => text("status"),
        };
        match sub {
            "task_started" if text("task_type") == Some("local_bash") => {
                let shell = shells.entry(tool.clone()).or_insert_with(|| BackgroundShell {
                    sid: sid.to_owned(),
                    command: text("description").unwrap_or("").to_owned(),
                    task: None,
                    background: false,
                    launched: backgrounded(line.get("is_backgrounded")),
                    announced: false,
                    output: None,
                });
                shell.task = task.map(str::to_owned).or(shell.task.take());
                shell.output = text("output_file").map(str::to_owned).or(shell.output.take());
                shell.background |= backgrounded(line.get("is_backgrounded"));
                return running(&tool, shell);
            }
            "task_updated" => {
                let shell = shells.get_mut(&tool)?;
                shell.background |= backgrounded(line.pointer("/patch/is_backgrounded"));
                shell.output = text("output_file").map(str::to_owned).or(shell.output.take());
                // Claude Code may send no notification after `stop_task`: a
                // stopped task ends here. A completed or failed one waits
                // for its notification, which carries the summary.
                if !matches!(status, Some("stopped" | "killed")) {
                    return running(&tool, shell);
                }
            }
            "task_notification" => {}
            _ => return None,
        }
        let mut shell = shells.remove(&tool).filter(|s| s.background)?;
        shell.output = text("output_file").map(str::to_owned).or(shell.output.take());
        let state = match status {
            Some("failed") => "failed",
            Some("killed" | "stopped") => "stopped",
            _ => "completed",
        };
        let mut update = background_task_update(&tool, &shell, state);
        if let Some(task) = task {
            update["taskId"] = json!(task);
        }
        for key in ["reason", "summary"] {
            if let Some(value) = text(key) {
                update[key] = json!(value);
            }
        }
        Some(shell_update(&shell, update))
    }

    /// The background shells still running when Claude's stdout closed: they
    /// ended with its process, so each is reported `stopped`, marked
    /// `_meta.acpmux.endedBy: "harness_exit"` for the hub (`hub/processes.rs`
    /// lists it `lost`); the update itself is what clients show.
    pub async fn end_background_shells(&self) -> Vec<Message> {
        let mut shells: Vec<_> =
            self.background_shells.lock().await.drain().filter(|(_, s)| s.background).collect();
        shells.sort_by(|a, b| a.0.cmp(&b.0));
        shells
            .into_iter()
            .map(|(tool, shell)| {
                let update = background_task_update(&tool, &shell, "stopped");
                Message::notification(
                    method::SESSION_UPDATE,
                    json!({"sessionId": shell.sid, "update": update,
                           "_meta": {"acpmux": {"endedBy": "harness_exit"}}}),
                )
            })
            .collect()
    }

    /// Claude's task events for a subagent: `task_started` or `task_updated`
    /// moves it to the background, and `task_notification` ends a background
    /// one (its Agent tool call returned at launch). Returns the subagent's
    /// `subagent_state_update` when it ended.
    async fn subagent_task(&self, sub: &str, line: &Value) -> Option<Value> {
        let task = line.get("task_id").and_then(Value::as_str).unwrap_or("");
        let tool = match line.get("tool_use_id").and_then(Value::as_str) {
            Some(tool) => tool.to_owned(),
            None => self.subagent_tasks.lock().await.get(task)?.clone(),
        };
        if !self.subagents.lock().await.contains_key(&tool) {
            return None;
        }
        if !task.is_empty() {
            self.subagent_tasks.lock().await.insert(task.to_owned(), tool.clone());
        }
        let backgrounded = match sub {
            "task_started" => line.get("is_backgrounded"),
            "task_updated" => line.pointer("/patch/is_backgrounded"),
            _ => None,
        };
        if backgrounded == Some(&Value::Bool(true)) {
            self.background_subagents.lock().await.insert(tool);
            return None;
        }
        if sub != "task_notification" || !self.background_subagents.lock().await.remove(&tool) {
            return None;
        }
        self.subagent_tasks.lock().await.remove(task);
        self.workflows.lock().await.remove(&tool);
        let child = self.subagents.lock().await.remove(&tool)?;
        let state = match line.get("status").and_then(Value::as_str) {
            Some("failed") => "failed",
            Some("stopped") => "cancelled",
            _ => "completed",
        };
        Some(json!({
            "sessionUpdate": "subagent_state_update",
            "subagentSessionId": child,
            "state": state,
        }))
    }

    /// Records a new Agent or Workflow tool call as a subagent session and
    /// returns its `subagent_spawned` update. Claude's short `description`
    /// names an agent; a workflow, which always runs in the background, is
    /// named by its saved name until its launch names the run.
    async fn spawn_subagent(&self, tool_use_id: &str, tool: &str, input: &Value) -> Value {
        let child = format!("{}/{tool_use_id}", self.acp_session_id);
        self.subagents.lock().await.insert(tool_use_id.to_owned(), child.clone());
        let workflow = tool == "Workflow";
        if workflow {
            self.workflows.lock().await.insert(tool_use_id.to_owned(), None);
        }
        if workflow || input.get("run_in_background") == Some(&Value::Bool(true)) {
            self.background_subagents.lock().await.insert(tool_use_id.to_owned());
        }
        let s = |k: &str| input.get(k).and_then(Value::as_str).filter(|v| !v.is_empty());
        let task = s("description").or(s("name")).or(s("subagent_type"));
        let task = task.unwrap_or(if workflow { "Workflow" } else { "Agent" });
        let kind = if workflow { Some(&json!("workflow")) } else { input.get("subagent_type") };
        json!({
            "sessionUpdate": "subagent_spawned",
            "subagentSessionId": child,
            "name": s("name").unwrap_or(task),
            "task": task,
            "prompt": input.get("prompt"),
            "capabilities": {},
            "_meta": {"claude": {"subagentType": kind, "toolUseId": tool_use_id}}
        })
    }
}

/// Adds a file edit's diff and location to its ACP tool call.
fn with_edit(call: &mut Value, name: &str, input: &Value) {
    if let Some(diffs) = edit_diffs(name, input) {
        call["content"] = diffs;
        if let Some(locations) = tool_locations(input) {
            call["locations"] = locations;
        }
    }
}

/// TodoWrite's `todos` as an ACP `plan` update: each item's text and status
/// (pending, in_progress or completed, as ACP names them). Nil for input
/// that is not a todo list.
fn todo_plan(input: &Value) -> Option<Value> {
    let entries: Vec<Value> = input
        .get("todos")?
        .as_array()?
        .iter()
        .filter_map(|todo| {
            let content = todo.get("content").and_then(Value::as_str)?;
            let status = todo
                .get("status")
                .and_then(Value::as_str)
                .filter(|status| matches!(*status, "in_progress" | "completed"))
                .unwrap_or("pending");
            Some(json!({"content": content, "status": status, "priority": "medium"}))
        })
        .collect();
    Some(json!({"sessionUpdate": "plan", "entries": entries}))
}

/// A `background_task_update` for one shell.
fn background_task_update(tool: &str, shell: &BackgroundShell, state: &str) -> Value {
    json!({
        "sessionUpdate": "background_task_update",
        "taskId": shell.task.as_deref().unwrap_or(""),
        "toolCallId": tool,
        "command": shell.command,
        "state": state,
    })
}

/// The `running` update of a shell Claude runs in the background now, once
/// per shell, with its `origin` (`background` when it started there,
/// `auto_backgrounded` when it moved there): the hub lists it as a process
/// (`hub/processes.rs`) and keeps a chat with one alive (`hub/idle.rs`).
/// Clients note only how a shell ended.
fn running(tool: &str, shell: &mut BackgroundShell) -> Option<Message> {
    if !shell.background || shell.announced {
        return None;
    }
    shell.announced = true;
    let mut update = background_task_update(tool, shell, "running");
    update["origin"] = json!(if shell.launched { "background" } else { "auto_backgrounded" });
    Some(shell_update(shell, update))
}

/// `update` as a session update in the shell's session, with its output
/// file once Claude named it as `_meta.acpmux.outputFile`, which the hub
/// takes off before the update is logged (`hub/processes.rs`): the path
/// stays in the registry.
fn shell_update(shell: &BackgroundShell, update: Value) -> Message {
    let mut params = json!({"sessionId": shell.sid, "update": update});
    if let Some(output) = &shell.output {
        params["_meta"] = json!({"acpmux": {"outputFile": output}});
    }
    Message::notification(method::SESSION_UPDATE, params)
}
