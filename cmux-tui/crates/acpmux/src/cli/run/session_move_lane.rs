//! The lane a move's git writes name, and the `lane/` branch a lane VM's git takes a
//! moving chat's branch as (`session_move.rs`).

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

/// What a lane VM's git says when it refuses a push to a branch outside `lane/`
/// (leo-workspace `tools/lane_gh_vm.py`): it pushes only `lane/` branches and the heads of PRs
/// the lane adopted.
pub(crate) const OUTSIDE_LANE: &str = "is not under lane/";

/// The `lane/` branch a push refused as [`OUTSIDE_LANE`] goes to instead: `lane/` and the
/// branch's last part ([`lane_of`]'s characters), as the refusal itself suggests. `None` for a
/// branch already under `lane/`, or with nothing left.
pub(crate) fn lane_branch_for(branch: &str) -> Option<String> {
    (!branch.starts_with("lane/")).then(|| lane_of(branch)).flatten().map(|n| format!("lane/{n}"))
}

/// Pushes HEAD to the full ref `dest` through `push`; when that is `refs/heads/BRANCH` and the
/// source's git refuses it as [`OUTSIDE_LANE`] (a lane VM's chat on a branch like `ux-trust`),
/// once more to `refs/heads/lane/BRANCH` ([`lane_branch_for`]), which the target then checks
/// out. Returns the ref pushed and its commit. Before, the refusal failed the move and held
/// the VM draining for deletion (gcp-codex-swarm-10, 2026-11-28).
pub(crate) fn push_or_lane_branch(
    dest: &str,
    push: impl Fn(&str) -> Result<String>,
) -> Result<(String, String)> {
    match push(dest) {
        Ok(commit) => Ok((dest.to_owned(), commit)),
        Err(e) => {
            let lane = dest.strip_prefix("refs/heads/").and_then(lane_branch_for);
            match lane {
                Some(lane) if format!("{e:#}").contains(OUTSIDE_LANE) => {
                    let to = format!("refs/heads/{lane}");
                    let commit = push(&to)
                        .with_context(|| format!("{e:#}; then pushing it as {lane} failed too"))?;
                    Ok((to, commit))
                }
                _ => Err(e),
            }
        }
    }
}
