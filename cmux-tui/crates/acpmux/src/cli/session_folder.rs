//! The folder an `acpmux new` session runs in (LAUNCH-NO-TCC-PROMPTS).

use anyhow::Result;
use std::path::PathBuf;

/// The folder for `acpmux new`. On a peer (`--host`) the folder is a remote
/// path and must be named: a daemon refuses a session with no folder and
/// never starts an agent in a home folder by default (LAUNCH-NO-TCC-PROMPTS).
/// Locally the folder defaults to the current directory.
pub(crate) fn new_session_cwd(host: Option<&str>, cwd: Option<PathBuf>) -> Result<PathBuf> {
    match (host, cwd) {
        (_, Some(c)) => Ok(c),
        (Some(host), None) => anyhow::bail!(
            "No folder for this session: pass --cwd <folder> to name the folder on {host} \
             to run the agent in (an agent never starts in the home folder by default)"
        ),
        (None, None) => Ok(std::env::current_dir()?),
    }
}
