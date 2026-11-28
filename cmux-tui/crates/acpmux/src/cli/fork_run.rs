//! `acpmux fork-run start|status|select`: "try this N ways, keep the best" on cmux Cloud. A fork
//! run captures one Cloud machine once and restores one copy-on-write machine per harness
//! (cmux-platform's fork runs, `/v1/workspaces/{workspace}/fork-runs`); `select` keeps one ready
//! child as the run's result. Not `acpmux fork`, which forks a chat's history on this machine.
//!
//! The call is `cmux_cloud_api`'s `owner.fork_run` (the same one the daemon's
//! `cloud.owner.fork_run` operation runs), sent with the caller's own Cloud credential:
//! `--cloud-api` (or `CMUX_CLOUD_API_URL`), `--cloud-token-file` (or `CMUX_CLOUD_ACCESS_TOKEN`)
//! and `--team` (or `CMUX_CLOUD_TEAM`), as `cmux machine access` takes them. The credential goes
//! only in the request's Authorization header, never in argv, a URL or an error.

use std::path::PathBuf;
use std::time::Duration;

use anyhow::Result;
use clap::{Args, Subcommand};
use serde_json::{Map, Value, json};

use super::errors::{AppError, Code};
use super::output::print_json;

const API_ENV: &str = "CMUX_CLOUD_API_URL";
const TOKEN_ENV: &str = "CMUX_CLOUD_ACCESS_TOKEN";
const TEAM_ENV: &str = "CMUX_CLOUD_TEAM";
/// The environment the credential's defaults are read from (a fake one in tests).
pub(crate) type Env = dyn Fn(&str) -> Option<String> + Sync;
/// How often `status --wait` reads the run again.
const POLL: Duration = Duration::from_secs(2);
/// The least time `status --wait` gives one read, so a read at the deadline can answer.
const READ_FLOOR: Duration = Duration::from_secs(5);

#[derive(Subcommand)]
pub enum ForkRunCmd {
    /// Fork a Cloud machine into one copy-on-write machine per harness (N harnesses, N forks).
    Start(StartArgs),
    /// Read a fork run: its state, its children and the one selected.
    Status(StatusArgs),
    /// Keep one ready child as the run's result.
    Select(SelectArgs),
}

#[derive(Args, Clone, Default)]
pub struct CloudArgs {
    /// The Cloud workspace the source machine belongs to.
    #[arg(long, required = true)]
    pub workspace: String,
    /// The cmux Cloud API (default: CMUX_CLOUD_API_URL).
    #[arg(long, value_name = "URL")]
    pub cloud_api: Option<String>,
    /// A file holding your Cloud access token (default: CMUX_CLOUD_ACCESS_TOKEN).
    #[arg(long, value_name = "PATH")]
    pub cloud_token_file: Option<PathBuf>,
    /// The Cloud team (default: CMUX_CLOUD_TEAM).
    #[arg(long)]
    pub team: Option<String>,
}

#[derive(Args)]
pub struct StartArgs {
    #[command(flatten)]
    pub cloud: CloudArgs,
    /// The source Cloud machine (vm_…).
    #[arg(long, required = true)]
    pub machine: String,
    /// One fork per harness: repeat it or give a list (`--harness claude,codex`).
    #[arg(long = "harness", value_delimiter = ',', required = true)]
    pub harnesses: Vec<String>,
    /// The chat on the source machine each fork continues.
    #[arg(long)]
    pub session: Option<String>,
    /// The prompt each fork works on.
    #[arg(long)]
    pub prompt: Option<String>,
    /// The run's idempotency key: the same key answers the same run (default: a new one).
    #[arg(long)]
    pub key: Option<String>,
}

#[derive(Args)]
pub struct StatusArgs {
    #[command(flatten)]
    pub cloud: CloudArgs,
    /// The fork run id `start` printed.
    pub run: String,
    /// Read again until the run is ready or failed, for at most this many seconds.
    #[arg(long, value_name = "SECONDS", default_value_t = 0)]
    pub wait: u64,
}

#[derive(Args)]
pub struct SelectArgs {
    #[command(flatten)]
    pub cloud: CloudArgs,
    /// The fork run id.
    pub run: String,
    /// The ready child to keep.
    pub child: String,
}

pub async fn run(cmd: ForkRunCmd, json_out: bool) -> Result<()> {
    let env = |name: &str| std::env::var(name).ok();
    let answer = execute(cmd, &env).await?;
    if json_out {
        print_json(&answer);
    } else {
        print!("{}", render(&answer));
    }
    Ok(())
}

/// The run the command answers, with `env` for the credential's defaults.
pub(crate) async fn execute(cmd: ForkRunCmd, env: &Env) -> Result<Value> {
    match cmd {
        ForkRunCmd::Start(a) => {
            let key = a.key.unwrap_or_else(new_key);
            let source = a.machine.clone();
            // `--session`: each fork continues that chat, a copy of its transcript.
            let mut spec = crate::fork_spec::ForkSpec::preset(crate::fork_spec::Preset::ForkRun);
            if a.session.is_some() {
                spec.context = crate::fork_spec::Context::Copy;
            }
            let mut args = json!({
                "verb": "start", "workspace": a.cloud.workspace, "clientKey": key,
                "sourceMachine": a.machine, "harnesses": a.harnesses,
            });
            for (name, value) in [("session", a.session), ("prompt", a.prompt)] {
                if let (Some(value), Some(args)) = (value, args.as_object_mut()) {
                    args.insert(name.to_owned(), json!(value));
                }
            }
            // A start whose answer was lost may still have made the run: the error names the
            // key, so a retry with it answers that run instead of making a second one.
            let mut answer = call(&a.cloud, args, env).await.map_err(|e| with_key(e, &key))?;
            crate::fork_spec::log(&spec, &source, &key);
            if let Some(answer) = answer.as_object_mut() {
                answer.insert("clientKey".to_owned(), json!(key));
            }
            Ok(answer)
        }
        ForkRunCmd::Status(a) => {
            let args = json!({ "verb": "get", "workspace": a.cloud.workspace, "run": a.run });
            let deadline = tokio::time::Instant::now() + Duration::from_secs(a.wait);
            let mut answer = call(&a.cloud, args.clone(), env).await?;
            loop {
                let settled = matches!(field(&answer, "state").as_str(), Some("ready" | "failed"));
                let left = deadline.saturating_duration_since(tokio::time::Instant::now());
                if settled || left.is_zero() {
                    if settled || a.wait == 0 {
                        return Ok(answer);
                    }
                    let state = field(&answer, "state").as_str().unwrap_or("unknown").to_owned();
                    return Err(AppError::timeout(format!(
                        "fork run {} is still {state} after {} s",
                        a.run, a.wait
                    ))
                    .with_data(answer)
                    .into());
                }
                // Sleep and read within what is left of --wait: the last read is at the deadline,
                // and a read gets what is left or READ_FLOOR, whichever is longer (a read past it
                // is cut off, and the run's last state seen is the answer).
                tokio::time::sleep(POLL.min(left)).await;
                let left = deadline.saturating_duration_since(tokio::time::Instant::now());
                let budget = left.max(READ_FLOOR);
                match tokio::time::timeout(budget, call(&a.cloud, args.clone(), env)).await {
                    Ok(read) => answer = read?,
                    Err(_) => continue,
                }
            }
        }
        ForkRunCmd::Select(a) => {
            let args = json!({
                "verb": "select", "workspace": a.cloud.workspace, "run": a.run, "childId": a.child,
            });
            call(&a.cloud, args, env).await
        }
    }
}

/// A key no earlier run has: the time and this process.
fn new_key() -> String {
    let ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis());
    format!("acpmux-fork-{ms}-{}", std::process::id())
}

/// The `owner.fork_run` request: the API, the credential and the team from the flags, else `env`.
#[cfg(unix)]
pub(crate) fn request(
    cloud: &CloudArgs,
    args: Value,
    env: &Env,
) -> Result<cmux_cloud_api::Request> {
    let set = |v: Option<String>| v.map(|v| v.trim().to_owned()).filter(|v| !v.is_empty());
    let api = set(cloud.cloud_api.clone()).or_else(|| set(env(API_ENV))).ok_or_else(|| {
        AppError::usage(format!("fork-run needs the Cloud API: --cloud-api URL or {API_ENV}"))
    })?;
    let credential = match &cloud.cloud_token_file {
        Some(path) => set(std::fs::read_to_string(path).ok()).ok_or_else(|| {
            AppError::usage(format!("--cloud-token-file {}: no token there", path.display()))
        })?,
        None => set(env(TOKEN_ENV)).ok_or_else(|| {
            AppError::usage(format!(
                "fork-run needs your Cloud credential: --cloud-token-file PATH or {TOKEN_ENV}"
            ))
        })?,
    };
    Ok(cmux_cloud_api::Request {
        call: "owner.fork_run".into(),
        api,
        auth: cmux_cloud_api::Auth::Owner,
        credential,
        refresh: None,
        team: set(cloud.team.clone()).or_else(|| set(env(TEAM_ENV))),
        app_version: None,
        local_only: false,
        args: args.as_object().cloned().unwrap_or_else(Map::new),
    })
}

#[cfg(not(unix))]
async fn call(_cloud: &CloudArgs, _args: Value, _env: &Env) -> Result<Value> {
    Err(AppError::usage("fork-run runs on macOS and Linux (the Cloud client is Unix-only)").into())
}

#[cfg(unix)]
async fn call(cloud: &CloudArgs, args: Value, env: &Env) -> Result<Value> {
    let request = request(cloud, args, env)?;
    cmux_cloud_api::perform(&request, zeroize::Zeroizing::new(Vec::new()))
        .await
        .map_err(|failure| anyhow::Error::from(failed(&failure, &request)))
}

/// A failed start's error with its key: the line says how to retry it, the data carries it.
fn with_key(error: anyhow::Error, key: &str) -> anyhow::Error {
    let Ok(mut app) = error.downcast::<AppError>() else {
        return anyhow::anyhow!("fork run start failed; retry it with --key {key}");
    };
    app.message =
        format!("{} Retry this start with --key {key}: it never makes a second run.", app.message);
    let mut data = app.data.take().unwrap_or_else(|| json!({}));
    if let Some(object) = data.as_object_mut() {
        object.insert("clientKey".to_owned(), json!(key));
    }
    app.with_data(data).into()
}

/// The library's failure as acpmux's error, in acpmux's own words with what to do next. The
/// platform's code (`fork_run.conflict`, …) or the failure's kind is the detail; the failure's
/// fields go in the data with the credential redacted (`cmux_cloud_api::scrub`).
#[cfg(unix)]
fn failed(failure: &cmux_cloud_api::Failure, request: &cmux_cloud_api::Request) -> AppError {
    use cmux_cloud_api::Failure;
    let scrubbed = cmux_cloud_api::scrub(failure.json().to_string(), request);
    let data = serde_json::from_str::<Value>(&scrubbed).unwrap_or(Value::Null);
    let platform = field(&data, "code").as_str().filter(|c| !c.is_empty());
    let detail = platform.unwrap_or(failure.kind()).to_owned();
    let message = match (failure, platform) {
        (Failure::TimedOut(_), _) => {
            "The Cloud API did not answer in time. Read the run with fork-run status, or retry."
                .to_owned()
        }
        (Failure::Transport(_) | Failure::NoBackend, _) => {
            "Could not reach the Cloud API. Check --cloud-api and the network.".to_owned()
        }
        (Failure::Decoding(_), _) => "The Cloud API's answer was not a fork run.".to_owned(),
        (Failure::PlanRequired { plan, .. }, _) => format!("Fork runs need the {plan} plan."),
        (_, Some("fork_run.child_not_ready")) => {
            "That fork is not ready yet. Wait with fork-run status RUN --wait 180.".to_owned()
        }
        (_, Some("fork_run.selection_conflict")) => {
            "This run already kept another fork; a run keeps one.".to_owned()
        }
        (_, Some("fork_run.conflict")) => {
            "That key belongs to a different fork run. Start again without --key.".to_owned()
        }
        (
            _,
            Some("fork_run.invalid" | "fork_run.empty_harnesses" | "fork_run.duplicate_harness"),
        ) => "Cloud refused the fork run: give 1 to 16 different --harness values and real ids."
            .to_owned(),
        (
            _,
            Some(
                "fork_run.unavailable"
                | "fork_run.provider_unavailable"
                | "fork_run.placement_unavailable",
            ),
        ) => "Cloud fork runs are not available here right now. Try again later.".to_owned(),
        (Failure::Http { status: 401 | 403, .. }, _) => {
            "Cloud refused your credential. Sign in again or check --team.".to_owned()
        }
        (Failure::Http { status: 404, .. }, _) => {
            "No such fork run, workspace or machine on this Cloud team.".to_owned()
        }
        (Failure::Http { status, .. }, _) => format!("Cloud refused the fork run ({status})."),
    };
    let code = if matches!(failure, Failure::TimedOut(_)) { Code::Timeout } else { Code::Runtime };
    AppError::new(code, &detail, message).with_data(data)
}

/// A field of a JSON object, null when absent: no indexing that can panic.
fn field<'a>(value: &'a Value, name: &str) -> &'a Value {
    value.get(name).unwrap_or(&Value::Null)
}

/// The run as text: one line for the run, one per child.
pub(crate) fn render(run: &Value) -> String {
    let text = |v: &Value| v.as_str().unwrap_or("-").to_owned();
    let mut out = format!("fork run {}: {}", text(field(run, "id")), text(field(run, "state")));
    if let Some(selected) = field(run, "selectedChild").as_str() {
        out.push_str(&format!(" (kept {selected})"));
    }
    if let Some(key) = field(run, "clientKey").as_str() {
        out.push_str(&format!("\n  key {key} (pass --key {key} to retry this start)"));
    }
    out.push('\n');
    for child in field(run, "children").as_array().into_iter().flatten() {
        let tail = field(child, "error")
            .as_str()
            .map_or_else(|| text(field(child, "machineId")), str::to_owned);
        out.push_str(&format!(
            "  {}  {}  {}  {}\n",
            text(field(child, "id")),
            text(field(child, "harness")),
            text(field(child, "state")),
            tail
        ));
    }
    out
}

#[cfg(all(test, unix))]
#[path = "fork_run_tests.rs"]
mod tests;
