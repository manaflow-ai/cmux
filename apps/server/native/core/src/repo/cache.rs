use anyhow::{anyhow, Result};
use dirs_next::cache_dir;
use std::{collections::HashMap, fs, path::PathBuf};
use std::sync::{Mutex, OnceLock};

use crate::util::run_git;

const MAX_CACHE_REPOS: usize = 20;

// Default SWR window for git fetches. Lower means fetch more often.
pub const DEFAULT_FETCH_WINDOW_MS: u128 = 5_000; // 5s

pub fn fetch_window_ms() -> u128 {
  if let Ok(v) = std::env::var("CMUX_GIT_FETCH_WINDOW_MS") {
    if let Ok(parsed) = v.parse::<u128>() { return parsed; }
  }
  DEFAULT_FETCH_WINDOW_MS
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
struct CacheIndexEntry {
  slug: String,
  path: String,
  last_access_ms: u128,
  #[serde(default)]
  last_fetch_ms: Option<u128>,
}

#[derive(Default, Debug, Clone, serde::Serialize, serde::Deserialize)]
struct CacheIndex {
  entries: Vec<CacheIndexEntry>,
}

fn default_cache_root() -> PathBuf {
  if let Ok(dir) = std::env::var("CMUX_RUST_GIT_CACHE") { return PathBuf::from(dir); }
  if let Some(mut d) = cache_dir() { d.push("cmux-git-cache"); return d; }
  std::env::temp_dir().join("cmux-git-cache")
}

fn slug_from_url(url: &str) -> String {
  let clean = url.trim_end_matches(".git");
  let name = clean.split('/').rev().take(2).collect::<Vec<_>>();
  if name.len() == 2 { format!("{}__{}", name[1], name[0]) } else { clean.replace(['/', ':', '@', '\\'], "_") }
}

pub fn ensure_repo(url: &str) -> Result<PathBuf> {
  let root = default_cache_root();
  fs::create_dir_all(&root)?;
  let path = root.join(slug_from_url(url));
  let git_dir = path.join(".git");
  let head = git_dir.join("HEAD");
  if path.exists() && (!git_dir.exists() || !head.exists()) {
    let _ = fs::remove_dir_all(&path);
  }
  if !path.exists() {
    fs::create_dir_all(&path)?;
    let dirname = path.file_name()
      .and_then(|n| n.to_str())
      .ok_or_else(|| anyhow!("Invalid path: unable to extract directory name"))?;
    run_git(
      root.to_string_lossy().as_ref(),
      &["clone", "--no-single-branch", url, dirname]
    )?;
    let _ = update_cache_index_with(&root, &path, Some(now_ms()));
  } else {
    let _ = swr_fetch_origin_all_path_bool(&path, fetch_window_ms());
  }
  let shallow = path.join(".git").join("shallow");
  if shallow.exists() {
    let _ = run_git(path.to_string_lossy().as_ref(), &["fetch", "--unshallow", "--tags"]);
  }

  update_cache_index(&root, &path)?;
  enforce_cache_limit(&root)?;
  Ok(path)
}

pub fn resolve_repo_url(repo_full_name: Option<&str>, repo_url: Option<&str>) -> Result<String> {
  if let Some(u) = repo_url { return Ok(u.to_string()); }
  if let Some(full) = repo_full_name { return Ok(format!("https://github.com/{}.git", full)); }
  Err(anyhow!("repoUrl or repoFullName required"))
}

fn load_index(root: &PathBuf) -> CacheIndex {
  let idx_path = root.join("cache-index.json");
  if let Ok(data) = fs::read(&idx_path) {
    if let Ok(idx) = serde_json::from_slice::<CacheIndex>(&data) {
      return idx;
    }
  }
  CacheIndex::default()
}

fn save_index(root: &PathBuf, idx: &CacheIndex) -> Result<()> {
  let idx_path = root.join("cache-index.json");
  let data = serde_json::to_vec_pretty(idx)?;
  fs::write(idx_path, data)?;
  Ok(())
}

fn update_cache_index(root: &PathBuf, repo_path: &PathBuf) -> Result<()> {
  let mut idx = load_index(root);
  let slug = repo_path
    .file_name()
    .and_then(|s| s.to_str())
    .unwrap_or("")
    .to_string();
  let now = std::time::SystemTime::now()
    .duration_since(std::time::UNIX_EPOCH)
    .map_err(|e| anyhow!("System time error: {}", e))?
    .as_millis();

  if let Some(e) = idx.entries.iter_mut().find(|e| e.slug == slug) {
    e.last_access_ms = now;
    e.path = repo_path.to_string_lossy().to_string();
  } else {
    idx.entries.push(CacheIndexEntry {
      slug,
      path: repo_path.to_string_lossy().to_string(),
      last_access_ms: now,
      last_fetch_ms: None,
    });
  }
  idx.entries.sort_by(|a, b| b.last_access_ms.cmp(&a.last_access_ms));
  idx.entries.dedup_by(|a, b| a.slug == b.slug);
  save_index(root, &idx)?;
  Ok(())
}

fn now_ms() -> u128 {
  std::time::SystemTime::now()
    .duration_since(std::time::UNIX_EPOCH)
    .map(|d| d.as_millis())
    .unwrap_or(0)
}

fn update_cache_index_with(root: &PathBuf, repo_path: &PathBuf, last_fetch_ms: Option<u128>) -> Result<()> {
  let mut idx = load_index(root);
  let pstr = repo_path.to_string_lossy().to_string();
  let now = now_ms();
  if let Some(e) = idx.entries.iter_mut().find(|e| e.path == pstr) {
    e.last_access_ms = now;
    if let Some(f) = last_fetch_ms { e.last_fetch_ms = Some(f); }
  } else {
    let slug = repo_path
      .file_name()
      .and_then(|s| s.to_str())
      .unwrap_or("")
      .to_string();
    idx.entries.push(CacheIndexEntry {
      slug,
      path: pstr,
      last_access_ms: now,
      last_fetch_ms,
    });
  }
  idx.entries.sort_by(|a, b| b.last_access_ms.cmp(&a.last_access_ms));
  idx.entries.dedup_by(|a, b| a.slug == b.slug);
  save_index(root, &idx)?;
  Ok(())
}

fn get_cache_last_fetch(root: &PathBuf, repo_path: &PathBuf) -> Option<u128> {
  let idx = load_index(root);
  let pstr = repo_path.to_string_lossy().to_string();
  idx.entries.into_iter().find(|e| e.path == pstr).and_then(|e| e.last_fetch_ms)
}

static SWR_FETCH_MAP: OnceLock<Mutex<HashMap<String, u128>>> = OnceLock::new();

fn swr_map() -> &'static Mutex<HashMap<String, u128>> {
  SWR_FETCH_MAP.get_or_init(|| Mutex::new(HashMap::new()))
}

fn get_map_last_fetch(repo_path: &PathBuf) -> Option<u128> {
  let pstr = repo_path.to_string_lossy().to_string();
  swr_map().lock().ok().and_then(|m| m.get(&pstr).copied())
}

fn set_map_last_fetch(repo_path: &PathBuf, t: u128) {
  let pstr = repo_path.to_string_lossy().to_string();
  if let Ok(mut m) = swr_map().lock() { m.insert(pstr, t); }
}

pub fn swr_fetch_origin_all_path_bool(path: &std::path::Path, window_ms: u128) -> Result<bool> {
  let cwd = path.to_string_lossy().to_string();
  let root = default_cache_root();
  let now = now_ms();

  let last_fetch_idx = get_cache_last_fetch(&root, &PathBuf::from(&cwd));
  let last_fetch_map = get_map_last_fetch(&PathBuf::from(&cwd));
  let last_fetch = last_fetch_idx.or(last_fetch_map);

  if let Some(t) = last_fetch {
    if now.saturating_sub(t) <= window_ms {
      let cwd_bg = cwd.clone();
      let root_bg = root.clone();
      std::thread::spawn(move || {
        let _ = run_git(&cwd_bg, &["fetch", "--all", "--tags", "--prune"]);
        let _ = update_cache_index_with(&root_bg, &PathBuf::from(&cwd_bg), Some(now_ms()));
        set_map_last_fetch(&PathBuf::from(&cwd_bg), now_ms());
      });
      return Ok(false);
    }
  }

  let _ = run_git(&cwd, &["fetch", "--all", "--tags", "--prune"]);
  let now2 = now_ms();
  let _ = update_cache_index_with(&root, &PathBuf::from(&cwd), Some(now2));
  set_map_last_fetch(&PathBuf::from(&cwd), now2);
  Ok(true)
}

pub fn swr_fetch_origin_all_path(path: &std::path::Path, window_ms: u128) -> Result<()> {
  let _ = swr_fetch_origin_all_path_bool(path, window_ms)?;
  Ok(())
}
#[allow(dead_code)]
pub fn fetch_origin_all_path(path: &std::path::Path) -> Result<()> {
  let cwd = path.to_string_lossy().to_string();
  let _ = run_git(&cwd, &["fetch", "--all", "--tags", "--prune"]);
  Ok(())
}

fn enforce_cache_limit(root: &PathBuf) -> Result<()> {
  let mut idx = load_index(root);
  if idx.entries.len() <= MAX_CACHE_REPOS { return Ok(()); }
  idx.entries.sort_by(|a, b| b.last_access_ms.cmp(&a.last_access_ms));
  let survivors = idx.entries[..MAX_CACHE_REPOS].to_vec();
  let victims = idx.entries[MAX_CACHE_REPOS..].to_vec();
  for v in &victims {
    let p = PathBuf::from(&v.path);
    let _ = fs::remove_dir_all(&p);
  }
  idx.entries = survivors;
  save_index(root, &idx)?;
  Ok(())
}

#[cfg(test)]
mod tests {
  use super::*;
  use tempfile::tempdir;

  #[test]
  fn swr_fetch_skips_within_window_and_backgrounds() {
    let tmp = tempdir().unwrap();
    let repo_dir = tmp.path().join("repo");
    std::fs::create_dir_all(&repo_dir).unwrap();
    let status = if cfg!(target_os = "windows") {
      std::process::Command::new("cmd").arg("/C").arg("git init").current_dir(&repo_dir).status()
    } else {
      std::process::Command::new("sh").arg("-c").arg("git init").current_dir(&repo_dir).status()
    }.expect("spawn");
    assert!(status.success());

    let first = swr_fetch_origin_all_path_bool(&repo_dir, 5_000).expect("swr fetch 1");
    let second = swr_fetch_origin_all_path_bool(&repo_dir, 5_000).expect("swr fetch 2");
    assert!(first, "first call should be synchronous fetch");
    assert!(!second, "second call within window should skip and background");
  }
}
