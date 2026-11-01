//! The commit part of the build id. `build.rs` includes this file with
//! `#[path]`. Keep it std-only: a build script cannot use the crate's
//! dependencies.
//!
//! A source archive has no `.git`, so it sets CMUX_GIT_SHORT_SHA to the commit
//! it was exported from. Git wins whenever it is available, so a checkout never
//! reports a commit other than its own.

/// Length of the hash in the build id, as `git rev-parse --short=9 HEAD`.
pub const SHORT_LEN: usize = 9;

/// Validates a CMUX_GIT_SHORT_SHA value: 7 to 40 lowercase hex characters.
pub fn validate(raw: &str) -> Result<&str, String> {
    let hex = raw.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b));
    if (7..=40).contains(&raw.len()) && hex {
        Ok(raw)
    } else {
        Err(format!("CMUX_GIT_SHORT_SHA={raw:?} is not 7 to 40 lowercase hex characters"))
    }
}

/// Picks the hash for the build id from git's short hash (when git is
/// available) and a validated CMUX_GIT_SHORT_SHA. Returns the hash and a
/// warning when both exist and name different commits.
pub fn choose(git: Option<&str>, env: Option<&str>) -> (String, Option<String>) {
    match (git, env) {
        (Some(git), env) => {
            let warning = env.filter(|e| !git.starts_with(e) && !e.starts_with(git)).map(|e| {
                format!("CMUX_GIT_SHORT_SHA={e} differs from the git checkout's {git}; using {git}")
            });
            (git.to_owned(), warning)
        }
        // Cut a longer value to git's length so an archive build and a
        // checkout build of one commit embed the same build id.
        (None, Some(env)) => (env[..env.len().min(SHORT_LEN)].to_owned(), None),
        (None, None) => ("nogit".to_owned(), None),
    }
}
