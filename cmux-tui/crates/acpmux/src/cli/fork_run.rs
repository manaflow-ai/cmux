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
            let mut args = json!({
                "verb": "start", "workspace": a.cloud.workspace, "clientKey": key,
                "sourceMachine": a.machine, "harnesses": a.harnesses,
            });
            for (name, value) in [("session", a.session), ("prompt", a.prompt)] {
                if let Some(value) = value {
                    args[name] = json!(value);
                }
            }
            let mut answer = call(&a.cloud, args, env).await?;
            answer["clientKey"] = json!(key);
            Ok(answer)
        }
        ForkRunCmd::Status(a) => {
            let args = json!({ "verb": "get", "workspace": a.cloud.workspace, "run": a.run });
            let deadline = tokio::time::Instant::now() + Duration::from_secs(a.wait);
            loop {
                let answer = call(&a.cloud, args.clone(), env).await?;
                let settled = matches!(answer["state"].as_str(), Some("ready" | "failed"));
                if settled || a.wait == 0 {
                    return Ok(answer);
                }
                if tokio::time::Instant::now() + POLL > deadline {
                    let state = answer["state"].as_str().unwrap_or("unknown").to_owned();
                    return Err(AppError::timeout(format!(
                        "fork run {} is still {state} after {} s",
                        a.run, a.wait
                    ))
                    .with_data(answer)
                    .into());
                }
                tokio::time::sleep(POLL).await;
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
        .map_err(|failure| anyhow::Error::from(failed(&failure)))
}

/// The library's failure as acpmux's error: the platform's code (`fork_run.conflict`, …) or the
/// failure's kind as the detail, its line as the message. A failure carries no credential.
#[cfg(unix)]
fn failed(failure: &cmux_cloud_api::Failure) -> AppError {
    let data = failure.json();
    let detail =
        data["code"].as_str().filter(|c| !c.is_empty()).unwrap_or(failure.kind()).to_owned();
    let code = match failure {
        cmux_cloud_api::Failure::TimedOut(_) => Code::Timeout,
        _ => Code::Runtime,
    };
    AppError::new(code, &detail, failure.to_string()).with_data(data)
}

/// The run as text: one line for the run, one per child.
pub(crate) fn render(run: &Value) -> String {
    let text = |v: &Value| v.as_str().unwrap_or("-").to_owned();
    let mut out = format!("fork run {}: {}", text(&run["id"]), text(&run["state"]));
    if let Some(selected) = run["selectedChild"].as_str() {
        out.push_str(&format!(" (kept {selected})"));
    }
    if let Some(key) = run["clientKey"].as_str() {
        out.push_str(&format!("\n  key {key} (pass --key {key} to retry this start)"));
    }
    out.push('\n');
    for child in run["children"].as_array().into_iter().flatten() {
        let tail = child["error"].as_str().map_or_else(|| text(&child["machineId"]), str::to_owned);
        out.push_str(&format!(
            "  {}  {}  {}  {}\n",
            text(&child["id"]),
            text(&child["harness"]),
            text(&child["state"]),
            tail
        ));
    }
    out
}

#[cfg(all(test, unix))]
#[path = "fork_run_tests.rs"]
mod tests;
