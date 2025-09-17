#![deny(clippy::all)]

mod types;
mod util;
mod repo;
mod diff;
mod merge_base;
mod branches;
mod files;

use napi::bindgen_prelude::*;
use napi_derive::napi;
use types::{
  BranchInfo,
  DiffEntry,
  GitDiffRefsOptions,
  GitDiffWorkspaceOptions,
  GitListRemoteBranchesOptions,
  GitDiffLandedOptions,
  RepoFileInfo,
  ListRepoFilesOptions,
};

#[napi]
pub async fn get_time() -> String {
  use std::time::{SystemTime, UNIX_EPOCH};
  #[cfg(debug_assertions)]
  println!("[cmux_native_core] get_time invoked");
  let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap();
  now.as_millis().to_string()
}

#[napi]
pub async fn git_diff_workspace(opts: GitDiffWorkspaceOptions) -> Result<Vec<DiffEntry>> {
  #[cfg(debug_assertions)]
  println!(
    "[cmux_native_git] git_diff_workspace worktreePath={} includeContents={:?} maxBytes={:?}",
    opts.worktreePath,
    opts.includeContents,
    opts.maxBytes
  );
  tokio::task::spawn_blocking(move || diff::workspace::diff_workspace(opts))
    .await
    .map_err(|e| Error::from_reason(format!("Join error: {e}")))?
    .map_err(|e| Error::from_reason(format!("{e:#}")))
}

#[napi]
pub async fn git_diff_refs(opts: GitDiffRefsOptions) -> Result<Vec<DiffEntry>> {
  #[cfg(debug_assertions)]
  println!(
    "[cmux_native_git] git_diff_refs ref1={} ref2={} originPathOverride={:?} repoUrl={:?} repoFullName={:?} includeContents={:?} maxBytes={:?}",
    opts.ref1,
    opts.ref2,
    opts.originPathOverride,
    opts.repoUrl,
    opts.repoFullName,
    opts.includeContents,
    opts.maxBytes
  );
  tokio::task::spawn_blocking(move || diff::refs::diff_refs(opts))
    .await
    .map_err(|e| Error::from_reason(format!("Join error: {e}")))?
    .map_err(|e| Error::from_reason(format!("{e:#}")))
}

#[napi]
pub async fn git_diff_landed(opts: GitDiffLandedOptions) -> Result<Vec<DiffEntry>> {
  #[cfg(debug_assertions)]
  println!(
    "[cmux_native_git] git_diff_landed baseRef={} headRef={} b0Ref={:?} originPathOverride={:?} repoUrl={:?} repoFullName={:?} includeContents={:?} maxBytes={:?}",
    opts.baseRef,
    opts.headRef,
    opts.b0Ref,
    opts.originPathOverride,
    opts.repoUrl,
    opts.repoFullName,
    opts.includeContents,
    opts.maxBytes
  );
  tokio::task::spawn_blocking(move || crate::diff::landed::landed_diff(opts))
    .await
    .map_err(|e| Error::from_reason(format!("Join error: {e}")))?
    .map_err(|e| Error::from_reason(format!("{e:#}")))
}

#[napi]
pub async fn git_list_remote_branches(opts: GitListRemoteBranchesOptions) -> Result<Vec<BranchInfo>> {
  #[cfg(debug_assertions)]
  println!(
    "[cmux_native_git] git_list_remote_branches repoFullName={:?} repoUrl={:?} originPathOverride={:?}",
    opts.repoFullName,
    opts.repoUrl,
    opts.originPathOverride
  );
  tokio::task::spawn_blocking(move || branches::list_remote_branches(opts))
    .await
    .map_err(|e| Error::from_reason(format!("Join error: {e}")))?
    .map_err(|e| Error::from_reason(format!("{e:#}")))
}

#[napi]
pub async fn list_repository_files(opts: ListRepoFilesOptions) -> Result<Vec<RepoFileInfo>> {
  tokio::task::spawn_blocking(move || crate::files::list_repository_files(opts))
    .await
    .map_err(|e| Error::from_reason(format!("Join error: {e}")))?
    .map_err(|e| Error::from_reason(format!("{e:#}")))
}

#[cfg(test)]
mod tests;
