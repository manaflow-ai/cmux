use anyhow::{anyhow, Result};
use fuzzy_matcher::skim::SkimMatcherV2;
use fuzzy_matcher::FuzzyMatcher;
use globset::{Glob, GlobSet, GlobSetBuilder};
use gix::bstr::ByteSlice;
use gix::{hash::ObjectId, Repository};
use std::path::{Path, PathBuf};

use crate::repo::cache::{
  ensure_repo,
  resolve_repo_url,
  swr_fetch_origin_all_path,
};
use crate::types::{ListRepoFilesOptions, RepoFileInfo};

const IGNORE_PATTERNS: &[&str] = &[
  "**/node_modules/**",
  "**/.git/**",
  "**/dist/**",
  "**/build/**",
  "**/.next/**",
  "**/coverage/**",
  "**/.turbo/**",
  "**/.vscode/**",
  "**/.idea/**",
  "**/tmp/**",
  "**/.DS_Store",
  "**/npm-debug.log*",
  "**/yarn-debug.log*",
  "**/yarn-error.log*",
];

fn build_ignore_set() -> Result<GlobSet> {
  let mut builder = GlobSetBuilder::new();
  for pattern in IGNORE_PATTERNS {
    builder.add(Glob::new(pattern)?);
  }
  Ok(builder.build()?)
}

fn resolve_branch_oid(repo: &Repository, branch: Option<&str>) -> Result<ObjectId> {
  if let Some(raw) = branch {
    let trimmed = raw.trim();
    if !trimmed.is_empty() {
      let direct = [
        trimmed.to_string(),
        format!("refs/remotes/origin/{}", trimmed),
        format!("refs/heads/{}", trimmed),
      ];
      for candidate in &direct {
        if let Ok(reference) = repo.find_reference(candidate) {
          if let Some(id) = reference.target().try_id() {
            return Ok(id.to_owned());
          }
          if let Some(name) = reference.target().try_name() {
            let s = name.as_bstr().to_str_lossy().into_owned();
            if let Ok(inner) = repo.find_reference(&s) {
              if let Some(id) = inner.target().try_id() {
                return Ok(id.to_owned());
              }
            }
          }
        }
        if let Ok(spec) = repo.rev_parse_single(candidate) {
          if let Ok(obj) = spec.object() {
            return Ok(obj.id);
          }
        }
      }
    }
  }

  let fallbacks = [
    "HEAD",
    "refs/remotes/origin/HEAD",
    "refs/remotes/origin/main",
    "refs/remotes/origin/master",
    "refs/heads/main",
    "refs/heads/master",
  ];

  for candidate in &fallbacks {
    if let Ok(reference) = repo.find_reference(candidate) {
      if let Some(id) = reference.target().try_id() {
        return Ok(id.to_owned());
      }
      if let Some(name) = reference.target().try_name() {
        let s = name.as_bstr().to_str_lossy().into_owned();
        if let Ok(inner) = repo.find_reference(&s) {
          if let Some(id) = inner.target().try_id() {
            return Ok(id.to_owned());
          }
        }
      }
    }
    if let Ok(spec) = repo.rev_parse_single(candidate) {
      if let Ok(obj) = spec.object() {
        return Ok(obj.id);
      }
    }
  }

  Err(anyhow!("unable to resolve branch or HEAD for repository"))
}

fn collect_tree(
  repo: &Repository,
  tree: gix::objs::Tree,
  ignore: &GlobSet,
  include_directories: bool,
  prefix: &str,
  repo_root: &Path,
  out: &mut Vec<RepoFileInfo>,
) -> Result<()> {
  for entry_res in tree.iter() {
    let entry = entry_res?;
    let name = entry.filename().to_str_lossy().into_owned();
    let rel = if prefix.is_empty() {
      name.clone()
    } else {
      format!("{}/{}", prefix, name)
    };
    let rel_norm = rel.replace('\\', "/");

    if ignore.is_match(&rel_norm) {
      continue;
    }

    let mode = entry.mode();
    let abs_path = repo_root.join(rel_norm.as_str());

    if mode.is_tree() {
      if include_directories {
        out.push(RepoFileInfo {
          path: abs_path.to_string_lossy().into_owned(),
          name: name.clone(),
          isDirectory: true,
          relativePath: rel_norm.clone(),
        });
      }

      let id = entry.oid().to_owned();
      let obj = repo.find_object(id)?;
      let subtree = obj.try_into_tree()?;
      collect_tree(
        repo,
        subtree,
        ignore,
        include_directories,
        &rel_norm,
        repo_root,
        out,
      )?;
    } else {
      out.push(RepoFileInfo {
        path: abs_path.to_string_lossy().into_owned(),
        name: name.clone(),
        isDirectory: false,
        relativePath: rel_norm.clone(),
      });
    }
  }

  Ok(())
}

pub fn list_repository_files(opts: ListRepoFilesOptions) -> Result<Vec<RepoFileInfo>> {
  let ignore = build_ignore_set()?;

  let origin_override = opts.originPath.clone();
  let repo_path = if let Some(ref origin) = origin_override {
    PathBuf::from(origin)
  } else {
    let url = resolve_repo_url(opts.repoFullName.as_deref(), opts.repoUrl.as_deref())?;
    ensure_repo(&url)?
  };

  let should_fetch = opts.originPath.is_none();
  if should_fetch {
    let _ = swr_fetch_origin_all_path(&repo_path, crate::repo::cache::fetch_window_ms());
  }

  let repo_root_for_paths = origin_override
    .unwrap_or_else(|| repo_path.to_string_lossy().into_owned());
  let repo = gix::open(&repo_path)?;

  let branch_oid = resolve_branch_oid(&repo, opts.branch.as_deref())?;
  let commit = repo.find_object(branch_oid)?.try_into_commit()?;
  let tree_id = commit.tree_id()?.detach();
  let tree = repo.find_object(tree_id)?.try_into_tree()?;

  let include_directories = opts
    .pattern
    .as_ref()
    .map(|s| s.trim().is_empty())
    .unwrap_or(true);

  let mut entries: Vec<RepoFileInfo> = Vec::new();
  collect_tree(
    &repo,
    tree,
    &ignore,
    include_directories,
    "",
    Path::new(&repo_root_for_paths),
    &mut entries,
  )?;

  let pattern = opts
    .pattern
    .as_deref()
    .map(|s| s.trim())
    .filter(|s| !s.is_empty())
    .map(|s| s.to_string());

  if let Some(pat) = pattern {
    let matcher = SkimMatcherV2::default();
    let limit = opts.limit.unwrap_or(1000).max(1) as usize;
    let mut matched: Vec<(i64, RepoFileInfo)> = entries
      .into_iter()
      .filter(|entry| !entry.isDirectory)
      .filter_map(|entry| {
        matcher
          .fuzzy_match(&entry.relativePath, &pat)
          .map(|score| (score, entry))
      })
      .collect();

    matched.sort_by(|a, b| {
      b.0.cmp(&a.0)
        .then_with(|| a.1.relativePath.cmp(&b.1.relativePath))
    });

    let mut out: Vec<RepoFileInfo> = Vec::new();
    for (_, entry) in matched.into_iter().take(limit) {
      out.push(entry);
    }
    return Ok(out);
  }

  entries.sort_by(|a, b| {
    if a.isDirectory != b.isDirectory {
      return if a.isDirectory {
        std::cmp::Ordering::Less
      } else {
        std::cmp::Ordering::Greater
      };
    }
    a.relativePath.cmp(&b.relativePath)
  });

  Ok(entries)
}
