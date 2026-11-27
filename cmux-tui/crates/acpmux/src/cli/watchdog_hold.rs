//! `acpmux daemon watchdog-hold`: the platform's ask, just before it pauses the VM, that the
//! running daemon hold its systemd watchdog until the machine resumes (`daemon/watchdog.rs`).
//! One JSON line: `{"held":true,"until_resume":true}`, or `held:false` when no systemd watchdog
//! is armed (exit 0 both). A daemon from before the method, no daemon, or no answer within
//! [`BOUND`] (1.5 s) fails: the platform ignores a failure and pauses anyway.

use std::time::Duration;

use anyhow::{Result, anyhow};
use serde_json::{Value, json};

use crate::rpc::method;

/// Inside the platform's 2 s `timeout` for the command (cmux-platform#2416), so a slow daemon
/// ends in this command's own error, not a kill.
pub(crate) const BOUND: Duration = Duration::from_millis(1_500);

/// `acpmux daemon watchdog-hold [--json]`: the line is JSON either way, for the platform.
pub async fn run() -> Result<()> {
    let answer = tokio::time::timeout(BOUND, async {
        let client = crate::daemon::connect(false).await?;
        client.request(method::MUX_WATCHDOG_HOLD, json!({})).await.map_err(|e| anyhow!("{e}"))
    })
    .await
    .map_err(|_| {
        anyhow!(
            "the daemon did not answer `{}` in {} ms",
            method::MUX_WATCHDOG_HOLD,
            BOUND.as_millis()
        )
    })??;
    println!("{}", line(&answer)?);
    Ok(())
}

/// The printed line of the daemon's answer: refused when it is not a hold's answer.
pub(crate) fn line(answer: &Value) -> Result<String> {
    let held = answer.get("held").and_then(Value::as_bool).ok_or_else(|| {
        anyhow!("the daemon answered `{}` without `held`: {answer}", method::MUX_WATCHDOG_HOLD)
    })?;
    let until_resume = answer.get("until_resume").and_then(Value::as_bool).unwrap_or(held);
    Ok(json!({"held": held, "until_resume": until_resume}).to_string())
}

#[cfg(test)]
#[path = "watchdog_hold_tests.rs"]
mod tests;
