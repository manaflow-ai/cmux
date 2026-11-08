use super::*;
use std::io::Write as _;
use std::process::{Command, Stdio};

/// Runs a fixed script on this machine, as `run/session_move.rs`'s `run_here` does.
fn here(script: &str, input: &[u8]) -> Result<RemoteOut> {
    let mut child = Command::new("/bin/sh")
        .arg("-c")
        .arg(script)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    child.stdin.take().unwrap().write_all(input)?;
    let out = child.wait_with_output()?;
    Ok(RemoteOut {
        ok: out.status.success(),
        stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
    })
}

fn sh(dir: &Path, script: &str) -> String {
    let out = Command::new("/bin/sh").arg("-c").arg(script).current_dir(dir).output().unwrap();
    assert!(out.status.success(), "{script}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).into_owned()
}

/// A repository with one commit: `kept.txt`, `gone.txt`, `bin.dat` and an ignored `target/`.
fn repo(dir: &Path) {
    sh(
        dir,
        "git init -q -b lane/t . && git config user.email t@t && git config user.name t \
         && printf 'one\\n' > kept.txt && printf 'bye\\n' > gone.txt \
         && printf '\\000\\001\\002' > bin.dat && printf 'target/\\n' > .gitignore \
         && git add -A && git commit -qm base",
    );
}

/// Applies `carry` in `dir` the way the target does, through [`APPLY_SCRIPT`].
fn apply(dir: &Path, carry: &Carry) -> RemoteOut {
    here(APPLY_SCRIPT, &apply_input(&dir.to_string_lossy(), carry)).unwrap()
}

#[test]
fn uncommitted_work_arrives_in_a_fresh_checkout_of_the_same_commit() {
    let src = tempfile::tempdir().unwrap();
    let dst = tempfile::tempdir().unwrap();
    repo(src.path());
    sh(
        src.path(),
        "printf 'two\\n' >> kept.txt && git add kept.txt && printf 'three\\n' >> kept.txt \
         && rm gone.txt && printf '\\003\\004' > bin.dat && mkdir -p new/deep \
         && printf 'fresh\\n' > new/deep/file.rs && printf 'SECRET=1\\n' > .env \
         && mkdir -p target && printf 'build\\n' > target/out \
         && printf 'spaced\\n' > 'with space é.md'",
    );
    // `--no-optional-locks`: the status read never refreshes the index it is compared with.
    let status = "git --no-optional-locks status --porcelain";
    let index = src.path().join(".git/index");
    let (index_before, status_before) = (std::fs::read(&index).unwrap(), sh(src.path(), status));

    let carry = snapshot(&here, src.path(), true).unwrap();

    // The person's checkout is as it was: same index, same status.
    assert_eq!(std::fs::read(&index).unwrap(), index_before);
    assert_eq!(sh(src.path(), status), status_before);
    assert_eq!(carry.base, sh(src.path(), "git rev-parse HEAD").trim());
    assert_eq!(carry.files, 5, "kept.txt, gone.txt, bin.dat, new/deep/file.rs, with space é.md");
    assert_eq!(carry.left_out.len(), 1, "{:?}", carry.left_out);
    assert_eq!(carry.left_out[0].0, ".env");

    sh(dst.path(), &format!("git clone -q --branch lane/t {} .", src.path().display()));
    let out = apply(dst.path(), &carry);
    assert!(out.ok, "{}", out.stderr);
    let read = |d: &Path, f: &str| std::fs::read(d.join(f)).ok();
    for f in ["kept.txt", "bin.dat", "new/deep/file.rs", "with space é.md"] {
        assert_eq!(read(dst.path(), f), read(src.path(), f), "{f}");
    }
    assert!(!dst.path().join("gone.txt").exists(), "a deletion is carried");
    assert!(!dst.path().join(".env").exists(), "a likely secret stays behind");
    assert!(!dst.path().join("target/out").exists(), "an ignored file stays behind");
    // It lands as uncommitted work, never as a commit.
    assert_eq!(sh(dst.path(), "git rev-parse HEAD"), sh(src.path(), "git rev-parse HEAD"));
}

#[test]
fn a_worktree_at_another_commit_takes_nothing() {
    let src = tempfile::tempdir().unwrap();
    let dst = tempfile::tempdir().unwrap();
    repo(src.path());
    sh(src.path(), "printf 'two\\n' >> kept.txt");
    let carry = snapshot(&here, src.path(), true).unwrap();
    sh(dst.path(), &format!("git clone -q --branch lane/t {} .", src.path().display()));
    sh(
        dst.path(),
        "git config user.email t@t && git config user.name t && git commit -qm moved --allow-empty",
    );
    let out = apply(dst.path(), &carry);
    assert!(!out.ok && out.stderr.contains("the new worktree is at"), "{}", out.stderr);
    assert_eq!(std::fs::read_to_string(dst.path().join("kept.txt")).unwrap(), "one\n");
}

#[test]
fn a_clean_checkout_carries_an_empty_patch() {
    let src = tempfile::tempdir().unwrap();
    repo(src.path());
    let carry = snapshot(&here, src.path(), true).unwrap();
    assert!(carry.patch.is_empty());
    assert_eq!(carry.files, 0);
}

#[test]
fn a_registry_file_on_another_machine_stays_there_unread() {
    let src = tempfile::tempdir().unwrap();
    repo(src.path());
    sh(
        src.path(),
        "printf 'registry=https://example.test/\\n' > .npmrc && printf 'x\\n' > notes.md",
    );
    // Here its content is read: no token, so it goes.
    let local = snapshot(&here, src.path(), true).unwrap();
    assert!(local.left_out.is_empty(), "{:?}", local.left_out);
    assert_eq!(local.files, 2);
    // From another machine it is not read, so it stays.
    let remote = snapshot(&here, src.path(), false).unwrap();
    assert_eq!(remote.left_out.iter().map(|l| l.0.as_str()).collect::<Vec<_>>(), [".npmrc"]);
    assert_eq!(remote.files, 1);
}

#[test]
fn a_file_named_like_pathspec_magic_carries_only_itself() {
    let src = tempfile::tempdir().unwrap();
    repo(src.path());
    sh(
        src.path(),
        "printf 'x\\n' > ':(glob)**' && printf 'SECRET=1\\n' > .env && mkdir -p keys \\
         && printf 'k\\n' > keys/id_ed25519",
    );
    let carry = snapshot(&here, src.path(), true).unwrap();
    assert_eq!(carry.files, 1, "only the oddly named file: {:?}", carry.left_out);
    let patch = String::from_utf8_lossy(&carry.patch);
    assert!(!patch.contains("SECRET") && !patch.contains("id_ed25519"), "{patch}");
}

#[test]
fn a_head_that_moves_between_the_two_reads_refuses() {
    let src = tempfile::tempdir().unwrap();
    repo(src.path());
    sh(src.path(), "printf 'two\\n' >> kept.txt");
    let moves = |script: &str, input: &[u8]| {
        let out = here(script, input);
        if script == LIST_SCRIPT {
            sh(src.path(), "git commit -qam next");
        }
        out
    };
    let e = snapshot(&moves, src.path(), true).unwrap_err().to_string();
    assert!(e.contains("HEAD moved"), "{e}");
}

#[test]
fn a_base_that_moved_refuses() {
    let carry = Carry { base: "a".repeat(40), patch: vec![], files: 0, left_out: vec![] };
    assert!(check_base(&carry, &"a".repeat(40)).is_ok());
    assert!(check_base(&carry, &"b".repeat(40)).is_err());
}
