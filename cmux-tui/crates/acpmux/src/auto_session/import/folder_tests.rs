//! A handback into the laptop's own folder, driven through the real export (`export/folder.rs`)
//! and the real import (`place`) on real git and tar in temp folders.
#![cfg(unix)]

use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::process::Command;

use cmux_auto_session::wire::Cwd;

use super::folder::place;
use crate::auto_session::export::folder::{self, Folder};

const BIN: &[u8] = &[0, 159, 146, 150, 255, 0, 10, 13, 1];
const BIN_CLOUD: &[u8] = &[255, 0, 0, 7, 200, 0, 13, 10];

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

fn write(path: &Path, bytes: &[u8], mode: u32) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, bytes).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).unwrap();
}

fn mode(path: &Path) -> u32 {
    if std::fs::metadata(path).unwrap().permissions().mode() & 0o111 == 0o111 {
        0o755
    } else {
        0o644
    }
}

/// A laptop checkout and the Cloud machine's clone of the same remote, both at one commit that
/// has `a.txt`, `b.txt`, `sub/s.txt`.
struct Rig {
    _root: tempfile::TempDir,
    laptop: PathBuf,
    cloud: PathBuf,
}

fn rig() -> Rig {
    let root = tempfile::tempdir().unwrap();
    let base = root.path().to_path_buf();
    let origin = base.join("origin.git");
    git(&base, &["init", "-q", "--bare", "-b", "main", origin.to_str().unwrap()]);
    let laptop = base.join("laptop");
    git(&base, &["init", "-q", "-b", "main", laptop.to_str().unwrap()]);
    git(&laptop, &["remote", "add", "origin", origin.to_str().unwrap()]);
    write(&laptop.join("a.txt"), b"a\n", 0o644);
    write(&laptop.join("b.txt"), b"b\n", 0o644);
    write(&laptop.join("sub/s.txt"), b"s\n", 0o644);
    git(&laptop, &["add", "."]);
    git(&laptop, &["commit", "-q", "-m", "one"]);
    git(&laptop, &["push", "-q", "-u", "origin", "main"]);
    let cloud = base.join("cloud");
    git(&base, &["clone", "-q", origin.to_str().unwrap(), cloud.to_str().unwrap()]);
    Rig { _root: root, laptop, cloud }
}

/// The Cloud's copy of the folder at `from`, handed back into `into`.
fn hand_back(from: &Path, into: &Path) -> Result<(), String> {
    let Folder::Git(copy) = folder::read(from, u64::MAX).unwrap() else { panic!("a git folder") };
    let cwd = Cwd::Git {
        remote: copy.remote,
        branch: copy.branch,
        base: copy.base,
        bundle: vec![],
        patch: vec![],
    };
    let Cwd::Git { .. } = &cwd else { unreachable!() };
    place(into, false, &cwd, &copy.bundle, &copy.patch, "chat-2")
}

#[test]
fn an_identical_untracked_file_is_no_conflict() {
    let rig = rig();
    for dir in [&rig.laptop, &rig.cloud] {
        write(&dir.join("new/bin.dat"), BIN, 0o644);
        write(&dir.join("run.sh"), b"#!/bin/sh\n", 0o755);
    }
    write(&rig.cloud.join("a.txt"), b"a by the cloud\n", 0o644);
    hand_back(&rig.cloud, &rig.laptop).unwrap();
    assert_eq!(std::fs::read(rig.laptop.join("new/bin.dat")).unwrap(), BIN);
    assert_eq!(std::fs::read(rig.laptop.join("run.sh")).unwrap(), b"#!/bin/sh\n");
    assert_eq!(mode(&rig.laptop.join("run.sh")), 0o755);
    assert_eq!(std::fs::read(rig.laptop.join("a.txt")).unwrap(), b"a by the cloud\n");
    // Nothing differed, so nothing is kept aside.
    assert!(!rig.laptop.join(".git/cmux-auto/quarantine/chat-2/run.sh").exists());
}

#[test]
fn a_modified_untracked_file_is_set_aside_and_the_clouds_goes_in() {
    let rig = rig();
    write(&rig.laptop.join("new/bin.dat"), BIN, 0o644);
    write(&rig.laptop.join("run.sh"), b"#!/bin/sh\necho laptop\n", 0o644);
    write(&rig.cloud.join("new/bin.dat"), BIN_CLOUD, 0o644);
    write(&rig.cloud.join("run.sh"), b"#!/bin/sh\necho cloud\n", 0o755);
    hand_back(&rig.cloud, &rig.laptop).unwrap();
    assert_eq!(std::fs::read(rig.laptop.join("new/bin.dat")).unwrap(), BIN_CLOUD);
    assert_eq!(std::fs::read(rig.laptop.join("run.sh")).unwrap(), b"#!/bin/sh\necho cloud\n");
    assert_eq!(mode(&rig.laptop.join("run.sh")), 0o755);
    let kept = rig.laptop.join(".git/cmux-auto/quarantine/chat-2");
    assert_eq!(std::fs::read(kept.join("new/bin.dat")).unwrap(), BIN);
    assert_eq!(std::fs::read(kept.join("run.sh")).unwrap(), b"#!/bin/sh\necho laptop\n");
}

#[test]
fn a_chat_in_a_subfolder_gets_the_clouds_edit_of_a_root_file() {
    let rig = rig();
    write(&rig.cloud.join("a.txt"), b"a at the root by the cloud\n", 0o644);
    write(&rig.cloud.join("sub/s.txt"), b"s by the cloud\n", 0o644);
    hand_back(&rig.cloud.join("sub"), &rig.laptop.join("sub")).unwrap();
    assert_eq!(std::fs::read(rig.laptop.join("a.txt")).unwrap(), b"a at the root by the cloud\n");
    assert_eq!(std::fs::read(rig.laptop.join("sub/s.txt")).unwrap(), b"s by the cloud\n");
}

#[test]
fn a_file_the_cloud_deleted_is_gone_here() {
    let rig = rig();
    std::fs::remove_file(rig.cloud.join("b.txt")).unwrap();
    hand_back(&rig.cloud, &rig.laptop).unwrap();
    assert!(!rig.laptop.join("b.txt").exists());
}

#[test]
fn a_conflicting_local_edit_is_kept_under_a_ref() {
    let rig = rig();
    write(&rig.laptop.join("a.txt"), b"a by the laptop\n", 0o644);
    write(&rig.cloud.join("a.txt"), b"a by the cloud\n", 0o644);
    hand_back(&rig.cloud, &rig.laptop).unwrap();
    assert_eq!(std::fs::read(rig.laptop.join("a.txt")).unwrap(), b"a by the cloud\n");
    let kept = git(&rig.laptop, &["show", "refs/cmux/auto/before/chat-2:a.txt"]);
    assert_eq!(kept, "a by the laptop");
}

#[test]
fn a_plain_folder_handback_never_resurrects_or_overwrites() {
    let root = tempfile::tempdir().unwrap();
    let cloud = root.path().join("cloud");
    let laptop = root.path().join("laptop");
    for dir in [&cloud, &laptop] {
        write(&dir.join("keep.txt"), b"keep\n", 0o644);
        write(&dir.join("gone.txt"), b"gone\n", 0o644);
    }
    std::fs::remove_file(cloud.join("gone.txt")).unwrap();
    // The laptop changed a file after the copy went out.
    write(&laptop.join("keep.txt"), b"keep, edited on the laptop\n", 0o644);
    let Folder::Plain(copy) = folder::read(&cloud, u64::MAX).unwrap() else { panic!("a tar") };
    let cwd = Cwd::Folder { tar: vec![] };
    let placed = place(&laptop, false, &cwd, &copy.tar, &[], "chat-2");
    // A snapshot of a plain folder cannot say what to delete, so it is not laid over a folder.
    assert!(placed.is_err(), "a plain folder is blocked, not overlaid");
    assert_eq!(std::fs::read(laptop.join("keep.txt")).unwrap(), b"keep, edited on the laptop\n");
}
