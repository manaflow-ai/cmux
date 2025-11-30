#![deny(clippy::all)]

mod types;
mod util;
mod repo;
mod diff;
mod merge_base;
mod branches;

use napi::bindgen_prelude::*;
use napi_derive::napi;
use types::{BranchInfo, DiffEntry, GitDiffOptions, GitListRemoteBranchesOptions};

#[napi]
pub async fn get_time() -> Result<String> {
  use std::time::{SystemTime, UNIX_EPOCH};
  #[cfg(debug_assertions)]
  println!("[cmux_native_core] get_time invoked");
  let now = SystemTime::now()
    .duration_since(UNIX_EPOCH)
    .map_err(|e| Error::from_reason(format!("System time error: {e}")))?;
  Ok(now.as_millis().to_string())
}

#[napi]
pub async fn git_diff(opts: GitDiffOptions) -> Result<Vec<DiffEntry>> {
  #[cfg(debug_assertions)]
  println!(
    "[cmux_native_git] git_diff headRef={} baseRef={:?} originPathOverride={:?} repoUrl={:?} repoFullName={:?} includeContents={:?} maxBytes={:?}",
    opts.headRef,
    opts.baseRef,
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

#[cfg(test)]
mod tests;
