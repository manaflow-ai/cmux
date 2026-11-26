//! `acpmux tools-mcp` (`tools_mcp.rs`): every acpmux server the env names, in one process.

use anyhow::{Result, anyhow};

/// Runs every server of [`SERVERS`](crate::tools_mcp::SERVERS) whose session this process's env names, over one daemon
/// connection.
pub async fn run() -> Result<()> {
    let servers = crate::tools_mcp::servers(&Default::default());
    if servers.is_empty() {
        return Err(anyhow!("tools-mcp: the env names no session for any server"));
    }
    crate::tools_mcp::serve(servers).await
}
