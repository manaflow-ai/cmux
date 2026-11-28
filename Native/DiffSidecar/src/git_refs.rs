//! Branch facts for branch sessions and the branch picker, read with
//! `cmux-git`: the same git code the cmux session host's `git.*` operations
//! run (plans/cmux-next/diff-host.md, Q1). The suggested base is
//! `refs::suggested_base`, whose first candidate is the base the host's
//! `git.diff --scope branch` compares with.
//!
//! cmux-git is synchronous; every read runs on the blocking pool. The
//! repository is opened with the read's deadline, so every git run inside it
//! stops there too: a read that times out leaves no git behind.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use cmux_git::Repository;
use cmux_git::refs::{self, BaseCandidate, BaseReason, BranchKind, Branches};

use tokio::sync::OwnedSemaphorePermit;

use crate::protocol::{
    BranchListResult, BranchPickerConfidence, BranchPickerGroup, BranchPickerRow,
};

/// Branches one picker load lists, local ones first.
const BRANCH_LIMIT: usize = 1000;

/// A repository's branches and base candidates.
pub(crate) struct RepositoryRefs {
    pub branches: Branches,
    pub bases: Vec<BaseCandidate>,
}

/// The suggested base's short name (`origin/main`), or `None` when `repo`
/// is not a repository, has no candidate, or the read misses `deadline`.
/// It runs under the caller's child-process permit (the session open's).
pub(crate) async fn suggested_base(repo: PathBuf, deadline: Duration) -> Option<String> {
    let until = Instant::now() + deadline;
    blocking(deadline, None, move || {
        let repository = Repository::open_within(&repo, until).ok()?;
        refs::suggested_base(&repository)
            .into_iter()
            .next()
            .map(|base| base.name)
    })
    .await
}

/// The branches and base candidates of `repo`, or `None` when it is not a
/// repository, git fails, or the read misses `deadline`. `permit` is held
/// until the blocking read ends, past a timeout too.
pub(crate) async fn repository_refs(
    repo: PathBuf,
    deadline: Duration,
    permit: OwnedSemaphorePermit,
) -> Option<RepositoryRefs> {
    let until = Instant::now() + deadline;
    blocking(deadline, Some(permit), move || {
        let repository = Repository::open_within(&repo, until).ok()?;
        let branches = refs::branches(&repository, BRANCH_LIMIT).ok()?;
        let bases = refs::suggested_base(&repository);
        Some(RepositoryRefs { branches, bases })
    })
    .await
}

async fn blocking<T: Send + 'static>(
    deadline: Duration,
    permit: Option<OwnedSemaphorePermit>,
    read: impl FnOnce() -> Option<T> + Send + 'static,
) -> Option<T> {
    let read = move || {
        let _permit = permit;
        read()
    };
    tokio::time::timeout(deadline, tokio::task::spawn_blocking(read))
        .await
        .ok()?
        .ok()?
}

/// The picker's groups, each left out when empty:
/// - `suggested`: the selected base when it is not a candidate (`manual`),
///   then the base candidates best first (`recorded`, `default`,
///   `upstream`);
/// - `branches`: local branches, with the upstream as the secondary text;
///   the branch HEAD is on carries the reason `head` instead, so the page
///   labels it (`current` stays the selected base, which the page checks);
/// - `remotes`: remote-tracking branches.
///
/// Rows name branches by short name, which `branchChange` resolves. The
/// selected base's rows are marked `current`.
pub(crate) fn branch_list(refs: &RepositoryRefs, selected: Option<&str>) -> BranchListResult {
    let selected = selected.map(str::trim).filter(|value| !value.is_empty());
    let mut suggested = Vec::new();
    if let Some(selected) = selected
        && refs.bases.iter().all(|base| base.name != selected)
    {
        suggested.push(BranchPickerRow {
            r#ref: selected.to_owned(),
            label: selected.to_owned(),
            secondary: None,
            reason: Some("manual".to_owned()),
            confidence: Some(BranchPickerConfidence::High),
            current: Some(true),
            worktree_dir: None,
        });
    }
    suggested.extend(refs.bases.iter().map(|base| {
        BranchPickerRow {
            r#ref: base.name.clone(),
            label: base.name.clone(),
            secondary: None,
            reason: Some(
                match base.reason {
                    BaseReason::RecordedBase => "recorded",
                    BaseReason::DefaultBranch => "default",
                    BaseReason::Upstream => "upstream",
                }
                .to_owned(),
            ),
            confidence: Some(BranchPickerConfidence::Low),
            current: (selected == Some(base.name.as_str())).then_some(true),
            worktree_dir: None,
        }
    }));
    let rows = |kind: BranchKind| {
        refs.branches
            .branches
            .iter()
            .filter(|branch| branch.kind == kind)
            .map(|branch| BranchPickerRow {
                r#ref: branch.name.clone(),
                label: branch.name.clone(),
                secondary: if branch.current {
                    None
                } else {
                    branch.upstream.clone()
                },
                reason: branch.current.then(|| "head".to_owned()),
                confidence: None,
                current: (selected == Some(branch.name.as_str())).then_some(true),
                worktree_dir: None,
            })
            .collect::<Vec<_>>()
    };
    let groups = [
        ("suggested", "Suggested", suggested),
        ("branches", "Local", rows(BranchKind::Local)),
        ("remotes", "Remote", rows(BranchKind::Remote)),
    ]
    .into_iter()
    .filter(|(_, _, rows)| !rows.is_empty())
    .map(|(id, label, rows)| BranchPickerGroup {
        id: id.to_owned(),
        label: label.to_owned(),
        rows,
    })
    .collect();
    BranchListResult {
        groups,
        truncated: refs.branches.truncated.then_some(true),
    }
}
