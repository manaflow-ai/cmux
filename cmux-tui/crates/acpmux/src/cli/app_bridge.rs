//! Forward agent-workspace commands to the installed cmux app CLI.
//!
//! The app owns workspace placement, target-pane and host validation. acpmux
//! keeps these spellings as aliases by forwarding the complete argument tail
//! rather than reimplementing that action protocol.

use anyhow::{Result, anyhow};
use std::process::Stdio;

use super::command::AppOpenArgs;

pub async fn run(args: AppOpenArgs, tab: bool, json_out: bool) -> Result<()> {
    // The app's own CLI, never a bare `cmux` that may be classic's (ask-3b6366d31e).
    let binary = crate::login_env::cmux_cli();
    let mut command = tokio::process::Command::new(binary);
    if json_out {
        command.arg("--json");
    }
    command
        .arg("agent")
        .arg(if tab { "open-tab" } else { "open" })
        .arg(&args.session)
        .args(&args.options)
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit());
    let status = command.status().await.map_err(|error| {
        anyhow!("cannot run cmux agent {}: {error}", if tab { "open-tab" } else { "open" })
    })?;
    if status.success() {
        Ok(())
    } else {
        Err(anyhow!("cmux agent {} exited with {}", if tab { "open-tab" } else { "open" }, status))
    }
}
