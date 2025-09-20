use anyhow::Result;
use gix::bstr::ByteSlice;
use std::collections::HashMap;
use std::time::{Duration, Instant};

use crate::{
  repo::cache::{ensure_repo, resolve_repo_url},
  types::{DiffEntry, GitDiffRefsOptions},
};
use gix::{Repository, hash::ObjectId};
use similar::TextDiff;

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

fn is_binary(data: &[u8]) -> bool {
  data.iter().any(|&b| b == 0) || std::str::from_utf8(data).is_err()
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

pub fn diff_refs(opts: GitDiffRefsOptions) -> Result<Vec<DiffEntry>> {
  let include = opts.includeContents.unwrap_or(true);
  let max_bytes = opts.maxBytes.unwrap_or(950*1024) as usize;
  let t_total = Instant::now();

  #[cfg(debug_assertions)]
  println!(
    "[native.refs] start ref1={} ref2={} originPathOverride={:?} repoFullName={:?}",
    opts.ref1, opts.ref2, opts.originPathOverride, opts.repoFullName
  );

  let t_repo_path = Instant::now();
  let repo_path = if let Some(p) = &opts.originPathOverride { std::path::PathBuf::from(p) } else {
    let url = resolve_repo_url(opts.repoFullName.as_deref(), opts.repoUrl.as_deref())?;
    ensure_repo(&url)?
  };
  let _d_repo_path = t_repo_path.elapsed();
  let cwd = repo_path.to_string_lossy().to_string();

  // If a specific repo path is provided, assume the caller ensures freshness.
  // Avoid synchronous fetch here to reduce latency.
  let _d_fetch = if opts.originPathOverride.is_some() {
    Duration::from_millis(0)
  } else {
    let t_fetch = Instant::now();
    let _ = crate::repo::cache::swr_fetch_origin_all_path(
      std::path::Path::new(&cwd),
      crate::repo::cache::fetch_window_ms(),
    );
    t_fetch.elapsed()
  };

  let t_open = Instant::now();
  let repo = gix::open(&cwd)?;
  let _d_open = t_open.elapsed();
  let t_r1 = Instant::now();
  let r1_oid = match oid_from_rev_parse(&repo, &opts.ref1) {
    Ok(oid) => oid,
    Err(_) => {
      let _d_r1 = t_r1.elapsed();
      #[cfg(debug_assertions)]
      println!(
        "[cmux_native_git] git_diff_refs timings: total={}ms resolve_r1={}ms (failed to resolve); cwd={}",
        t_total.elapsed().as_millis(),
        _d_r1.as_millis(),
        cwd,
      );
      return Ok(Vec::new());
    },
  };
  let _d_r1 = t_r1.elapsed();
  let t_r2 = Instant::now();
  let r2_oid = match oid_from_rev_parse(&repo, &opts.ref2) {
    Ok(oid) => oid,
    Err(_) => {
      let _d_r2 = t_r2.elapsed();
      #[cfg(debug_assertions)]
      println!(
        "[cmux_native_git] git_diff_refs timings: total={}ms resolve_r1={}ms resolve_r2={}ms (failed to resolve); cwd={}",
        t_total.elapsed().as_millis(),
        _d_r1.as_millis(),
        _d_r2.as_millis(),
        cwd,
      );
      return Ok(Vec::new());
    }
  };
  let _d_r2 = t_r2.elapsed();
  let t_merge_base = Instant::now();
  // Compute merge-base; prefer BFS (pure gix) to avoid shelling out
  let base_oid = crate::merge_base::merge_base(&cwd, &repo, r1_oid, r2_oid, crate::merge_base::MergeBaseStrategy::Bfs)
    .unwrap_or(r1_oid);
  let _d_merge_base = t_merge_base.elapsed();
  #[cfg(debug_assertions)]
  println!("[native.refs] MB({}, {})={}", r1_oid, r2_oid, base_oid);

  let t_tree_ids = Instant::now();
  let base_commit = repo.find_object(base_oid)?.try_into_commit()?;
  let base_tree_id = base_commit.tree_id()?.detach();
  let head_commit = repo.find_object(r2_oid)?.try_into_commit()?;
  let head_tree_id = head_commit.tree_id()?.detach();
  let _d_tree_ids = t_tree_ids.elapsed();

  let mut base_map: HashMap<String, ObjectId> = HashMap::new();
  let mut head_map: HashMap<String, ObjectId> = HashMap::new();
  let t_collect_base = Instant::now();
  collect_tree_blobs(&repo, base_tree_id, "", &mut base_map)?;
  let _d_collect_base = t_collect_base.elapsed();
  let t_collect_head = Instant::now();
  collect_tree_blobs(&repo, head_tree_id, "", &mut head_map)?;
  let _d_collect_head = t_collect_head.elapsed();

  // Utility closures to obtain blob data safely; handle submodules and non-blobs gracefully
  let mut out: Vec<DiffEntry> = Vec::new();
  let mut _num_added: usize = 0;
  let mut _num_modified: usize = 0;
  let mut _num_deleted: usize = 0;
  let mut _num_binary: usize = 0;
  let mut _total_scanned_bytes: usize = 0;
  let mut _blob_read_ns: u128 = 0;
  let mut _textdiff_ns: u128 = 0;
  let mut _textdiff_count: usize = 0;
  let mut _max_diff_ns: u128 = 0;
  let mut _max_diff_path: Option<String> = None;

  let get_blob_bytes = |id: ObjectId| -> Option<Vec<u8>> {
    if let Ok(obj) = repo.find_object(id) {
      if let Ok(blob) = obj.try_into_blob() {
        return Some(blob.data.to_vec());
      }
    }
    None
  };

  // Precompute path partitions
  let mut base_only: HashMap<String, ObjectId> = HashMap::new();
  let mut head_only: HashMap<String, ObjectId> = HashMap::new();
  for (p, oid) in &base_map { if !head_map.contains_key(p) { base_only.insert(p.clone(), *oid); } }
  for (p, oid) in &head_map { if !base_map.contains_key(p) { head_only.insert(p.clone(), *oid); } }

  // Identity-based rename detection: pair deletions and additions with the same blob OID
  let mut id_to_old: HashMap<ObjectId, Vec<String>> = HashMap::new();
  let mut id_to_new: HashMap<ObjectId, Vec<String>> = HashMap::new();
  for (p, oid) in &base_only { id_to_old.entry(*oid).or_default().push(p.clone()); }
  for (p, oid) in &head_only { id_to_new.entry(*oid).or_default().push(p.clone()); }

  let mut renamed_pairs: Vec<(String, String, ObjectId)> = Vec::new();
  for (oid, olds) in id_to_old.iter_mut() {
    if let Some(news) = id_to_new.get_mut(oid) {
      let n = std::cmp::min(olds.len(), news.len());
      for _ in 0..n {
        let old_p = olds.pop().unwrap();
        let new_p = news.pop().unwrap();
        renamed_pairs.push((old_p.clone(), new_p.clone(), *oid));
        // Remove matched from base_only/head_only
        base_only.remove(&old_p);
        head_only.remove(&new_p);
      }
    }
  }

  // Emit renames (content identical by OID)
  for (old_path, new_path, oid) in renamed_pairs {
    let t_bl = Instant::now();
    let new_data = get_blob_bytes(oid);
    _blob_read_ns += t_bl.elapsed().as_nanos();
    // New content may be missing (e.g., submodule) -> treat as binary
    let bin = match &new_data {
      Some(buf) => is_binary(buf),
      None => true,
    };
    let mut e = DiffEntry{ filePath: new_path.clone(), oldPath: Some(old_path.clone()), status: "renamed".into(), additions: 0, deletions: 0, isBinary: bin, ..Default::default() };
    if let Some(buf) = &new_data {
      e.newSize = Some(buf.len() as i32);
      e.oldSize = Some(buf.len() as i32);
    }
    if include && !bin {
      e.contentOmitted = Some(true);
    } else { e.contentOmitted = Some(false); }
    out.push(e);
  }

  // Handle modifications where the path exists in both
  let t_loop_add_mod = Instant::now();
  for (path, new_id) in &head_map {
    if let Some(old_id) = base_map.get(path) {
      if old_id == new_id { continue; }
      let t_bl1 = Instant::now();
      let old_data = get_blob_bytes(*old_id);
      let new_data = get_blob_bytes(*new_id);
      _blob_read_ns += t_bl1.elapsed().as_nanos();
      let bin = match (&old_data, &new_data) {
        (Some(a), Some(b)) => is_binary(a) || is_binary(b),
        _ => true,
      };
      let mut e = DiffEntry{ filePath: path.clone(), status: "modified".into(), additions: 0, deletions: 0, isBinary: bin, ..Default::default() };
      if include && !bin {
        let old_str = String::from_utf8_lossy(old_data.as_ref().unwrap()).into_owned();
        let new_str = String::from_utf8_lossy(new_data.as_ref().unwrap()).into_owned();
        let old_sz = old_str.as_bytes().len();
        let new_sz = new_str.as_bytes().len();
        e.oldSize = Some(old_sz as i32);
        e.newSize = Some(new_sz as i32);
        if old_sz + new_sz <= max_bytes {
          let t_diff = Instant::now();
          // Use changes grouped by operations; count per-line inserts/deletes only.
          let diff = TextDiff::from_lines(&old_str, &new_str);
          let mut adds = 0i32; let mut dels = 0i32;
          for op in diff.ops() {
            for change in diff.iter_changes(op) {
              match change.tag() {
                similar::ChangeTag::Insert => adds += 1,
                similar::ChangeTag::Delete => dels += 1,
                _ => {}
              }
            }
          }
          let d_diff = t_diff.elapsed().as_nanos();
          _textdiff_ns += d_diff; _textdiff_count += 1; _total_scanned_bytes += old_sz + new_sz;
          if d_diff > _max_diff_ns { _max_diff_ns = d_diff; _max_diff_path = Some(path.clone()); }
          e.additions = adds; e.deletions = dels;
          e.oldContent = Some(old_str);
          e.newContent = Some(new_str);
          e.contentOmitted = Some(false);
        } else { e.contentOmitted = Some(true); }
      } else { e.contentOmitted = Some(false); }
      // Do not filter out zero-line modifications: mode changes or metadata changes should still show up.
      out.push(e);
      _num_modified += 1;
      if bin { _num_binary += 1; }
    }
  }
  let _d_loop_add_mod = t_loop_add_mod.elapsed();

  // Additions not matched as renames
  for (path, new_id) in &head_only {
    let t_bl = Instant::now();
    let new_data = get_blob_bytes(*new_id);
    _blob_read_ns += t_bl.elapsed().as_nanos();
    let (bin, new_sz) = match &new_data {
      Some(buf) => (is_binary(buf), buf.len()),
      None => (true, 0),
    };
    let mut e = DiffEntry{ filePath: path.clone(), status: "added".into(), additions: 0, deletions: 0, isBinary: bin, ..Default::default() };
    if include && !bin {
      let new_str = String::from_utf8_lossy(new_data.as_ref().unwrap()).into_owned();
      e.newSize = Some(new_sz as i32);
      e.oldSize = Some(0);
      if new_sz <= max_bytes {
        e.oldContent = Some(String::new());
        e.newContent = Some(new_str.clone());
        e.contentOmitted = Some(false);
        e.additions = new_str.lines().count() as i32;
        _total_scanned_bytes += new_sz;
      } else { e.contentOmitted = Some(true); }
    } else { e.contentOmitted = Some(false); }
    out.push(e);
    _num_added += 1;
    if bin { _num_binary += 1; }
  }

  // Deletions not matched as renames
  let t_loop_del = Instant::now();
  for (path, old_id) in &base_only {
    let t_bl = Instant::now();
    let old_data = get_blob_bytes(*old_id);
    _blob_read_ns += t_bl.elapsed().as_nanos();
    let (bin, old_sz) = match &old_data {
      Some(buf) => (is_binary(buf), buf.len()),
      None => (true, 0),
    };
    let mut e = DiffEntry{ filePath: path.clone(), status: "deleted".into(), additions: 0, deletions: 0, isBinary: bin, ..Default::default() };
    if include && !bin {
      let old_str = String::from_utf8_lossy(old_data.as_ref().unwrap()).into_owned();
      e.oldSize = Some(old_sz as i32);
      if old_sz <= max_bytes {
        e.oldContent = Some(old_str);
        e.newContent = Some(String::new());
        e.contentOmitted = Some(false);
        e.deletions = e.oldContent.as_ref().unwrap().lines().count() as i32;
        _total_scanned_bytes += old_sz;
      } else { e.contentOmitted = Some(true); }
    } else { e.contentOmitted = Some(false); }
    out.push(e);
    _num_deleted += 1;
    if bin { _num_binary += 1; }
  }
  let _d_loop_del = t_loop_del.elapsed();

  let _d_total = t_total.elapsed();
  #[cfg(debug_assertions)]
  println!(
    "[cmux_native_git] git_diff_refs timings: total={}ms repo_path={}ms fetch={}ms open_repo={}ms resolve_r1={}ms resolve_r2={}ms merge_base={}ms tree_ids={}ms collect_base={}ms collect_head={}ms add_mod_loop={}ms del_loop={}ms blob_read={}ms textdiff={}ms textdiff_count={} scanned_bytes={} files: +{} ~{} -{} (binary={}) max_textdiff={{path: {:?}, ms: {}}} cwd={} out_len={}",
    _d_total.as_millis(),
    _d_repo_path.as_millis(),
    _d_fetch.as_millis(),
    _d_open.as_millis(),
    _d_r1.as_millis(),
    _d_r2.as_millis(),
    _d_merge_base.as_millis(),
    _d_tree_ids.as_millis(),
    _d_collect_base.as_millis(),
    _d_collect_head.as_millis(),
    _d_loop_add_mod.as_millis(),
    _d_loop_del.as_millis(),
    (_blob_read_ns as f64 / 1_000_000.0) as i64,
    (_textdiff_ns as f64 / 1_000_000.0) as i64,
    _textdiff_count,
    _total_scanned_bytes,
    _num_added,
    _num_modified,
    _num_deleted,
    _num_binary,
    _max_diff_path,
    (_max_diff_ns as f64 / 1_000_000.0) as i64,
    cwd,
    out.len(),
  );
  if out.is_empty() {
    // Fallback to git CLI diff parsing if our tree comparison produced nothing but there might be changes (e.g., merge edge-cases)
    #[cfg(debug_assertions)]
    println!("[native.refs] tree-diff empty; attempting CLI fallback");
    let r = crate::util::run_git(&cwd, &["diff", "--name-status", &base_oid.to_string(), &r2_oid.to_string()]);
    if let Ok(ns) = r {
      #[cfg(debug_assertions)]
      println!("[native.refs] CLI fallback detected {} lines", ns.lines().count());
      let mut fallback: Vec<DiffEntry> = Vec::new();
      for line in ns.lines() {
        if line.trim().is_empty() { continue; }
        // Format: <status>\t<path> [\t<path2>]
        let parts: Vec<&str> = line.split('\t').collect();
        if parts.is_empty() { continue; }
        let status = parts[0].trim();
        match status {
          "A" => {
            if parts.len() >= 2 {
              let path = parts[1].to_string();
              let mut e = DiffEntry{ filePath: path.clone(), status: "added".into(), additions: 0, deletions: 0, isBinary: false, ..Default::default() };
              if include {
                // new content from r2
                if let Ok(buf) = crate::util::run_git(&cwd, &["show", &format!("{}:{}", r2_oid, path)]) {
                  let new_sz = buf.as_bytes().len();
                  e.newSize = Some(new_sz as i32);
                  e.oldSize = Some(0);
                  if new_sz <= max_bytes { e.newContent = Some(buf.clone()); e.oldContent = Some(String::new()); e.additions = buf.lines().count() as i32; e.contentOmitted = Some(false);} else { e.contentOmitted = Some(true); }
                }
              }
              fallback.push(e);
            }
          }
          "M" => {
            if parts.len() >= 2 {
              let path = parts[1].to_string();
              let mut e = DiffEntry{ filePath: path.clone(), status: "modified".into(), additions: 0, deletions: 0, isBinary: false, ..Default::default() };
              if include {
                let old_s = crate::util::run_git(&cwd, &["show", &format!("{}:{}", base_oid, path)]).unwrap_or_default();
                let new_s = crate::util::run_git(&cwd, &["show", &format!("{}:{}", r2_oid, path)]).unwrap_or_default();
                let old_sz = old_s.as_bytes().len(); let new_sz = new_s.as_bytes().len();
                e.oldSize = Some(old_sz as i32); e.newSize = Some(new_sz as i32);
                if old_sz + new_sz <= max_bytes {
                  let diff = TextDiff::from_lines(&old_s, &new_s);
                  let mut adds=0i32; let mut dels=0i32; for op in diff.ops(){ let tag=op.tag(); for ch in diff.iter_changes(op){ match (tag, ch.tag()) { (similar::DiffTag::Insert, _) => adds+=1, (similar::DiffTag::Delete, _) => dels+=1, _=>{} } } }
                  e.additions = adds; e.deletions = dels; e.oldContent = Some(old_s); e.newContent = Some(new_s); e.contentOmitted = Some(false);
                } else { e.contentOmitted = Some(true); }
              }
              fallback.push(e);
            }
          }
          "D" => {
            if parts.len() >= 2 {
              let path = parts[1].to_string();
              let mut e = DiffEntry{ filePath: path.clone(), status: "deleted".into(), additions: 0, deletions: 0, isBinary: false, ..Default::default() };
              if include {
                if let Ok(buf) = crate::util::run_git(&cwd, &["show", &format!("{}:{}", base_oid, path)]) {
                  let old_sz = buf.as_bytes().len(); e.oldSize = Some(old_sz as i32);
                  if old_sz <= max_bytes { e.oldContent = Some(buf.clone()); e.newContent = Some(String::new()); e.deletions = buf.lines().count() as i32; e.contentOmitted = Some(false);} else { e.contentOmitted = Some(true); }
                }
              }
              fallback.push(e);
            }
          }
          "R" | "R100" | "R099" | "R098" | "R097" | "R096" | "R095" | "R094" | "R093" | "R092" | "R091" | "R090" => {
            if parts.len() >= 3 {
              let oldp = parts[1].to_string();
              let newp = parts[2].to_string();
              let mut e = DiffEntry{ filePath: newp.clone(), oldPath: Some(oldp.clone()), status: "renamed".into(), additions: 0, deletions: 0, isBinary: false, ..Default::default() };
              if include {
                let new_s = crate::util::run_git(&cwd, &["show", &format!("{}:{}", r2_oid, newp)]).unwrap_or_default();
                let new_sz = new_s.as_bytes().len(); e.newSize = Some(new_sz as i32); e.oldSize = Some(new_sz as i32);
                if new_sz <= max_bytes { e.oldContent = Some(new_s.clone()); e.newContent = Some(new_s); e.contentOmitted = Some(false);} else { e.contentOmitted = Some(true); }
              }
              fallback.push(e);
            }
          }
          _ => {}
        }
      }
      if !fallback.is_empty() {
        #[cfg(debug_assertions)] println!("[native.refs] CLI fallback returning {} entries", fallback.len());
        return Ok(fallback);
      }
    }
  }

  Ok(out)
}
