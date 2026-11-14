//! The folder an `acpmux new` session runs in (LAUNCH-NO-TCC-PROMPTS).

use anyhow::Result;
use std::path::PathBuf;

/// The folder for `acpmux new`. On a peer (`--host`) the folder is a remote
/// path: with none named the request carries no folder, and the peer runs the
/// session in a scratch folder of its own named after the session
/// (`server/remote_guard.rs` `peer_scratch`), never in a home folder
/// (LAUNCH-NO-TCC-PROMPTS). Locally the folder defaults to the current
/// directory.
pub(crate) fn new_session_cwd(host: Option<&str>, cwd: Option<PathBuf>) -> Result<Option<PathBuf>> {
    match (host, cwd) {
        (_, Some(c)) => Ok(Some(c)),
        (Some(_), None) => Ok(None),
        (None, None) => Ok(Some(std::env::current_dir()?)),
    }
}

/// The line `acpmux new` prints once the session exists: on a peer, the machine and the
/// folder the session runs in there (with no --cwd, the one the peer picked).
pub(crate) fn created_line(name: &str, id: &str, host: Option<&str>, cwd: Option<&str>) -> String {
    let mut line = format!("created {name} ({})", id.get(..8).unwrap_or(id));
    if let Some(host) = host {
        line.push_str(&format!(" on {host}"));
        if let Some(cwd) = cwd.filter(|c| !c.is_empty()) {
            line.push_str(&format!(" in {cwd}"));
        }
    }
    line
}

#[cfg(test)]
mod tests;
