//! claude stdout → ACP: stream-json lines become session updates and replies.

use super::*;
use crate::no_panic::JsonExt;

impl Translator {
    /// Translate one line from claude's stdout into ACP messages for the hub.
    pub async fn inbound(&self, line: &Value) -> Vec<Message> {
        // A Ctrl-B the hub stopped waiting for leaves no mark (`end_background_asks`).
        let now = std::time::Instant::now();
        self.end_background_asks(false, |_, deadline| deadline.is_some_and(|d| d <= now)).await;
        let kind = line.get("type").and_then(Value::as_str).unwrap_or("");
        let sub = line.get("subtype").and_then(Value::as_str).unwrap_or("");
        if kind == "system" && sub == "status" {
            if line.get("status").and_then(Value::as_str) == Some("compacting") {
                self.compacting.store(true, Ordering::SeqCst);
            } else if line.get("compact_result").is_some() {
                // A successful compaction still has its boundary and summary
                // to deliver; the boundary below is the point at which Claude
                // can take another prompt. Failed compactions end at result.
                if line.get("compact_result").and_then(Value::as_str) != Some("success") {
                    self.compacting.store(false, Ordering::SeqCst);
                }
            }
        } else if kind == "system" && sub == "compact_boundary" {
            self.compacting.store(false, Ordering::SeqCst);
        } else if kind == "result" {
            self.compacting.store(false, Ordering::SeqCst);
        }
        // A subagent's lines stream under its own session, ended or not (`subagent_route`).
        let parent = line.get("parent_tool_use_id").and_then(Value::as_str);
        let sid = self.line_session(parent);
        let upd = |u: Value| {
            Message::notification(method::SESSION_UPDATE, json!({"sessionId": sid, "update": u}))
        };
        let mut out = Vec::new();
        // A local slash command answers with a synthetic assistant line, or
        // `/clear` with its reset, before its result (Claude Code 2.1.299);
        // `/compact` with its boundary, and nothing else (2.1.303).
        // The summary is the line right after the boundary; any other line of
        // the chat's own (not the summary) means this compaction wrote none.
        if parent.is_none()
            && (kind == "assistant"
                || (kind == "user"
                    && line.get("isSynthetic").and_then(Value::as_bool) != Some(true)))
        {
            self.awaiting_summary.store(false, Ordering::SeqCst);
        }
        // A failed compaction writes no boundary: its status line is the
        // turn's output, so the zero-turn result after it ends the prompt.
        let compaction_failed = parent.is_none()
            && kind == "system"
            && sub == "status"
            && line.get("status").and_then(Value::as_str).is_none()
            && line
                .get("compact_result")
                .and_then(Value::as_str)
                .is_some_and(|result| result != "success");
        if kind == "assistant"
            || (kind == "system" && (sub == "conversation_reset" || sub == "compact_boundary"))
            || compaction_failed
        {
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
                    // A tool call is named as its block starts (early_calls.rs).
                    Some("content_block_start") => {
                        if let Some(call) = self.announce_tool(&ev, &sid, parent).await {
                            out.push(upd(call));
                        }
                    }
                    Some("content_block_delta") => {
                        let d = ev.get("delta").cloned().unwrap_or(Value::Null);
                        match d.get("type").and_then(Value::as_str) {
                            Some("text_delta") => {
                                if let Some(p) = parent {
                                    self.streamed_subagents.lock().await.insert(p.to_owned());
                                }
                                let mut chunk = json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": d.get("text").and_then(Value::as_str).unwrap_or("")}});
                                if let Some(id) =
                                    self.message_ids.lock().await.get(parent.unwrap_or(""))
                                {
                                    chunk.set("messageId", json!(id));
                                }
                                out.push(upd(chunk));
                            }
                            Some("thinking_delta") => {
                                if let Some(p) = parent {
                                    self.streamed_subagents.lock().await.insert(p.to_owned());
                                }
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
                            // `used` is the context held by the last request. It is the prompt
                            // side of the usage, including cache reads/writes, and deliberately
                            // excludes output: the context ring must not grow from generated text.
                            let input = u.get("input_tokens").and_then(Value::as_u64).unwrap_or(0);
                            let cache_read = u
                                .get("cache_read_input_tokens")
                                .and_then(Value::as_u64)
                                .unwrap_or(0);
                            let cache_write = u
                                .get("cache_creation_input_tokens")
                                .and_then(Value::as_u64)
                                .unwrap_or(0);
                            let output =
                                u.get("output_tokens").and_then(Value::as_u64).unwrap_or(0);
                            let used = input + cache_read + cache_write;
                            // A subagent's usage is its own context, not the chat's.
                            if parent.is_none() {
                                self.context_used.store(used, Ordering::SeqCst);
                            }
                            let size = self.context_window.load(Ordering::SeqCst);
                            // One model call's own usage, marked so a client can add a turn's
                            // calls up (the pane's running line). The result's resend below is
                            // the context ring's and is not marked. A subagent's calls are
                            // marked too: they are the turn's spend. The four counts split the
                            // call so the line can say its output apart from what it read (fresh
                            // input, cache reads and cache writes).
                            out.push(upd(json!({
                                "sessionUpdate": "usage_update",
                                "used": used,
                                "size": size,
                                "inputTokens": input,
                                "cachedReadTokens": cache_read,
                                "cachedWriteTokens": cache_write,
                                "outputTokens": output,
                                "_meta": {"acpmux": {"call": true}},
                            })));
                        }
                    }
                    _ => {}
                }
            }
            "assistant" => {
                // A subagent's text and thinking, which Claude Code sends only
                // in its whole lines (Leo: "why subagents have so little
                // talking?"), go to its session before the line's tool calls.
                // The chat's own, and a subagent's that streams, came as
                // stream events already.
                if let Some(p) = parent
                    && !self.streamed_subagents.lock().await.contains(p)
                {
                    let id = line.pointer("/message/id").and_then(Value::as_str);
                    for c in line
                        .pointer("/message/content")
                        .and_then(Value::as_array)
                        .into_iter()
                        .flatten()
                    {
                        let (kind, key) = match c.get("type").and_then(Value::as_str) {
                            Some("text") => ("agent_message_chunk", "text"),
                            Some("thinking") => ("agent_thought_chunk", "thinking"),
                            _ => continue,
                        };
                        let text = c.get(key).and_then(Value::as_str).unwrap_or("");
                        if text.is_empty() {
                            continue;
                        }
                        let mut chunk = json!({"sessionUpdate": kind, "content": {"type": "text", "text": text}});
                        if let (Some(id), "agent_message_chunk") = (id, kind) {
                            chunk.set("messageId", json!(id));
                        }
                        out.push(upd(chunk));
                    }
                }
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
                                asked: false,
                                announced: false,
                                output: None,
                            };
                            self.background_shells.lock().await.insert(id.to_owned(), shell);
                        }
                        let mut call = tool_call_fields(name, &input);
                        call.set("sessionUpdate", json!("tool_call"));
                        call.set("toolCallId", c.get("id").cloned().unwrap_or(Value::Null));
                        call.set("status", json!("in_progress"));
                        if let (Some(diffs), Some(id)) =
                            (call.get("content"), c.get("id").and_then(Value::as_str))
                        {
                            self.edits.lock().await.insert(id.to_owned(), diffs.clone());
                        }
                        // Named early (early_calls.rs): the whole call is that call's update.
                        if let Some(id) = c.get("id").and_then(Value::as_str)
                            && self.take_announced(id).await
                        {
                            call.set("sessionUpdate", json!("tool_call_update"));
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
                // A line of several sessions' messages answers each (`steer_batch.rs`).
                let read: Vec<String> = steers
                    .iter()
                    .filter(|(u, _)| !uuid.is_empty() && u == uuid)
                    .map(|(_, k)| k.clone())
                    .collect();
                if !read.is_empty() {
                    steers.retain(|(u, _)| u != uuid);
                    drop(steers);
                    self.forget_batch(uuid).await;
                    for k in read {
                        let id: Id = serde_json::from_str(&k).unwrap_or(Value::String(k));
                        out.push(Message::ok(id, json!({"stopReason": "steered"})));
                    }
                    // A turn the client stopped: Claude Code runs a line it
                    // read after the stop as one more turn, so that turn is
                    // stopped too, and the prompt ends cancelled.
                    if self.cancelled.load(Ordering::SeqCst) {
                        let n = self.next_control.fetch_add(1, Ordering::SeqCst);
                        self.stdin_replies.lock().await.push(json!({"type": "control_request", "request_id": format!("int-{n}"), "request": {"subtype": "interrupt"}}));
                    }
                }
            }
            // The summary a compaction leaves: the synthetic user line after
            // its boundary. It is not a prompt; acpmux keeps it as the context
            // a handoff or fallback carries.
            "user"
                if parent.is_none()
                    && line.get("isSynthetic").and_then(Value::as_bool) == Some(true)
                    && compaction_summary_text(line).is_some()
                    && self.awaiting_summary.swap(false, Ordering::SeqCst) =>
            {
                if let Some(text) = compaction_summary_text(line) {
                    out.push(upd(json!({"sessionUpdate": "compaction_summary", "text": text})));
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
                            // The launch's result names the output file while
                            // the shell runs; the task notification names it
                            // only at its end. A shell announced already is
                            // announced again with it, once.
                            if let Some(shell) = shells.get_mut(tool).filter(|s| s.output.is_none())
                                && let Some(file) = launch_output_file(&text)
                            {
                                shell.output = Some(file);
                                if shell.announced && shell.background {
                                    let mut update = background_task_update(tool, shell, "running");
                                    update.set("origin", json!(origin(shell)));
                                    out.push(shell_update(shell, update));
                                }
                            }
                        }
                        // ACP content replaces the call's content: a finished edit
                        // keeps its diff, and a failed one says why.
                        let content = match self.edits.lock().await.remove(tool) {
                            Some(diffs) if !is_err => {
                                settle_write(diffs, &text, line.get("tool_use_result"))
                            }
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
                        // A background subagent's result is only its launch, unless the launch
                        // failed: then it never ran, and ends here (manaflow-ai/cmux#25230: else
                        // the chat reads working forever).
                        {
                            let mut background = self.background_subagents.lock().await;
                            if background.contains(tool) && !is_err {
                                continue;
                            }
                            background.remove(tool);
                        }
                        if let Some(child) = self.subagents.lock().await.remove(tool) {
                            let mut tasks = self.subagent_tasks.lock().await;
                            let agent =
                                tasks.iter().find(|(_, t)| *t == tool).map(|(a, _)| a.clone());
                            tasks.retain(|_, t| *t != tool);
                            drop(tasks);
                            let mut update = json!({
                                "sessionUpdate": "subagent_state_update",
                                "subagentSessionId": child,
                                "state": if is_err { "failed" } else { "completed" },
                            });
                            if is_err {
                                self.failed_with(&mut update, tool, &child, agent, &text).await;
                            }
                            out.push(upd(update));
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
                    // An MCP server's form, asked as a question (elicitation.rs).
                    Some("elicitation") => out.extend(self.elicit(&sid, &rid, &req).await),
                    // Anything else (hook_callback, mcp_message) is declined
                    // with an error response, so claude does not wait on it.
                    other => self.decline_control(&rid, other.unwrap_or("?")).await,
                }
            }
            // Claude Code no longer needs the answer to one of its requests.
            "control_cancel_request" => {
                let rid = line.get("request_id").and_then(Value::as_str).unwrap_or("");
                if let Some(id) = self.cancel_control_request(rid).await {
                    out.push(Message::notification(
                        method::CANCEL_REQUEST,
                        json!({"requestId": id}),
                    ));
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
                } else if let Some(acp) = rid.strip_prefix("bg-") {
                    // A background_tasks answer (`BACKGROUND_TASKS`, Ctrl-B). Claude Code's
                    // SDK reads a missing `backgrounded` as true.
                    let id: Id = serde_json::from_str(acp).unwrap_or(Value::String(acp.to_owned()));
                    let moved =
                        ok && inner.get("backgrounded").and_then(Value::as_bool).unwrap_or(true);
                    // Nothing moved: a shell Claude Code moves later on its own is not the
                    // person's, unless another Ctrl-B moved it or still waits.
                    let key = id.to_string();
                    self.end_background_asks(moved, |k, _| k == key).await;
                    out.push(if ok {
                        Message::ok(id, json!({"backgrounded": moved}))
                    } else {
                        let why = resp.get("error").and_then(Value::as_str);
                        let why =
                            why.unwrap_or("Claude Code did not move its work to the background");
                        Message::err(id, RpcError::internal(why))
                    });
                } else if let Some(uuid) = rid.strip_prefix("rebatch-") {
                    // A line dropped to be written again with more messages (`steer_batch.rs`).
                    out.extend(self.rebatched(uuid, ok, &inner).await);
                } else if let Some(rest) = rid.strip_prefix("unsteer-") {
                    // A steer taken back, or read first (`steer_withdraw.rs`).
                    out.extend(self.steer_withdrawn(rest, ok, &inner).await);
                } else if let Some(acp) = rid.strip_prefix("now-") {
                    // A step stopped for a steer sent now (`MUX_STEP_NOW`).
                    let id: Id = serde_json::from_str(acp).unwrap_or(Value::String(acp.to_owned()));
                    out.push(Message::ok(id, json!({"interrupted": ok})));
                } else if let Some(acp) = rid.strip_prefix("mcp-") {
                    // An mcp_reconnect's answer (`MCP_RECONNECT`).
                    let id: Id = serde_json::from_str(acp).unwrap_or(Value::String(acp.to_owned()));
                    out.push(if ok {
                        Message::ok(id, json!({}))
                    } else {
                        let why = resp.get("error").and_then(Value::as_str);
                        let why = why.unwrap_or("Claude Code did not reconnect the MCP server");
                        Message::err(id, RpcError::internal(why))
                    });
                } else if rid.starts_with("ctx-")
                    && let Some(breakdown) = ok.then(|| context_breakdown(&inner)).flatten()
                {
                    // The turn's context breakdown (`get_context_usage`, asked at its result). A
                    // Claude Code that cannot answer leaves the last one, or none.
                    out.push(upd(json!({
                        "sessionUpdate": "session_info_update",
                        "_meta": {"acpmux": {"contextBreakdown": breakdown}},
                    })));
                }
                // "int-*" acks need no reply; the result message ends the turn.
            }
            "result" => {
                // A compaction's summary comes before its turn's result.
                self.awaiting_summary.store(false, Ordering::SeqCst);
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
                // A call named early whose whole call never came ends with its turn.
                out.extend(self.end_announced().await);
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
                // Out of the turn first: a steer that takes the steer locks after `fail_steers`
                // finds it ended and is not left waiting (`steer_batch.rs` `write_steer`).
                self.in_turn.store(false, Ordering::SeqCst);
                out.extend(self.fail_steers().await);
                *self.prompt_echo.lock().await = None;
                // A Ctrl-B still unanswered leaves no mark past its turn.
                self.end_background_asks(false, |_, _| true).await;
                // What the context holds now, as Claude Code's /context breaks it down; its
                // answer comes after the turn ended (`context_breakdown`). `summary` answers
                // from the last response's usage, with no token-count API call.
                let n = self.next_control.fetch_add(1, Ordering::SeqCst);
                self.stdin_replies.lock().await.push(json!({"type": "control_request", "request_id": format!("ctx-{n}"), "request": {"subtype": "get_context_usage", "detail": "summary"}}));
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
                self.awaiting_summary.store(true, Ordering::SeqCst);
                out.push(upd(compaction_update("completed", line)));
            }
            // Claude Code 2.1.303 says `status: compacting` when a compaction
            // starts, and clears it with `compact_result` when it ends.
            "system" if sub == "status" && parent.is_none() => {
                let result = line.get("compact_result").and_then(Value::as_str);
                match (line.get("status").and_then(Value::as_str), result) {
                    (Some("compacting"), _) => out.push(upd(compaction_update("running", line))),
                    (None, Some(result)) if result != "success" => {
                        out.push(upd(compaction_update("failed", line)))
                    }
                    _ => {}
                }
            }
            // The account's plan usage limits, newest per window (`usage_limits.rs`).
            "rate_limit_event" => out.extend(self.usage_limits_update(line).await),
            "system" if sub.starts_with("task_") => {
                if let Some(update) = self.background_shell_task(sub, line, &sid).await {
                    out.push(update);
                }
                if let Some(progress) = self.subagent_progress(sub, line).await {
                    out.push(upd(progress));
                }
                if let Some((update, ended)) = self.subagent_task(sub, line).await {
                    if let Some(tool) = ended {
                        out.extend(self.end_announced_of(&tool).await);
                    }
                    out.push(upd(update));
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
                    asked: false,
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
            update.set("taskId", json!(task));
        }
        for key in ["reason", "summary"] {
            if let Some(value) = text(key) {
                update.set(key, json!(value));
            }
        }
        Some(shell_update(&shell, update))
    }

    /// The background shells still running when Claude's stdout closed: they
    /// ended with its process, so each is reported `stopped`, marked
    /// `_meta.acpmux.endedBy: "harness_exit"` for the hub (`hub/processes.rs`
    /// lists it `lost`); the update itself is what clients show. A call named
    /// early whose input was still streaming ends `failed` with them.
    pub async fn end_background_shells(&self) -> Vec<Message> {
        let mut shells: Vec<_> =
            self.background_shells.lock().await.drain().filter(|(_, s)| s.background).collect();
        shells.sort_by(|a, b| a.0.cmp(&b.0));
        let mut out = self.end_all_announced().await;
        out.extend(shells.into_iter().map(|(tool, shell)| {
            let update = background_task_update(&tool, &shell, "stopped");
            Message::notification(
                method::SESSION_UPDATE,
                json!({"sessionId": shell.sid, "update": update,
                           "_meta": {"acpmux": {"endedBy": "harness_exit"}}}),
            )
        }));
        out
    }

    /// Claude's task events for a subagent: `task_started` or `task_updated`
    /// moves it to the background, and `task_notification` ends a background
    /// one (its Agent tool call returned at launch). Returns the subagent's
    /// `subagent_progress` marking it background when it moved there, and its
    /// `subagent_state_update` with its tool id when it ended.
    async fn subagent_task(&self, sub: &str, line: &Value) -> Option<(Value, Option<String>)> {
        let task = line.get("task_id").and_then(Value::as_str).unwrap_or("");
        // SendMessage resumed an agent that failed: its task starts again under the SendMessage
        // call, and it is that subagent running again (its lines still name its Agent call).
        let resumed = {
            let mut failed = self.failed_agents.lock().await;
            let at = failed.iter().position(|(agent, _, _)| !task.is_empty() && agent == task);
            at.filter(|_| sub == "task_started").and_then(|at| failed.remove(at))
        };
        if let Some((_, tool, child)) = resumed {
            self.subagents.lock().await.insert(tool.clone(), child.clone());
            self.background_subagents.lock().await.insert(tool.clone());
            self.subagent_tasks.lock().await.insert(task.to_owned(), tool);
            let update = json!({"sessionUpdate": "subagent_state_update",
                "subagentSessionId": child, "state": "running", "agentId": task});
            return Some((update, None));
        }
        let tool = self.task_tool(line).await?;
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
            let child = self.subagents.lock().await.get(&tool)?.clone();
            if !self.background_subagents.lock().await.insert(tool) {
                return None;
            }
            return Some((
                json!({
                    "sessionUpdate": "subagent_progress",
                    "subagentSessionId": child,
                    "background": true,
                }),
                None,
            ));
        }
        // A workflow's task_updated that ends it counts too: Claude Code sends no
        // notification after it pauses a workflow (which stops its agents; a
        // resume is a new task with the same run id) and may send none after a
        // stop.
        let status = match sub {
            "task_notification" => {
                Some(line.get("status").and_then(Value::as_str).unwrap_or("completed"))
            }
            // Only a workflow: a plain agent always ends with its notification.
            "task_updated" if self.workflows.lock().await.contains_key(&tool) => {
                super::workflows::ended_status(line)
            }
            _ => None,
        }?;
        if !self.background_subagents.lock().await.remove(&tool) {
            return None;
        }
        self.subagent_tasks.lock().await.retain(|_, t| *t != tool);
        let workflow = self.workflows.lock().await.remove(&tool).is_some();
        let child = self.subagents.lock().await.remove(&tool)?;
        let state = match status {
            "failed" => "failed",
            "stopped" | "killed" | "paused" => "cancelled",
            _ => "completed",
        };
        let mut update = json!({
            "sessionUpdate": "subagent_state_update",
            "subagentSessionId": child,
            "state": state,
        });
        if status == "paused" {
            update.set("reason", json!("paused"));
        }
        if state == "failed" {
            // A workflow resumes by its run id, never by SendMessage: it names no agent.
            let agent = (!workflow && !task.is_empty()).then(|| task.to_owned());
            let error = line.get("summary").and_then(Value::as_str).unwrap_or_default();
            self.failed_with(&mut update, &tool, &child, agent, error).await;
        }
        Some((update, Some(tool)))
    }

    /// The Agent call a task line is about: its `tool_use_id` when that is a subagent's, else
    /// the call its task id ran under (a resumed agent's lines name the SendMessage call).
    pub(super) async fn task_tool(&self, line: &Value) -> Option<String> {
        let text = |key: &str| line.get(key).and_then(Value::as_str).filter(|v| !v.is_empty());
        if let Some(tool) = text("tool_use_id")
            && self.subagents.lock().await.contains_key(tool)
        {
            return Some(tool.to_owned());
        }
        self.subagent_tasks.lock().await.get(text("task_id")?).cloned()
    }

    /// A failed subagent's end says why (`error`) and, when Claude named its agent, the
    /// `agentId` SendMessage resumes it by; a resume then reports it running again.
    async fn failed_with(
        &self,
        update: &mut Value,
        tool: &str,
        child: &str,
        agent: Option<String>,
        error: &str,
    ) {
        if !error.is_empty() {
            let error: String = error.chars().take(MAX_FAILURE_CHARS).collect();
            update.set("error", json!(error));
        }
        if let Some(agent) = agent {
            update.set("agentId", json!(agent));
            let mut failed = self.failed_agents.lock().await;
            failed.retain(|(a, _, _)| *a != agent);
            if failed.len() >= MAX_FAILED_AGENTS {
                failed.pop_front();
            }
            failed.push_back((agent, tool.to_owned(), child.to_owned()));
        }
    }

    /// Records a new Agent or Workflow tool call as a subagent session and
    /// returns its `subagent_spawned` update. Claude's short `description`
    /// names an agent; a workflow, which always runs in the background, is
    /// named by its saved name until its launch names the run.
    async fn spawn_subagent(&self, tool_use_id: &str, tool: &str, input: &Value) -> Value {
        let child = self.line_session(Some(tool_use_id));
        self.subagents.lock().await.insert(tool_use_id.to_owned(), child.clone());
        let workflow = tool == "Workflow";
        let background = workflow || input.get("run_in_background") == Some(&Value::Bool(true));
        if background {
            self.background_subagents.lock().await.insert(tool_use_id.to_owned());
        }
        let s = |k: &str| input.get(k).and_then(Value::as_str).filter(|v| !v.is_empty());
        let task = s("description").or(s("name")).or(s("subagent_type"));
        let task = task.unwrap_or(if workflow { "Workflow" } else { "Agent" });
        let kind = if workflow { Some(&json!("workflow")) } else { input.get("subagent_type") };
        let model = Some(
            s("model")
                .filter(|m| *m != "inherit")
                .map(str::to_owned)
                .unwrap_or(self.model.lock().await.clone()),
        );
        let effort = s("effort")
            .or(s("reasoning_effort"))
            .map(str::to_owned)
            .or(Some(self.effort.lock().await.clone()));
        if workflow {
            self.workflows
                .lock()
                .await
                .insert(tool_use_id.to_owned(), workflows::WorkflowRun::new(input, effort.clone()));
        }
        let mut update = json!({
            "sessionUpdate": "subagent_spawned",
            "subagentSessionId": child,
            "name": s("name").unwrap_or(task),
            "task": task,
            "prompt": input.get("prompt"),
            "capabilities": {},
            "_meta": {"claude": {"subagentType": kind, "toolUseId": tool_use_id}}
        });
        if let Some(model) = model {
            update.set("model", json!(model));
        }
        if let Some(effort) = effort {
            update.set("effort", json!(effort));
        }
        // It outlives a stopped turn: a client keeps it running past one.
        if background {
            update.set("background", json!(true));
        }
        update
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

/// A `compaction` update: a compaction of the chat's context `state`
/// (`running`, `completed`, `failed`), with what Claude's line says about it.
/// Claude Code repeats `running` every 30 seconds while it compacts; clients
/// keep one compaction on one row.
/// `reason` is set by a wrapper that compacted for its own purpose (the
/// subrouter relay compacts before moving the chat to another account).
fn compaction_update(state: &str, line: &Value) -> Value {
    let meta = line.get("compact_metadata");
    let field = |key: &str| meta.and_then(|m| m.get(key)).cloned().filter(|v| !v.is_null());
    let mut update = json!({"sessionUpdate": "compaction", "state": state});
    for (from, to) in [
        ("trigger", "trigger"),
        ("reason", "reason"),
        ("pre_tokens", "preTokens"),
        ("post_tokens", "postTokens"),
    ] {
        if let Some(v) = field(from) {
            update.set(to, v);
        }
    }
    // Why it failed, in Claude Code's words (2.1.305 `compact_error`).
    if state == "failed"
        && let Some(error) = line.get("compact_error").and_then(Value::as_str)
        && !error.trim().is_empty()
    {
        update.set("error", json!(error.trim()));
    }
    update
}

/// The text of a compaction's summary line (string or text-block content).
fn compaction_summary_text(line: &Value) -> Option<String> {
    let text = match line.pointer("/message/content")? {
        Value::String(s) => s.clone(),
        // A tool result is never a summary; the general user arm reads it.
        Value::Array(blocks)
            if blocks
                .iter()
                .any(|b| b.get("type").and_then(Value::as_str) == Some("tool_result")) =>
        {
            return None;
        }
        Value::Array(blocks) => blocks
            .iter()
            .filter_map(|b| b.get("text").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join("\n"),
        _ => return None,
    };
    (!text.trim().is_empty()).then_some(text)
}

/// The output file a background Bash launch's result names ("… Output is
/// being written to: PATH"), as Claude Code words it; None for any other text.
fn launch_output_file(text: &str) -> Option<String> {
    const MARK: &str = "Output is being written to: ";
    let (_, rest) = text.split_once(MARK)?;
    let path = rest.lines().next()?.trim();
    (path.starts_with('/') && path.ends_with(".output")).then(|| path.to_owned())
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
/// per shell, with its `origin`: the hub lists it as a process
/// (`hub/processes.rs`) and keeps a chat with one alive (`hub/idle.rs`).
/// Clients note only how a shell ended.
fn running(tool: &str, shell: &mut BackgroundShell) -> Option<Message> {
    if !shell.background || shell.announced {
        return None;
    }
    shell.announced = true;
    let mut update = background_task_update(tool, shell, "running");
    update.set("origin", json!(origin(shell)));
    Some(shell_update(shell, update))
}

/// How a shell got to the background: `background` when it started there,
/// `user_backgrounded` when the person moved it (Ctrl-B), else
/// `auto_backgrounded` (Claude Code moved it).
fn origin(shell: &BackgroundShell) -> &'static str {
    match (shell.launched, shell.asked) {
        (true, _) => "background",
        (false, true) => "user_backgrounded",
        (false, false) => "auto_backgrounded",
    }
}

/// `update` as a session update in the shell's session, with its output
/// file once Claude named it as `_meta.acpmux.outputFile`, which the hub
/// takes off before the update is logged (`hub/processes.rs`): the path
/// stays in the registry.
fn shell_update(shell: &BackgroundShell, update: Value) -> Message {
    let mut params = json!({"sessionId": shell.sid, "update": update});
    if let Some(output) = &shell.output {
        params.set("_meta", json!({"acpmux": {"outputFile": output}}));
    }
    Message::notification(method::SESSION_UPDATE, params)
}
