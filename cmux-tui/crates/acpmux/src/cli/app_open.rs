//! App open aliases use the installed cmux CLI's existing action and option parser.

use std::path::PathBuf;

use anyhow::{Context as _, Result};

fn cmux_binary() -> PathBuf {
    let sibling = std::env::current_exe().ok().and_then(|exe| {
        let path = exe.parent()?.join(if cfg!(windows) { "cmux.exe" } else { "cmux" });
        path.is_file().then_some(path)
    });
    sibling.unwrap_or_else(|| PathBuf::from("cmux"))
}

pub async fn run(verb: &str, args: Vec<String>, json_out: bool) -> Result<()> {
    let mut command = std::process::Command::new(cmux_binary());
    if json_out {
        command.arg("--json");
    }
    command.args(["agent", verb]).args(args);
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt as _;
        Err(command.exec()).context("opening an agent session needs the installed cmux CLI")
    }
    #[cfg(not(unix))]
    {
        let status = tokio::process::Command::from(command)
            .status()
            .await
            .context("opening an agent session needs the installed cmux CLI")?;
        if status.success() {
            return Ok(());
        }
        use crate::cli::errors::{AppError, Code};
        Err(AppError::new(Code::Runtime, "app_open_failed", status.to_string())
            .with_exit(status.code().unwrap_or(1))
            .into())
    }
}
