//! Cloud repository tools for agent sessions on a Cloud machine.
//!
//! The agent and the web UI use the same daemon actions.  This stdio server
//! forwards the chat ID supplied by acpmux; it never trusts a session id
//! supplied by tool arguments. The acpmux connection must also prove the
//! same session with its caller token before any CLI operation runs.

use crate::client::Client;
use crate::secret_mcp::error_result;
use anyhow::Result;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;

pub const SERVER_NAME: &str = "cmux-cloud-repos";
pub const SESSION_ENV: &str = "ACPMUX_CLOUD_REPO_SESSION";
/// Its acpmux command word: its own stdio process, where the daemon's gateway does not serve it.
pub const COMMAND: &str = "repo-mcp";
/// The daemon action names are deliberately shared with `cmux mcp` and the
/// webview action bridge (rather than a second agent-only protocol).
pub const REPO_LIST_ACTION: &str = "cloud.repo.list";
pub const REPO_ADD_ACTION: &str = "cloud.repo.add";
pub const REPO_WAIT_GITHUB_ACTION: &str = "cloud.repo.wait_github";

/// What the agent tells a person who asks where it runs: the machine, where its working folder
/// comes from, and how work leaves it. A Cloud chat can start with no repository, so the agent
/// says so plainly instead of guessing (Leo, 2026-11-02, on Claude Code's cloud session that does:
/// "i want us to be able to do this too"). Facts, not policy: the machine is a cmux Cloud Linux VM
/// (`/etc/cmux/vm-kind`), its disk stays until it is deleted, and an idle machine may be paused
/// (cmux-platform CloudIdle) and resumes with its files. A chat started on a folder from the
/// person's Mac works in that folder projected (RFD 0007), empty or not, git or not, and its edits
/// reach the Mac on Bring Back; the text says both cases and `this_folder` tells which, since the
/// same text opens every chat (the cached prompt prefix, `tools_mcp::INSTRUCTIONS_IN_PROMPT_ENV`).
/// Leo, 2026-11-25, on an empty folder's chat that said nothing comes back to the Mac: "and then
/// like on an empty folder cloud whatever im not sure".
pub const INSTRUCTIONS: &str = "This chat runs on a cmux Cloud machine: a Linux virtual machine \
in cmux Cloud, not the person's Mac. When the person started it on a folder from their Mac, the \
working folder is that folder projected (empty or not, a git repository or not): its files read \
from the Mac on first use, and what you write stays on this machine over them until the person \
brings it back (Bring Back), which applies it to that same Mac folder. Otherwise the working \
folder is the machine's own (a repository cloned here, or empty when the chat started with none): \
its files stay on the machine between chats, even while it is paused when idle, until the machine \
is deleted, and nothing in it is copied to the Mac, so push work to GitHub to keep it anywhere \
else. Before saying which case this is, call this_folder with your working folder: it names the \
Mac folder a projection mirrors, how edits reach it, and whether it is a git repository. Attach \
a repository at any time with add_repo (list_repos finds names); Session Info may also offer the \
person Add repository. A needs_github result is retried automatically after Connect GitHub \
finishes. When asked what this environment is, say these things plainly.";

/// Cloud machines carry the same image marker used by acpmux host updates.
pub fn is_cloud_machine() -> bool {
    std::path::Path::new("/etc/cmux/vm-kind").exists()
}

fn tools() -> Value {
    json!([
        {
            "name": "this_folder",
            "description": "Say what a folder on this Cloud machine is: a projection of a folder on the person's Mac (which one, and that edits reach it on Bring Back) or the machine's own folder, and whether it is a git repository. Call it with your working folder before describing where files live or whether they sync to the Mac.",
            "inputSchema": {
                "type": "object",
                "properties": {"path": {"type": "string", "description": "An absolute folder path, usually your working folder (pwd)."}},
                "required": ["path"]
            }
        },
        {
            "name": "list_repos",
            "description": "List repositories you can attach to this Cloud chat. A bare name is resolved from local projects, recently used Cloud repositories, and the GitHub App installation. If GitHub is not connected, follow the connect action in the result.",
            "inputSchema": {
                "type": "object",
                "properties": {"query": {"type": "string", "description": "Optional repository name or owner/name filter."}}
            }
        },
        {
            "name": "add_repo",
            "description": "Attach a repository to this Cloud chat. Pass a bare name, owner/name, or GitHub URL. Ambiguous names return one-tap choices. GitHub and clone errors include the next action.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "repo": {"type": "string", "description": "Repository name, owner/name, or GitHub URL."},
                    "ref": {"type": "string", "description": "Optional branch, tag, or commit to clone."}
                },
                "required": ["repo"]
            }
        }
    ])
}

/// The server for the session in the env, as one of acpmux's own
/// ([`crate::tools_mcp::SERVERS`]): the daemon's gateway, or the chat's one `acpmux tools-mcp`,
/// answers it, so a chat runs no `acpmux repo-mcp` process of its own.
pub(crate) fn served(daemon: &Arc<crate::tools_mcp::Daemon>) -> Result<crate::tools_mcp::Served> {
    crate::tools_mcp::served(
        SERVER_NAME,
        SESSION_ENV,
        tools(),
        Some(INSTRUCTIONS.to_owned()),
        daemon,
        |daemon, session, params| async move { call(&daemon, &session, &params).await },
    )
}

pub async fn run() -> Result<()> {
    crate::secret_mcp::serve(
        SERVER_NAME,
        SESSION_ENV,
        tools(),
        Some(INSTRUCTIONS.to_owned()),
        |daemon, session, params| async move { call(&daemon, &session, &params).await },
    )
    .await
}

fn ok(result: Value) -> Value {
    let text = result_text(&result);
    let code = result
        .get("code")
        .and_then(Value::as_str)
        .or_else(|| result.pointer("/error/code").and_then(Value::as_str));
    let is_error = code.is_some_and(|code| !matches!(code, "repo.needs_github" | "repo.ambiguous"));
    json!({"content":[{"type":"text","text":text}],"structuredContent":result,"isError":is_error})
}

fn result_text(result: &Value) -> String {
    let error = if result.get("code").and_then(Value::as_str).is_some() {
        result
    } else {
        result.get("error").filter(|v| v.is_object()).unwrap_or(&Value::Null)
    };
    if error.get("code").and_then(Value::as_str).is_some() {
        let mut text = error
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("Repository action failed")
            .to_owned();
        if error.get("code").and_then(Value::as_str) == Some("repo.needs_github") {
            text.push_str(
                " Connect GitHub; this add will be retried automatically when it finishes.",
            );
        }
        return text;
    }
    if let Some(repos) = result.get("repos").and_then(Value::as_array) {
        return if repos.is_empty() {
            "No repositories match. Connect GitHub, or use a local project.".to_owned()
        } else {
            format!(
                "Found {} {}.",
                repos.len(),
                if repos.len() == 1 { "repository" } else { "repositories" }
            )
        };
    }
    if result.get("state").and_then(Value::as_str) == Some("done") {
        return format!(
            "Attached {} at {}.",
            result.get("repo").and_then(Value::as_str).unwrap_or("the repository"),
            result.get("folder").and_then(Value::as_str).unwrap_or("the chat folder")
        );
    }
    serde_json::to_string(result).unwrap_or_else(|_| "Repository action completed.".to_owned())
}

/// The Cloud CLI already speaks the legacy machine socket contract. Calling
/// it without a shell keeps the chat ID in an argv value only
/// (never interpolated into a command string), and makes this bridge work with
/// the same socket as `cmux cloud repo`.
async fn run_cli(action: &'static str, request: Value) -> Result<Value, String> {
    // The chat's env where the daemon's gateway serves it, else this process's.
    let binary: std::ffi::OsString =
        crate::tool_env::var("CMUX_BIN").unwrap_or_else(|| "cmux".into()).into();
    let socket = crate::tool_env::var("CMUX_SOCKET_PATH").map(std::ffi::OsString::from);
    run_cli_with(&binary, socket.as_deref(), action, request).await
}

async fn run_cli_with(
    binary: &std::ffi::OsStr,
    socket: Option<&std::ffi::OsStr>,
    action: &str,
    request: Value,
) -> Result<Value, String> {
    let mut command = tokio::process::Command::new(binary);
    command.kill_on_drop(true).arg("--json");
    if let Some(socket) = socket {
        command.arg("--socket").arg(socket);
    }
    command.args([
        "cloud",
        "repo",
        if action == REPO_LIST_ACTION { "list" } else { "add" },
        "--session",
    ]);
    let session = request.get("session").and_then(Value::as_str).unwrap_or_default();
    command.arg(session);
    if action == REPO_LIST_ACTION {
        if let Some(query) = request.get("query").and_then(Value::as_str) {
            command.args(["--query", query]);
        }
    } else {
        command.args(["--repo", request.get("repo").and_then(Value::as_str).unwrap_or_default()]);
        if let Some(reference) = request.get("ref").and_then(Value::as_str) {
            command.args(["--ref", reference]);
        }
    }
    let output = tokio::time::timeout(
        Duration::from_secs(if action == REPO_ADD_ACTION { 610 } else { 70 }),
        command.output(),
    )
    .await
    .map_err(|_| {
        "The Cloud machine did not finish the repository action in time; it is slow or unreachable."
            .to_owned()
    })?
    .map_err(|e| format!("Could not run cmux to reach the Cloud machine ({e})."))?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    if let Some(line) = stdout.lines().rev().find(|line| line.trim_start().starts_with('{'))
        && let Ok(value) = serde_json::from_str::<Value>(line)
    {
        if value.get("code").is_some()
            || value.get("repos").is_some()
            || value.get("state").is_some()
        {
            return Ok(value);
        }
        if let Some(data) = value.get("data") {
            return Ok(data.clone());
        }
        // `cmux --json` wraps a rejected machine reply as error_code/error;
        // restore the shared flat typed action result for the agent.
        if value.get("error_code").is_some() {
            return Ok(json!({
                "code": value.get("error_code").and_then(Value::as_str).unwrap_or("repo.unavailable"),
                "message": value.get("error").and_then(Value::as_str).unwrap_or("The Cloud machine refused the repository action.")
            }));
        }
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    Err(if stderr.trim().is_empty() {
        "The Cloud machine returned no repository result.".to_owned()
    } else {
        format!("Repository action failed: {}", stderr.trim())
    })
}

fn args_object(params: &Value) -> Result<Value, Value> {
    let args = params.get("arguments").cloned().unwrap_or_else(|| json!({}));
    if args.is_object() {
        Ok(args)
    } else {
        Err(error_result("arguments must be an object".to_owned()))
    }
}

pub async fn call(daemon: &Arc<Client>, session: &str, params: &Value) -> Value {
    call_for_caller(daemon.proven_caller_session(), session, params, run_cli).await
}

async fn call_for_caller<F, Fut>(
    caller: Option<&str>,
    session: &str,
    params: &Value,
    run: F,
) -> Value
where
    F: Fn(&'static str, Value) -> Fut,
    Fut: std::future::Future<Output = Result<Value, String>>,
{
    if caller != Some(session) {
        return error_result(
            "Repository tools could not verify this chat. Restart the chat session to use them."
                .to_owned(),
        );
    }
    let args = match args_object(params) {
        Ok(v) => v,
        Err(v) => return v,
    };
    let name = params.get("name").and_then(Value::as_str).unwrap_or_default();
    match name {
        "this_folder" => {
            let Some(path) = args
                .get("path")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|path| path.starts_with('/'))
            else {
                return error_result("path is required: an absolute folder path".to_owned());
            };
            let answer = crate::cloud_folder::describe(path);
            let text = answer["summary"].as_str().unwrap_or_default().to_owned();
            json!({"content":[{"type":"text","text":text}],"structuredContent":answer,"isError":false})
        }
        "list_repos" => {
            let mut req = json!({"session": session});
            if let Some(query) =
                args.get("query").and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty())
            {
                req.set("query", json!(query));
            }
            // A list only reads: one the Cloud machine did not answer is asked again for a few
            // seconds (a reconnect in progress), never handed to the agent as "retry".
            let listed = cmux_tui_util::retry::Patience::new("the Cloud machine", LIST_PATIENCE)
                .quiet()
                .run_async(
                    || "The Cloud machine did not return the repository list in time.".to_owned(),
                    {
                        let run = &run;
                        move || {
                            let req = req.clone();
                            async move {
                                run(REPO_LIST_ACTION, req)
                                    .await
                                    .map_err(cmux_tui_util::retry::Attempt::Retry)
                            }
                        }
                    },
                )
                .await;
            match listed {
                Ok(result) => ok(result),
                Err(e) => error_result(e),
            }
        }
        "add_repo" => {
            let Some(repo) =
                args.get("repo").and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty())
            else {
                return error_result("repo is required".to_owned());
            };
            let mut req = json!({"session": session, "repo": repo});
            if let Some(reference) =
                args.get("ref").and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty())
            {
                req.set("ref", json!(reference));
            }
            match run(REPO_ADD_ACTION, req).await {
                Ok(mut result) => {
                    enrich_retry(&mut result, session, repo, args.get("ref"));
                    ok(result)
                }
                Err(e) => error_result(e),
            }
        }
        other => {
            error_result(crate::mcp_hint::unknown_tool(other, crate::mcp_hint::names(&tools())))
        }
    }
}

/// How long `list_repos` asks the Cloud machine again while it does not answer.
const LIST_PATIENCE: Duration = Duration::from_secs(10);

/// Keep retry information in the agent result even if an older daemon only
/// returns the typed error. The UI uses this exact payload to retry silently.
fn enrich_retry(result: &mut Value, session: &str, repo: &str, reference: Option<&Value>) {
    let error = if result.get("code").and_then(Value::as_str).is_some() {
        result
    } else if let Some(error) = result.get_mut("error").filter(|error| error.is_object()) {
        error
    } else {
        return;
    };
    let code = error.get("code").and_then(Value::as_str);
    if code != Some("repo.needs_github") && code != Some("repo.no_access") {
        return;
    }
    let mut args = json!({"session": session, "repo": repo});
    if let Some(reference) = reference.and_then(Value::as_str).filter(|s| !s.trim().is_empty()) {
        args.set("ref", json!(reference));
    }
    // No access is granted on GitHub (an install on the organization, its owner's yes), never by a
    // connect to wait on: its retry is the same add, with no wait.
    let retry = if code == Some("repo.needs_github") {
        json!({"action": REPO_ADD_ACTION, "args": args, "wait_action": REPO_WAIT_GITHUB_ACTION})
    } else {
        json!({"action": REPO_ADD_ACTION, "args": args})
    };
    error.set("retry", retry);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn this_folder_answers_from_the_machine_without_the_cli() {
        let folder = std::env::temp_dir();
        let result = call_for_caller(
            Some("own-chat"),
            "own-chat",
            &json!({"name": "this_folder", "arguments": {"path": folder}}),
            |_, _| async { panic!("this_folder reached the CLI") },
        )
        .await;
        assert_eq!(result["isError"], false, "{result}");
        assert_eq!(result["structuredContent"]["projected"], false, "{result}");
        let relative = call_for_caller(
            Some("own-chat"),
            "own-chat",
            &json!({"name": "this_folder", "arguments": {"path": "work"}}),
            |_, _| async { panic!("this_folder reached the CLI") },
        )
        .await;
        assert_eq!(relative["isError"], true, "{relative}");
    }

    /// Leo, 2026-11-25: an empty folder's Cloud chat told him nothing comes back to the Mac.
    #[test]
    fn the_instructions_say_a_mac_folder_is_projected_and_comes_back() {
        assert!(INSTRUCTIONS.contains("projected (empty or not, a git repository or not)"));
        assert!(INSTRUCTIONS.contains("Bring Back"));
        assert!(INSTRUCTIONS.contains("call this_folder"));
        assert!(!INSTRUCTIONS.contains("Nothing on it is copied back to the Mac"));
        assert!(tools().as_array().unwrap().iter().any(|tool| tool["name"] == "this_folder"));
    }
    #[tokio::test]
    async fn cloud_repo_missing_or_foreign_caller_never_invokes_cli() {
        for caller in [None, Some("other-chat")] {
            for tool in ["list_repos", "add_repo"] {
                let result = call_for_caller(
                    caller,
                    "own-chat",
                    &json!({"name":tool,"arguments":{"repo":"org/repo"}}),
                    |_, _| async { panic!("unauthenticated caller reached the CLI") },
                )
                .await;
                assert_eq!(result["isError"], true);
                assert!(
                    result["content"][0]["text"]
                        .as_str()
                        .unwrap()
                        .contains("Restart the chat session")
                );
            }
        }
    }

    #[tokio::test]
    async fn cloud_repo_proven_caller_uses_protected_session() {
        let result = call_for_caller(
            Some("own-chat"),
            "own-chat",
            &json!({"name":"add_repo","arguments":{"repo":"org/repo","session":"other-chat"}}),
            |action, request| async move {
                assert_eq!(action, REPO_ADD_ACTION);
                assert_eq!(request["session"], "own-chat");
                Ok(json!({"state":"done","repo":"org/repo","folder":"/home/chats/own-chat/repo"}))
            },
        )
        .await;
        assert_eq!(result["isError"], false);
    }

    /// A list the Cloud machine did not answer is asked again, and the agent gets the list.
    #[tokio::test]
    async fn an_unanswered_list_is_asked_again() {
        let tries = std::sync::atomic::AtomicU32::new(0);
        let result = call_for_caller(
            Some("own-chat"),
            "own-chat",
            &json!({"name":"list_repos","arguments":{}}),
            |_, _| {
                let n = tries.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                async move {
                    if n == 0 {
                        Err("The Cloud machine returned no repository result.".to_owned())
                    } else {
                        Ok(json!({"repos": [{"name": "org/repo"}]}))
                    }
                }
            },
        )
        .await;
        assert_eq!(result["isError"], false, "{result}");
        assert_eq!(tries.load(std::sync::atomic::Ordering::SeqCst), 2);
    }

    #[test]
    fn instructions_state_the_machine_and_its_lifetime() {
        for fact in [
            "Linux virtual machine",
            "until the machine is deleted",
            "push work",
            // A chat started with no repository (Leo, 2026-11-02), said apart from a Mac folder's.
            "empty when the chat started with none",
            "add_repo",
        ] {
            assert!(INSTRUCTIONS.contains(fact), "instructions lack {fact:?}");
        }
    }

    #[test]
    fn retry_shape_is_stable() {
        let mut result = json!({"code":"repo.needs_github","message":"Connect GitHub."});
        enrich_retry(&mut result, "chat-1", "cmux-platform", Some(&json!("main")));
        assert_eq!(result["retry"]["action"], REPO_ADD_ACTION);
        assert_eq!(
            result["retry"]["args"],
            json!({"session":"chat-1","repo":"cmux-platform","ref":"main"})
        );
    }
    #[test]
    fn no_access_retries_the_add_with_no_wait() {
        let mut result = json!({"code":"repo.no_access","org":"acme"});
        enrich_retry(&mut result, "chat-1", "acme/tool", None);
        assert_eq!(
            result["retry"],
            json!({"action": REPO_ADD_ACTION, "args": {"session":"chat-1","repo":"acme/tool"}})
        );
    }
    #[test]
    fn other_errors_are_not_retried() {
        let mut result = json!({"code":"repo.not_found"});
        enrich_retry(&mut result, "chat", "x", None);
        assert!(result.get("retry").is_none());
    }
}

#[cfg(all(test, unix))]
mod bridge_tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[tokio::test]
    async fn cloud_repo_cli_error_exit_preserves_recovery_and_literal_arguments() {
        let dir = tempfile::tempdir().unwrap();
        let script = dir.path().join("cmux");
        let argv = dir.path().join("argv");
        std::fs::write(&script, format!("#!/bin/sh\nprintf '%s\\n' \"$@\" > '{}'\nprintf '%s\\n' '{{\"code\":\"repo.needs_github\",\"message\":\"Connect GitHub.\",\"install_url\":\"https://github.com/install\"}}'\nexit 1\n", argv.display())).unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o700)).unwrap();
        let result = run_cli_with(
            script.as_os_str(),
            Some(std::ffi::OsStr::new("/tmp/daemon.sock")),
            REPO_ADD_ACTION,
            json!({"session":"chat-1","repo":"literal; $(false)","ref":"main"}),
        )
        .await
        .unwrap();
        assert_eq!(result["code"], "repo.needs_github");
        let words = std::fs::read_to_string(argv).unwrap();
        assert_eq!(
            words.lines().collect::<Vec<_>>(),
            vec![
                "--json",
                "--socket",
                "/tmp/daemon.sock",
                "cloud",
                "repo",
                "add",
                "--session",
                "chat-1",
                "--repo",
                "literal; $(false)",
                "--ref",
                "main"
            ]
        );
        assert_eq!(ok(result)["isError"], false);
        assert_eq!(
            ok(json!({"code":"seed.disk_full","message":"Free disk space and retry."}))["isError"],
            true
        );
    }
}
