use super::*;
use std::{fs, process::Command};
use tempfile::tempdir;
use std::path::{Path, PathBuf};
use crate::types::ListRepoFilesOptions;

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
fn list_repository_files_handles_branch_and_directories() {
  let tmp = tempdir().unwrap();
  let repo = tmp.path().join("repo");
  fs::create_dir_all(&repo).unwrap();

  run(&repo, "git init");
  run(
    &repo,
    "git -c user.email=test@example.com -c user.name=Test checkout -b main",
  );

  fs::create_dir_all(repo.join("src")).unwrap();
  fs::write(repo.join("src/lib.rs"), b"fn main() {}\n").unwrap();
  fs::write(repo.join("README.md"), b"# Main branch\n").unwrap();
  fs::create_dir_all(repo.join("node_modules/pkg")).unwrap();
  fs::write(
    repo.join("node_modules/pkg/index.js"),
    b"module.exports = {}\n",
  )
  .unwrap();

  run(&repo, "git add .");
  run(&repo, "git -c user.email=test@example.com -c user.name=Test commit -m init");

  run(&repo, "git checkout -b feature");
  fs::create_dir_all(repo.join("docs")).unwrap();
  fs::write(repo.join("docs/guide.md"), b"feature docs\n").unwrap();
  run(&repo, "git add .");
  run(
    &repo,
    "git -c user.email=test@example.com -c user.name=Test commit -m docs",
  );
  run(&repo, "git checkout main");

  let origin_path = repo.to_string_lossy().to_string();

  let main_files = crate::files::list_repository_files(ListRepoFilesOptions {
    originPath: Some(origin_path.clone()),
    branch: Some("main".into()),
    ..Default::default()
  })
  .expect("list main");

  assert!(
    main_files
      .iter()
      .any(|f| f.isDirectory && f.relativePath == "src"),
    "expected src directory in listing"
  );
  assert!(
    main_files
      .iter()
      .any(|f| !f.isDirectory && f.relativePath == "src/lib.rs"),
    "expected lib.rs on main"
  );
  assert!(
    !main_files
      .iter()
      .any(|f| f.relativePath.contains("node_modules")),
    "node_modules should be ignored"
  );
  assert!(
    !main_files
      .iter()
      .any(|f| f.relativePath == "docs/guide.md"),
    "feature file should not appear on main"
  );

  let feature_files = crate::files::list_repository_files(ListRepoFilesOptions {
    originPath: Some(origin_path.clone()),
    branch: Some("feature".into()),
    ..Default::default()
  })
  .expect("list feature");

  assert!(
    feature_files
      .iter()
      .any(|f| f.relativePath == "docs/guide.md"),
    "feature branch should include docs/guide.md"
  );
  assert!(
    feature_files
      .iter()
      .any(|f| f.relativePath == "src/lib.rs"),
    "feature branch should include shared files"
  );
}

#[test]
fn list_repository_files_supports_fuzzy_matching() {
  let tmp = tempdir().unwrap();
  let repo = tmp.path().join("repo");
  fs::create_dir_all(&repo).unwrap();

  run(&repo, "git init");
  run(
    &repo,
    "git -c user.email=test@example.com -c user.name=Test checkout -b main",
  );

  fs::create_dir_all(repo.join("docs")).unwrap();
  fs::create_dir_all(repo.join("src")).unwrap();
  fs::write(repo.join("docs/guide.md"), b"docs\n").unwrap();
  fs::write(repo.join("src/app.ts"), b"console.log('app');\n").unwrap();
  fs::write(repo.join("src/another.ts"), b"console.log('another');\n").unwrap();

  run(&repo, "git add .");
  run(
    &repo,
    "git -c user.email=test@example.com -c user.name=Test commit -m initial",
  );

  let origin_path = repo.to_string_lossy().to_string();

  let fuzzy = crate::files::list_repository_files(ListRepoFilesOptions {
    originPath: Some(origin_path.clone()),
    branch: Some("main".into()),
    pattern: Some("guide".into()),
    limit: Some(5),
    ..Default::default()
  })
  .expect("list fuzzy");

  assert_eq!(fuzzy.len(), 1, "expected only docs/guide.md to match");
  assert_eq!(fuzzy[0].relativePath, "docs/guide.md");
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
