//! `acpmux tools-mcp` (`tools_mcp.rs`): every acpmux server the env names, in one process.

use crate::tools_mcp::{Daemon, Served, serve};
use anyhow::{Result, anyhow};
use std::sync::Arc;

/// Runs every server of [`SERVERS`](crate::tools_mcp::SERVERS) whose session this process's env names, over one daemon
/// connection.
pub async fn run() -> Result<()> {
    let daemon = Arc::<Daemon>::default();
    let makers: [fn(&Arc<Daemon>) -> Result<Served>; 5] = [
        crate::secret_mcp::served,
        crate::offer_mcp::served,
        crate::subsession_mcp::served,
        crate::forum_mcp::served,
        crate::acpmux_mcp::served,
    ];
    let mut servers = Vec::new();
    for make in makers {
        // A server whose session the env does not name (the secret tools without the card)
        // is not asked for: `cmux mcp serve` asks only for the servers acpmux gave it.
        match make(&daemon) {
            Ok(served) => servers.push(served),
            Err(e) => tracing::debug!("tools-mcp: a server is left out: {e:#}"),
        }
    }
    if servers.is_empty() {
        return Err(anyhow!("tools-mcp: the env names no session for any server"));
    }
    serve(servers).await
}
