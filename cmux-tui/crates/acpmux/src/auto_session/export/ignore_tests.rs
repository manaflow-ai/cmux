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
