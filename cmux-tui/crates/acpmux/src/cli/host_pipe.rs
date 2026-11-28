//! `acpmux machine pipe MACHINE [--port P]`: stdin and stdout to loopback port P on MACHINE
//! through this person's carrier, held across breaks (RFD 0127 cut 4,
//! `cmux_remote::provider::MachinePipeDialer::hold`). ssh's ProxyCommand runs it, so an ssh
//! session lives through either machine's acpmux restarting: this one's (the pipe is asked for
//! again through the new daemon) and the far one's (its pipe host keeps the far end,
//! `hub_carrier_pipe_host.rs`).
//!
//! Leo, 2026-11-23: "we ought to have more graceful handoffs... similar to network drains".

use anyhow::{Result, anyhow};
use cmux_remote::provider::MachinePipeDialer;
use cmux_remote::resume_hold::Held;

pub async fn run(machine: String, port: u16) -> Result<()> {
    let dialer = MachinePipeDialer::new(crate::config::socket_path(), machine);
    let stdio = tokio::io::join(tokio::io::stdin(), tokio::io::stdout());
    match dialer.hold(port, stdio).await {
        Ok(Held::Finished) => Ok(()),
        Ok(Held::Failed(why)) => Err(anyhow!("the held pipe ended: {why}")),
        Err(error) => Err(anyhow!("{error}")),
    }
}
