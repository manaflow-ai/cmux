//! The lane a move's git writes name, and the branch a refused push goes to instead
//! (`session_move.rs`).

use anyhow::{Context as _, Result};

/// The moving chat's lane, as lane-gh's `LANE_GH_LANE` names it: the last part of the chat's
/// name (`swarm-10/lane-12` -> `lane-12`), kept to `[A-Za-z0-9._-]`. A move is driven from
/// outside the chat (lane-gh's broker strips its own `ACPMUX_SESSION*`), so the pushes it makes
/// for the chat name its lane themselves, or lane-gh refuses them as "lease acquisition requires
/// a lane session". `None` for a name with nothing left: lane-gh's own lookup then applies.
pub(crate) fn lane_of(name: &str) -> Option<String> {
    let last = name.rsplit('/').next().unwrap_or(name);
    let mut out = String::new();
    for c in last.chars() {
        if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') {
            out.push(c);
        } else if !out.ends_with('-') {
            out.push('-');
        }
    }
    let out: String = out.trim_matches(|c| c == '-' || c == '.').chars().take(60).collect();
    (!out.is_empty()).then_some(out)
}

/// The setting that turns on a move's second push: `ACPMUX_MOVE_BRANCH_PREFIX`, a prefix like
/// `lane/`. Unset or empty (the default), a refused push fails the move as before.
pub(crate) const BRANCH_PREFIX_ENV: &str = "ACPMUX_MOVE_BRANCH_PREFIX";

/// [`BRANCH_PREFIX_ENV`]'s value, or `None` while it is off.
pub(crate) fn branch_prefix() -> Option<String> {
    std::env::var(BRANCH_PREFIX_ENV).ok().filter(|p| !p.trim().is_empty())
}

/// The branch a refused push of `branch` goes to instead: `prefix` and the branch's last part
/// ([`lane_of`]'s characters). `None` for a branch already under `prefix`, or with nothing left.
pub(crate) fn prefixed_branch(branch: &str, prefix: &str) -> Option<String> {
    (!branch.starts_with(prefix)).then(|| lane_of(branch)).flatten().map(|n| format!("{prefix}{n}"))
}

/// Pushes HEAD to the full ref `dest` through `push`. With a [`branch_prefix`] set, when that
/// is `refs/heads/BRANCH` and the push is refused, once more to `refs/heads/PREFIX BRANCH`
/// ([`prefixed_branch`]), which the target then checks out: for an origin that takes only
/// branches under a prefix. Returns the ref pushed and its commit.
pub(crate) fn push_or_prefixed(
    dest: &str,
    prefix: Option<&str>,
    push: impl Fn(&str) -> Result<String>,
) -> Result<(String, String)> {
    match push(dest) {
        Ok(commit) => Ok((dest.to_owned(), commit)),
        Err(e) => {
            let retry = prefix
                .zip(dest.strip_prefix("refs/heads/"))
                .and_then(|(p, b)| prefixed_branch(b, p));
            let Some(branch) = retry else { return Err(e) };
            let to = format!("refs/heads/{branch}");
            let commit = push(&to)
                .with_context(|| format!("{e:#}; then pushing it as {branch} failed too"))?;
            Ok((to, commit))
        }
    }
}

/// What a failed push says, for the move's error: every non-empty line of git's stderr, joined
/// and kept to 600 characters. A server's refusal wraps over several lines before git's own
/// "failed to push some refs"; keeping only the last line lost the reason.
pub(crate) fn push_refusal(stderr: &str) -> String {
    let all = stderr.lines().map(str::trim).filter(|l| !l.is_empty()).collect::<Vec<_>>().join(" ");
    all.chars().take(600).collect()
}
