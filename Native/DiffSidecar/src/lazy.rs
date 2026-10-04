//! Prototype (cargo feature `lazy-hunks`, off in the shipped binary): summary first, hunks
//! on demand. plans/cmux-next/diff-perf.md measures it against the one-patch session.
//!
//! Three stdio RPC methods, outside the typed `DiffCommand` protocol until the design lands:
//!
//! - `lazySummary {capabilityToken, repoRoot, baseRef}`: the merge base and the changed
//!   files (`git diff --name-status -z`, a tree comparison that reads no file contents).
//! - `lazyStats {capabilityToken, repoRoot, base}`: added and deleted lines per file
//!   (`--numstat -z`; reads every blob, so it streams after the list).
//! - `lazyPatches {capabilityToken, repoRoot, base, paths}`: the hunks of only these files
//!   (`--patch -- <paths>`), for the files in and near the viewport; files with 2,000 or more
//!   changed lines come back as `deferred` (a `--numstat` of those paths first).
//!
//! Every git argument list and parser comes from `cmux-git` (`diff::diff_args`,
//! `parse::name_status`, `parse::numstat`, `parse::patches`); this module adds no git code.
//! The base is the merge-base commit the summary returned, so the three reads compare the
//! same trees. Untracked files are not part of this prototype.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use cmux_git::Repository;
use cmux_git::diff::{Comparison, diff_args};
use cmux_git::parse;
use serde::Deserialize;
use serde_json::{Value, json};

use super::{AppState, authorize_repo_for_token};

const LAZY_DEADLINE: Duration = Duration::from_mins(1);
/// One patches reply stays well under the 32 MiB stdio reply limit.
const MAX_PATCHES_BYTES: usize = 24 * 1024 * 1024;
const MAX_LISTING_BYTES: usize = 64 * 1024 * 1024;
const MAX_PATHS_PER_CALL: usize = 512;
/// `LARGE_DIFF_CHANGED_LINES` in `webviews/src/deferred-diffs.ts`.
const LARGE_DIFF_CHANGED_LINES: u64 = 2_000;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LazyParams {
    capability_token: String,
    repo_root: String,
    #[serde(default)]
    base_ref: Option<String>,
    #[serde(default)]
    base: Option<String>,
    #[serde(default)]
    paths: Vec<String>,
}

/// Whether a raw request names one of this module's methods.
pub(super) fn is_lazy_method(request: &Value) -> bool {
    request
        .get("method")
        .and_then(Value::as_str)
        .is_some_and(|method| method.starts_with("lazy"))
}

pub(super) async fn handle(state: &AppState, request: Value) -> Value {
    let id = request.get("id").cloned().unwrap_or(Value::Null);
    let method = request
        .get("method")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    let failure = |code: &str, message: &str| {
        json!({"id": id, "version": crate::PROTOCOL_VERSION, "result": null,
               "error": {"code": code, "message": message}})
    };
    let Ok(params) =
        serde_json::from_value::<LazyParams>(request.get("params").cloned().unwrap_or(Value::Null))
    else {
        return failure("invalidRequest", "Invalid lazy request");
    };
    if !authorize_repo_for_token(state, &params.capability_token, &params.repo_root).await {
        return failure("notAllowed", "Diff session is not authorized");
    }
    let repo = PathBuf::from(&params.repo_root);
    let started = Instant::now();
    let read = tokio::time::timeout(
        LAZY_DEADLINE,
        tokio::task::spawn_blocking(move || run(&method, &repo, params)),
    )
    .await;
    match read {
        Ok(Ok(Ok(mut value))) => {
            value["rustMs"] = json!(started.elapsed().as_secs_f64() * 1000.0);
            json!({"id": id, "version": crate::PROTOCOL_VERSION, "result": value, "error": null})
        }
        Ok(Ok(Err(message))) => failure("lazyFailed", &message),
        _ => failure("lazyFailed", "The lazy read did not finish"),
    }
}

fn comparison(base: String) -> Comparison {
    Comparison {
        revisions: Some(vec![base]),
        cached: false,
        untracked: false,
        head: None,
        base: None,
    }
}

fn run(method: &str, repo: &std::path::Path, params: LazyParams) -> Result<Value, String> {
    let repository = Repository::open(repo).map_err(|error| error.to_string())?;
    match method {
        "lazySummary" => {
            let base_ref = params.base_ref.ok_or("baseRef is required")?;
            let base_commit = repository.commit(&base_ref).ok_or("unknown base")?;
            let output = repository
                .run(
                    &["merge-base", "HEAD", &base_commit],
                    cmux_git::MAX_SMALL_OUTPUT_BYTES,
                )
                .map_err(|failure| failure.reason())?;
            let base = String::from_utf8_lossy(&output.stdout).trim().to_owned();
            let compare = comparison(base.clone());
            let output = repository
                .run(
                    &diff_args(&compare, &["--name-status", "-z"], &[]),
                    MAX_LISTING_BYTES,
                )
                .map_err(|failure| failure.reason())?;
            let files: Vec<Value> = parse::name_status(&output.stdout)
                .into_iter()
                .map(|file| json!({"path": file.path, "prevPath": file.previous_path, "status": file.status}))
                .collect();
            Ok(json!({"type": "lazySummary", "base": base, "files": files}))
        }
        "lazyStats" => {
            let compare = comparison(params.base.ok_or("base is required")?);
            let output = repository
                .run(
                    &diff_args(&compare, &["--numstat", "-z"], &[]),
                    MAX_LISTING_BYTES,
                )
                .map_err(|failure| failure.reason())?;
            let stats: serde_json::Map<String, Value> = parse::numstat(&output.stdout)
                .into_iter()
                .map(|(path, counts)| {
                    let value = counts.map_or(Value::Null, |counts| {
                        json!([counts.additions, counts.deletions])
                    });
                    (path, value)
                })
                .collect();
            Ok(json!({"type": "lazyStats", "stats": stats}))
        }
        "lazyPatches" => {
            if params.paths.is_empty() || params.paths.len() > MAX_PATHS_PER_CALL {
                return Err("paths must name 1 to 512 files".to_owned());
            }
            let compare = comparison(params.base.ok_or("base is required")?);
            // Large files (the viewer's LARGE_DIFF_CHANGED_LINES) stay deferred: their
            // counts come back instead of their hunks, so one generated file never delays
            // the viewport.
            let counts = repository
                .run(
                    &diff_args(&compare, &["--numstat", "-z"], &params.paths),
                    MAX_LISTING_BYTES,
                )
                .map_err(|failure| failure.reason())?;
            let (deferred, small): (Vec<String>, Vec<String>) = {
                let counts = parse::numstat(&counts.stdout);
                params.paths.iter().cloned().partition(|path| {
                    counts.get(path).copied().flatten().is_some_and(|lines| {
                        lines.additions + lines.deletions >= LARGE_DIFF_CHANGED_LINES
                    })
                })
            };
            if small.is_empty() {
                return Ok(
                    json!({"type": "lazyPatches", "truncated": false, "patches": [], "deferred": deferred}),
                );
            }
            let output = repository
                .run(
                    &diff_args(&compare, &["--patch"], &small),
                    MAX_PATCHES_BYTES,
                )
                .map_err(|failure| failure.reason())?;
            let patches: Vec<Value> = parse::patches(&output.stdout)
                .into_iter()
                .map(|(path, hunks)| json!({"path": path, "hunks": hunks}))
                .collect();
            Ok(
                json!({"type": "lazyPatches", "truncated": output.truncated, "patches": patches, "deferred": deferred}),
            )
        }
        _ => Err("unknown lazy method".to_owned()),
    }
}
