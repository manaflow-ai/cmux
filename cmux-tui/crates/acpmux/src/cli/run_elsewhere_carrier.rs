//! `acpmux run-elsewhere-carrier --machine NAME --script PATH` (hidden): the runner of a
//! run-elsewhere task bound for a Cloud or AutoCloud machine (`server/run_elsewhere.rs`). It
//! sends its calls through this machine's daemon (`_acpmux/machine_files_call`,
//! `server/machine_files_relay.rs`), which the far machine's grant and policy decide
//! (`machine_files.rs`):
//!
//! 1. `exec mktemp -d`: a private folder (0700 whatever the umask) in the far temp folder.
//! 2. `fs.write` the script into it. `fs.write` makes a new file 0644, so the folder is what
//!    keeps the patch from other users there, from the first byte.
//! 3. `exec /bin/bash` on it. The script removes its folder before anything else runs.
//!
//! When a step fails or is refused after the folder exists, this asks the far machine to remove
//! the folder (`exec rm -rf`). That call can be refused too (control revoked mid-run: the grant is
//! checked on every call), so a failure that could not clean up says so and names the private
//! folder left there, still 0700. The output prints here when the run ends (the far
//! machine's `exec` holds a run to ten minutes, 256 KB per stream), and this exits with the run's
//! exit code.

use anyhow::{Context, Result, anyhow, bail};
use futures::future::BoxFuture;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

use crate::rpc::method;

/// The longest run the far machine's `exec` allows (`hand/exec.rs`).
const RUN_TIMEOUT_MS: u64 = 600_000;
/// The far temp folder every run's private folder is made in.
const FAR_TMP: &str = "/tmp";
const FAR_PREFIX: &str = "/tmp/cmux-run-elsewhere-";

#[derive(clap::Args, Debug, Clone)]
pub struct RunElsewhereCarrierArgs {
    /// The machine, by the name `_acpmux/run_elsewhere/plan` listed.
    #[arg(long)]
    pub machine: String,
    /// The run's script here (`<ACPMUX_HOME>/run-elsewhere/<run>.sh`).
    #[arg(long)]
    pub script: PathBuf,
}

/// The `mktemp -d` template of the run's private folder on the far machine, named for its run.
pub(crate) fn far_template(script: &Path) -> Result<String> {
    let stem = script
        .file_stem()
        .and_then(|s| s.to_str())
        .filter(|s| !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '-'))
        .ok_or_else(|| anyhow!("{}: not a run-elsewhere script", script.display()))?;
    Ok(format!("{FAR_PREFIX}{stem}-XXXXXX"))
}

fn exec_call(machine: &str, argv: &[&str], timeout_ms: u64) -> Value {
    json!({
        "machine": machine,
        "action": "exec",
        "params": {"argv": argv, "cwd": FAR_TMP, "timeout_ms": timeout_ms},
    })
}

/// Make the private folder.
pub(crate) fn mkdir_call(machine: &str, template: &str) -> Value {
    exec_call(machine, &["mktemp", "-d", template], 30_000)
}

/// The folder `mktemp -d` answered with, only if it is the one asked for.
pub(crate) fn made_folder(reply: &Value, template: &str) -> Result<String> {
    let out = reply.get("stdout").and_then(Value::as_str).unwrap_or_default().trim_end();
    let stem = template.trim_end_matches('X');
    let ok = reply.get("exit").and_then(Value::as_i64) == Some(0)
        && out.len() == template.len()
        && out
            .strip_prefix(stem)
            .is_some_and(|tail| tail.chars().all(|c| c.is_ascii_alphanumeric()));
    if !ok {
        let err = reply.get("stderr").and_then(Value::as_str).unwrap_or_default().trim();
        bail!("could not make a private folder there: {err}");
    }
    Ok(out.to_owned())
}

/// Write the script into the folder (it removes the folder first), then run it.
pub(crate) fn run_calls(machine: &str, folder: &str, script: &str) -> [Value; 2] {
    let far = format!("{folder}/run.sh");
    let text = format!("rm -rf -- \"${{0%/*}}\"\n{script}");
    [
        json!({"machine": machine, "action": "fs.write", "params": {"path": far, "text": text}}),
        exec_call(machine, &["/bin/bash", &far], RUN_TIMEOUT_MS),
    ]
}

/// Remove the folder when a step after making it failed.
pub(crate) fn cleanup_call(machine: &str, folder: &str) -> Value {
    exec_call(machine, &["rm", "-rf", "--", folder], 30_000)
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

/// Sends the run's calls through `call` (one `_acpmux/machine_files_call` each) and returns the
/// run's `exec` answer. Any failure after the folder exists removes it first.
pub(crate) async fn deliver(
    call: &mut dyn FnMut(Value) -> BoxFuture<'static, Result<Value>>,
    machine: &str,
    script_path: &Path,
    script: &str,
) -> Result<Value> {
    let template = far_template(script_path)?;
    let made = call(mkdir_call(machine, &template))
        .await
        .with_context(|| format!("{machine}: make the run's private folder"))?;
    let folder = made_folder(&made, &template).with_context(|| machine.to_owned())?;
    let [write, exec] = run_calls(machine, &folder, script);
    let ran = match call(write).await {
        Ok(_) => call(exec).await.with_context(|| format!("{machine}: run the script")),
        Err(e) => Err(e).with_context(|| format!("{machine}: send the run's script")),
    };
    let Err(failed) = ran else { return ran };
    // The far side may never have started bash, so its own first line never ran.
    let left = match call(cleanup_call(machine, &folder)).await {
        Ok(reply) if reply.get("exit").and_then(Value::as_i64) == Some(0) => return Err(failed),
        Ok(reply) => {
            let err = reply.get("stderr").and_then(Value::as_str).unwrap_or_default();
            err.trim().to_owned()
        }
        Err(e) => format!("{e:#}"),
    };
    Err(failed.context(format!(
        "{machine}: and removing the run's private folder failed too ({left}); {folder} is still \
         there (0700, only the account the run used can read it): remove it by hand"
    )))
}

pub async fn run(args: RunElsewhereCarrierArgs) -> Result<i32> {
    let script = std::fs::read_to_string(&args.script)
        .with_context(|| format!("read {}", args.script.display()))?;
    let client = crate::daemon::connect(true).await?;
    eprintln!("[cmux] sending the run to {} over the hub carrier", args.machine);
    let mut call = |params: Value| -> BoxFuture<'static, Result<Value>> {
        let client = client.clone();
        Box::pin(async move { client.request(method::MUX_MACHINE_FILES_CALL, params).await })
    };
    let reply = deliver(&mut call, &args.machine, &args.script, &script).await?;
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
