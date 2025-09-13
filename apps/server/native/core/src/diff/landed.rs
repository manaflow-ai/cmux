use anyhow::Result;
use gix::{bstr::ByteSlice, hash::ObjectId, Repository};
use std::time::{Instant};

use crate::types::{DiffEntry, GitDiffLandedOptions, GitDiffRefsOptions};

fn oid_from_rev_parse(repo: &Repository, rev: &str) -> anyhow::Result<ObjectId> {
  if let Ok(oid) = ObjectId::from_hex(rev.as_bytes()) { return Ok(oid); }
  let candidates = [
    rev.to_string(),
    format!("refs/remotes/origin/{}", rev),
    format!("refs/heads/{}", rev),
    format!("refs/tags/{}", rev),
  ];
  for cand in candidates {
    if let Ok(r) = repo.find_reference(&cand) {
      if let Some(id) = r.target().try_id() { return Ok(id.to_owned()); }
    }
  }
  if let Ok(spec) = repo.rev_parse_single(rev) {
    if let Ok(obj) = spec.object() { return Ok(obj.id); }
  }
  Err(anyhow::anyhow!("could not resolve rev '{}'", rev))
}

fn is_ancestor(cwd: &str, repo: &Repository, anc: ObjectId, desc: ObjectId) -> bool {
  // ancestor if merge-base(desc, anc) == anc
  match crate::merge_base::merge_base(cwd, repo, desc, anc, crate::merge_base::MergeBaseStrategy::Git) {
    Some(x) if x == anc => true,
    _ => false,
  }
}

fn first_commit_after_b0_on_first_parent(repo: &Repository, b_tip: ObjectId, b0: ObjectId) -> Option<ObjectId> {
  let mut cur = b_tip;
  let mut guard = 0usize;
  while guard < 200_000 {
    guard += 1;
    if cur == b0 { return None; }
    let obj = repo.find_object(cur).ok()?;
    let commit = obj.try_into_commit().ok()?;
    let mut parents = commit.parent_ids();
    let p1 = parents.next()?.detach();
    if p1 == b0 { return Some(cur); }
    cur = p1;
  }
  None
}

fn find_merge_integrating_head(cwd: &str, repo: &Repository, base_tip: ObjectId, head_tip: ObjectId, limit: usize) -> Option<(ObjectId, ObjectId)> {
  let mut cur = base_tip;
  let mut seen = 0usize;
  while seen < limit {
    seen += 1;
    let obj = repo.find_object(cur).ok()?;
    let commit = obj.try_into_commit().ok()?;
    let (p1, p2) = {
      let mut it = commit.parent_ids();
      (it.next().map(|x| x.detach()), it.next().map(|x| x.detach()))
    };
    if let (Some(p1), Some(p2)) = (p1, p2) {
      // We want merges where the second parent (integration branch) contains the head tip.
      // That is, `head_tip` must be an ancestor of `p2`.
      if is_ancestor(cwd, repo, head_tip, p2) {
        return Some((p1, cur));
      }
    }
    let pnext = {
      let mut it = commit.parent_ids();
      it.next().map(|x| x.detach())
    };
    if let Some(p1) = pnext { cur = p1; } else { break; }
  }
  None
}

fn find_merge_by_message(
  repo: &Repository,
  base_tip: ObjectId,
  head_ref: &str,
  limit: usize,
) -> Option<(ObjectId, ObjectId)> {
  let mut cur = base_tip;
  let mut seen = 0usize;
  let needle = head_ref.trim_start_matches("origin/");
  while seen < limit {
    seen += 1;
    let obj = repo.find_object(cur).ok()?;
    let commit = obj.try_into_commit().ok()?;
    // Only consider merge commits (>=2 parents)
    let (p1, p2) = {
      let mut it = commit.parent_ids();
      (it.next().map(|x| x.detach()), it.next().map(|x| x.detach()))
    };
    if let (Some(p1), Some(_p2)) = (p1, p2) {
      // Match commit message against head branch name
      let msg = commit.message_raw().ok()?;
      let text = msg.to_str_lossy();
      if text.contains(needle) {
        #[cfg(debug_assertions)]
        println!(
          "[native.landed] merge-by-message matched branch '{}' at {}",
          needle, cur
        );
        return Some((p1, cur));
      }
    }
    // Walk first-parent chain
    let next = {
      let mut it = commit.parent_ids();
      it.next().map(|x| x.detach())
    };
    if let Some(n) = next { cur = n; } else { break; }
  }
  None
}

fn last_fp_block_ancestor_of_head(cwd: &str, repo: &Repository, b_tip: ObjectId, b0: ObjectId, head_tip: ObjectId) -> Option<ObjectId> {
  let mut cur = b_tip;
  let mut last = None;
  let mut guard = 0usize;
  while guard < 200_000 {
    guard += 1;
    if is_ancestor(cwd, repo, cur, head_tip) { last = Some(cur); }
    if cur == b0 { break; }
    let obj = repo.find_object(cur).ok()?;
    let commit = obj.try_into_commit().ok()?;
    let pnext = {
      let mut it = commit.parent_ids();
      it.next().map(|x| x.detach())
    };
    if let Some(p1) = pnext { cur = p1; } else { break; }
  }
  last
}

pub fn landed_diff(opts: GitDiffLandedOptions) -> Result<Vec<DiffEntry>> {
  let t_total = Instant::now();
  #[cfg(debug_assertions)]
  println!(
    "[native.landed] start baseRef={} headRef={} b0Ref={:?} originPathOverride={:?}",
    opts.baseRef, opts.headRef, opts.b0Ref, opts.originPathOverride
  );
  let include = opts.includeContents.unwrap_or(true);
  let max_bytes = opts.maxBytes.unwrap_or(950*1024);

  // Reuse ensure_repo & path resolution
  let t_repo_path = Instant::now();
  let repo_path = if let Some(p) = &opts.originPathOverride { std::path::PathBuf::from(p) } else {
    let url = crate::repo::cache::resolve_repo_url(opts.repoFullName.as_deref(), opts.repoUrl.as_deref())?;
    crate::repo::cache::ensure_repo(&url)?
  };
  let _d_repo_path = t_repo_path.elapsed();
  let cwd = repo_path.to_string_lossy().to_string();
  let t_open = Instant::now();
  let repo = gix::open(&cwd)?;
  let _d_open = t_open.elapsed();

  // Prefer origin/<ref> if plain ref fails
  let t_resolve = Instant::now();
  let b_tip = oid_from_rev_parse(&repo, &opts.baseRef)
    .or_else(|_| oid_from_rev_parse(&repo, &format!("origin/{}", opts.baseRef)))?;
  let h_tip = oid_from_rev_parse(&repo, &opts.headRef)
    .or_else(|_| oid_from_rev_parse(&repo, &format!("origin/{}", opts.headRef)))?;
  let _d_resolve = t_resolve.elapsed();
  #[cfg(debug_assertions)]
  println!("[native.landed] resolved base_tip={} head_tip={}", b_tip, h_tip);

  // Early-out: if refs point to the same commit, nothing landed
  if b_tip == h_tip {
    let _d_total = t_total.elapsed();
    #[cfg(debug_assertions)]
    println!(
      "[cmux_native_git] git_diff_landed timings: total={}ms repo_path={}ms open_repo={}ms resolve={}ms detect={}ms refs_diff={}ms out_len=0 (equal tips)",
      _d_total.as_millis(),
      _d_repo_path.as_millis(),
      _d_open.as_millis(),
      _d_resolve.as_millis(),
      0,
      0,
    );
    #[cfg(debug_assertions)]
    println!("[native.landed] tips equal; returning empty");
    return Ok(Vec::new());
  }

  // Determine ref pair to diff via refs-diff
  let t_detect = Instant::now();
  // Precompute if head is already ancestor of base (i.e., HEAD tip is contained in base).
  // This is true for: (a) merged via merge-commit; (b) merged via fast-forward; (c) no commits on head yet.
  // We'll use this only as a guard to avoid expensive and error-prone heuristics when there's no merge-by-message.
  let head_is_ancestor_of_base = is_ancestor(&cwd, &repo, h_tip, b_tip);

  let pair: Option<(String, String)> = if let Some(b0s) = &opts.b0Ref {
    let b0 = oid_from_rev_parse(&repo, b0s)?;
    if let Some(c1) = first_commit_after_b0_on_first_parent(&repo, b_tip, b0) {
      let c1_commit = repo.find_object(c1)?.try_into_commit()?;
      let mut parents = c1_commit.parent_ids();
      let p1_opt = parents.next().map(|x| x.detach());
      let p2_opt = parents.next().map(|x| x.detach());
      if let (Some(p1), Some(_p2)) = (p1_opt, p2_opt) {
        // Merge-commit: landed is P1 -> C1
        Some((p1.to_string(), c1.to_string()))
      } else if is_ancestor(&cwd, &repo, c1, h_tip) {
        // Fast-forward: extend block to last ancestor of head
        let h0 = last_fp_block_ancestor_of_head(&cwd, &repo, b_tip, b0, h_tip).unwrap_or(c1);
        Some((b0.to_string(), h0.to_string()))
      } else {
        // Squash or rebase-merge: minimal landed slice B0 -> C1
        Some((b0.to_string(), c1.to_string()))
      }
    } else {
      None
    }
  } else {
    // No B0: prefer message-based detection (GitHub-style merge commits)
    #[cfg(debug_assertions)]
    println!("[native.landed] scanning merges on base first-parent (by message, then heuristic)");
    if let Some((p1, m)) = find_merge_by_message(&repo, b_tip, &opts.headRef, 10_000) {
      #[cfg(debug_assertions)]
      println!("[native.landed] strategy=merge-by-message P1={} MERGE={}", p1, m);
      Some((p1.to_string(), m.to_string()))
    } else if let Some((p1, m)) = find_merge_integrating_head(&cwd, &repo, b_tip, h_tip, 10_000) {
      #[cfg(debug_assertions)]
      println!("[native.landed] strategy=heuristic-merge P1={} MERGE={}", p1, m);
      Some((p1.to_string(), m.to_string()))
    } else {
      if head_is_ancestor_of_base {
        #[cfg(debug_assertions)]
        println!("[native.landed] head is ancestor of base but no merge found; returning empty");
      }
      #[cfg(debug_assertions)]
      println!("[native.landed] no merging commit found on base first-parent");
      None
    }
  };

  let _d_detect = t_detect.elapsed();
  if let Some((r1, r2)) = pair {
    #[cfg(debug_assertions)]
    println!("[native.landed] diff pair: {} -> {} (cwd={})", r1, r2, cwd);
    // Delegate to refs diff with chosen commit IDs
    let t_refs = Instant::now();
    let d = crate::diff::refs::diff_refs(GitDiffRefsOptions{
      ref1: r1,
      ref2: r2,
      repoFullName: opts.repoFullName.clone(),
      repoUrl: opts.repoUrl.clone(),
      teamSlugOrId: opts.teamSlugOrId.clone(),
      originPathOverride: Some(cwd.clone()),
      includeContents: Some(include),
      maxBytes: Some(max_bytes),
    })?;
    let _d_refs = t_refs.elapsed();
    let _d_total = t_total.elapsed();
    #[cfg(debug_assertions)]
    println!(
      "[cmux_native_git] git_diff_landed timings: total={}ms repo_path={}ms open_repo={}ms resolve={}ms detect={}ms refs_diff={}ms out_len={}",
      _d_total.as_millis(),
      _d_repo_path.as_millis(),
      _d_open.as_millis(),
      _d_resolve.as_millis(),
      _d_detect.as_millis(),
      _d_refs.as_millis(),
      d.len()
    );
    #[cfg(debug_assertions)]
    println!("[native.landed] result entries={}", d.len());
    Ok(d)
  } else {
    let _d_total = t_total.elapsed();
    #[cfg(debug_assertions)]
    println!(
      "[cmux_native_git] git_diff_landed timings: total={}ms repo_path={}ms open_repo={}ms resolve={}ms detect={}ms refs_diff={}ms out_len=0",
      _d_total.as_millis(),
      _d_repo_path.as_millis(),
      _d_open.as_millis(),
      _d_resolve.as_millis(),
      _d_detect.as_millis(),
      0,
    );
    #[cfg(debug_assertions)]
    println!("[native.landed] no pair determined; returning empty");
    Ok(Vec::new())
  }
}
