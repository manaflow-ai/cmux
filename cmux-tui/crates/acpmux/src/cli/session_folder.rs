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
