//! The doctor's real hello turn for a `claude-stdio` harness (u2586): one
//! `claude -p` with the profile's env, started the way a session's Claude
//! Code is (`agent::harness_command`, so an endpoint harness drops the
//! inherited provider env), in a private temp folder, with a time limit.
//! The reply and every error are masked; a failed turn of an endpoint
//! harness names its fix (the key, the base URL or the model).
//!
//! The turn speaks stream-json, as a session does (`claude_stdio::spawn_plan`): the
//! prompt goes in as one user line on stdin, the reply is the `result` line. A
//! launcher may accept only that shape headless: `sr2 claude2` refuses `-p PROMPT`
//! ("runs the Claude TUI only in a cmux terminal"), so until this turn matched the
//! session's, `cmux harness doctor claude-sr2` failed its prompt step while every
//! claude-sr2 chat ran (cmux#57823).

use super::*;
use crate::byo_endpoint::{self, Kind};
use crate::stderr::clean_stderr_lines;

/// The least time the turn gets: a first request through a slow endpoint.
const TURN_LIMIT: Duration = Duration::from_secs(60);
/// Most bytes of output kept for the report.
const DETAIL_MAX: usize = 1200;
/// The flags after the harness's own argv: a session's stream-json shape (module docs).
const TURN_ARGS: [&str; 8] = [
    "-p",
    "--input-format",
    "stream-json",
    "--output-format",
    "stream-json",
    "--verbose",
    "--no-session-persistence",
    "--strict-mcp-config",
];

/// The stdin of the turn: [`DOCTOR_PROMPT`] as one stream-json user message.
fn prompt_line() -> String {
    let message = json!({
        "type": "user",
        "message": {"role": "user", "content": [{"type": "text", "text": DOCTOR_PROMPT}]},
    });
    format!("{message}\n")
}

/// The turn's result object (`{type: "result", is_error, result, ...}`): the
/// last `result` line, else the last JSON object, for a harness that prints
/// only that.
fn result_object(stdout: &str) -> Option<Value> {
    let objects: Vec<Value> = stdout
        .lines()
        .filter_map(|l| serde_json::from_str::<Value>(l.trim()).ok().filter(Value::is_object))
        .collect();
    let is_result = |v: &&Value| v.get("type").and_then(Value::as_str) == Some("result");
    objects.iter().rev().find(is_result).or(objects.last()).cloned()
}

/// What one `claude -p` printed, and how it ended.
struct Outcome {
    success: bool,
    stdout: String,
    stderr: String,
}

pub(super) async fn run(
    r: &mut Report,
    id: &str,
    profile: &HarnessProfile,
    env: BTreeMap<String, String>,
    opts: &DoctorOptions,
) {
    let endpoint = Kind::of_env(&profile.env);
    let temp = match TempFolder::new(id) {
        Ok(f) => f,
        Err(e) => {
            r.push("prompt", StepStatus::Fail, &format!("temp folder: {e}"), None);
            return;
        }
    };
    let model = profile
        .model
        .clone()
        .or_else(|| env.get("ANTHROPIC_MODEL").cloned())
        .filter(|m| !m.trim().is_empty());
    let program = profile.argv.first().cloned().unwrap_or_default();
    let mut args: Vec<String> = profile.argv.iter().skip(1).cloned().collect();
    args.extend(TURN_ARGS.map(str::to_owned));
    if let Some(m) = &model {
        args.extend(["--model".to_owned(), m.clone()]);
    }
    let mut spawn = profile.clone();
    spawn.env = env;
    let mut cmd = match crate::agent::harness_command_ready(
        id,
        &spawn,
        &temp.path,
        Some((program, args)),
        None,
    )
    .await
    {
        Ok(cmd) => cmd,
        Err(e) => {
            r.push("prompt", StepStatus::Fail, &e.to_string(), None);
            return;
        }
    };
    cmd.stdin(std::process::Stdio::piped());
    let limit = opts.timeout.max(TURN_LIMIT);
    let outcome = match turn(cmd, limit).await {
        Ok(o) => o,
        Err(e) => {
            let fix = match endpoint {
                Some(kind) => byo_endpoint::fix(byo_endpoint::classify(&e), kind, id),
                None => "check the model, its login and quota".to_owned(),
            };
            r.push("prompt", StepStatus::Fail, &e, Some(fix));
            return;
        }
    };
    let result = result_object(&outcome.stdout);
    let is_error = result.as_ref().and_then(|v| v.get("is_error")).and_then(Value::as_bool);
    let text = result
        .as_ref()
        .and_then(|v| v.get("result"))
        .and_then(Value::as_str)
        .map(str::to_owned)
        .unwrap_or_default();
    if outcome.success && is_error != Some(true) && !text.trim().is_empty() {
        let model = model.map(|m| format!(", model {m}")).unwrap_or_default();
        r.push("prompt", StepStatus::Pass, &format!("one turn answered{model}"), None);
        r.reply = Some(text.trim().to_owned());
        return;
    }
    // Without a result, the last line: a stream's first lines are its long init record.
    let mut detail = if text.trim().is_empty() {
        outcome.stdout.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("").trim().to_owned()
    } else {
        text.trim().to_owned()
    };
    let tail: Vec<String> =
        clean_stderr_lines(&outcome.stderr).into_iter().filter(|line| !line.is_empty()).collect();
    let tail = tail[tail.len().saturating_sub(8)..].join("\n");
    if !tail.is_empty() {
        detail.push_str(&format!("\nstderr:\n{tail}"));
    }
    if detail.trim().is_empty() {
        detail = "the turn ended with no reply".into();
    }
    let problem = byo_endpoint::classify(&detail);
    // Masked before the cut: a cut key would no longer match its mask.
    let detail = clip(&r.mask(&detail));
    let fix = match endpoint {
        Some(kind) => byo_endpoint::fix(problem, kind, id),
        None if problem == byo_endpoint::Problem::Key => {
            format!("sign in again: `claude auth login`, or check the key the profile of {id} sets")
        }
        None => "check the model, its login and quota".to_owned(),
    };
    r.push("prompt", StepStatus::Fail, &detail, Some(fix));
}

/// Run the turn: Ok with its output when it exits within `limit`; on the
/// limit the turn and everything it started (its process group) is killed.
async fn turn(mut cmd: tokio::process::Command, limit: Duration) -> Result<Outcome, String> {
    let mut child = cmd.spawn().map_err(|e| format!("cannot start the harness: {e}"))?;
    let pid = child.id();
    let stdin = child.stdin.take();
    let run = async move {
        // The one prompt, then EOF, which ends a stream-json turn. A harness that
        // exits without reading it (a refusal) closes the pipe: its own output
        // says why, so a failed write is not the error.
        if let Some(mut stdin) = stdin {
            let _ = stdin.write_all(prompt_line().as_bytes()).await;
            let _ = stdin.shutdown().await;
        }
        child.wait_with_output().await
    };
    match tokio::time::timeout(limit, run).await {
        Ok(Ok(out)) => Ok(Outcome {
            success: out.status.success(),
            stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
        }),
        Ok(Err(e)) => Err(format!("the harness failed: {e}")),
        Err(_) => {
            #[cfg(unix)]
            if let Some(pid) = pid {
                // SAFETY: killpg only signals; the group is the harness's own
                // (harness_command puts it in a new process group).
                unsafe {
                    libc::killpg(pid as libc::pid_t, libc::SIGKILL);
                }
            }
            #[cfg(not(unix))]
            let _ = pid;
            Err(format!("the turn did not end in {} s (timed out)", limit.as_secs()))
        }
    }
}

/// `text` cut to [`DETAIL_MAX`] bytes on a character boundary.
fn clip(text: &str) -> String {
    if text.len() <= DETAIL_MAX {
        return text.to_owned();
    }
    let mut end = DETAIL_MAX;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}…", &text[..end])
}
