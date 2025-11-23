use anyhow::Result;
use gix::bstr::ByteSlice;
use std::{collections::{HashMap, HashSet}, fs, path::{Path, PathBuf}};
use gix::{hash::ObjectId, Repository};
use similar::TextDiff;
use crate::types::{DiffEntry, GitDiffWorkspaceOptions};

fn is_binary(data: &[u8]) -> bool { data.iter().any(|&b| b == 0) || std::str::from_utf8(data).is_err() }

fn default_remote_head(repo: &Repository) -> Option<ObjectId> {
  if let Ok(r) = repo.find_reference("refs/remotes/origin/HEAD") {
    if let Some(name) = r.target().try_name() {
      let s = name.as_bstr().to_str_lossy().into_owned();
      if let Ok(rr) = repo.find_reference(&s) { if let Some(id) = rr.target().try_id() { return Some(id.to_owned()); } }
    }
  }
  if let Ok(r) = repo.find_reference("refs/remotes/origin/main") { if let Some(id) = r.target().try_id() { return Some(id.to_owned()); } }
  None
}

fn merge_base_oid(repo: &Repository, a: ObjectId, b: ObjectId) -> ObjectId {
  use std::collections::{HashMap, VecDeque};
  let mut dist_a: HashMap<ObjectId, usize> = HashMap::new();
  let mut qa: VecDeque<(ObjectId, usize)> = VecDeque::new();
  qa.push_back((a, 0));
  while let Some((id, d)) = qa.pop_front() {
    if dist_a.contains_key(&id) { continue; }
    dist_a.insert(id, d);
    if let Ok(obj) = repo.find_object(id) {
      if let Ok(commit) = obj.try_into_commit() {
        for p in commit.parent_ids() { qa.push_back((p.detach(), d + 1)); }
      }
    }
  }
  let mut best: Option<(ObjectId, usize)> = None;
  let mut qb: VecDeque<(ObjectId, usize)> = VecDeque::new();
  let mut seen_b: HashMap<ObjectId, usize> = HashMap::new();
  qb.push_back((b, 0));
  while let Some((id, d)) = qb.pop_front() {
    if seen_b.contains_key(&id) { continue; }
    seen_b.insert(id, d);
    if let Some(da) = dist_a.get(&id) {
      let cost = *da + d;
      match best {
        None => best = Some((id, cost)),
        Some((_, c)) if cost < c => best = Some((id, cost)),
        _ => {}
      }
    }
    if let Ok(obj) = repo.find_object(id) {
      if let Ok(commit) = obj.try_into_commit() {
        for p in commit.parent_ids() { qb.push_back((p.detach(), d + 1)); }
      }
    }
  }
  best.map(|(id, _)| id).unwrap_or(a)
}

fn collect_tree_blobs(repo: &Repository, tree_id: ObjectId, prefix: &str, out: &mut HashMap<String, ObjectId>) -> anyhow::Result<()> {
  let obj = repo.find_object(tree_id)?;
  let tree = obj.try_into_tree()?;
  for entry_res in tree.iter() {
    let entry = entry_res?;
    let name = entry.filename().to_str_lossy().into_owned();
    let full = if prefix.is_empty() { name.clone() } else { format!("{}/{}", prefix, name) };
    let mode = entry.mode();
    if mode.is_tree() {
      let id = entry.oid().to_owned();
      collect_tree_blobs(repo, id, &full, out)?;
    } else {
      let id = entry.oid().to_owned();
      out.insert(full, id);
    }
  }
  Ok(())
}

fn should_ignore(root: &Path, rel: &str) -> bool {
  let gi = root.join(".gitignore");
  if let Ok(s) = fs::read_to_string(&gi) {
    for line in s.lines() {
      let rule = line.trim();
      if rule.is_empty() || rule.starts_with('#') { continue; }
      if rule.ends_with('/') {
        let d = &rule[..rule.len()-1];
        if rel == d || rel.starts_with(&format!("{}/", d)) { return true; }
      } else {
        if rel == rule || rel.starts_with(&format!("{}/", rule)) { return true; }
      }
    }
  }
  false
}

fn scan_workdir(root: &Path) -> Vec<String> {
  let mut out = Vec::new();
  fn rec(cur: &Path, base: &Path, out: &mut Vec<String>) {
    if let Ok(entries) = fs::read_dir(cur) {
      for ent in entries.flatten() {
        let p = ent.path();
        if p.file_name().map(|s| s == ".git").unwrap_or(false) { continue; }
        let rel = match p.strip_prefix(base) {
          Ok(r) => r.to_string_lossy().replace('\\', "/"),
          Err(_) => continue,
        };
        if should_ignore(base, &rel) { continue; }
        if p.is_dir() { rec(&p, base, out); } else if p.is_file() { out.push(rel); }
      }
    }
  }
  rec(root, root, &mut out);
  out
}

pub fn diff_workspace(opts: GitDiffWorkspaceOptions) -> Result<Vec<DiffEntry>> {
  let cwd = PathBuf::from(&opts.worktreePath);
  let include = opts.includeContents.unwrap_or(true);
  let max_bytes = opts.maxBytes.unwrap_or(950*1024) as usize;
  let _ = crate::repo::cache::swr_fetch_origin_all_path(&cwd, crate::repo::cache::fetch_window_ms());
  let repo = gix::open(&cwd)?;

  // Determine base tree for diff. If HEAD is unborn (no commits), fall back to remote default.
  let mut base_map: HashMap<String, ObjectId> = HashMap::new();
  match repo.head_commit() {
    Ok(commit) => {
      let head_oid = commit.id;
      let base_candidate = default_remote_head(&repo).unwrap_or(head_oid);
      let merge_base = merge_base_oid(&repo, base_candidate, head_oid);
      let base_commit = repo.find_object(merge_base)?.try_into_commit()?;
      let base_tree_id = base_commit.tree_id()?.detach();
      collect_tree_blobs(&repo, base_tree_id, "", &mut base_map)?;
    }
    Err(_) => {
      // Unborn HEAD: try remote default HEAD tree; otherwise empty base
      if let Some(remote_head) = default_remote_head(&repo) {
        if let Ok(obj) = repo.find_object(remote_head) {
          if let Ok(base_commit) = obj.try_into_commit() {
            if let Ok(tree_id) = base_commit.tree_id() {
              collect_tree_blobs(&repo, tree_id.detach(), "", &mut base_map)?;
            }
          }
        }
      }
    }
  }

  let workdir = repo.work_dir().unwrap_or_else(|| cwd.as_path());
  let files = scan_workdir(workdir);

  let mut out: Vec<DiffEntry> = Vec::new();

  for rel in &files {
    let abs = workdir.join(rel);
    let new_data = fs::read(&abs).unwrap_or_default();
    match base_map.get(rel) {
      None => {
        let bin = is_binary(&new_data);
        let mut e = DiffEntry{ filePath: rel.clone(), status: "added".into(), additions: 0, deletions: 0, isBinary: bin, ..Default::default() };
        if include && !bin {
          let new_str = String::from_utf8_lossy(&new_data).into_owned();
          let new_sz = new_str.as_bytes().len();
          e.newSize = Some(new_sz as i32);
          e.oldSize = Some(0);
          if new_sz <= max_bytes { e.newContent = Some(new_str.clone()); e.oldContent = Some(String::new()); e.contentOmitted = Some(false); e.additions = new_str.lines().count() as i32; } else { e.contentOmitted = Some(true) }
        } else { e.contentOmitted = Some(false) }
        out.push(e);
      }
      Some(old_id) => {
        let old_blob = repo.find_object(*old_id)?.try_into_blob()?;
        let old_data = &old_blob.data;
        if new_data == *old_data { continue; }
        let bin = is_binary(&old_data) || is_binary(&new_data);
        let mut e = DiffEntry{ filePath: rel.clone(), status: "modified".into(), additions: 0, deletions: 0, isBinary: bin, ..Default::default() };
        if include && !bin {
          let old_str = String::from_utf8_lossy(&old_data).into_owned();
          let new_str = String::from_utf8_lossy(&new_data).into_owned();
          let old_sz = old_str.as_bytes().len(); let new_sz = new_str.as_bytes().len();
          if old_sz + new_sz <= max_bytes { let diff = TextDiff::from_lines(&old_str, &new_str); let mut adds=0i32; let mut dels=0i32; for op in diff.ops(){ let tag=op.tag(); for ch in diff.iter_changes(op){ match (tag, ch.tag()) { (similar::DiffTag::Insert, _) => adds+=1, (similar::DiffTag::Delete, _) => dels+=1, _=>{} } } } e.additions=adds; e.deletions=dels; e.oldContent=Some(old_str); e.newContent=Some(new_str); e.contentOmitted=Some(false);} else { e.contentOmitted=Some(true) }
          e.oldSize = Some(old_sz as i32); e.newSize = Some(new_sz as i32);
        } else { e.contentOmitted = Some(false) }
        if include && !e.isBinary && e.additions==0 && e.deletions==0 { continue; }
        out.push(e);
      }
    }
  }

  let file_set: HashSet<&str> = files.iter().map(|s| s.as_str()).collect();
  for (rel, old_id) in &base_map {
    if file_set.contains(rel.as_str()) { continue; }
    let old_blob = repo.find_object(*old_id)?.try_into_blob()?;
    let old_data = &old_blob.data;
    let bin = is_binary(&old_data);
    let mut e = DiffEntry{ filePath: rel.clone(), status: "deleted".into(), additions: 0, deletions: 0, isBinary: bin, ..Default::default() };
    if include && !bin {
      let old_str = String::from_utf8_lossy(&old_data).into_owned();
      let old_sz = old_str.as_bytes().len();
      e.oldSize = Some(old_sz as i32);
      if old_sz <= max_bytes {
        let deletions = old_str.lines().count() as i32;
        e.oldContent = Some(old_str);
        e.newContent = Some(String::new());
        e.contentOmitted = Some(false);
        e.deletions = deletions;
      } else { e.contentOmitted = Some(true) }
    } else { e.contentOmitted = Some(false) }
    out.push(e);
  }

  // Stable sort by filePath (case-insensitive)
  out.sort_by(|a, b| {
    a.filePath.to_lowercase().cmp(&b.filePath.to_lowercase())
      .then_with(|| a.filePath.cmp(&b.filePath))
  });

  Ok(out)
}
