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
//! `run_wait` is a `bg_start` the server writes: one blocking wait under the daemon, then the
//! failed jobs named, and the outcome printed last, which the task's summary is (`resultLine`), so
//! the chat wakes once with "... passed" or "... failed: JOB, JOB". Where `glaeda-gh` is on the
//! PATH and answers `glaeda-gh gh --probe`, the wait is one `glaeda-gh wait run|pr`: the host's
//! one shared daemon polls GitHub for every waiter, and the task itself makes no GitHub call. Only
//! a machine without it (a user's own Mac) waits with `gh run watch` or `gh pr checks --watch`,
//! every 120 s. Leo, 2026-11-17, on the Claude desktop app showing a GitHub rate limit: "this
//! is... interesting. so claude desktop shows rate limit on hover of the github links
//! sometimes..."; one gh watcher every 30 s spent about 240 to 360 REST calls an hour of his
//! login's quota. A machine with neither is refused before a task starts.
//!
//! Own tasks first (incident 2026-11-14: a subagent listed every task of its chat and stopped
//! all ten running ones, none its own): `bg_list` lists the tasks its caller started (that
//! subagent's, or the lead's own) unless `all` is true, and says how many it left out;
//! `bg_stop` refuses a task another caller started, naming who, unless `force_other_owner` is
//! true. The caller is the one `acpmux_mcp.rs` reads from the call (`subagent_call.rs`).

use super::{error_result, ok, refusal};
use crate::client::Client;
use crate::rpc::method;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};
use std::process::Stdio;
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
        json!({"name": "bg_list", "description": "Your background tasks (the ones you started; a subagent sees its own), oldest first: id, state (running, exited, stopped, killed, lost), exit code and the tail of the output. Tasks other subagents or the lead started are counted, not listed, unless all is true; they are not yours to stop.",
            "inputSchema": {"type": "object", "properties": {"description": description,
                "all": {"type": "boolean", "description": "List every task of this chat, whoever started it, each with who started it (default false: only yours)."}}}}),
        json!({"name": "bg_output", "description": "Read a background task's output: by default its last 64 KiB; with fromByte, from there (pass the last nextByte to read only what is new). Each task keeps its newest 8 MiB of output; skippedBytes says how much before fromByte is gone.",
            "inputSchema": {"type": "object", "properties": {"id": id, "description": description,
                "fromByte": {"type": "integer", "minimum": 0},
                "maxBytes": {"type": "integer", "minimum": 1, "maximum": 1048576}},
                "required": ["id"]}}),
        json!({"name": "bg_stop", "description": "Stop a background task you started: SIGTERM to every process it started (its process group and those that left it), then SIGKILL to them 5 s later; returns once it ended. A task another subagent or the lead started is refused, naming who started it.",
            "inputSchema": {"type": "object", "properties": {"id": id, "description": description,
                "force_other_owner": {"type": "boolean", "description": "Stop it even though another subagent or the lead started it. Only when its owner asked you to or is gone; never as cleanup (default false)."}},
                "required": ["id"]}}),
        json!({"name": "run_wait", "description": "Wait for a GitHub Actions run, or a pull request's checks, in the background, and get one message in this chat when it is done: passed, or failed with the failed jobs named. Returns at once with a background task id (bg_output reads it meanwhile). Use it instead of polling CI yourself. Needs glaeda-gh or the gh CLI.",
            "inputSchema": {"type": "object", "properties": {
                "repo": {"type": "string", "description": "OWNER/REPO."},
                "run": {"type": "integer", "minimum": 1, "description": "The Actions run id to wait for."},
                "pr": {"type": "integer", "minimum": 1, "description": "The pull request whose checks to wait for (instead of run)."},
                "sha": {"type": "string", "description": "With pr: the head commit the checks must be for; a pull request whose head is another commit, before or after the wait, fails."},
                "description": description},
                "required": ["repo"]}}),
    ]
}

/// What a Claude Code subagent's start (`callerSubagent`) adds to its answer: when its end comes.
const SUBAGENT_END: &str = "You get its end after your next Bash or acpmux tool call; if you end first, it goes to your lead. bg_output reads it now.";

pub(super) async fn call(daemon: &Arc<Client>, session: &str, name: &str, args: &Value) -> Value {
    let by_subagent = args.get("callerSubagent").is_some_and(Value::is_object);
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
        let Some(waiter) = Waiter::find(std::env::var_os("PATH")).await else {
            return error_result(
                "run_wait needs glaeda-gh or the gh CLI, and neither is on this machine's PATH; install gh (https://cli.github.com) or wait another way".to_owned(),
            );
        };
        let sub = params.get("callerSubagent").cloned().unwrap_or(Value::Null);
        params = json!({"sessionId": session, "command": wait.script(&waiter),
            "description": wait.description, "notify": true, "resultLine": true,
            "callerSubagent": sub});
        return match daemon.request(method::MUX_BG_START, params).await {
            Ok(r) => {
                let (line, status) = outcome("bg_start", &r);
                let mut structured = r;
                structured.set("summary", json!(line));
                structured.set("status", json!(status));
                let id = structured.get("id").and_then(Value::as_str).unwrap_or_default();
                let text = if by_subagent {
                    format!("{line}\nBackground task {id}. {SUBAGENT_END}")
                } else {
                    format!(
                        "{line}\nBackground task {id}; this chat gets one message when it is done."
                    )
                };
                if by_subagent {
                    structured.set("endMessage", json!(SUBAGENT_END));
                }
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
            let mut text = format!("{line}\n{}", summary(name, &structured)).trim_end().to_owned();
            if by_subagent && name == "bg_start" && structured.get("notify") == Some(&json!(true)) {
                text.push_str(&format!("\n{SUBAGENT_END}"));
                // Claude Code shows the structured result, not the text, when there is one.
                structured.set("endMessage", json!(SUBAGENT_END));
            }
            ok(text, structured)
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
    // Tasks the list left out: other callers' (`hub::BgScope`).
    let others = r.get("otherOwners").and_then(Value::as_u64).unwrap_or(0);
    let others = match others {
        0 => String::new(),
        1 => "; 1 more started by another subagent or the lead (not yours; all: true lists it)"
            .to_owned(),
        n => format!(
            "; {n} more started by other subagents or the lead (not yours; all: true lists them)"
        ),
    };
    if tasks.is_empty() {
        let line = if others.is_empty() {
            "No background tasks.".to_owned()
        } else {
            format!("No background tasks of yours{others}")
        };
        return (line, "ok");
    }
    let plural = if tasks.len() == 1 { "" } else { "s" };
    let line = format!(
        "{} background task{plural}: {running} running, {ok} ok, {failed} failed{others}",
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
    let by = t.get("startedBy").filter(|v| v.is_object()).map_or(String::new(), |sub| {
        format!("  (started by {})", crate::hub::bg_owner_words(Some(sub)))
    });
    format!("{}  [{}{end}]  {what}{by}\n{}", s("id"), s("state"), s("tail").trim_end())
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
        // Tasks of other callers are counted, never listed as the caller's.
        let others = json!({"tasks": [task("running", 0)], "otherOwners": 9});
        assert!(outcome("bg_list", &others).0.ends_with(
            "1 running, 0 ok, 0 failed; 9 more started by other subagents or the lead (not yours; all: true lists them)"
        ));
        let none = json!({"tasks": [], "otherOwners": 1});
        assert!(outcome("bg_list", &none).0.starts_with("No background tasks of yours; 1 more"));
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

    /// Where there is no glaeda-gh, the script waits with one blocking gh call every 120 s, names
    /// what failed, and ends on its outcome line and gh's exit code; a pinned head that is another
    /// commit fails without a wait.
    #[cfg(unix)]
    #[test]
    fn run_wait_gh_scripts_end_on_their_outcome() {
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
            let script = RunWait::of(&args).unwrap().script(&Waiter::Gh);
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
        assert!(calls.contains("run watch 7 --repo o/r --exit-status --interval 120"), "{calls}");
        assert!(
            calls.contains("pr checks 3 --repo o/r --watch --fail-fast --interval 120"),
            "{calls}"
        );
        assert!(!calls.contains("--interval 30"), "{calls}");
    }

    /// A fake executable at `path` that appends its arguments to `calls` and runs `body`.
    #[cfg(unix)]
    fn fake(path: &Path, calls: &Path, body: &str) {
        use std::os::unix::fs::PermissionsExt;
        let text = format!("#!/bin/sh\necho \"$*\" >> '{}'\n{body}\n", calls.display());
        std::fs::write(path, text).unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    /// Where glaeda-gh answers its probe, the script is one `glaeda-gh wait` (by its full path,
    /// quoted) and no gh call: it names the failed jobs or checks the wait's summary lists, reads
    /// a pinned head from the daemon's cache, and turns each of the wait's exit codes into its
    /// outcome line.
    #[cfg(unix)]
    #[test]
    fn run_wait_glaeda_scripts_wait_once_through_the_daemon() {
        let dir = cmux_unix_socket::short_test_dir("run-wait-glaeda");
        let bin = dir.path().join("it's bin");
        std::fs::create_dir(&bin).unwrap();
        let calls = dir.path().join("calls");
        let gh_calls = dir.path().join("gh-calls");
        let glaeda = bin.join("glaeda-gh");
        fake(
            &glaeda,
            &calls,
            r#"case "$*" in
  "wait run o/r/7 --jobs --timeout 21600")
    echo "o/r/7 CI: completed / failure  attempt 1  main 0123456789"
    echo "jobs: 3 total, 2 failed, 0 not finished"
    echo "  failed: build (step: compile)  https://example.com/job/1"
    echo "  cancelled: lint  https://example.com/job/2"
    echo "https://example.com/run/7"
    exit 1 ;;
  "wait run o/r/8"*) exit 2 ;;
  "status pr o/r#3 --field head") echo 0123456789abcdef0123456789abcdef01234567 ;;
  "status pr o/r#5 --field head") echo "" ;;
  "wait pr o/r#3 --until done --timeout 21600") echo "checks SUCCESS: 5 passed, 0 failed"; exit 0 ;;
  "wait pr o/r#4 --until done"*) exit 4 ;;
  "wait pr o/r#5 --until done"*) exit 0 ;;
  "wait pr o/r#6 --until done"*) exit 6 ;;
esac"#,
        );
        fake(&dir.path().join("gh"), &gh_calls, "exit 1");
        let path =
            format!("{}:{}", dir.path().display(), std::env::var("PATH").unwrap_or_default());
        let waiter = Waiter::Glaeda(glaeda.clone());
        let run = |args: Value| {
            let script = RunWait::of(&args).unwrap().script(&waiter);
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
            (Some(1), "Actions run 7 in o/r failed: build (step: compile), lint"),
            "{all}"
        );
        assert!(all.contains("failed jobs: build (step: compile), lint"), "{all}");
        assert!(all.contains("https://example.com/run/7"), "the wait's summary is kept: {all}");
        let (code, last, _) = run(json!({"repo": "o/r", "run": 8}));
        assert_eq!(
            (code, last.as_str()),
            (Some(2), "Actions run 8 in o/r failed: not done within 6 h")
        );
        let (code, last, _) = run(json!({"repo": "o/r", "pr": 3, "sha": "0123456789abcdef"}));
        assert_eq!((code, last.as_str()), (Some(0), "Checks of o/r#3 passed"));
        let (code, last, _) = run(json!({"repo": "o/r", "pr": 3, "sha": "fedcba9"}));
        assert_eq!(code, Some(2));
        assert!(last.contains("its head is 0123456789abcdef"), "{last}");
        let (code, last, _) = run(json!({"repo": "o/r", "pr": 4}));
        assert_eq!(code, Some(4));
        assert!(last.contains("conflicts with its base"), "{last}");
        // A head the daemon cannot read, before or after the wait, is not taken as the pinned one.
        let (code, last, _) = run(json!({"repo": "o/r", "pr": 5, "sha": "abcdef1"}));
        assert_eq!(
            (code, last.as_str()),
            (Some(2), "Checks of o/r#5 failed: its head could not be read")
        );
        let (code, last, _) = run(json!({"repo": "o/r", "pr": 6}));
        assert_eq!(
            (code, last.as_str()),
            (Some(6), "Checks of o/r#6 failed: no check ever reported on its head")
        );
        let calls = std::fs::read_to_string(&calls).unwrap();
        // The pinned-elsewhere call never waited: the one wait of #3 is the earlier call's.
        assert_eq!(calls.matches("wait pr o/r#3").count(), 1, "{calls}");
        assert!(
            !gh_calls.exists(),
            "no gh call: {}",
            std::fs::read_to_string(&gh_calls).unwrap_or_default()
        );
    }

    /// glaeda-gh is used where it answers its probe; an older one (a usage error) or none leaves
    /// gh, and a machine with neither has no waiter.
    #[cfg(unix)]
    #[tokio::test]
    async fn run_wait_prefers_a_glaeda_gh_that_answers_its_probe() {
        let dir = cmux_unix_socket::short_test_dir("run-wait-find");
        let calls = dir.path().join("calls");
        let (new, old, gh_only, none) = (
            dir.path().join("new"),
            dir.path().join("old"),
            dir.path().join("gh"),
            dir.path().join("none"),
        );
        for d in [&new, &old, &gh_only, &none] {
            std::fs::create_dir(d).unwrap();
        }
        fake(&new.join("glaeda-gh"), &calls, r#"[ "$*" = "gh --probe" ] && echo "broker 2""#);
        fake(&old.join("glaeda-gh"), &calls, "echo 'usage: glaeda-gh' >&2; exit 2");
        fake(&gh_only.join("gh"), &calls, "exit 0");
        let path = |dirs: &[&PathBuf]| Some(std::env::join_paths(dirs).unwrap());
        assert_eq!(
            Waiter::find(path(&[&new, &gh_only])).await,
            Some(Waiter::Glaeda(new.join("glaeda-gh")))
        );
        assert_eq!(Waiter::find(path(&[&old, &gh_only])).await, Some(Waiter::Gh));
        assert_eq!(Waiter::find(path(&[&none])).await, None);
        assert_eq!(Waiter::find(None).await, Some(Waiter::Gh));
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

    /// The task's command (module docs): one blocking wait, then what failed, and the outcome as
    /// its last line (the task's summary, `resultLine`). Every value in it was checked above
    /// (digits, hex, OWNER/REPO characters), so only glaeda-gh's path needs quoting.
    fn script(&self, waiter: &Waiter) -> String {
        match waiter {
            Waiter::Glaeda(path) => self.glaeda_script(&sh_quote(&path.to_string_lossy())),
            Waiter::Gh => self.gh_script(),
        }
    }

    /// One `glaeda-gh wait`: the host's daemon polls GitHub for it, so the task makes no GitHub
    /// call of its own. What failed is what the wait's summary lists.
    fn glaeda_script(&self, glaeda: &str) -> String {
        let repo = &self.repo;
        let mut lines = vec![format!("g={glaeda}")];
        let (name, wait, what) = match &self.target {
            Target::Run(run) => (
                format!("Actions run {run} in {repo}"),
                format!("\"$g\" wait run {repo}/{run} --jobs --timeout {WAIT_TIMEOUT_S}"),
                "jobs",
            ),
            Target::Pr { number, .. } => (
                format!("Checks of {repo}#{number}"),
                format!("\"$g\" wait pr {repo}#{number} --until done --timeout {WAIT_TIMEOUT_S}"),
                "checks",
            ),
        };
        let pinned = match &self.target {
            Target::Pr { number, sha: Some(sha) } => {
                Some((format!("\"$g\" status pr {repo}#{number} --field head 2>/dev/null"), sha))
            }
            _ => None,
        };
        if let Some((head, sha)) = &pinned {
            // A head the daemon has not read yet is checked after the wait, which reads it.
            lines.push(format!("head=$({head})"));
            lines.push(format!("case \"$head\" in ''|{sha}*) ;; *) echo \"{name} failed: its head is $head, not {sha}\"; exit 2;; esac"));
        }
        lines.push(format!("out=$({wait} 2>&1); rc=$?"));
        lines.push("printf '%s\\n' \"$out\"".to_owned());
        lines.push(format!("failed=$(printf '%s\\n' \"$out\" | awk '{FAILED_AWK}')"));
        lines.push(format!("[ -n \"$failed\" ] && echo \"failed {what}: $failed\""));
        if let Some((head, sha)) = &pinned {
            lines.push(format!("now=$({head})"));
            lines.push(format!("case \"$now\" in {sha}*) ;; '') echo \"{name} failed: its head could not be read\"; exit 2;; *) echo \"{name} failed: its head moved to $now while it was waited for\"; exit 2;; esac"));
        }
        let hours = WAIT_TIMEOUT_S / 3600;
        lines.push(format!(
            "case $rc in 0) echo \"{name} passed\";; \
             1) echo \"{name} failed${{failed:+: $failed}}\";; \
             2) echo \"{name} failed: not done within {hours} h\";; \
             3) echo \"{name} failed: the glaeda-gh daemon is not running (glaeda-gh restart starts it)\";; \
             4) echo \"{name} failed: it conflicts with its base, so its checks run only after the next push\";; \
             6) echo \"{name} failed: no check ever reported on its head\";; \
             *) echo \"{name} failed: glaeda-gh wait exited $rc\";; esac"
        ));
        lines.push("exit $rc".to_owned());
        lines.join("\n")
    }

    /// One blocking `gh` wait every `GH_INTERVAL_S`, then one read of what failed: only where
    /// there is no glaeda-gh, since each watcher polls on the login's own quota.
    fn gh_script(&self) -> String {
        let repo = &self.repo;
        let mut lines = vec![
            "command -v gh >/dev/null 2>&1 || { echo 'run_wait: gh is not installed'; exit 127; }"
                .to_owned(),
        ];
        match &self.target {
            Target::Run(run) => {
                let name = format!("Actions run {run} in {repo}");
                lines.push(format!("gh run watch {run} --repo {repo} --exit-status --interval {GH_INTERVAL_S} >/dev/null 2>&1; rc=$?"));
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
                lines.push(format!("gh pr checks {number} --repo {repo} --watch --fail-fast --interval {GH_INTERVAL_S} >/dev/null 2>&1; rc=$?"));
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

/// How long a glaeda-gh wait waits before it ends as not done: 6 h, an Actions job's own limit.
const WAIT_TIMEOUT_S: u64 = 6 * 3600;

/// How often the gh fallback reads the run or the checks: each read spends the login's own REST
/// quota (about 2 to 3 calls), so 120 s keeps one watcher near 60 to 90 calls an hour.
const GH_INTERVAL_S: u64 = 120;

/// How long `glaeda-gh gh --probe` may take before the gh fallback is used.
const PROBE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

/// The failed jobs or checks a `glaeda-gh wait` summary lists, comma-joined: its lines
/// `  failed: NAME (step: S)  URL` (or cancelled, timed_out, ...), without the URL.
const FAILED_AWK: &str = r#"/^  (failed|cancelled|timed_out|startup_failure|action_required): /{sub(/^  [a-z_]+: /, ""); sub(/  https?:\/\/.*$/, ""); s = s (s == "" ? "" : ", ") $0} END {print s}"#;

/// How a `run_wait` task waits (module docs).
#[derive(Debug, Clone, PartialEq, Eq)]
enum Waiter {
    /// `glaeda-gh` at this path: its host's one daemon polls GitHub for every waiter.
    Glaeda(PathBuf),
    /// `gh`, polling on its own: a machine with no glaeda-gh.
    Gh,
}

impl Waiter {
    /// glaeda-gh when `path` has one that answers `glaeda-gh gh --probe`, else gh when `path` has
    /// it (or there is no PATH, which says nothing of the agent's: the task's own check decides
    /// then), else none.
    async fn find(path: Option<OsString>) -> Option<Self> {
        if let Some(glaeda) = find_on_path(path.as_deref(), "glaeda-gh")
            && probe(&glaeda).await
        {
            return Some(Self::Glaeda(glaeda));
        }
        (path.is_none() || find_on_path(path.as_deref(), "gh").is_some()).then_some(Self::Gh)
    }
}

/// Whether `glaeda-gh gh --probe` answers `broker N`; an older glaeda-gh answers with a usage
/// error, and a hung one is cut off at `PROBE_TIMEOUT`.
async fn probe(glaeda: &Path) -> bool {
    let mut cmd = tokio::process::Command::new(glaeda);
    cmd.args(["gh", "--probe"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    match tokio::time::timeout(PROBE_TIMEOUT, cmd.output()).await {
        Ok(Ok(out)) => {
            out.status.success() && String::from_utf8_lossy(&out.stdout).starts_with("broker ")
        }
        _ => false,
    }
}

/// `text` as one shell word.
fn sh_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', r"'\''"))
}

/// The first executable named `name` in `path`'s folders.
fn find_on_path(path: Option<&OsStr>, name: &str) -> Option<PathBuf> {
    std::env::split_paths(path?).map(|dir| dir.join(name)).find(|file| {
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
}
