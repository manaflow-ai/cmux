//! A folder that is no git checkout goes to the Cloud as a tar of its files, with no
//! `.gitignore` to leave anything out. The default ignore set (`ignore.rs`) keeps the usual
//! version control folders, dependency trees and credential stores behind (security review of
//! cmux#52931, item 3); before it, every file the name-based secrets rule did not catch went.

use std::path::Path;

use super::folder::{self, Folder};

fn put(top: &Path, relative: &str) {
    let path = top.join(relative);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, b"x").unwrap();
}

fn names(tar: &[u8]) -> Vec<String> {
    let mut archive = tar::Archive::new(tar);
    let mut names: Vec<String> = archive
        .entries()
        .unwrap()
        .map(|entry| entry.unwrap().path().unwrap().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

#[test]
fn a_plain_folder_leaves_version_control_dependencies_and_credentials_behind() {
    let dir = tempfile::tempdir().unwrap();
    let top = dir.path();
    for kept in ["src/main.rs", "README.md", "docs/keys.md"] {
        put(top, kept);
    }
    for left in [
        ".hg/store/data",
        ".svn/entries",
        ".jj/repo/store",
        "node_modules/left-pad/index.js",
        "web/node_modules/react/index.js",
        ".ssh/config",
        ".aws/credentials",
        ".gnupg/pubring.kbx",
        ".docker/config.json",
        ".kube/config",
        ".git-credentials",
        "release.jks",
        "app.keystore",
        "vault.kdbx",
        ".env.production",
    ] {
        put(top, left);
    }
    let Folder::Plain(plain) = folder::read(top, 1 << 20).unwrap() else {
        panic!("a folder that is no checkout goes as a tar")
    };
    assert_eq!(names(&plain.tar), ["README.md", "docs/keys.md", "src/main.rs"]);
}

/// A chat's folder in the home folder's own repository (a dotfiles `~/.git`) goes as the tar of
/// itself, never from that repository's top: its untracked files are the whole home folder, the
/// Photos library included (LAUNCH-NO-TCC-PROMPTS). For another home folder the same repository
/// is a checkout, and the folder goes from its top as before.
#[test]
fn a_folder_in_the_home_folders_repository_goes_as_itself() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let git = |dir: &Path, args: &[&str]| {
        let out = std::process::Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(["-c", "user.name=t", "-c", "user.email=t@example.com"])
            .args(["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"])
            .args(args)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .output()
            .unwrap();
        assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    };
    git(home, &["init", "-q"]);
    put(home, ".zshrc");
    std::fs::write(home.join(".gitignore"), "*.log\n").unwrap();
    git(home, &["add", ".zshrc", ".gitignore"]);
    git(home, &["commit", "-qm", "dotfiles"]);
    put(home, "Pictures/Photos Library.photoslibrary/database/Photos.sqlite");
    put(home, "Documents/notes.txt");
    put(home, "itp-rs/tools/run.py");
    put(home, "itp-rs/tools/debug.log");
    let chat = home.join("itp-rs/tools");

    let Folder::Plain(plain) = folder::read_in(&chat, 1 << 20, Some(home)).unwrap() else {
        panic!("a folder in the home folder's repository goes as a tar")
    };
    assert_eq!(names(&plain.tar), ["run.py"], "below the chat's folder, ignore rules kept");
    // A chat in the home folder itself takes what the repository tracks, no untracked file.
    let Folder::Plain(plain) = folder::read_in(home, 1 << 20, Some(home)).unwrap() else {
        panic!("the home folder's repository with no remote goes as a tar")
    };
    assert_eq!(names(&plain.tar), [".gitignore", ".zshrc"]);
    // A repository of its own below the home folder goes from its own top, as any checkout.
    let app = home.join("code/app");
    std::fs::create_dir_all(&app).unwrap();
    git(app.as_path(), &["init", "-q"]);
    put(&app, "new.rs");
    let Folder::Plain(plain) = folder::read_in(&app, 1 << 20, Some(home)).unwrap() else {
        panic!("a checkout with no remote goes as a tar")
    };
    assert_eq!(names(&plain.tar), ["new.rs"]);

    let elsewhere = tempfile::tempdir().unwrap();
    let Folder::Plain(plain) = folder::read_in(&chat, 1 << 20, Some(elsewhere.path())).unwrap()
    else {
        panic!("a checkout with no remote goes as a tar")
    };
    let listed = names(&plain.tar);
    assert!(listed.contains(&"Documents/notes.txt".to_owned()), "{listed:?}");
}
