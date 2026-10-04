//! Branch facts for branch sessions and the branch picker, read with
//! `cmux-git`: the same git code the cmux session host's `git.*` operations
//! run (plans/cmux-next/diff-host.md, Q1). The suggested base is
//! `refs::suggested_base`, whose first candidate is the base the host's
//! `git.diff --scope branch` compares with.
//!
//! cmux-git is synchronous; every read runs on the blocking pool, and each
//! git run inside it has its own deadline.

use std::path::PathBuf;
use std::time::Duration;

use cmux_git::Repository;
use cmux_git::refs::{self, BaseCandidate, BaseReason, BranchKind, Branches};

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
pub(crate) async fn suggested_base(repo: PathBuf, deadline: Duration) -> Option<String> {
    blocking(deadline, move || {
        let repository = Repository::open(&repo).ok()?;
        refs::suggested_base(&repository)
            .into_iter()
            .next()
            .map(|base| base.name)
    })
    .await
}

/// The branches and base candidates of `repo`, or `None` when it is not a
/// repository, git fails, or the read misses `deadline`.
pub(crate) async fn repository_refs(repo: PathBuf, deadline: Duration) -> Option<RepositoryRefs> {
    blocking(deadline, move || {
        let repository = Repository::open(&repo).ok()?;
        let branches = refs::branches(&repository, BRANCH_LIMIT).ok()?;
        let bases = refs::suggested_base(&repository);
        Some(RepositoryRefs { branches, bases })
    })
    .await
}

async fn blocking<T: Send + 'static>(
    deadline: Duration,
    read: impl FnOnce() -> Option<T> + Send + 'static,
) -> Option<T> {
    tokio::time::timeout(deadline, tokio::task::spawn_blocking(read))
        .await
        .ok()?
        .ok()?
}

/// The picker's groups, each left out when empty:
/// - `suggested`: the selected base when it is not a candidate (`manual`),
///   then the base candidates best first (`default`, `upstream`);
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
    BranchListResult { groups }
}

#[cfg(test)]
mod tests {
    use cmux_git::refs::{BaseCandidate, BaseReason, BranchKind, BranchRef, Branches};

    use super::{RepositoryRefs, branch_list};

    fn branch(name: &str, kind: BranchKind, current: bool, upstream: Option<&str>) -> BranchRef {
        let prefix = match kind {
            BranchKind::Local => "refs/heads/",
            BranchKind::Remote => "refs/remotes/",
        };
        BranchRef {
            name: name.to_owned(),
            reference: format!("{prefix}{name}"),
            kind,
            commit: "0".repeat(40),
            current,
            upstream: upstream.map(str::to_owned),
            upstream_gone: false,
            ahead: upstream.map(|_| 0),
            behind: upstream.map(|_| 0),
            committed_at: Some(1),
        }
    }

    fn base(name: &str, reason: BaseReason) -> BaseCandidate {
        BaseCandidate {
            name: name.to_owned(),
            reference: format!("refs/remotes/{name}"),
            reason,
        }
    }

    fn sample() -> RepositoryRefs {
        RepositoryRefs {
            branches: Branches {
                current: Some("feat".to_owned()),
                branches: vec![
                    branch("feat", BranchKind::Local, true, Some("origin/release")),
                    branch("main", BranchKind::Local, false, Some("origin/main")),
                    branch("old", BranchKind::Local, false, None),
                    branch("origin/main", BranchKind::Remote, false, None),
                    branch("origin/release", BranchKind::Remote, false, None),
                ],
                truncated: false,
            },
            bases: vec![
                base("origin/main", BaseReason::DefaultBranch),
                base("origin/release", BaseReason::Upstream),
            ],
        }
    }

    /// (group id, [(ref, reason, secondary, current)]).
    type Summary = Vec<(String, Vec<(String, Option<String>, Option<String>, bool)>)>;

    fn summary(result: &crate::protocol::BranchListResult) -> Summary {
        result
            .groups
            .iter()
            .map(|group| {
                let rows = group
                    .rows
                    .iter()
                    .map(|row| {
                        (
                            row.r#ref.clone(),
                            row.reason.clone(),
                            row.secondary.clone(),
                            row.current == Some(true),
                        )
                    })
                    .collect();
                (group.id.clone(), rows)
            })
            .collect()
    }

    fn row(
        reference: &str,
        reason: Option<&str>,
        secondary: Option<&str>,
        current: bool,
    ) -> (String, Option<String>, Option<String>, bool) {
        (
            reference.to_owned(),
            reason.map(str::to_owned),
            secondary.map(str::to_owned),
            current,
        )
    }

    #[test]
    fn groups_are_suggested_then_local_then_remote() {
        let result = branch_list(&sample(), Some("origin/main"));
        assert_eq!(
            result
                .groups
                .iter()
                .map(|group| group.label.as_str())
                .collect::<Vec<_>>(),
            ["Suggested", "Local", "Remote"]
        );
        assert_eq!(
            summary(&result),
            [
                (
                    "suggested".to_owned(),
                    vec![
                        row("origin/main", Some("default"), None, true),
                        row("origin/release", Some("upstream"), None, false),
                    ]
                ),
                (
                    "branches".to_owned(),
                    vec![
                        row("feat", Some("head"), None, false),
                        row("main", None, Some("origin/main"), false),
                        row("old", None, None, false),
                    ]
                ),
                (
                    "remotes".to_owned(),
                    vec![
                        row("origin/main", None, None, true),
                        row("origin/release", None, None, false),
                    ]
                ),
            ]
        );
    }

    #[test]
    fn a_selected_base_outside_the_candidates_leads_as_manual() {
        let result = branch_list(&sample(), Some(" old "));
        assert_eq!(
            summary(&result)[0].1[0],
            row("old", Some("manual"), None, true)
        );
        assert_eq!(summary(&result)[0].1.len(), 3);
        assert!(
            summary(&result)[1]
                .1
                .contains(&row("old", None, None, true))
        );
    }

    #[test]
    fn empty_groups_are_left_out() {
        let empty = RepositoryRefs {
            branches: Branches {
                current: Some("main".to_owned()),
                branches: Vec::new(),
                truncated: false,
            },
            bases: Vec::new(),
        };
        assert!(branch_list(&empty, Some("  ")).groups.is_empty());
        let manual = branch_list(&empty, Some("release"));
        assert_eq!(
            summary(&manual),
            [(
                "suggested".to_owned(),
                vec![row("release", Some("manual"), None, true)]
            )]
        );
    }
}
