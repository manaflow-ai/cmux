//! The git a diff session runs (the patch, untracked files, generated
//! paths), confined by cmux-git's `run::confine_read`, the same confinement
//! as the session host's `git.*` reads: a repository's own config never
//! runs a program (no fsmonitor, no hooks, no submodule inline diff, no
//! lazy fetch, and every filter driver blanked, in the repository and each
//! checked-out submodule, the user's global ones such as git-lfs's
//! included) and never names a file the diff reads to the end. Each diff
//! also passes `--no-ext-diff` and `--no-textconv`.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use cmux_git::Repository;
use cmux_git::run::{Override, PROGRAM, confine_read};
use tokio::process::Command;

pub(crate) struct SessionGit {
    repo: PathBuf,
    overrides: Vec<Override>,
}

impl SessionGit {
    /// The git runs for `repo`, or `None` when it is not in a work tree, or
    /// its filter drivers (its submodules' too) cannot be listed within
    /// `deadline`. Without that list no run would be safe.
    pub(crate) async fn open(repo: &Path, deadline: Duration) -> Option<Self> {
        let until = Instant::now() + deadline;
        let directory = repo.to_path_buf();
        let overrides = tokio::time::timeout(
            deadline,
            tokio::task::spawn_blocking(move || {
                let repository = Repository::open_within(&directory, until).ok()?;
                Some(repository.with_submodule_filters().ok()?.overrides)
            }),
        )
        .await
        .ok()?
        .ok()??;
        Some(Self {
            repo: repo.to_path_buf(),
            overrides,
        })
    }

    /// `git -C <repo>`, confined; the caller adds the subcommand. It is the
    /// git cmux-git runs (`run::PROGRAM`), which listed the filter drivers
    /// to blank.
    pub(crate) fn command(&self) -> Command {
        let mut command = Command::new(PROGRAM);
        confine_read(command.as_std_mut(), &self.overrides);
        command.arg("-C").arg(&self.repo);
        command
    }
}
