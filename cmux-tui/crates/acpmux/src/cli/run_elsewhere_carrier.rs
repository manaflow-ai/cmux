//! `acpmux run-elsewhere-carrier --machine NAME --script PATH` (hidden): the runner of a
//! run-elsewhere task bound for a Cloud or AutoCloud machine (`server/run_elsewhere.rs`). It
//! sends two calls through this machine's daemon (`_acpmux/machine_files_call`,
//! `server/machine_files_relay.rs`), which the far machine's grant and policy decide
//! (`machine_files.rs`): write the script into its temp folder, then run it with bash. The
//! script removes itself there before anything else runs. The output prints here when the run
//! ends (the far machine's `exec` holds a run to ten minutes, 256 KB per stream), and this exits
//! with the run's exit code.

use anyhow::{Context, Result, anyhow};
use serde_json::{Value, json};
use std::path::PathBuf;

use crate::rpc::method;

/// The longest run the far machine's `exec` allows (`hand/exec.rs`).
const RUN_TIMEOUT_MS: u64 = 600_000;

#[derive(clap::Args, Debug, Clone)]
pub struct RunElsewhereCarrierArgs {
    /// The machine, by the name `_acpmux/run_elsewhere/plan` listed.
    #[arg(long)]
    pub machine: String,
    /// The run's script here (`<ACPMUX_HOME>/run-elsewhere/<run>.sh`).
    #[arg(long)]
    pub script: PathBuf,
}

/// Where the script goes on the far machine: its temp folder, named for this run.
pub(crate) fn far_path(script: &std::path::Path) -> Result<String> {
    let stem = script
        .file_stem()
        .and_then(|s| s.to_str())
        .filter(|s| !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '-'))
        .ok_or_else(|| anyhow!("{}: not a run-elsewhere script", script.display()))?;
    Ok(format!("/tmp/cmux-run-elsewhere-{stem}.sh"))
}

/// The two calls, in order: write the script (which removes itself first), then run it.
pub(crate) fn calls(machine: &str, far: &str, script: &str) -> [Value; 2] {
    let text = format!("rm -f -- \"$0\"\n{script}");
    [
        json!({"machine": machine, "action": "fs.write", "params": {"path": far, "text": text}}),
        json!({
            "machine": machine,
            "action": "exec",
            "params": {"argv": ["/bin/bash", far], "cwd": "/tmp", "timeout_ms": RUN_TIMEOUT_MS},
        }),
    ]
}

/// The run's exit code from the far machine's `exec` answer, and what to say about its end.
pub(crate) fn outcome(reply: &Value) -> (i32, Option<String>) {
    let note = |s: &str| Some(format!("[cmux] {s}"));
    let cut = reply.get("truncated") == Some(&Value::Bool(true));
    let mut said = cut.then(|| "output cut at 256 KB per stream".to_owned());
    let code = match reply.get("exit").and_then(Value::as_i64) {
        Some(code) => code as i32,
        None if reply.get("timed_out") == Some(&Value::Bool(true)) => {
            said = Some("the run passed ten minutes and was stopped there".to_owned());
            124
        }
        None => {
            said = Some("the run was ended by a signal".to_owned());
            137
        }
    };
    (code, said.and_then(|s| note(&s)))
}

pub async fn run(args: RunElsewhereCarrierArgs) -> Result<i32> {
    let script = std::fs::read_to_string(&args.script)
        .with_context(|| format!("read {}", args.script.display()))?;
    let far = far_path(&args.script)?;
    let [write, exec] = calls(&args.machine, &far, &script);
    let client = crate::daemon::connect(true).await?;
    eprintln!("[cmux] sending the run to {} over the hub carrier", args.machine);
    client
        .request(method::MUX_MACHINE_FILES_CALL, write)
        .await
        .with_context(|| format!("{}: send the run's script", args.machine))?;
    let reply = client
        .request(method::MUX_MACHINE_FILES_CALL, exec)
        .await
        .with_context(|| format!("{}: run the script", args.machine))?;
    let text = |k: &str| reply.get(k).and_then(Value::as_str).unwrap_or_default().to_owned();
    print!("{}", text("stdout"));
    eprint!("{}", text("stderr"));
    let (code, note) = outcome(&reply);
    if let Some(note) = note {
        eprintln!("{note}");
    }
    Ok(code)
}

#[cfg(test)]
#[path = "run_elsewhere_carrier_tests.rs"]
mod tests;
