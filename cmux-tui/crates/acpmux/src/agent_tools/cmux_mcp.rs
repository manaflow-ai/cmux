//! Whether a `cmux` binary can serve MCP: the carrier every other agent tool server is folded
//! behind (`AgentTools::folded`).

use std::path::{Path, PathBuf};

/// How long `cmux help mcp` may take before the binary counts as one that cannot serve.
const SERVES_MCP_LIMIT: std::time::Duration = std::time::Duration::from_secs(5);

/// Whether the `cmux` at `path` has `mcp serve` (`cmux help mcp` exits 0). The static
/// `cmux 0.1.0` from install-static.sh has none: listed as the `cmux` server it exits at once,
/// and every server [`super::AgentTools::folded`] put behind it goes with it (the chat shows
/// "cmux: CONNECTION_CLOSED" and has no sessions, sub-session or browser tools). Left out, the
/// other servers stay listed on their own. Asked once per file (path, size, modified time).
pub(super) fn serves_mcp(path: &Path) -> bool {
    use std::collections::HashMap;
    use std::sync::{Mutex, OnceLock};
    type Key = (PathBuf, u64, Option<std::time::SystemTime>);
    static SEEN: OnceLock<Mutex<HashMap<Key, bool>>> = OnceLock::new();
    let Ok(meta) = std::fs::metadata(path) else { return false };
    let key = (path.to_owned(), meta.len(), meta.modified().ok());
    let seen = SEEN.get_or_init(Default::default);
    if let Some(&known) = seen.lock().unwrap_or_else(|e| e.into_inner()).get(&key) {
        return known;
    }
    let serves = probe_serves_mcp(path);
    if !serves {
        tracing::warn!(
            "agent tools: {} has no `mcp serve`; its other servers are listed on their own",
            path.display()
        );
    }
    seen.lock().unwrap_or_else(|e| e.into_inner()).insert(key, serves);
    serves
}

fn probe_serves_mcp(path: &Path) -> bool {
    use cmux_process::{Command, Stdio};
    let Ok(mut child) = Command::new(path)
        .args(["help", "mcp"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    else {
        return false;
    };
    // A child still running past the limit is ended when `child` drops.
    child.wait_timeout(SERVES_MCP_LIMIT).ok().flatten().is_some_and(|status| status.success())
}
