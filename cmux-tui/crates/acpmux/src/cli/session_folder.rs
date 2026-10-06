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

#[cfg(test)]
mod new_session_cwd_tests {
    use super::new_session_cwd;
    use std::path::PathBuf;

    #[test]
    fn host_without_cwd_tells_the_user_to_pass_cwd() {
        let err = new_session_cwd(Some("mini"), None).unwrap_err().to_string();
        assert!(err.starts_with("No folder for this session: pass --cwd <folder>"), "{err}");
        assert!(err.contains("mini"), "{err}");
    }

    #[test]
    fn host_with_cwd_keeps_the_remote_folder() {
        let got = new_session_cwd(Some("mini"), Some(PathBuf::from("/srv/proj"))).unwrap();
        assert_eq!(got, PathBuf::from("/srv/proj"));
    }

    #[test]
    fn local_without_cwd_uses_the_current_directory() {
        let got = new_session_cwd(None, None).unwrap();
        assert_eq!(got, std::env::current_dir().unwrap());
    }
}
