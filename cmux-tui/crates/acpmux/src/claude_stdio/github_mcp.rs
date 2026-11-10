//! The GitHub broker (`github_broker.rs`) as a remote chain's MCP server, `acpmux-github`,
//! served by this translator over Claude Code's own stdio.
//!
//! A remote chain's Claude Code runs in the sandbox (`hub/remote_sandbox.rs`), which allows no
//! Unix socket, so `acpmux gh` cannot reach the daemon there. Claude Code hosts an SDK MCP
//! server in its client: one named in `initialize.sdkMcpServers` is reached by `mcp_message`
//! control requests on the same stdin and stdout this translator already owns, and answered with
//! `mcp_response`. So the server needs no process, socket, file or token in the sandbox, and the
//! chain's `--strict-mcp-config` with its empty server list stays exactly as it is: this one
//! server is added by acpmux's own `initialize` line and by nothing a project or the user can
//! write. Only a chat the hub turned it on for offers it ([`Translator::github_broker`]: a
//! remote chain on a machine a Mac lends GitHub to).
//!
//! `initialize`, `tools/list` and `ping` are answered here. A `tools/call` becomes one broker
//! action, sent to the hub as [`super::GITHUB_ACTION`]; the hub decides from the session that
//! owns this process (`hub/github_owner.rs`), never from anything in the call, and its answer
//! (the action's output or its refusal) becomes the tool's result.

use super::*;

/// The SDK MCP server's name; its tools are `mcp__acpmux-github__*` to Claude Code.
pub const SERVER: &str = "acpmux-github";

/// One tool: its name, what it does, the broker action and the arguments it maps from.
fn tools() -> Value {
    let repo = json!({"type": "string", "description": "OWNER/REPO on github.com"});
    let text = |d: &str| json!({"type": "string", "description": d});
    let number = |d: &str| json!({"type": "integer", "minimum": 1, "description": d});
    json!([
        {"name": "repo_view", "description": "Read a GitHub repository's name, URL, default branch and visibility, through the GitHub login of the Mac that added this machine.",
         "inputSchema": {"type": "object", "properties": {"repo": repo}, "required": ["repo"], "additionalProperties": false}},
        {"name": "pr_view", "description": "Read one pull request (number, title, state, draft, URL, head and base branch).",
         "inputSchema": {"type": "object", "properties": {"repo": repo, "number": number("The pull request number")}, "required": ["repo", "number"], "additionalProperties": false}},
        {"name": "issue_create", "description": "Open an issue.",
         "inputSchema": {"type": "object", "properties": {"repo": repo, "title": text("The title"), "body": text("The body, Markdown")}, "required": ["repo", "title"], "additionalProperties": false}},
        {"name": "issue_comment", "description": "Comment on an issue or a pull request.",
         "inputSchema": {"type": "object", "properties": {"repo": repo, "number": number("The issue or pull request number"), "body": text("The comment, Markdown")}, "required": ["repo", "number", "body"], "additionalProperties": false}},
        {"name": "pr_create_draft", "description": "Open a draft pull request from a branch already pushed to the repository.",
         "inputSchema": {"type": "object", "properties": {"repo": repo, "branch": text("The head branch"), "title": text("The title"), "base": text("The base branch (the default branch when not given)"), "body": text("The body, Markdown")}, "required": ["repo", "branch", "title"], "additionalProperties": false}},
        {"name": "repo_clone", "description": "Clone a repository into a new folder under this chat's folder (git runs outside the sandbox, so its .git is written for you). The folder must not exist yet.",
         "inputSchema": {"type": "object", "properties": {"repo": repo, "dir": text("The new folder's name (one name, no path); the repository's name when not given")}, "required": ["repo"], "additionalProperties": false}},
    ])
}

/// The broker request a tool call names, or why it names none. Every value is checked again by
/// the hub's `validate`, on this machine and on the Mac.
pub(super) fn action_of(name: &str, args: &Value) -> Result<Value, String> {
    let Some(args) = args.as_object() else { return Err("arguments must be an object".into()) };
    let (action, fields): (&str, &[(&str, &str)]) = match name {
        "repo_view" => ("read", &[("repo", "repo")]),
        "pr_view" => ("read", &[("repo", "repo"), ("number", "issue")]),
        "issue_create" => ("issue", &[("repo", "repo"), ("title", "title"), ("body", "body")]),
        "issue_comment" => ("comment", &[("repo", "repo"), ("number", "issue"), ("body", "body")]),
        "pr_create_draft" => (
            "draft_pr",
            &[
                ("repo", "repo"),
                ("branch", "branch"),
                ("title", "title"),
                ("base", "base"),
                ("body", "body"),
            ],
        ),
        "repo_clone" => ("clone", &[("repo", "repo"), ("dir", "dir")]),
        _ => return Err(format!("{SERVER} has no tool {name}")),
    };
    if let Some(extra) = args.keys().find(|k| !fields.iter().any(|(f, _)| f == k)) {
        return Err(format!("{name} takes no argument {extra}"));
    }
    let mut request = json!({"action": action});
    for &(from, to) in fields {
        if let Some(v) = args.get(from).filter(|v| !v.is_null()) {
            request.set(to, v.clone());
        }
    }
    Ok(request)
}

/// A tool result with `text`; `error` marks a refusal or a failure.
fn tool_result(text: &str, error: bool) -> Value {
    json!({"content": [{"type": "text", "text": text}], "isError": error})
}

/// The `control_response` that carries the server's JSON-RPC `reply` for Claude Code's `rid`.
fn mcp_reply(rid: &str, reply: Value) -> Value {
    json!({"type": "control_response", "response": {
        "subtype": "success", "request_id": rid, "response": {"mcp_response": reply}
    }})
}

/// The calls that wait on the hub: the ACP request id sent -> Claude Code's control request id
/// and the JSON-RPC id of its `tools/call`.
#[derive(Default)]
pub(super) struct GithubMcp {
    asked: Mutex<HashMap<String, (String, Value)>>,
}

impl Translator {
    /// `initialize.sdkMcpServers` for this process: the broker's server when it is on.
    pub(super) fn sdk_mcp_servers(&self) -> Option<Value> {
        self.github_broker.load(Ordering::SeqCst).then(|| json!([SERVER]))
    }

    /// Claude Code's `mcp_message` `req` (control request `rid`): answered here, sent to the hub
    /// as the returned request, or declined as before for any other server or a chat without it.
    pub(super) async fn github_mcp(&self, sid: &str, rid: &str, req: &Value) -> Option<Message> {
        let server = req.get("server_name").and_then(Value::as_str);
        if server != Some(SERVER) || !self.github_broker.load(Ordering::SeqCst) {
            self.decline_control(rid, "mcp_message").await;
            return None;
        }
        let msg = req.get("message").cloned().unwrap_or(Value::Null);
        let id = msg.get("id").cloned();
        let method = msg.get("method").and_then(Value::as_str).unwrap_or("");
        let ok = |result: Value| {
            let mut reply = json!({"jsonrpc": "2.0", "result": result});
            if let Some(id) = &id {
                reply.set("id", id.clone());
            }
            reply
        };
        let reply = match (method, &id) {
            // A notification (`notifications/initialized`): an empty result, as the SDKs answer.
            (_, None) => json!({"jsonrpc": "2.0", "result": {}}),
            ("initialize", Some(_)) => {
                let version = msg.pointer("/params/protocolVersion").cloned();
                ok(json!({
                    "protocolVersion": version.unwrap_or_else(|| json!("2025-06-18")),
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": SERVER, "version": env!("CARGO_PKG_VERSION")},
                }))
            }
            ("ping", Some(_)) => ok(json!({})),
            ("tools/list", Some(_)) => ok(json!({"tools": tools()})),
            ("tools/call", Some(call_id)) => {
                let name = msg.pointer("/params/name").and_then(Value::as_str).unwrap_or("");
                let args = msg.pointer("/params/arguments").cloned().unwrap_or(json!({}));
                match action_of(name, &args) {
                    Err(why) => ok(tool_result(&why, true)),
                    Ok(mut request) => {
                        request.set("sessionId", json!(sid));
                        let n = self.next_control.fetch_add(1, Ordering::SeqCst);
                        let acp_id = Value::from(1_000_000_i64.saturating_add(n));
                        self.github_mcp
                            .asked
                            .lock()
                            .await
                            .insert(acp_id.to_string(), (rid.to_owned(), call_id.clone()));
                        return Some(Message::request(acp_id, GITHUB_ACTION, request));
                    }
                }
            }
            (other, Some(id)) => json!({"jsonrpc": "2.0", "id": id,
                "error": {"code": -32601, "message": format!("{SERVER} has no method {other}")}}),
        };
        self.stdin_replies.lock().await.push(mcp_reply(rid, reply));
        None
    }

    /// The hub's answer `id` to a tool call, as its `mcp_response`; `None` when `id` is not one.
    pub(super) async fn github_mcp_answer(
        &self,
        id: &Value,
        result: Option<&Value>,
        error: Option<&RpcError>,
    ) -> Option<Value> {
        let (rid, call_id) = self.github_mcp.asked.lock().await.remove(&id.to_string())?;
        let result = match (error, result) {
            (Some(e), _) => tool_result(&e.message, true),
            (None, Some(r)) => {
                let output = r.get("output").and_then(Value::as_str).unwrap_or("");
                tool_result(if output.is_empty() { "done" } else { output }, false)
            }
            (None, None) => tool_result("no answer", true),
        };
        Some(mcp_reply(&rid, json!({"jsonrpc": "2.0", "id": call_id, "result": result})))
    }

    /// Claude Code no longer waits on control request `rid`: a tool call's late answer is dropped.
    pub(super) async fn forget_github_mcp(&self, rid: &str) {
        self.github_mcp.asked.lock().await.retain(|_, (r, _)| r != rid);
    }
}
