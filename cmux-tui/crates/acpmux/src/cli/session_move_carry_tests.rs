use super::*;

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
fn apply(dir: &Path, carry: &Carry) -> std::process::Output {
    let mut child = Command::new("/bin/sh")
        .arg("-c")
        .arg(APPLY_SCRIPT)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(&apply_input(&dir.to_string_lossy(), carry)).unwrap();
    child.wait_with_output().unwrap()
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
         && mkdir -p target && printf 'build\\n' > target/out",
    );
    // `--no-optional-locks`: the status read never refreshes the index it is compared with.
    let status = "git --no-optional-locks status --porcelain";
    let index = src.path().join(".git/index");
    let (index_before, status_before) = (std::fs::read(&index).unwrap(), sh(src.path(), status));

    let carry = snapshot(src.path()).unwrap();

    // The person's checkout is as it was: same index, same status.
    assert_eq!(std::fs::read(&index).unwrap(), index_before);
    assert_eq!(sh(src.path(), status), status_before);
    assert_eq!(carry.base, sh(src.path(), "git rev-parse HEAD").trim());
    assert_eq!(carry.files, 4, "kept.txt, gone.txt, bin.dat, new/deep/file.rs");
    assert_eq!(carry.left_out.len(), 1, "{:?}", carry.left_out);
    assert_eq!(carry.left_out[0].0, ".env");

    sh(dst.path(), &format!("git clone -q --branch lane/t {} .", src.path().display()));
    let out = apply(dst.path(), &carry);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let read = |d: &Path, f: &str| std::fs::read(d.join(f)).ok();
    for f in ["kept.txt", "bin.dat", "new/deep/file.rs"] {
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
    let carry = snapshot(src.path()).unwrap();
    sh(dst.path(), &format!("git clone -q --branch lane/t {} .", src.path().display()));
    sh(
        dst.path(),
        "git config user.email t@t && git config user.name t && git commit -qm moved --allow-empty",
    );
    let out = apply(dst.path(), &carry);
    assert_eq!(out.status.code(), Some(4), "{}", String::from_utf8_lossy(&out.stderr));
    assert_eq!(std::fs::read_to_string(dst.path().join("kept.txt")).unwrap(), "one\n");
}

#[test]
fn a_clean_checkout_carries_an_empty_patch() {
    let src = tempfile::tempdir().unwrap();
    repo(src.path());
    let carry = snapshot(src.path()).unwrap();
    assert!(carry.patch.is_empty());
    assert_eq!(carry.files, 0);
}

#[test]
fn the_wire_form_reads_back() {
    let carry = Carry {
        base: "a".repeat(40),
        patch: vec![0, 1, 2, b'\n', 255],
        files: 2,
        left_out: vec![(".env".into(), "it may hold secrets".into())],
    };
    assert_eq!(Carry::from_wire(&carry.to_wire()).unwrap(), carry);
    assert!(Carry::from_wire("{\"base\":\"main\"}\n\n").is_err(), "a base that is no commit");
}

#[test]
fn a_base_that_moved_refuses() {
    let carry = Carry { base: "a".repeat(40), patch: vec![], files: 0, left_out: vec![] };
    assert!(check_base(&carry, &"a".repeat(40)).is_ok());
    assert!(check_base(&carry, &"b".repeat(40)).is_err());
}
