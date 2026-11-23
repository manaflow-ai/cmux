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
//! `run_wait` is a `bg_start` the server writes: one blocking `glaeda-gh wait` (the machine's one
//! GitHub poller, which waits on PR events where GitHub grants them), else `gh run watch` or `gh pr checks
//! --watch` (one per target for every chat on the machine, `SHARED_WATCH`), under the daemon, then the failed jobs read once, and the outcome printed last, which
//! the task's summary is (`resultLine`), so the chat wakes once with "... passed" or "... failed:
//! JOB, JOB". A machine with no `gh` is refused before a task starts. Given a background task's id
//! (`{"id": "bg-...", "timeoutSeconds": 900}`, as agents call it to wait for a task), it blocks
//! until the task ends or the bound passes (at most [`TASK_WAIT_MAX`], a longer one clamped and
//! said so), then answers as `bg_output` does.
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
        json!({"name": "bg_list", "description": "Your background tasks (the ones you started; a subagent sees its own), newest first, one line each: id, state (running, exited, stopped, killed, lost), exit code, age and the command, cut. A bare call lists the newest 30; the last line says how many more there are and the argument that lists them. Tasks other subagents or the lead started are counted, not listed, unless all is true; they are not yours to stop.",
            "inputSchema": {"type": "object", "properties": {"description": description,
                "all": {"type": "boolean", "description": "List every task of this chat, whoever started it, each with who started it (default false: only yours)."},
                "limit": {"type": "integer", "minimum": 1, "maximum": 500, "description": "How many tasks to list (default 30)."},
                "offset": {"type": "integer", "minimum": 0, "description": "How many of the newest to skip first (default 0): the last line's offset lists the next page."},
                "state": {"type": "string", "enum": ["running", "exited", "stopped", "killed", "lost", "ok", "failed"], "description": "Only tasks in this state, or with this outcome (ok, failed)."},
                "full": {"type": "boolean", "description": "Each task's whole command and the tail of its output (default false). bg_output reads one task's output."}}}}),
        json!({"name": "bg_output", "description": "Read a background task's output: by default its last 64 KiB; with fromByte, from there (pass the last nextByte to read only what is new). Each task keeps its newest 8 MiB of output; skippedBytes says how much before fromByte is gone.",
            "inputSchema": {"type": "object", "properties": {"id": id, "description": description,
                "fromByte": {"type": "integer", "minimum": 0},
                "maxBytes": {"type": "integer", "minimum": 1, "maximum": 1048576}},
                "required": ["id"]}}),
        json!({"name": "bg_stop", "description": "Stop a background task you started: SIGTERM to every process it started (its process group and those that left it), then SIGKILL to them 5 s later; returns once it ended. A task another subagent or the lead started is refused, naming who started it.",
            "inputSchema": {"type": "object", "properties": {"id": id, "description": description,
                "force_other_owner": {"type": "boolean", "description": "Stop it even though another subagent or the lead started it. Only when its owner asked you to or is gone; never as cleanup (default false)."}},
                "required": ["id"]}}),
        json!({"name": "run_wait", "description": "Wait for a GitHub Actions run, or a pull request's checks, in the background, and get one message in this chat when it is done: passed, or failed with the failed jobs named. Returns at once with a background task id (bg_output reads it meanwhile). Use it instead of polling CI yourself. Needs the gh CLI; waits through glaeda-gh (one shared poller, GitHub's PR events) when it is installed, else through one gh watch per pull request or run that every chat on the machine shares. Given a background task's id (bg-...) and timeoutSeconds instead, it blocks until that task ends or the timeout passes (at most 1800 s; a longer one is clamped and the result says so), then answers as bg_output does.",
            "inputSchema": {"type": "object", "properties": {
                "repo": {"type": "string", "description": "OWNER/REPO."},
                "id": {"type": "string", "description": "Instead of repo: a background task's id (bg-...) to wait for, with timeoutSeconds."},
                "timeoutSeconds": {"type": "number", "minimum": 0, "description": "With id: how long to block for the task to end (at most 1800). Without it the task is read at once."},
                "run": {"type": "integer", "minimum": 1, "description": "The Actions run id to wait for."},
                "pr": {"type": "integer", "minimum": 1, "description": "The pull request whose checks to wait for (instead of run)."},
                "sha": {"type": "string", "description": "With pr: the head commit the checks must be for; a pull request whose head is another commit, before or after the wait, fails."},
                "description": description},
                "required": ["repo"]}}),
    ]
}

/// What a Claude Code subagent's start (`callerSubagent`) adds to its answer: when its end comes.
const SUBAGENT_END: &str = "You get its end after your next Bash or acpmux tool call; if you end first, it goes to your lead. bg_output reads it now.";

pub(crate) async fn call(daemon: &Arc<Client>, session: &str, name: &str, args: &Value) -> Value {
    let by_subagent = args.get("callerSubagent").is_some_and(Value::is_object);
    let mut params = match args {
        Value::Object(_) => args.clone(),
        Value::Null => json!({}),
        _ => return error_result("arguments must be an object".to_owned()),
    };
    params.set("sessionId", json!(session));
    // A background task's id given to run_wait (`{"id": "bg-..."}`): run_wait waits for GitHub,
    // and a bg task's end already comes as a message, so read it as bg_output does and say so.
    // With a timeout (`{"id": "bg-...", "timeoutSeconds": 900}`), it first blocks until the task
    // ends or the bound passes (`TaskWait`), and says which.
    let mut note = None;
    let mut waited = None;
    let name = match bg_task_given_to_run_wait(name, &params) {
        Some(task) => {
            let bound = match TaskWait::of(&params) {
                Ok(bound) => bound,
                Err(why) => return error_result(why),
            };
            let sub = params.get("callerSubagent").cloned();
            params = json!({"sessionId": session, "id": task});
            if let Some(sub) = sub {
                params.set("callerSubagent", sub);
            }
            note = Some(match bound {
                None => format!(
                    "run_wait waits for a GitHub run or pull request (repo with run or pr); {task} is a background task, whose end comes to this chat as one message, so there is nothing to wait on. Its output so far, as bg_output {{\"id\": \"{task}\"}} reads it:"
                ),
                Some(bound) => {
                    let waited_for = bound.wait(daemon, &params).await;
                    let line = bound.line(&task, waited_for);
                    waited = Some((bound, waited_for));
                    line
                }
            });
            "bg_output"
        }
        None => name,
    };
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
        let sub = params.get("callerSubagent").cloned().unwrap_or(Value::Null);
        params = json!({"sessionId": session, "command": wait.script(),
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
    // A list's page (`acpmux_mcp_bg_list.rs`): the daemon answers the whole chat.
    let page = match name {
        "bg_list" => match super::bg_list::Page::take(&mut params) {
            Ok(page) => Some(page),
            Err(why) => return error_result(why),
        },
        _ => None,
    };
    match daemon.request(m, params).await {
        Ok(r) => {
            let (line, status) = outcome(name, &r);
            if let Some(page) = page {
                let (mut structured, text) = page.apply(r, crate::store::now_ms());
                structured.set("summary", json!(line));
                structured.set("status", json!(status));
                return ok(format!("{line}\n{text}").trim_end().to_owned(), structured);
            }
            let mut structured = r;
            structured.set("summary", json!(line));
            structured.set("status", json!(status));
            let mut text = format!("{line}\n{}", summary(name, &structured)).trim_end().to_owned();
            if let Some(note) = &note {
                text = format!("{note}\n{text}");
                structured.set("redirectedFrom", json!("run_wait"));
            }
            if let Some((bound, waited)) = &waited {
                structured.set("wait", bound.view(*waited));
            }
            if by_subagent && name == "bg_start" && structured.get("notify") == Some(&json!(true)) {
                text.push_str(&format!("\n{SUBAGENT_END}"));
                // Claude Code shows the structured result, not the text, when there is one.
                structured.set("endMessage", json!(SUBAGENT_END));
            }
            ok(text, structured)
        }
        Err(e) => match &note {
            Some(note) => error_result(format!("{note}\n{e:#}")),
            None => refusal(e),
        },
    }
}

/// The background task id a `run_wait` call gives instead of a repo: a `bg-` value under
/// `id`, `task`, `taskId`, `task_id` or `run`.
fn bg_task_given_to_run_wait(name: &str, params: &Value) -> Option<String> {
    if name != "run_wait" || params.get("repo").is_some_and(|r| !r.is_null()) {
        return None;
    }
    ["id", "task", "taskId", "task_id", "run"].iter().find_map(|k| {
        let v = params.get(*k)?.as_str()?.trim();
        v.starts_with("bg-").then(|| v.to_owned())
    })
}

/// The most a `run_wait` on a background task blocks (`timeoutSeconds`); a longer bound is
/// clamped to it, and the result says so.
const TASK_WAIT_MAX: std::time::Duration = std::time::Duration::from_secs(1800);
/// The first and the longest pause between two reads of the task's state while it runs.
const TASK_LOOK_FIRST: std::time::Duration = std::time::Duration::from_millis(100);
const TASK_LOOK_MAX: std::time::Duration = std::time::Duration::from_secs(2);

/// How long a `run_wait` given a background task blocks for it to end: the bound the call gave
/// under `timeoutSeconds`, `timeout` or `timeout_seconds` (seconds, a number or a numeric
/// string), clamped to [`TASK_WAIT_MAX`].
#[derive(Clone, Copy, Debug, PartialEq)]
struct TaskWait {
    /// The seconds the call asked for.
    asked: f64,
    /// What it waits: `asked`, or [`TASK_WAIT_MAX`] when that is less.
    bound: std::time::Duration,
}

impl TaskWait {
    /// The call's bound; `None` when it gives none (or 0), so the task is read at once.
    fn of(params: &Value) -> Result<Option<Self>, String> {
        let Some((key, v)) = ["timeoutSeconds", "timeout", "timeout_seconds"]
            .iter()
            .find_map(|k| params.get(*k).filter(|v| !v.is_null()).map(|v| (*k, v)))
        else {
            return Ok(None);
        };
        let asked = match v {
            Value::String(s) => s.trim().trim_end_matches('s').parse::<f64>().ok(),
            v => v.as_f64(),
        };
        let asked = asked
            .filter(|a| a.is_finite() && *a >= 0.0)
            .ok_or_else(|| format!("{key} must be a number of seconds, 0 or more (it was {v})"))?;
        if asked == 0.0 {
            return Ok(None);
        }
        let bound = std::time::Duration::from_secs_f64(asked).min(TASK_WAIT_MAX);
        Ok(Some(Self { asked, bound }))
    }

    fn clamped(&self) -> bool {
        std::time::Duration::from_secs_f64(self.asked) > self.bound
    }

    /// Blocks until the task `params` names is no longer running or the bound passes: how long
    /// it waited, and whether it timed out with the task still running. A read the daemon
    /// refuses (no such task) ends the wait at once: the read after it says why.
    async fn wait(&self, daemon: &Arc<Client>, params: &Value) -> (std::time::Duration, bool) {
        let start = tokio::time::Instant::now();
        let deadline = start + self.bound;
        let mut look = params.clone();
        look.set("maxBytes", json!(1));
        let mut pause = TASK_LOOK_FIRST;
        loop {
            let running = match daemon.request(method::MUX_BG_OUTPUT, look.clone()).await {
                Ok(r) => r.get("state").and_then(Value::as_str) == Some("running"),
                Err(_) => return (start.elapsed(), false),
            };
            let now = tokio::time::Instant::now();
            if !running || now >= deadline {
                return (now - start, running);
            }
            tokio::time::sleep(pause.min(deadline - now)).await;
            pause = (pause * 2).min(TASK_LOOK_MAX);
        }
    }

    /// The line the result starts with: how the wait ended, and a clamp when there was one.
    fn line(&self, task: &str, (waited, timed_out): (std::time::Duration, bool)) -> String {
        let clamp = if self.clamped() {
            format!(
                " (you asked for {} s; clamped to the most, {} s)",
                self.asked,
                TASK_WAIT_MAX.as_secs()
            )
        } else {
            String::new()
        };
        let (secs, bound) = (waited.as_secs_f64(), self.bound.as_secs_f64());
        if timed_out {
            format!(
                "{task} is a background task; timed out after waiting {bound:.0} s{clamp} and it is still running. Its output so far, as bg_output reads it:"
            )
        } else {
            format!(
                "{task} is a background task; it is not running after a wait of {secs:.1} s of {bound:.0} s{clamp}. Its output, as bg_output reads it:"
            )
        }
    }

    /// The result's `wait`: what was asked, what was waited, and whether it clamped or timed out.
    fn view(&self, (waited, timed_out): (std::time::Duration, bool)) -> Value {
        json!({"askedSeconds": self.asked, "boundSeconds": self.bound.as_secs_f64(),
            "clamped": self.clamped(), "waitedSeconds": waited.as_secs_f64(),
            "timedOut": timed_out})
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
    // Every task of the caller's, counted before the page's state filter, offset and limit
    // (`bg_list::Page::apply` takes the page after this line is built), so the line says so:
    // a reader took "1 running" for the page's own count and read 29 exited tasks as running.
    let line = format!(
        "{} background task{plural} in all, not only the page below: {running} running, {ok} ok, {failed} failed{others}",
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
        let line = "3 background tasks in all, not only the page below: 1 running, 1 ok, 1 failed"
            .to_owned();
        assert_eq!(outcome("bg_list", &r), (line, "running"));
        // The counts are the whole list's, never the page's (`bg_list::Page::apply` pages after
        // this line is built), and the line says which.
        assert!(outcome("bg_list", &r).0.contains("in all, not only the page below"));
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

    /// A bg task's wait bound comes from timeoutSeconds, timeout or timeout_seconds, as a number
    /// or a numeric string; 0 or none reads at once, a bound past the most is clamped and says so,
    /// and anything else is refused.
    #[test]
    fn a_task_waits_bound_is_read_and_clamped() {
        let of = |v: Value| TaskWait::of(&v);
        let b = of(json!({"id": "bg-1", "timeoutSeconds": 900})).unwrap().unwrap();
        assert_eq!((b.bound.as_secs(), b.clamped()), (900, false));
        assert_eq!(of(json!({"timeout": "60"})).unwrap().unwrap().bound.as_secs(), 60);
        assert_eq!(of(json!({"timeout_seconds": 1.5})).unwrap().unwrap().bound.as_millis(), 1500);
        assert_eq!(of(json!({"id": "bg-1"})).unwrap(), None);
        assert_eq!(of(json!({"timeoutSeconds": 0})).unwrap(), None);
        let long = of(json!({"timeoutSeconds": 7200})).unwrap().unwrap();
        assert_eq!((long.bound, long.clamped()), (TASK_WAIT_MAX, true));
        let timed_out = long.line("bg-1", (TASK_WAIT_MAX, true));
        assert!(timed_out.contains("timed out after waiting 1800 s"), "{timed_out}");
        assert!(
            timed_out.contains("you asked for 7200 s; clamped to the most, 1800 s"),
            "{timed_out}"
        );
        assert_eq!(long.view((TASK_WAIT_MAX, true))["clamped"], true);
        assert!(of(json!({"timeoutSeconds": -1})).unwrap_err().contains("timeoutSeconds must be"));
        assert!(of(json!({"timeout": "soon"})).is_err());
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
  "pr checks"*) echo "lint" ;;
esac
"#,
            calls.display()
        );
        std::fs::write(&gh, fake).unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&gh, std::fs::Permissions::from_mode(0o755)).unwrap();
        // Only the fakes and the base tools: a host's own glaeda-gh must not answer for the fake gh.
        let path = format!("{}:/usr/bin:/bin", dir.path().display());
        let run = |args: Value| {
            let script = RunWait::of(&args).unwrap().script();
            let out = std::process::Command::new("sh")
                .arg("-c")
                .arg(script)
                .env("PATH", &path)
                .env("ACPMUX_RUN_WAIT_SHARE", dir.path().join("share"))
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
        // A passing wait names no failed checks, even when gh still lists a superseded run's cancelled
        // check ("lint" here): cmux#50630's own wait printed six of those above its "passed".
        let (code, last, all) = run(json!({"repo": "o/r", "pr": 3, "sha": "0123456789abcdef"}));
        assert_eq!((code, last.as_str()), (Some(0), "Checks of o/r#3 passed"), "{all}");
        assert!(!all.contains("failed checks"), "{all}");
        let (code, last, _) = run(json!({"repo": "o/r", "pr": 3, "sha": "fedcba9"}));
        assert_eq!(code, Some(2));
        assert!(last.contains("its head is 0123456789abcdef"), "{last}");
        let calls = std::fs::read_to_string(&calls).unwrap();
        // The pinned-elsewhere call never waited: the one wait is the earlier call's.
        assert_eq!(calls.matches("--watch").count(), 1, "{calls}");
        assert!(calls.contains("run watch 7 --repo o/r --exit-status"), "{calls}");
    }

    /// With glaeda-gh on PATH the wait is its daemon's (one poller for every session, PR events where GitHub
    /// grants them), pinned to the head it read; a daemon that is down (exit 3) or a glaeda-gh too old for the
    /// arguments (64) falls back to the gh watch, so the wait never gets less reliable.
    // Shell-script stand-ins for gh and glaeda-gh run through `sh`: unix only.
    #[cfg(unix)]
    #[test]
    fn run_wait_waits_through_glaeda_gh_and_falls_back_to_gh() {
        let dir = cmux_unix_socket::short_test_dir("run-wait-glaeda");
        let calls = dir.path().join("calls");
        let rc = dir.path().join("glaeda-rc");
        let gh = format!(
            r#"#!/bin/sh
echo "gh $*" >> '{calls}'
case "$*" in
  "pr view"*) echo 0123456789abcdef0123456789abcdef01234567 ;;
  "pr checks"*--watch*) exit 0 ;;
  "run watch"*) exit 0 ;;
  "run view"*"--json conclusion"*) echo "conclusion: success  https://example.com/run/7" ;;
  *) echo "" ;;
esac
"#,
            calls = calls.display()
        );
        let glaeda = format!(
            "#!/bin/sh\necho \"glaeda-gh $*\" >> '{}'\nexit $(cat '{}')\n",
            calls.display(),
            rc.display()
        );
        use std::os::unix::fs::PermissionsExt;
        for (name, body) in [("gh", gh), ("glaeda-gh", glaeda)] {
            let file = dir.path().join(name);
            std::fs::write(&file, body).unwrap();
            std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let path = format!("{}:/usr/bin:/bin", dir.path().display());
        let run = |args: Value, code: &str| {
            std::fs::write(&rc, code).unwrap();
            let _ = std::fs::remove_file(&calls);
            let out = std::process::Command::new("sh")
                .arg("-c")
                .arg(RunWait::of(&args).unwrap().script())
                .env("PATH", &path)
                .env("ACPMUX_RUN_WAIT_SHARE", dir.path().join("share"))
                .output()
                .unwrap();
            let text = String::from_utf8_lossy(&out.stdout).into_owned();
            let calls = std::fs::read_to_string(&calls).unwrap_or_default();
            (out.status.code(), text.lines().last().unwrap_or_default().to_owned(), calls)
        };
        let pr = json!({"repo": "o/r", "pr": 3, "sha": "0123456789abcdef"});
        let (code, last, calls) = run(pr.clone(), "0");
        assert_eq!((code, last.as_str()), (Some(0), "Checks of o/r#3 passed"), "{calls}");
        assert!(
            calls
                .contains("glaeda-gh wait pr o/r#3 --sha 0123456789abcdef0123456789abcdef01234567"),
            "{calls}"
        );
        assert!(!calls.contains("--watch"), "glaeda-gh waited: no gh poll: {calls}");
        let (code, last, calls) = run(pr.clone(), "4");
        assert_eq!(code, Some(4), "{calls}");
        assert!(last.contains("failed") && last.contains("conflicts with its base"), "{last}");
        assert!(!calls.contains("--watch"), "{calls}");
        for down in ["3", "64"] {
            let (code, last, calls) = run(pr.clone(), down);
            assert_eq!((code, last.as_str()), (Some(0), "Checks of o/r#3 passed"), "{calls}");
            assert!(calls.contains("gh pr checks 3 --repo o/r --watch"), "exit {down}: {calls}");
        }
        let (code, last, calls) = run(json!({"repo": "o/r", "run": 7}), "0");
        assert_eq!((code, last.as_str()), (Some(0), "Actions run 7 in o/r passed"), "{calls}");
        assert!(calls.contains("glaeda-gh wait run o/r/7"), "{calls}");
        assert!(!calls.contains("run watch"), "{calls}");
        let (code, _, calls) = run(json!({"repo": "o/r", "run": 7}), "3");
        assert_eq!(code, Some(0), "{calls}");
        assert!(calls.contains("gh run watch 7 --repo o/r"), "{calls}");
    }

    /// A head read the shared quota refused with its reset time ("until HH:MMZ", gh-quota exit 3)
    /// sleeps until that reset and reads again instead of failing the wait; a reset already passed
    /// reads again after 60 s; a refusal naming no reset still fails at once, naming the refusal.
    #[cfg(unix)]
    #[test]
    fn run_wait_head_read_waits_out_a_quota_refusal() {
        let dir = cmux_unix_socket::short_test_dir("run-wait-quota");
        let calls = dir.path().join("calls");
        let refusal = dir.path().join("refusal");
        let refused = dir.path().join("refused");
        let gh = format!(
            r#"#!/bin/sh
echo "gh $*" >> '{calls}'
case "$*" in
  "pr view"*)
    if [ -s '{refusal}' ] && [ ! -e '{refused}' ]; then
      : > '{refused}'; cat '{refusal}' >&2; exit 3
    fi
    echo 0123456789abcdef0123456789abcdef01234567 ;;
  *) echo "" ;;
esac
"#,
            calls = calls.display(),
            refusal = refusal.display(),
            refused = refused.display()
        );
        let glaeda = format!("#!/bin/sh\necho \"glaeda-gh $*\" >> '{}'\nexit 0\n", calls.display());
        let sleep = format!("#!/bin/sh\necho \"sleep $*\" >> '{}'\n", calls.display());
        use std::os::unix::fs::PermissionsExt;
        for (name, body) in [("gh", gh), ("glaeda-gh", glaeda), ("sleep", sleep)] {
            let file = dir.path().join(name);
            std::fs::write(&file, body).unwrap();
            std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let path = format!("{}:/usr/bin:/bin", dir.path().display());
        let run = |text: &str| {
            std::fs::write(&refusal, text).unwrap();
            let _ = std::fs::remove_file(&refused);
            let _ = std::fs::remove_file(&calls);
            let out = std::process::Command::new("sh")
                .arg("-c")
                .arg(
                    RunWait::of(&json!({"repo": "o/r", "pr": 3, "sha": "0123456789abcdef"}))
                        .unwrap()
                        .script(),
                )
                .env("PATH", &path)
                .env("ACPMUX_RUN_WAIT_SHARE", dir.path().join("share"))
                .output()
                .unwrap();
            let text = String::from_utf8_lossy(&out.stdout).into_owned();
            let calls = std::fs::read_to_string(&calls).unwrap_or_default();
            (out.status.code(), text.lines().last().unwrap_or_default().to_owned(), calls)
        };
        let sleeps = |calls: &str| -> Vec<u64> {
            calls.lines().filter_map(|l| l.strip_prefix("sleep ")?.trim().parse().ok()).collect()
        };
        // A reset two minutes from now, in the refusal's own UTC "HH:MMZ" form.
        let utc = |minutes_ahead: i64| {
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_secs() as i64;
            let minute = (now % 86400 / 60 + minutes_ahead).rem_euclid(1440);
            format!("{:02}:{:02}Z", minute / 60, minute % 60)
        };
        let ahead = format!(
            "gh-quota: refused: GitHub's REST rate limit is spent for read-pool until {} (reset)",
            utc(2)
        );
        let (code, last, calls) = run(&ahead);
        assert_eq!((code, last.as_str()), (Some(0), "Checks of o/r#3 passed"), "{calls}");
        let slept = sleeps(&calls);
        assert!(slept.len() == 1 && (60..=140).contains(&slept[0]), "{calls}");
        assert!(calls.contains("glaeda-gh wait pr o/r#3 --sha 0123456789abcdef"), "{calls}");

        let passed = format!(
            "gh-quota: refused: GitHub's REST rate limit is spent for read-pool until {} (reset)",
            utc(-2)
        );
        let (code, last, calls) = run(&passed);
        assert_eq!((code, last.as_str()), (Some(0), "Checks of o/r#3 passed"), "{calls}");
        assert_eq!(sleeps(&calls), vec![60], "{calls}");

        let (code, last, calls) = run("lane-gh: refused: retry after 30 s");
        assert_eq!((code, last.as_str()), (Some(0), "Checks of o/r#3 passed"), "{calls}");
        assert_eq!(sleeps(&calls), vec![35], "{calls}");

        let (code, last, calls) = run("gh-quota: refused: a jobs sweep is forbidden");
        assert_eq!(code, Some(2), "{calls}");
        assert_eq!(
            last,
            "Checks of o/r#3 failed: its head could not be read (gh-quota: refused: a jobs sweep is forbidden)"
        );
        assert!(sleeps(&calls).is_empty() && !calls.contains("glaeda-gh"), "{calls}");
    }

    /// With no glaeda-gh, chats waiting for the same pull request share one `gh` watch: the second
    /// waiter makes no GitHub call and takes the first's outcome; a lock left by a waiter that died is
    /// taken over, so that wait still polls once and ends on its outcome.
    #[cfg(unix)]
    #[test]
    fn run_wait_without_glaeda_gh_shares_one_gh_watch_per_target() {
        let dir = cmux_unix_socket::short_test_dir("run-wait-share");
        let calls = dir.path().join("calls");
        let gh = format!(
            r#"#!/bin/sh
echo "gh $*" >> '{calls}'
case "$*" in
  "pr checks"*--watch*) /bin/sleep 2; exit 1 ;;
  "pr checks"*) echo "build" ;;
  *) echo "" ;;
esac
"#,
            calls = calls.display()
        );
        let file = dir.path().join("gh");
        std::fs::write(&file, gh).unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o755)).unwrap();
        let share = dir.path().join("share");
        let path = format!("{}:/usr/bin:/bin", dir.path().display());
        let script = RunWait::of(&json!({"repo": "o/r", "pr": 3})).unwrap().script();
        let spawn = || {
            std::process::Command::new("sh")
                .arg("-c")
                .arg(&script)
                .env("PATH", &path)
                .env("ACPMUX_RUN_WAIT_SHARE", &share)
                .stdout(std::process::Stdio::piped())
                .spawn()
                .unwrap()
        };
        let last = |child: std::process::Child| {
            let out = child.wait_with_output().unwrap();
            let text = String::from_utf8_lossy(&out.stdout).into_owned();
            (out.status.code(), text.lines().last().unwrap_or_default().to_owned())
        };
        let first = spawn();
        std::thread::sleep(std::time::Duration::from_millis(300));
        let second = spawn();
        for child in [first, second] {
            assert_eq!(last(child), (Some(1), "Checks of o/r#3 failed: build".to_owned()));
        }
        let text = std::fs::read_to_string(&calls).unwrap();
        assert_eq!(text.matches("--watch").count(), 1, "one watch for both waiters: {text}");

        // A leader that died: its lock names a pid that no longer runs.
        let mut gone = std::process::Command::new("true").spawn().unwrap();
        gone.wait().unwrap();
        let name = std::process::Command::new("sh")
            .arg("-c")
            .arg("printf '%s' 'pr o/r#3' | cksum | tr -c '0-9\\n' -")
            .output()
            .unwrap();
        let name = String::from_utf8_lossy(&name.stdout).trim().to_owned();
        std::os::unix::fs::symlink(gone.id().to_string(), share.join(format!("{name}.lock")))
            .unwrap();
        std::fs::remove_file(&calls).unwrap();
        assert_eq!(last(spawn()), (Some(1), "Checks of o/r#3 failed: build".to_owned()));
        let text = std::fs::read_to_string(&calls).unwrap();
        assert_eq!(text.matches("--watch").count(), 1, "the stale lock was taken over: {text}");
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
                lines.push(glaeda_wait(&format!("run {repo}/{run}")));
                lines.push(SHARED_WATCH.to_owned());
                lines.push(format!("case $rc in 3|64) shared_watch \"run {repo}/{run}\" gh run watch {run} --repo {repo} --exit-status --interval {GH_INTERVAL_S} ;; esac"));
                lines.push(format!("gh run view {run} --repo {repo} --json conclusion,url --jq '\"conclusion: \" + (.conclusion // \"none\") + \"  \" + .url'"));
                lines.push(format!("failed=; [ $rc -eq 0 ] || failed=$(gh run view {run} --repo {repo} --json jobs --jq '[.jobs[] | select(.conclusion == \"failure\" or .conclusion == \"cancelled\" or .conclusion == \"timed_out\") | .name] | join(\", \")' 2>/dev/null)"));
                lines.push("[ -n \"$failed\" ] && echo \"failed jobs: $failed\"".to_owned());
                lines.push(format!("if [ $rc -eq 0 ]; then echo \"{name} passed\"; else echo \"{name} failed${{failed:+: $failed}}${{why:+ ($why)}}\"; fi"));
            }
            Target::Pr { number, sha } => {
                let name = format!("Checks of {repo}#{number}");
                let head =
                    format!("gh pr view {number} --repo {repo} --json headRefOid --jq .headRefOid");
                if let Some(sha) = sha {
                    lines.push(head_reader(&head));
                    lines.push(format!("read_head || {{ echo \"{name} failed: its head could not be read${{refusal:+ ($refusal)}}\"; exit 2; }}"));
                    lines.push(format!("case \"$head\" in {sha}*) ;; *) echo \"{name} failed: its head is $head, not {sha}\"; exit 2;; esac"));
                }
                let pin = if sha.is_some() { " --sha \"$head\"" } else { "" };
                lines.push(glaeda_wait(&format!("pr {repo}#{number}{pin}")));
                lines.push(SHARED_WATCH.to_owned());
                let key = if sha.is_some() {
                    format!("pr {repo}#{number} $head")
                } else {
                    format!("pr {repo}#{number}")
                };
                lines.push(format!("case $rc in 3|64) shared_watch \"{key}\" gh pr checks {number} --repo {repo} --watch --fail-fast --interval {GH_INTERVAL_S} ;; esac"));
                lines.push(format!("failed=; [ $rc -eq 0 ] || failed=$(gh pr checks {number} --repo {repo} --json name,bucket --jq '[.[] | select(.bucket == \"fail\" or .bucket == \"cancel\") | .name] | join(\", \")' 2>/dev/null)"));
                lines.push("[ -n \"$failed\" ] && echo \"failed checks: $failed\"".to_owned());
                if let Some(sha) = sha {
                    lines.push(format!("read_head || {{ echo \"{name} failed: its head could not be read after the wait${{refusal:+ ($refusal)}}\"; exit 2; }}"));
                    lines.push(format!("case \"$head\" in {sha}*) ;; *) echo \"{name} failed: its head moved to $head while it was waited for\"; exit 2;; esac"));
                }
                lines.push(format!("if [ $rc -eq 0 ]; then echo \"{name} passed\"; else echo \"{name} failed${{failed:+: $failed}}${{why:+ ($why)}}\"; fi"));
            }
        }
        lines.push("exit $rc".to_owned());
        lines.join("\n")
    }
}

/// How often the gh fallback (no glaeda-gh, or one that refused) reads the run or the checks: each
/// read spends the login's own REST quota (about 2 to 3 calls), so 120 s keeps one watcher near 60
/// to 90 calls an hour, where 30 s spent about 240 to 360 (Leo, 2026-11-17, on the Claude desktop app
/// showing a GitHub rate limit: "this is... interesting. so claude desktop shows rate limit on hover
/// of the github links sometimes...").
const GH_INTERVAL_S: u64 = 120;

/// The wait itself, through glaeda-gh when it is installed: its daemon is the one poller for every session
/// on the machine and waits on GitHub's pull request events (`gh event listen`) where the account has
/// access, so this task makes no GitHub calls while it waits. `rc` 3 (its daemon is down) or 64 (a
/// glaeda-gh too old for these arguments), or no glaeda-gh, leaves the caller's `gh` watch to run instead;
/// `why` names an outcome other than pass or fail. TARGET is `run OWNER/REPO/ID` or `pr OWNER/REPO#N`
/// (with `--sha "$head"`), every value checked by `RunWait::of`.
fn glaeda_wait(target: &str) -> String {
    format!(
        "if command -v glaeda-gh >/dev/null 2>&1; then glaeda-gh wait {target} --timeout 21600 >/dev/null 2>&1; rc=$?; else rc=3; fi\n\
         case $rc in 2) why='timed out after 6 h' ;; 4) why='conflicts with its base' ;; 6) why='no check ever reported' ;; 7) why='inconclusive' ;; esac"
    )
}

/// `shared_watch KEY CMD...`: the `gh` watch of a machine with no glaeda-gh (or one whose daemon is
/// down), shared by every chat on the machine that waits for the same KEY (`run OWNER/REPO/ID`, or
/// `pr OWNER/REPO#N [HEAD]`). The first waiter takes the lock, a symlink whose target is its pid
/// (`ln -s` makes it atomically or fails), runs CMD, and writes its exit code with the time it
/// ended; every other waiter reads GitHub not at all, checks every 5 s that the lock's pid lives,
/// and takes the outcome once it is newer than its own start. A waiter whose leader died (stopped,
/// killed, the machine slept) removes the stale lock and becomes the leader, so a wait is never
/// less reliable than its own poll. This is glaeda-gh's one-poller-per-machine for a paying user or
/// a teammate who never installed it (Leo, ask-922dfe5e36: "we need to be able to make sure
/// arbitrary paying users/teammates can properly use it with the way that we properly use it"):
/// ten sessions waiting on one pull request spent ten logins' worth of polls on one login before.
/// The folder is `ACPMUX_RUN_WAIT_SHARE` (tests), else this user's own under `TMPDIR`.
const SHARED_WATCH: &str = r#"shared_watch() {
  key=$1; shift
  share=${ACPMUX_RUN_WAIT_SHARE:-${TMPDIR:-/tmp}/acpmux-run-wait-$(id -u)}
  mkdir -p "$share" 2>/dev/null && chmod 700 "$share" 2>/dev/null
  name=$(printf '%s' "$key" | cksum | tr -c '0-9\n' -)
  lock="$share/$name.lock"; out="$share/$name.rc"; since=$(date +%s)
  while :; do
    if ln -s "$$" "$lock" 2>/dev/null; then
      "$@" >/dev/null 2>&1; rc=$?
      printf '%s %s\n' "$(date +%s)" "$rc" > "$out.$$" && mv -f "$out.$$" "$out"
      rm -f "$lock"; return 0
    fi
    pid=$(readlink "$lock" 2>/dev/null)
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then rm -f "$lock"; continue; fi
    sleep 5
    if [ -f "$out" ] && read t r < "$out" && [ "$t" -gt "$since" ] 2>/dev/null; then rc=$r; return 0; fi
  done
}"#;

/// How long a refused head read waits at most for the quota to come back: the wait's own bound.
const HEAD_READ_DEADLINE_S: u64 = 21600;

/// `read_head`: sets `head` from READ (the `gh pr view` of the pinned pull request). A read the
/// shared quota refused with its reset time (gh-quota exit 3, "... spent for read-pool until
/// 06:26Z (reset)", or the broker's "retry after N s") sleeps until that reset and reads again,
/// within the wait's own 6 h bound, instead of ending the wait on a false failure (cmuxterm-hq#16309
/// and #16265 twice in 10 minutes, 2026-11-21). Any other refusal, or a reset past the bound, returns
/// false with `refusal` set to the read's last stderr line. A reset time already passed (the quota's
/// reset slips) reads again after 60 s.
fn head_reader(read: &str) -> String {
    r#"deadline=$(( $(date +%s) + DEADLINE ))
gh_err=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/run-wait-$$.err")
trap 'rm -f "$gh_err"' EXIT
read_head() {
  while :; do
    refusal=
    head=$(READ 2>"$gh_err") && [ -n "$head" ] && return 0
    refusal=$(grep -v '^[[:space:]]*$' "$gh_err" | tail -n 1)
    t=$(grep -oE 'until [0-9]{1,2}:[0-9]{2}Z' "$gh_err" | tail -n 1 | tr -dc '0-9:')
    now_s=$(date +%s)
    if [ -n "$t" ]; then
      h=$(echo "${t%%:*}" | sed 's/^0*//'); m=$(echo "${t##*:}" | sed 's/^0*//')
      s=$(( ( ${h:-0} * 3600 + ${m:-0} * 60 - now_s % 86400 + 86400 ) % 86400 + 15 ))
      [ "$s" -gt 43200 ] && s=60
    else
      n=$(grep -oE 'retry after [0-9]+ ?s' "$gh_err" | tail -n 1 | tr -dc '0-9')
      [ -n "$n" ] || return 1
      s=$(( n + 5 ))
    fi
    [ $(( now_s + s )) -lt "$deadline" ] || return 1
    echo "run_wait: the head read was refused ($refusal); reading again in ${s}s, after the reset"
    sleep "$s"
  done
}"#
    .replace("DEADLINE", &HEAD_READ_DEADLINE_S.to_string())
    .replace("READ", read)
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
