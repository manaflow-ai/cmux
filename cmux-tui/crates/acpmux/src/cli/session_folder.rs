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
    let mut line = format!("created {name} ({})", &id[..8.min(id.len())]);
    if let Some(host) = host {
        line.push_str(&format!(" on {host}"));
        if let Some(cwd) = cwd.filter(|c| !c.is_empty()) {
            line.push_str(&format!(" in {cwd}"));
        }
    }
    line
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A session on a peer started with no --cwd runs in a folder the peer
    /// picked: the created line names the machine and that folder, so the
    /// person knows where the agent works.
    #[test]
    fn the_created_line_names_the_folder_a_peer_picked() {
        let scratch = "/tmp/acpmux-peer-scratch-1000-01a1/api-work";
        assert_eq!(
            created_line("api-work", "01a17621d3c67800", Some("gcp-codex-lane-1"), Some(scratch)),
            format!("created api-work (01a17621) on gcp-codex-lane-1 in {scratch}")
        );
        // A peer that did not say: the machine only.
        assert_eq!(
            created_line("api-work", "01a17621d3c67800", Some("gcp-codex-lane-1"), None),
            "created api-work (01a17621) on gcp-codex-lane-1"
        );
        // Here, as before: the folder is the one the person is in.
        assert_eq!(created_line("x", "abc", None, Some("/home/u/p")), "created x (abc)");
    }

    #[test]
    fn a_peer_start_with_no_cwd_sends_none() {
        assert_eq!(new_session_cwd(Some("gcp-codex-lane-1"), None).unwrap(), None);
        let given = PathBuf::from("/home/cmux/Projects/x");
        assert_eq!(new_session_cwd(Some("h"), Some(given.clone())).unwrap(), Some(given));
    }
}
