use super::*;
use std::{fs, process::Command};
use tempfile::tempdir;
use std::path::{Path, PathBuf};

fn run(cwd: &std::path::Path, cmd: &str) {
  let status = if cfg!(target_os = "windows") {
    Command::new("cmd").arg("/C").arg(cmd).current_dir(cwd).status()
  } else {
    Command::new("sh").arg("-c").arg(cmd).current_dir(cwd).status()
  }
  .expect("spawn");
  assert!(status.success(), "command failed: {cmd}");
}

fn find_git_root(mut p: PathBuf) -> PathBuf {
  loop {
    if p.join(".git").exists() { return p; }
    if !p.pop() { break; }
  }
  panic!(".git not found from test cwd");
}

fn parse_numstat_sum(cwd: &Path, from: &str, to: &str) -> (i32, i32) {
  use std::process::Command;
  let mut cmd = if cfg!(target_os = "windows") {
    let mut c = Command::new("cmd");
    c.arg("/C").arg(format!("git diff --numstat {} {}", from, to));
    c
  } else {
    let mut c = Command::new("sh");
    c.arg("-c").arg(format!("git diff --numstat {} {}", from, to));
    c
  };
  let out = cmd
  .current_dir(cwd)
  .output()
  .expect("spawn numstat");
  assert!(out.status.success(), "git diff --numstat failed");
  let s = String::from_utf8_lossy(&out.stdout);
  let mut adds = 0i32; let mut dels = 0i32;
  for line in s.lines() {
    let parts: Vec<&str> = line.split('\t').collect();
    if parts.len() < 3 { continue; }
    let a = parts[0]; let d = parts[1];
    if a != "-" && d != "-" {
      adds += a.parse::<i32>().unwrap_or(0);
      dels += d.parse::<i32>().unwrap_or(0);
    }
  }
  (adds, dels)
}

// Tiny PRNG for fuzz tests to avoid extra dependencies
#[derive(Clone)]
struct Prng { state: u64 }
impl Prng {
  fn new(seed: u64) -> Self { Self { state: seed } }
  fn next(&mut self) -> u32 { // xorshift64*
    let mut x = self.state;
    x ^= x >> 12; x ^= x << 25; x ^= x >> 27; self.state = x;
    ((x.wrapping_mul(2685821657736338717)) >> 32) as u32
  }
  fn gen_range(&mut self, lo: usize, hi: usize) -> usize { lo + (self.next() as usize % (hi - lo)) }
}

#[test]
fn workspace_diff_basic() {
  let tmp = tempdir().unwrap();
  let work = tmp.path().join("work");
  fs::create_dir_all(&work).unwrap();
  run(&work, "git init");
  run(&work, "git -c user.email=a@b -c user.name=test checkout -b main");
  fs::write(work.join("a.txt"), b"a1\n").unwrap();
  run(&work, "git add .");
  run(&work, "git -c user.email=a@b -c user.name=test commit -m init");

  fs::write(work.join("a.txt"), b"a1\na2\n").unwrap();
  fs::create_dir_all(work.join("src")).unwrap();
  fs::write(work.join("src/new.txt"), b"x\ny\n").unwrap();

  let out = crate::diff::workspace::diff_workspace(GitDiffWorkspaceOptions{
    worktreePath: work.to_string_lossy().to_string(),
    includeContents: Some(true),
    maxBytes: Some(1024*1024),
  }).unwrap();

  let mut has_a = false;
  let mut has_new = false;
  for e in &out {
    if e.filePath == "a.txt" { has_a = true; }
    if e.filePath == "src/new.txt" { has_new = true; }
  }
  assert!(has_a && has_new, "expected modified and untracked files");
}

#[test]
fn workspace_diff_unborn_head_uses_remote_default() {
  let tmp = tempdir().unwrap();
  let root = tmp.path();

  // Create bare origin with a main branch and one file
  let origin_path = root.join("origin.git");
  fs::create_dir_all(&origin_path).unwrap();
  run(&root, &format!("git init --bare {}", origin_path.file_name().unwrap().to_str().unwrap()));

  // Seed repo to populate origin/main
  let seed = root.join("seed");
  fs::create_dir_all(&seed).unwrap();
  run(&seed, "git init");
  run(&seed, "git -c user.email=a@b -c user.name=test checkout -b main");
  fs::write(seed.join("a.txt"), b"one\n").unwrap();
  run(&seed, "git add .");
  run(&seed, "git -c user.email=a@b -c user.name=test commit -m init");

  // Point origin HEAD to main and push
  let origin_url = origin_path.to_string_lossy().to_string();
  run(&seed, &format!("git remote add origin {}", origin_url));
  // Ensure origin default branch is main
  run(&origin_path, "git symbolic-ref HEAD refs/heads/main");
  run(&seed, "git push -u origin main");

  // Create work repo with unborn HEAD, add remote, fetch only
  let work = root.join("work");
  fs::create_dir_all(&work).unwrap();
  run(&work, "git init");
  run(&work, &format!("git remote add origin {}", origin_url));
  run(&work, "git fetch origin");

  // Modify file relative to remote default without any local commit
  fs::write(work.join("a.txt"), b"one\ntwo\n").unwrap();

  let out = crate::diff::workspace::diff_workspace(GitDiffWorkspaceOptions{
    worktreePath: work.to_string_lossy().to_string(),
    includeContents: Some(true),
    maxBytes: Some(1024*1024),
  }).expect("diff workspace unborn");

  // Expect a diff against remote default: a.txt should be modified
  if !out.iter().any(|e| e.filePath == "a.txt") {
    eprintln!("entries: {:?}", out.iter().map(|e| format!("{}:{}", e.status, e.filePath)).collect::<Vec<_>>());
  }
  let row = out.iter().find(|e| e.filePath == "a.txt").expect("has a.txt");
  assert_eq!(row.status, "modified");
  assert_eq!(row.contentOmitted, Some(false));
  assert!(row.oldContent.as_deref() == Some("one\n"));
  assert!(row.newContent.as_deref() == Some("one\ntwo\n"));
  assert!(row.additions >= 1);
}

#[test]
fn refs_diff_basic_on_local_repo() {
  let tmp = tempdir().unwrap();
  let work = tmp.path().join("repo");
  std::fs::create_dir_all(&work).unwrap();
  run(&work, "git init");
  run(&work, "git -c user.email=a@b -c user.name=test checkout -b main");
  std::fs::write(work.join("a.txt"), b"a1\n").unwrap();
  run(&work, "git add .");
  run(&work, "git -c user.email=a@b -c user.name=test commit -m init");
  run(&work, "git checkout -b feature");
  std::fs::write(work.join("b.txt"), b"b\n").unwrap();
  run(&work, "git add .");
  run(&work, "git -c user.email=a@b -c user.name=test commit -m change");

  let out = crate::diff::refs::diff_refs(GitDiffRefsOptions{
    ref1: "main".into(),
    ref2: "feature".into(),
    repoFullName: None,
    repoUrl: None,
    teamSlugOrId: None,
    originPathOverride: Some(work.to_string_lossy().to_string()),
    includeContents: Some(true),
    maxBytes: Some(1024*1024),
  }).unwrap();

  assert!(out.iter().any(|e| e.filePath == "b.txt"));
}

#[test]
fn refs_merge_base_after_merge_is_branch_tip() {
  let tmp = tempdir().unwrap();
  let work = tmp.path().join("repo");
  fs::create_dir_all(&work).unwrap();

  run(&work, "git init");
  run(&work, "git -c user.email=a@b -c user.name=test checkout -b main");
  std::fs::write(work.join("file.txt"), b"base\n").unwrap();
  run(&work, "git add .");
  run(&work, "git -c user.email=a@b -c user.name=test commit -m base");

  run(&work, "git checkout -b feature");
  std::fs::write(work.join("feat.txt"), b"feat\n").unwrap();
  run(&work, "git add .");
  run(&work, "git -c user.email=a@b -c user.name=test commit -m feature-change");

  run(&work, "git checkout main");
  run(&work, "git -c user.email=a@b -c user.name=test merge --no-ff feature -m merge-feature");

  std::fs::write(work.join("main.txt"), b"main\n").unwrap();
  run(&work, "git add .");
  run(&work, "git -c user.email=a@b -c user.name=test commit -m main-after-merge");

  let out = crate::diff::refs::diff_refs(GitDiffRefsOptions{
    ref1: "main".into(),
    ref2: "feature".into(),
    repoFullName: None,
    repoUrl: None,
    teamSlugOrId: None,
    originPathOverride: Some(work.to_string_lossy().to_string()),
    includeContents: Some(true),
    maxBytes: Some(1024*1024),
  }).unwrap();

  assert_eq!(out.len(), 0, "Expected no differences after merge, got: {:?}", out);
}

#[test]
fn landed_diff_merge_by_message_yields_changes() {
  let tmp = tempdir().unwrap();
  let work = tmp.path().join("repo");
  fs::create_dir_all(&work).unwrap();

  // Initialize base
  run(&work, "git init");
  run(&work, "git -c user.email=a@b -c user.name=test checkout -b main");
  fs::write(work.join("f.txt"), b"base\n").unwrap();
  run(&work, "git add .");
  run(&work, "git -c user.email=a@b -c user.name=test commit -m base");

  // Feature branch with a change
  run(&work, "git checkout -b feature");
  fs::write(work.join("f.txt"), b"feature\n").unwrap();
  run(&work, "git add .");
  run(&work, "git -c user.email=a@b -c user.name=test commit -m feature-change");

  // Merge back to main with a message that includes the head branch name
  run(&work, "git checkout main");
  run(&work, "git -c user.email=a@b -c user.name=test merge --no-ff feature -m 'Merge pull request #1 from test/feature'");

  let out = crate::diff::landed::landed_diff(GitDiffLandedOptions {
    baseRef: "main".into(),
    headRef: "feature".into(),
    b0Ref: None,
    repoFullName: None,
    repoUrl: None,
    teamSlugOrId: None,
    originPathOverride: Some(work.to_string_lossy().to_string()),
    includeContents: Some(true),
    maxBytes: Some(1024 * 1024),
  })
  .expect("landed diff");

  assert!(
    out.iter().any(|e| e.filePath == "f.txt"),
    "expected f.txt in landed diff, got {:?}",
    out
  );
}

#[test]
fn landed_diff_with_path_override_is_fast() {
  use std::time::Instant;
  let tmp = tempdir().unwrap();
  let work = tmp.path().join("repo");
  fs::create_dir_all(&work).unwrap();

  // Initialize repo and create a merge commit to exercise landed
  run(&work, "git init");
  run(&work, "git -c user.email=a@b -c user.name=test checkout -b main");
  fs::write(work.join("f.txt"), b"base\n").unwrap();
  run(&work, "git add .");
  run(&work, "git -c user.email=a@b -c user.name=test commit -m base");
  run(&work, "git checkout -b feature");
  fs::write(work.join("f.txt"), b"feature\n").unwrap();
  run(&work, "git add .");
  run(&work, "git -c user.email=a@b -c user.name=test commit -m change");
  run(&work, "git checkout main");
  run(&work, "git -c user.email=a@b -c user.name=test merge --no-ff feature -m merge-feature");

  let t0 = Instant::now();
  let out = crate::diff::landed::landed_diff(GitDiffLandedOptions {
    baseRef: "main".into(),
    headRef: "feature".into(),
    b0Ref: None,
    repoFullName: None,
    repoUrl: None,
    teamSlugOrId: None,
    originPathOverride: Some(work.to_string_lossy().to_string()),
    includeContents: Some(true),
    maxBytes: Some(1024 * 1024),
  })
  .expect("landed diff");
  let ms = t0.elapsed().as_millis();
  assert!(
    ms < 300,
    "landed diff with originPathOverride should be fast; took {}ms; entries={:?}",
    ms,
    out.len()
  );
}

#[test]
fn landed_diff_equal_tips_returns_empty() {
  let tmp = tempdir().unwrap();
  let work = tmp.path().join("repo");
  fs::create_dir_all(&work).unwrap();

  // Initialize base and create a new branch without commits
  run(&work, "git init");
  run(&work, "git -c user.email=a@b -c user.name=test checkout -b main");
  fs::write(work.join("f.txt"), b"base\n").unwrap();
  run(&work, "git add .");
  run(&work, "git -c user.email=a@b -c user.name=test commit -m base");
  run(&work, "git checkout -b feature");
  // No commits on feature; tips equal

  let out = crate::diff::landed::landed_diff(GitDiffLandedOptions {
    baseRef: "main".into(),
    headRef: "feature".into(),
    b0Ref: None,
    repoFullName: None,
    repoUrl: None,
    teamSlugOrId: None,
    originPathOverride: Some(work.to_string_lossy().to_string()),
    includeContents: Some(true),
    maxBytes: Some(1024 * 1024),
  })
  .expect("landed diff");
  assert!(out.is_empty(), "expected empty landed diff for equal tips");
}

#[test]
fn refs_diff_numstat_matches_known_pairs() {
  // Ensure we run against the repo root so refs are available
  let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
  let repo_root = find_git_root(manifest_dir);
  // Proactively fetch to make sure remote-only commits are present locally
  run(&repo_root, "git fetch --all --tags --prune");

  let cases = vec![
    ("63f3bf66676b5bc7d495f6aaacabe75895ff2045", "0ae5f5b2098b4d7c5f3185943251fba8ee791575", 6, 30),
    ("7a985028c3ecc57f110d91191a4d000c39f0a63e", "5f7d671ca484360df34e363511a0dd60ebe25c79", 294, 255),
    ("4a886e5e769857b9af000224a33460f96fa66545", "08db1fe57536b2832a75b8eff5c1955e735157e6", 512, 232),
    ("2f5f387feee44af6d540da544a0501678dcc2538", "2b292770f68d8c097420bd70fd446ca22a88ec62", 3, 3),
  ];

  for (from, to, exp_adds, exp_dels) in cases {
    let out = crate::diff::refs::diff_refs(GitDiffRefsOptions{
      ref1: from.into(),
      ref2: to.into(),
      repoFullName: None,
      repoUrl: None,
      teamSlugOrId: None,
      originPathOverride: Some(repo_root.to_string_lossy().to_string()),
      includeContents: Some(true),
      maxBytes: Some(10*1024*1024),
    }).expect("diff refs");
    let adds: i32 = out.iter().map(|e| e.additions).sum();
    let dels: i32 = out.iter().map(|e| e.deletions).sum();
    assert_eq!((adds, dels), (exp_adds, exp_dels), "mismatch for {}..{} entries={}", from, to, out.len());
  }
}

#[test]
fn refs_diff_handles_binary_files() {
  let tmp = tempdir().unwrap();
  let work = tmp.path().join("repo");
  std::fs::create_dir_all(&work).unwrap();
  run(&work, "git init");
  run(&work, "git -c user.email=a@b -c user.name=test checkout -b main");

  // Commit an initial binary file with NUL bytes
  let bin1: Vec<u8> = vec![0, 159, 146, 150, 0, 1, 2, 3, 4, 5];
  std::fs::write(work.join("bin.dat"), &bin1).unwrap();
  run(&work, "git add .");
  run(&work, "git -c user.email=a@b -c user.name=test commit -m init");
  let c1 = String::from_utf8(Command::new(if cfg!(target_os = "windows") {"cmd"} else {"sh"})
    .arg(if cfg!(target_os = "windows") {"/C"} else {"-c"})
    .arg("git rev-parse HEAD")
    .current_dir(&work)
    .output().unwrap().stdout).unwrap();
  let c1 = c1.trim().to_string();

  // Modify the binary file
  let mut bin2 = bin1.clone();
  bin2.extend_from_slice(&[6,7,8,9,0]);
  std::fs::write(work.join("bin.dat"), &bin2).unwrap();
  run(&work, "git add .");
  run(&work, "git -c user.email=a@b -c user.name=test commit -m update");
  let c2 = String::from_utf8(Command::new(if cfg!(target_os = "windows") {"cmd"} else {"sh"})
    .arg(if cfg!(target_os = "windows") {"/C"} else {"-c"})
    .arg("git rev-parse HEAD")
    .current_dir(&work)
    .output().unwrap().stdout).unwrap();
  let c2 = c2.trim().to_string();

  let out = crate::diff::refs::diff_refs(GitDiffRefsOptions{
    ref1: c1.clone(),
    ref2: c2.clone(),
    repoFullName: None,
    repoUrl: None,
    teamSlugOrId: None,
    originPathOverride: Some(work.to_string_lossy().to_string()),
    includeContents: Some(true),
    maxBytes: Some(1024*1024),
  }).expect("diff refs binary");

  let bin_entry = out.iter().find(|e| e.filePath == "bin.dat").expect("binary entry");
  assert!(bin_entry.isBinary, "binary file should be detected");
  assert_eq!(bin_entry.additions, 0);
  assert_eq!(bin_entry.deletions, 0);
}

#[test]
fn refs_diff_pr_282_counts() {
  // PR 282 landed patch stats relative to the merge commit on main: +3250 -22
  let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
  let repo_root = find_git_root(manifest_dir);
  // Ensure both main and PR head are available locally
  run(&repo_root, "git fetch --prune --tags --force origin refs/heads/main:refs/remotes/origin/main refs/pull/282/head:refs/remotes/origin/pr-282");

  let base_ref = "origin/main"; // base branch
  let head_ref = "d2f53cf036676bc56f949b9a9454c421ab06940c"; // PR #282 head (ancestor of merged second parent)

  let out = crate::diff::landed::landed_diff(GitDiffLandedOptions {
    baseRef: base_ref.into(),
    headRef: head_ref.into(),
    b0Ref: None,
    repoFullName: None,
    repoUrl: None,
    teamSlugOrId: None,
    originPathOverride: Some(repo_root.to_string_lossy().to_string()),
    includeContents: Some(true),
    maxBytes: Some(100 * 1024 * 1024),
  })
  .expect("landed diff pr 282");

  let adds: i32 = out.iter().map(|e| e.additions).sum();
  let dels: i32 = out.iter().map(|e| e.deletions).sum();

  assert_eq!((adds, dels), (3250, 22), "mismatch for pr 282 landed {}..{} entries={}", base_ref, head_ref, out.len());
}

#[test]
fn refs_diff_pr_255_counts() {
  // PR 255 expected stats: +56 -8 relative to main
  // Head commit resolved locally:
  //   head: c7ab60e672d48475d9da08b494044f38183755d3
  let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
  let repo_root = find_git_root(manifest_dir);
  // Fetch main and PR ref to ensure availability
  run(&repo_root, "git fetch --prune --tags --force origin refs/heads/main:refs/remotes/origin/main refs/pull/255/head:refs/remotes/origin/pr-255");

  let from = "origin/main"; // base branch
  let to = "c7ab60e672d48475d9da08b494044f38183755d3"; // PR #255 head

  let out = crate::diff::refs::diff_refs(GitDiffRefsOptions{
    ref1: from.into(),
    ref2: to.into(),
    repoFullName: None,
    repoUrl: None,
    teamSlugOrId: None,
    originPathOverride: Some(repo_root.to_string_lossy().to_string()),
    includeContents: Some(true),
    maxBytes: Some(100*1024*1024),
  }).expect("diff refs pr 255");

  let adds: i32 = out.iter().map(|e| e.additions).sum();
  let dels: i32 = out.iter().map(|e| e.deletions).sum();

  assert_eq!((adds, dels), (56, 8), "mismatch for pr 255 {}..{} entries={}", from, to, out.len());
}

#[test]
fn refs_diff_pr_198_counts() {
  // PR 198 expected stats: +1644 -325 relative to main
  // Head commit resolved locally:
  //   head: 15492f88e1a4216b1ef9771015515055ed7f25b9
  let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
  let repo_root = find_git_root(manifest_dir);
  // Fetch main and PR ref to ensure availability
  run(&repo_root, "git fetch --prune --tags --force origin refs/heads/main:refs/remotes/origin/main refs/pull/198/head:refs/remotes/origin/pr-198");

  let from = "origin/main"; // base branch
  let to = "15492f88e1a4216b1ef9771015515055ed7f25b9"; // PR #198 head

  let out = crate::diff::refs::diff_refs(GitDiffRefsOptions{
    ref1: from.into(),
    ref2: to.into(),
    repoFullName: None,
    repoUrl: None,
    teamSlugOrId: None,
    originPathOverride: Some(repo_root.to_string_lossy().to_string()),
    includeContents: Some(true),
    maxBytes: Some(100*1024*1024),
  }).expect("diff refs pr 198");

  let adds: i32 = out.iter().map(|e| e.additions).sum();
  let dels: i32 = out.iter().map(|e| e.deletions).sum();

  assert_eq!((adds, dels), (1644, 325), "mismatch for pr 198 {}..{} entries={}", from, to, out.len());
}

#[test]
fn refs_diff_external_repo_hello_world() {
  // Use pinned SHAs from octocat/Hello-World
  let tmp = tempdir().unwrap();
  let root = tmp.path();
  run(root, "git clone --depth=50 https://github.com/octocat/Hello-World.git repo");
  let repo = root.join("repo");
  let from = "553c2077f0edc3d5dc5d17262f6aa498e69d6f8e";
  let to = "7fd1a60b01f91b314f59955a4e4d4e80d8edf11d";
  let (ga, gd) = parse_numstat_sum(&repo, from, to);

  let out = crate::diff::refs::diff_refs(GitDiffRefsOptions{
    ref1: from.into(),
    ref2: to.into(),
    repoFullName: None,
    repoUrl: None,
    teamSlugOrId: None,
    originPathOverride: Some(repo.to_string_lossy().to_string()),
    includeContents: Some(true),
    maxBytes: Some(32*1024*1024),
  }).expect("diff refs external hello-world");
  let adds: i32 = out.iter().map(|e| e.additions).sum();
  let dels: i32 = out.iter().map(|e| e.deletions).sum();
  assert_eq!((adds, dels), (ga, gd));
}

#[test]
fn refs_diff_external_repo_spoon_knife() {
  // Use pinned SHAs from octocat/Spoon-Knife
  let tmp = tempdir().unwrap();
  let root = tmp.path();
  run(root, "git clone --depth=50 https://github.com/octocat/Spoon-Knife.git repo");
  let repo = root.join("repo");
  let from = "bb4cc8d3b2e14b3af5df699876dd4ff3acd00b7f";
  let to = "d0dd1f61b33d64e29d8bc1372a94ef6a2fee76a9";
  let (ga, gd) = parse_numstat_sum(&repo, from, to);

  let out = crate::diff::refs::diff_refs(GitDiffRefsOptions{
    ref1: from.into(),
    ref2: to.into(),
    repoFullName: None,
    repoUrl: None,
    teamSlugOrId: None,
    originPathOverride: Some(repo.to_string_lossy().to_string()),
    includeContents: Some(true),
    maxBytes: Some(32*1024*1024),
  }).expect("diff refs external spoon-knife");
  let adds: i32 = out.iter().map(|e| e.additions).sum();
  let dels: i32 = out.iter().map(|e| e.deletions).sum();
  assert_eq!((adds, dels), (ga, gd));
}

#[test]
fn refs_diff_fuzz_synthetic_repos() {
  // Randomized operations on small repos; compare to git numstat
  let mut rng = Prng::new(0xC0FFEE);
  let rounds = 8usize; // keep runtime reasonable
  for r in 0..rounds {
    let tmp = tempdir().unwrap();
    let work = tmp.path().join("repo");
    std::fs::create_dir_all(&work).unwrap();
    run(&work, "git init");
    run(&work, "git -c user.email=a@b -c user.name=test checkout -b main");

    // seed a few text files
    let mut text_files: Vec<String> = Vec::new();
    for i in 0..rng.gen_range(2, 5) { // 2..4 files
      let p = format!("t{}.txt", i);
      let mut content = String::new();
      for j in 0..rng.gen_range(3, 10) { content.push_str(&format!("seed {} {}\n", i, j)); }
      std::fs::write(work.join(&p), content).unwrap();
      text_files.push(p);
    }
    // seed some binaries
    let mut bin_files: Vec<String> = Vec::new();
    for i in 0..rng.gen_range(1, 3) { // 1..2 bins
      let p = format!("b{}.dat", i);
      let mut bytes = vec![0u8, 1, 2, 3, 0u8];
      for _ in 0..rng.gen_range(0, 5) { bytes.push((rng.next() & 0xFF) as u8); }
      std::fs::write(work.join(&p), bytes).unwrap();
      bin_files.push(p);
    }
    run(&work, "git add .");
    run(&work, &format!("git -c user.email=a@b -c user.name=test commit -m seed-r{}", r));
    let out = std::process::Command::new(if cfg!(target_os = "windows") {"cmd"} else {"sh"})
      .arg(if cfg!(target_os = "windows") {"/C"} else {"-c"})
      .arg("git rev-parse HEAD")
      .current_dir(&work)
      .output().unwrap();
    let base = String::from_utf8(out.stdout).unwrap().trim().to_string();

    // apply random ops
    let ops = rng.gen_range(5, 12); // 5..11 ops
    for _ in 0..ops {
      let choice = rng.gen_range(0, 6);
      match choice {
        0 => { // modify random text file
          if !text_files.is_empty() {
            let idx = rng.gen_range(0, text_files.len());
            let p = &text_files[idx];
            let mut s = std::fs::read_to_string(work.join(p)).unwrap_or_default();
            if rng.gen_range(0, 2) == 0 { s.push_str(&format!("app {}\n", rng.next())); } else { s = s.lines().enumerate().filter(|(i,_)| i % 2 == 0).map(|(_,l)| l).collect::<Vec<_>>().join("\n"); s.push('\n'); }
            std::fs::write(work.join(p), s).unwrap();
          }
        }
        1 => { // add new text file
          let p = format!("n{}_{}.txt", r, rng.next());
          let mut s = String::new(); for j in 0..rng.gen_range(1, 8) { s.push_str(&format!("line {}\n", j)); }
          std::fs::write(work.join(&p), s).unwrap();
          text_files.push(p);
        }
        2 => { // delete text file
          if !text_files.is_empty() { let idx = rng.gen_range(0, text_files.len()); let p = text_files.remove(idx); let _ = std::fs::remove_file(work.join(p)); }
        }
        3 => { // binary modify
          if !bin_files.is_empty() { let idx = rng.gen_range(0, bin_files.len()); let p = &bin_files[idx]; let mut v = std::fs::read(work.join(p)).unwrap_or_default(); v.push(0); std::fs::write(work.join(p), v).unwrap(); }
        }
        4 => { // binary add
          let p = format!("nb{}_{}.dat", r, rng.next()); let mut v = vec![0u8, 3, 2, 0]; for _ in 0..rng.gen_range(0, 5) { v.push((rng.next() & 0xFF) as u8); } std::fs::write(work.join(&p), v).unwrap(); bin_files.push(p);
        }
        5 => { // identity rename of text file (no content change)
          if !text_files.is_empty() {
            let idx = rng.gen_range(0, text_files.len());
            let old = text_files[idx].clone();
            let new = format!("ren_{}_{}", r, rng.next());
            run(&work, &format!("git mv {} {} || mv {} {}", old, new, old, new));
            text_files[idx] = new;
          }
        }
        _ => {}
      }
    }
    run(&work, "git add -A");
    run(&work, &format!("git -c user.email=a@b -c user.name=test commit -m end-r{}", r));
    let out2 = std::process::Command::new(if cfg!(target_os = "windows") {"cmd"} else {"sh"})
      .arg(if cfg!(target_os = "windows") {"/C"} else {"-c"})
      .arg("git rev-parse HEAD")
      .current_dir(&work)
      .output().unwrap();
    let head = String::from_utf8(out2.stdout).unwrap().trim().to_string();

    // Baseline via git CLI numstat (A..B)
    let (ga, gd) = parse_numstat_sum(&work, &base, &head);

    // Our result
    let out = crate::diff::refs::diff_refs(GitDiffRefsOptions{
      ref1: base.clone(),
      ref2: head.clone(),
      repoFullName: None,
      repoUrl: None,
      teamSlugOrId: None,
      originPathOverride: Some(work.to_string_lossy().to_string()),
      includeContents: Some(true),
      maxBytes: Some(16*1024*1024),
    }).expect("diff refs fuzz");
    let adds: i32 = out.iter().map(|e| e.additions).sum();
    let dels: i32 = out.iter().map(|e| e.deletions).sum();

    if (adds, dels) != (ga, gd) {
      eprintln!("round {} mismatch: ours=({}, {}) git=({}, {}); entries={:?}", r, adds, dels, ga, gd, out.iter().map(|e| format!("{}:{} +{} -{} bin:{}", e.status, e.filePath, e.additions, e.deletions, e.isBinary)).collect::<Vec<_>>());
    }
    assert_eq!((adds, dels), (ga, gd), "fuzz round {} mismatch", r);
  }
}
