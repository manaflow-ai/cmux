//! AutoCloud start's folder from the warm mirror (`mirror.rs`), on real git in temp folders,
//! against a `file://` remote that serves partial clones as GitHub does.
#![cfg(unix)]

use std::path::{Path, PathBuf};
use std::process::Command;

use cmux_auto_session::wire::Cwd;

use super::folder::{clone, place};

fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@t.invalid", "-c", "commit.gpgsign=false"])
        .args(args)
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

struct Rig {
    _root: tempfile::TempDir,
    base: PathBuf,
    work: PathBuf,
    remote: String,
}

/// A remote with `main` (two commits) and `feature`, served as GitHub serves: filters and any
/// object id in a want.
fn rig(serves_filters: bool) -> Rig {
    let root = tempfile::tempdir().unwrap();
    let base = root.path().canonicalize().unwrap();
    let origin = base.join("origin.git");
    git(&base, &["init", "-q", "--bare", "-b", "main", origin.to_str().unwrap()]);
    if serves_filters {
        git(&origin, &["config", "uploadpack.allowFilter", "true"]);
        git(&origin, &["config", "uploadpack.allowAnySHA1InWant", "true"]);
    }
    let work = base.join("work");
    git(&base, &["init", "-q", "-b", "main", work.to_str().unwrap()]);
    git(&work, &["remote", "add", "origin", origin.to_str().unwrap()]);
    std::fs::write(work.join("a.txt"), "one\n").unwrap();
    git(&work, &["add", "."]);
    git(&work, &["commit", "-q", "-m", "one"]);
    std::fs::write(work.join("a.txt"), "two\n").unwrap();
    std::fs::write(work.join("b.txt"), "b\n").unwrap();
    git(&work, &["add", "."]);
    git(&work, &["commit", "-q", "-m", "two"]);
    git(&work, &["push", "-q", "origin", "main", "main:feature"]);
    let remote = format!("file://{}", origin.display());
    std::fs::create_dir_all(base.join("chats")).unwrap();
    Rig { _root: root, base, work, remote }
}

impl Rig {
    fn chat(&self, id: &str) -> PathBuf {
        self.base.join("chats").join(id)
    }

    fn mirrors(&self) -> Vec<String> {
        let dir = self.base.join("chats/.cmux-git-mirrors");
        let mut names: Vec<String> = std::fs::read_dir(dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        names
    }
}

fn borrows(dir: &Path) -> bool {
    dir.join(".git/objects/info/alternates").is_file()
}

#[test]
fn a_start_borrows_the_warm_mirror_and_is_a_whole_checkout() {
    let rig = rig(true);
    let chat = rig.chat("c1");
    clone(&chat, &rig.remote, "feature").unwrap();
    assert!(borrows(&chat), "the folder borrows the mirror's objects");
    assert_eq!(std::fs::read_to_string(chat.join("a.txt")).unwrap(), "two\n");
    assert_eq!(git(&chat, &["rev-parse", "--abbrev-ref", "HEAD"]), "feature");
    assert_eq!(git(&chat, &["rev-parse", "--abbrev-ref", "@{upstream}"]), "origin/feature");
    assert_eq!(git(&chat, &["rev-parse", "origin/main"]), git(&rig.work, &["rev-parse", "main"]));
    assert_eq!(git(&chat, &["status", "--porcelain"]), "");
    git(&chat, &["fsck", "--no-progress"]);
    // History reads, an old file comes from the remote on demand.
    assert_eq!(git(&chat, &["show", "HEAD~1:a.txt"]), "one");
    // A commit made in the chat is the chat's own.
    std::fs::write(chat.join("c.txt"), "c\n").unwrap();
    git(&chat, &["add", "."]);
    git(&chat, &["commit", "-q", "-m", "chat"]);
    git(&chat, &["fsck", "--no-progress"]);
}

#[test]
fn the_next_start_reuses_the_mirror_and_sees_new_commits() {
    let rig = rig(true);
    clone(&rig.chat("c1"), &rig.remote, "main").unwrap();
    std::fs::write(rig.work.join("a.txt"), "three\n").unwrap();
    git(&rig.work, &["commit", "-q", "-am", "three"]);
    git(&rig.work, &["push", "-q", "origin", "main"]);
    let chat = rig.chat("c2");
    clone(&chat, &rig.remote, "main").unwrap();
    assert_eq!(rig.mirrors().len(), 1, "one mirror per remote: {:?}", rig.mirrors());
    assert_eq!(std::fs::read_to_string(chat.join("a.txt")).unwrap(), "three\n");
    assert_eq!(git(&chat, &["rev-parse", "HEAD"]), git(&rig.work, &["rev-parse", "main"]));
}

#[test]
fn a_branch_the_remote_lacks_starts_at_its_default_head() {
    let rig = rig(true);
    let chat = rig.chat("c1");
    clone(&chat, &rig.remote, "new-work").unwrap();
    assert!(borrows(&chat));
    assert_eq!(git(&chat, &["rev-parse", "--abbrev-ref", "HEAD"]), "new-work");
    assert_eq!(git(&chat, &["rev-parse", "HEAD"]), git(&rig.work, &["rev-parse", "main"]));
}

#[test]
fn a_remote_without_partial_clone_still_starts() {
    let rig = rig(false);
    let chat = rig.chat("c1");
    clone(&chat, &rig.remote, "main").unwrap();
    assert_eq!(std::fs::read_to_string(chat.join("a.txt")).unwrap(), "two\n");
    assert_eq!(git(&chat, &["rev-parse", "--abbrev-ref", "@{upstream}"]), "origin/main");
    git(&chat, &["fsck", "--no-progress"]);
}

#[test]
fn a_mirror_that_cannot_be_made_leaves_the_start_to_the_full_clone() {
    let rig = rig(true);
    std::fs::write(rig.base.join("chats/.cmux-git-mirrors"), "in the way").unwrap();
    let chat = rig.chat("c1");
    clone(&chat, &rig.remote, "feature").unwrap();
    assert!(!borrows(&chat), "the full clone, not the mirror");
    assert_eq!(std::fs::read_to_string(chat.join("a.txt")).unwrap(), "two\n");
    assert_eq!(git(&chat, &["rev-parse", "--abbrev-ref", "@{upstream}"]), "origin/feature");
}

#[test]
fn a_snapshot_into_a_new_folder_gets_its_base_from_the_mirror() {
    let rig = rig(true);
    let base = git(&rig.work, &["rev-parse", "main~1"]);
    let cwd = Cwd::Git {
        remote: rig.remote.clone(),
        branch: "main".to_owned(),
        base: base.clone(),
        bundle: vec![],
        patch: vec![],
    };
    let chat = rig.chat("c1");
    place(&chat, true, &cwd, &[], &[], "chat-1").unwrap();
    assert!(borrows(&chat));
    assert_eq!(git(&chat, &["rev-parse", "HEAD"]), base);
    assert_eq!(std::fs::read_to_string(chat.join("a.txt")).unwrap(), "one\n");
    assert_eq!(git(&chat, &["rev-parse", super::folder::BASE_REF]), base);
    git(&chat, &["fsck", "--no-progress"]);
}
