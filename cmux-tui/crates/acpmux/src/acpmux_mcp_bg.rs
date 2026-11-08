//! The `acpmux` MCP server's background-task tools (`hub/bg_tasks.rs`, docs/hibernation.md):
//! `bg_start`, `bg_list`, `bg_output` and `bg_stop`, each for this server's own chat. A task
//! started here runs under the daemon, not the harness, so it keeps running while the chat's
//! agent hibernates, and the woken agent finds it by id. The daemon gives the task the
//! environment the chat's agent runs with (`Hub::bg_env`), not this server's, which a harness
//! may filter (Codex passes only a few names).
//!
//! Condensed tools (Leo, 2026-11-03: "hmm claude code desktop's summarization of tool
//! calls/parsing of them seem kinda good? we should bea bel to do that AND have condensed tools
//! that are callable in acpmux/cmux-next..."): each takes an optional `description` (a few
//! words, what the call is for, which the transcript titles its row with), and each result's
//! first text line is a one-line outcome, also `structuredContent.summary`, with
//! `structuredContent.status` `running`, `ok` or `failed`. `bg_start` asks the daemon to tell
//! the chat when the task ends (`notify`, on unless false; `hub/bg_notify.rs`).
//!
//! `run_wait` is a `bg_start` the server writes: one blocking `gh run watch` or `gh pr checks
//! --watch` under the daemon, then the failed jobs read once, and the outcome printed last, which
//! the task's summary is (`resultLine`), so the chat wakes once with "... passed" or "... failed:
//! JOB, JOB". A machine with no `gh` is refused before a task starts.

use super::{error_result, ok, refusal};
use crate::client::Client;
use crate::rpc::method;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::sync::Arc;

pub(super) const TOOLS: [&str; 5] = ["bg_start", "bg_list", "bg_output", "bg_stop", "run_wait"];

pub(super) fn tools() -> Vec<Value> {
    let id =
        json!({"type": "string", "description": "The task's id, as bg_start or bg_list gave it."});
    let description = json!({"type": "string", "description": "A few words: what this call is for. The transcript titles the call with it."});
    vec![
        json!({"name": "bg_start", "description": "Run a shell command in the background: a dev server, a watcher, a long build or test run. It keeps running while this chat is idle or its agent hibernates, and after a restart; read it later with bg_output by its id. Prefer it to the harness's own background shell, which ends when the agent hibernates. Returns at once with the task's id. When it ends, this chat gets one message with how it ended and its last lines (unless notify is false), so there is no need to poll it.",
            "inputSchema": {"type": "object", "properties": {
                "command": {"type": "string", "description": "The command, run by bash -c (/bin/sh where there is no bash), in the agent's environment."},
                "cwd": {"type": "string", "description": "Its folder (default: the chat's)."},
                "description": {"type": "string", "description": "A few words: what the task is for. Kept with the task; bg_list, bg_output and the end message name it by this."},
                "notify": {"type": "boolean", "description": "Send this chat one message when the task ends (default true). It waits for a running turn to end; it never interrupts one."}},
                "required": ["command"]}}),
        json!({"name": "bg_list", "description": "This chat's background tasks, oldest first: id, state (running, exited, stopped, killed, lost), exit code and the tail of the output.",
            "inputSchema": {"type": "object", "properties": {"description": description}}}),
        json!({"name": "bg_output", "description": "Read a background task's output: by default its last 64 KiB; with fromByte, from there (pass the last nextByte to read only what is new). Each task keeps its newest 8 MiB of output; skippedBytes says how much before fromByte is gone.",
            "inputSchema": {"type": "object", "properties": {"id": id, "description": description,
                "fromByte": {"type": "integer", "minimum": 0},
                "maxBytes": {"type": "integer", "minimum": 1, "maximum": 1048576}},
                "required": ["id"]}}),
        json!({"name": "bg_stop", "description": "Stop a background task: SIGTERM to its process group, then SIGKILL to the group 5 s later; returns once it ended.",
            "inputSchema": {"type": "object", "properties": {"id": id, "description": description}, "required": ["id"]}}),
        json!({"name": "run_wait", "description": "Wait for a GitHub Actions run, or a pull request's checks, in the background, and get one message in this chat when it is done: passed, or failed with the failed jobs named. Returns at once with a background task id (bg_output reads it meanwhile). Use it instead of polling CI yourself. Needs the gh CLI.",
            "inputSchema": {"type": "object", "properties": {
                "repo": {"type": "string", "description": "OWNER/REPO."},
                "run": {"type": "integer", "minimum": 1, "description": "The Actions run id to wait for."},
                "pr": {"type": "integer", "minimum": 1, "description": "The pull request whose checks to wait for (instead of run)."},
                "sha": {"type": "string", "description": "With pr: the head commit the checks must be for; a pull request whose head is another commit, before or after the wait, fails."},
                "description": description},
                "required": ["repo"]}}),
    ]
}

pub(super) async fn call(daemon: &Arc<Client>, session: &str, name: &str, args: &Value) -> Value {
    let mut params = match args {
        Value::Object(_) => args.clone(),
        Value::Null => json!({}),
        _ => return error_result("arguments must be an object".to_owned()),
    };
    params.set("sessionId", json!(session));
    if name == "run_wait" {
        let wait = match RunWait::of(&params) {
            Ok(wait) => wait,
            Err(why) => return error_result(why),
        };
        if !on_path("gh") {
            return error_result(
                "run_wait needs the gh CLI, and none is on this machine's PATH; install gh (https://cli.github.com) or wait another way".to_owned(),
            );
        }
        params = json!({"sessionId": session, "command": wait.script(),
            "description": wait.description, "notify": true, "resultLine": true});
        return match daemon.request(method::MUX_BG_START, params).await {
            Ok(r) => {
                let (line, status) = outcome("bg_start", &r);
                let mut structured = r;
                structured.set("summary", json!(line));
                structured.set("status", json!(status));
                let id = structured.get("id").and_then(Value::as_str).unwrap_or_default();
                let text = format!(
                    "{line}\nBackground task {id}; this chat gets one message when it is done."
                );
                ok(text, structured)
            }
            Err(e) => refusal(e),
        };
    }
    // A call's own description titles its row; only a start keeps it, with the task.
    if name == "bg_start" {
        if params.get("notify").is_none_or(Value::is_null) {
            params.set("notify", json!(true));
        }
    } else if let Some(p) = params.as_object_mut() {
        p.remove("description");
    }
    let m = match name {
        "bg_start" => method::MUX_BG_START,
        "bg_list" => method::MUX_BG_LIST,
        "bg_output" => method::MUX_BG_OUTPUT,
        "bg_stop" => method::MUX_BG_STOP,
        other => return error_result(crate::mcp_hint::unknown_tool(other, TOOLS)),
    };
    match daemon.request(m, params).await {
        Ok(r) => {
            let (line, status) = outcome(name, &r);
            let mut structured = r;
            structured.set("summary", json!(line));
            structured.set("status", json!(status));
            ok(format!("{line}\n{}", summary(name, &structured)).trim_end().to_owned(), structured)
        }
        Err(e) => refusal(e),
    }
}

/// The result's one-line outcome and status (module docs): a task's own (`bg_run::outcome`, as
/// the daemon put it in its view), or for a list how many run, finished and failed.
fn outcome(name: &str, r: &Value) -> (String, &'static str) {
    if name != "bg_list" {
        return crate::bg_run::outcome(r);
    }
    let tasks = r.get("tasks").and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default();
    let count =
        |status: &str| tasks.iter().filter(|t| crate::bg_run::outcome(t).1 == status).count();
    let (running, ok, failed) = (count("running"), count("ok"), count("failed"));
    if tasks.is_empty() {
        return ("No background tasks.".to_owned(), "ok");
    }
    let plural = if tasks.len() == 1 { "" } else { "s" };
    let line = format!(
        "{} background task{plural}: {running} running, {ok} ok, {failed} failed",
        tasks.len()
    );
    let status = if running > 0 {
        "running"
    } else if failed > 0 {
        "failed"
    } else {
        "ok"
    };
    (line, status)
}

/// One task as a line, then its tail.
fn task_line(t: &Value) -> String {
    let s = |k: &str| t.get(k).and_then(Value::as_str).unwrap_or_default();
    let int = |k: &str| t.get(k).and_then(Value::as_i64);
    let end = match (int("exitCode"), int("signal")) {
        (Some(code), _) => format!(" (exit {code})"),
        (_, Some(signal)) => format!(" (signal {signal})"),
        _ => String::new(),
    };
    let what = match s("description") {
        "" => s("command").to_owned(),
        d => format!("{d}: {}", s("command")),
    };
    format!("{}  [{}{end}]  {what}\n{}", s("id"), s("state"), s("tail").trim_end())
}

fn summary(name: &str, r: &Value) -> String {
    let field = |k: &str| r.get(k).unwrap_or(&Value::Null);
    match name {
        "bg_list" => {
            let tasks = field("tasks").as_array().map(Vec::as_slice).unwrap_or_default();
            tasks.iter().map(task_line).collect::<Vec<_>>().join("\n\n")
        }
        "bg_output" => format!(
            "{}\n[{} bytes {}..{} of {}; next fromByte {}]",
            field("text").as_str().unwrap_or_default(),
            field("id").as_str().unwrap_or_default(),
            field("fromByte"),
            field("nextByte"),
            field("totalBytes"),
            field("nextByte")
        ),
        _ => task_line(r),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A list's outcome counts its tasks by status; the list runs while any task runs.
    #[test]
    fn a_lists_outcome_counts_its_tasks() {
        let task =
            |state: &str, code: i64| json!({"state": state, "exitCode": code, "command": "c"});
        let r = json!({"tasks": [task("running", 0), task("exited", 0), task("exited", 1)]});
        let line = "3 background tasks: 1 running, 1 ok, 1 failed".to_owned();
        assert_eq!(outcome("bg_list", &r), (line, "running"));
        let done = json!({"tasks": [task("exited", 0), task("exited", 1)]});
        assert_eq!(outcome("bg_list", &done).1, "failed");
        assert_eq!(
            outcome("bg_list", &json!({"tasks": []})),
            ("No background tasks.".to_owned(), "ok")
        );
    }

    /// A call names a repo and a run or a pull request (with an optional sha); anything else is
    /// refused before a task starts, and the description defaults to what is waited for.
    #[test]
    fn run_wait_checks_its_arguments() {
        let of = |v: Value| RunWait::of(&v);
        let run = of(json!({"repo": "o/r", "run": 7})).unwrap();
        assert_eq!(
            (run.target, run.description.as_str()),
            (Target::Run(7), "Actions run 7 in o/r")
        );
        let pr =
            of(json!({"repo": "o/r", "pr": "12", "sha": "ABCDEF1", "description": "CI"})).unwrap();
        assert_eq!(pr.target, Target::Pr { number: 12, sha: Some("abcdef1".into()) });
        assert_eq!(pr.description, "CI");
        for bad in [
            json!({"run": 7}),
            json!({"repo": "o/r; rm -rf /", "run": 7}),
            json!({"repo": "o/r"}),
            json!({"repo": "o/r", "run": 7, "pr": 1}),
            json!({"repo": "o/r", "run": 0}),
            json!({"repo": "o/r", "run": 7, "sha": "abcdef1"}),
            json!({"repo": "o/r", "pr": 1, "sha": "not-a-sha"}),
        ] {
            assert!(of(bad.clone()).is_err(), "{bad}");
        }
    }

    /// The script waits with one blocking gh call, names what failed, and ends on its outcome
    /// line and gh's exit code; a pinned head that is another commit fails without a wait.
    #[cfg(unix)]
    #[test]
    fn run_wait_scripts_end_on_their_outcome() {
        let dir = cmux_unix_socket::short_test_dir("run-wait");
        let calls = dir.path().join("calls");
        let gh = dir.path().join("gh");
        let fake = format!(
            r#"#!/bin/sh
echo "$*" >> '{}'
case "$*" in
  "run watch"*) exit 1 ;;
  "run view"*"--json conclusion"*) echo "conclusion: failure  https://example.com/run/7" ;;
  "run view"*"--json jobs"*) echo "build, lint" ;;
  "pr view"*) echo 0123456789abcdef0123456789abcdef01234567 ;;
  "pr checks"*--watch*) exit 0 ;;
  "pr checks"*) echo "" ;;
esac
"#,
            calls.display()
        );
        std::fs::write(&gh, fake).unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&gh, std::fs::Permissions::from_mode(0o755)).unwrap();
        let path =
            format!("{}:{}", dir.path().display(), std::env::var("PATH").unwrap_or_default());
        let run = |args: Value| {
            let script = RunWait::of(&args).unwrap().script();
            let out = std::process::Command::new("sh")
                .arg("-c")
                .arg(script)
                .env("PATH", &path)
                .output()
                .unwrap();
            let text = String::from_utf8_lossy(&out.stdout).into_owned();
            (out.status.code(), text.lines().last().unwrap_or_default().to_owned(), text)
        };
        let (code, last, all) = run(json!({"repo": "o/r", "run": 7}));
        assert_eq!(
            (code, last.as_str()),
            (Some(1), "Actions run 7 in o/r failed: build, lint"),
            "{all}"
        );
        assert!(all.contains("failed jobs: build, lint"), "{all}");
        let (code, last, _) = run(json!({"repo": "o/r", "pr": 3, "sha": "0123456789abcdef"}));
        assert_eq!((code, last.as_str()), (Some(0), "Checks of o/r#3 passed"));
        let (code, last, _) = run(json!({"repo": "o/r", "pr": 3, "sha": "fedcba9"}));
        assert_eq!(code, Some(2));
        assert!(last.contains("its head is 0123456789abcdef"), "{last}");
        let calls = std::fs::read_to_string(&calls).unwrap();
        // The pinned-elsewhere call never waited: the one wait is the earlier call's.
        assert_eq!(calls.matches("--watch").count(), 1, "{calls}");
        assert!(calls.contains("run watch 7 --repo o/r --exit-status"), "{calls}");
    }

    /// A task that prints its outcome last is summed up by that line once it ended.
    #[test]
    fn a_result_line_task_is_summed_up_by_its_last_line() {
        let view = json!({"state": "exited", "exitCode": 1, "command": "c", "description": "d",
            "resultLine": true, "lastLine": "Checks of o/r#3 failed: build"});
        assert_eq!(
            crate::bg_run::outcome(&view),
            ("Checks of o/r#3 failed: build".to_owned(), "failed")
        );
        let running = json!({"state": "running", "command": "c", "description": "d", "resultLine": true, "lastLine": "x"});
        assert_eq!(crate::bg_run::outcome(&running).0, "Background command running: d");
    }
}

/// A checked `run_wait` call: what to wait for and what the task is called.
#[derive(Debug, PartialEq, Eq)]
struct RunWait {
    repo: String,
    target: Target,
    description: String,
}

#[derive(Debug, PartialEq, Eq)]
enum Target {
    Run(u64),
    Pr { number: u64, sha: Option<String> },
}

/// A positive integer argument, as a number or a string of digits.
fn number(params: &Value, key: &str) -> Result<Option<u64>, String> {
    match params.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(v) => v
            .as_u64()
            .or_else(|| v.as_str().and_then(|s| s.trim().parse().ok()))
            .filter(|n| *n > 0)
            .map(Some)
            .ok_or_else(|| format!("{key} must be a positive integer")),
    }
}

impl RunWait {
    fn of(params: &Value) -> Result<Self, String> {
        let s = |k: &str| {
            params.get(k).and_then(Value::as_str).map(str::trim).filter(|v| !v.is_empty())
        };
        let repo = s("repo").ok_or("repo is required (OWNER/REPO)")?;
        let part = |p: &str| {
            !p.is_empty()
                && p.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
        };
        if !repo.split_once('/').is_some_and(|(o, r)| part(o) && part(r)) {
            return Err(format!("repo must be OWNER/REPO, not {repo:?}"));
        }
        let sha = s("sha").map(str::to_ascii_lowercase);
        if let Some(sha) = &sha
            && !((7..=40).contains(&sha.len()) && sha.chars().all(|c| c.is_ascii_hexdigit()))
        {
            return Err(format!("sha must be a commit sha (7 to 40 hex digits), not {sha:?}"));
        }
        let target = match (number(params, "run")?, number(params, "pr")?) {
            (Some(run), None) if sha.is_none() => Target::Run(run),
            (Some(_), None) => return Err("sha goes with pr, not run".to_owned()),
            (None, Some(number)) => Target::Pr { number, sha },
            (Some(_), Some(_)) => return Err("give run or pr, not both".to_owned()),
            (None, None) => {
                return Err("give run (an Actions run id) or pr (a pull request number)".to_owned());
            }
        };
        let description = match (s("description"), &target) {
            (Some(d), _) => d.to_owned(),
            (None, Target::Run(run)) => format!("Actions run {run} in {repo}"),
            (None, Target::Pr { number, .. }) => format!("checks of {repo}#{number}"),
        };
        Ok(Self { repo: repo.to_owned(), target, description })
    }

    /// The task's command: one blocking `gh` wait, then one read of what failed, and the outcome
    /// as its last line (the task's summary, `resultLine`). Every value in it was checked above
    /// (digits, hex, OWNER/REPO characters), so nothing needs quoting.
    fn script(&self) -> String {
        let repo = &self.repo;
        let mut lines = vec![
            "command -v gh >/dev/null 2>&1 || { echo 'run_wait: gh is not installed'; exit 127; }"
                .to_owned(),
        ];
        match &self.target {
            Target::Run(run) => {
                let name = format!("Actions run {run} in {repo}");
                lines.push(format!("gh run watch {run} --repo {repo} --exit-status --interval 30 >/dev/null 2>&1; rc=$?"));
                lines.push(format!("gh run view {run} --repo {repo} --json conclusion,url --jq '\"conclusion: \" + (.conclusion // \"none\") + \"  \" + .url'"));
                lines.push(format!("failed=$(gh run view {run} --repo {repo} --json jobs --jq '[.jobs[] | select(.conclusion == \"failure\" or .conclusion == \"cancelled\" or .conclusion == \"timed_out\") | .name] | join(\", \")' 2>/dev/null)"));
                lines.push("[ -n \"$failed\" ] && echo \"failed jobs: $failed\"".to_owned());
                lines.push(format!("if [ $rc -eq 0 ]; then echo \"{name} passed\"; else echo \"{name} failed${{failed:+: $failed}}\"; fi"));
            }
            Target::Pr { number, sha } => {
                let name = format!("Checks of {repo}#{number}");
                let head =
                    format!("gh pr view {number} --repo {repo} --json headRefOid --jq .headRefOid");
                if let Some(sha) = sha {
                    lines.push(format!("head=$({head}) || {{ echo \"{name} failed: its head could not be read\"; exit 2; }}"));
                    lines.push(format!("case \"$head\" in {sha}*) ;; *) echo \"{name} failed: its head is $head, not {sha}\"; exit 2;; esac"));
                }
                lines.push(format!("gh pr checks {number} --repo {repo} --watch --fail-fast --interval 30 >/dev/null 2>&1; rc=$?"));
                lines.push(format!("failed=$(gh pr checks {number} --repo {repo} --json name,bucket --jq '[.[] | select(.bucket == \"fail\" or .bucket == \"cancel\") | .name] | join(\", \")' 2>/dev/null)"));
                lines.push("[ -n \"$failed\" ] && echo \"failed checks: $failed\"".to_owned());
                if let Some(sha) = sha {
                    lines.push(format!("now=$({head})"));
                    lines.push(format!("case \"$now\" in {sha}*) ;; *) echo \"{name} failed: its head moved to $now while it was waited for\"; exit 2;; esac"));
                }
                lines.push(format!("if [ $rc -eq 0 ]; then echo \"{name} passed\"; else echo \"{name} failed${{failed:+: $failed}}\"; fi"));
            }
        }
        lines.push("exit $rc".to_owned());
        lines.join("\n")
    }
}

/// Whether an executable named `name` is on this process's PATH (true when it has none).
fn on_path(name: &str) -> bool {
    // No PATH here says nothing of the agent's: the task's own check decides then.
    std::env::var_os("PATH").is_none_or(|path| {
        std::env::split_paths(&path).any(|dir| {
            let file = dir.join(name);
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                file.metadata().is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
            }
            #[cfg(not(unix))]
            {
                file.is_file()
            }
        })
    })
}
