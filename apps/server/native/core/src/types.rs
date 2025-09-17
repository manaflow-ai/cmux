#![allow(non_snake_case)]
use napi_derive::napi;

#[napi(object)]
#[derive(Default, Debug, Clone)]
pub struct DiffEntry {
  pub filePath: String,
  pub oldPath: Option<String>,
  pub status: String,
  pub additions: i32,
  pub deletions: i32,
  pub isBinary: bool,
  pub contentOmitted: Option<bool>,
  pub oldContent: Option<String>,
  pub newContent: Option<String>,
  pub oldSize: Option<i32>,
  pub newSize: Option<i32>,
  pub patchSize: Option<i32>,
  pub patch: Option<String>,
}

#[napi(object)]
#[derive(Default, Debug, Clone)]
pub struct BranchInfo {
  pub name: String,
  pub lastCommitSha: Option<String>,
  pub lastActivityAt: Option<i64>,
  pub isDefault: Option<bool>,
}

#[napi(object)]
#[derive(Default, Debug, Clone)]
pub struct RepoFileInfo {
  pub path: String,
  pub name: String,
  pub isDirectory: bool,
  pub relativePath: String,
}

#[napi(object)]
#[derive(Default, Debug, Clone)]
pub struct ListRepoFilesOptions {
  pub repoUrl: Option<String>,
  pub repoFullName: Option<String>,
  pub originPath: Option<String>,
  pub branch: Option<String>,
  pub pattern: Option<String>,
  pub limit: Option<i32>,
}

#[napi(object)]
#[derive(Default, Debug, Clone)]
pub struct GitListRemoteBranchesOptions {
  pub repoFullName: Option<String>,
  pub repoUrl: Option<String>,
  pub originPathOverride: Option<String>,
}

#[napi(object)]
#[derive(Default, Debug, Clone)]
pub struct GitDiffWorkspaceOptions {
  pub worktreePath: String,
  pub includeContents: Option<bool>,
  pub maxBytes: Option<i32>,
}

#[napi(object)]
#[derive(Default, Debug, Clone)]
pub struct GitDiffRefsOptions {
  pub ref1: String,
  pub ref2: String,
  pub repoFullName: Option<String>,
  pub repoUrl: Option<String>,
  pub teamSlugOrId: Option<String>,
  pub originPathOverride: Option<String>,
  pub includeContents: Option<bool>,
  pub maxBytes: Option<i32>,
}

#[napi(object)]
#[derive(Default, Debug, Clone)]
pub struct GitDiffLandedOptions {
  pub baseRef: String,
  pub headRef: String,
  pub b0Ref: Option<String>,
  pub repoFullName: Option<String>,
  pub repoUrl: Option<String>,
  pub teamSlugOrId: Option<String>,
  pub originPathOverride: Option<String>,
  pub includeContents: Option<bool>,
  pub maxBytes: Option<i32>,
}
