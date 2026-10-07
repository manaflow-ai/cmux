import { Schema } from "effect"

/**
 * cmux.mobile/1 `git` family params and results (plans/cmux-next/ios-next/c13-viewers.md section 2;
 * schemas/mobile-rpc/families/git.schema.json). Read-only facts from the Mac's session host, served
 * by CmuxMobileHost after the files policy. Field names are the session host's `GitStatusResult` and
 * `GitDiffResult`.
 */

export const GitDiffScope = Schema.Literals(["uncommitted", "unstaged", "staged", "committed", "branch"])
export type GitDiffScope = typeof GitDiffScope.Type

export const GitChangeStatus = Schema.Literals(["added", "modified", "deleted", "renamed", "untracked"])
export type GitChangeStatus = typeof GitChangeStatus.Type

export const GitStatusParams = Schema.Struct({ path: Schema.String })
export type GitStatusParams = typeof GitStatusParams.Type

export const GitStatusResult = Schema.Struct({
  root: Schema.String,
  branch: Schema.optionalKey(Schema.String),
  detached: Schema.Boolean,
  head: Schema.optionalKey(Schema.String),
  upstream: Schema.optionalKey(Schema.String),
  base: Schema.optionalKey(Schema.String),
  ahead: Schema.Int,
  behind: Schema.Int
})
export type GitStatusResult = typeof GitStatusResult.Type

export const GitDiffParams = Schema.Struct({
  path: Schema.String,
  scope: GitDiffScope,
  paths: Schema.optionalKey(Schema.Array(Schema.String)),
  include_patch: Schema.optionalKey(Schema.Boolean),
  max_patch_bytes: Schema.optionalKey(Schema.Int),
  max_files: Schema.optionalKey(Schema.Int)
})
export type GitDiffParams = typeof GitDiffParams.Type

export const GitChangedFile = Schema.Struct({
  path: Schema.String,
  previous_path: Schema.optionalKey(Schema.String),
  status: GitChangeStatus,
  additions: Schema.Int,
  deletions: Schema.Int,
  binary: Schema.optionalKey(Schema.Boolean),
  patch: Schema.optionalKey(Schema.String),
  patch_truncated: Schema.optionalKey(Schema.Boolean)
})
export type GitChangedFile = typeof GitChangedFile.Type

export const GitDiffResult = Schema.Struct({
  scope: GitDiffScope,
  root: Schema.String,
  head: Schema.optionalKey(Schema.String),
  base: Schema.optionalKey(Schema.String),
  files: Schema.Array(GitChangedFile),
  additions: Schema.Int,
  deletions: Schema.Int,
  total_files: Schema.Int,
  files_omitted: Schema.Int,
  untracked_skipped: Schema.optionalKey(Schema.Int)
})
export type GitDiffResult = typeof GitDiffResult.Type

export const decodeGitStatusResult = Schema.decodeUnknownSync(GitStatusResult)
export const decodeGitDiffResult = Schema.decodeUnknownSync(GitDiffResult)
export const decodeGitDiffParams = Schema.decodeUnknownSync(GitDiffParams)
