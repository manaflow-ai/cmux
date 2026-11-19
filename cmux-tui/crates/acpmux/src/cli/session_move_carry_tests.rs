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
         && touch empty.txt && git add -A && git commit -qm base",
    );
}

/// Applies `carry` in `dir` the way the target does, through [`APPLY_SCRIPT`].
fn apply(dir: &Path, carry: &Carry) -> RemoteOut {
    here(APPLY_SCRIPT, &apply_input(&dir.to_string_lossy(), carry).unwrap()).unwrap()
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
    assert!(sh(dst.path(), "git diff --cached -- kept.txt").contains("+two"));
    assert!(!sh(dst.path(), "git diff --cached -- kept.txt").contains("+three"));
    assert!(sh(dst.path(), "git diff -- kept.txt").contains("+three"));
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
fn a_failed_apply_leaves_the_target_safe_for_a_retry() {
    let src = tempfile::tempdir().unwrap();
    let dst = tempfile::tempdir().unwrap();
    repo(src.path());
    sh(
        src.path(),
        "printf 'two\\n' >> kept.txt && git add kept.txt && printf 'three\\n' >> kept.txt",
    );
    let carry = snapshot(&here, src.path(), true).unwrap();
    sh(dst.path(), &format!("git clone -q --branch lane/t {} .", src.path().display()));
    sh(dst.path(), "printf 'target-only\\n' > kept.txt");
    let index_before = std::fs::read(dst.path().join(".git/index")).unwrap();
    let out = apply(dst.path(), &carry);
    assert!(!out.ok, "a conflicting target must refuse the apply");
    assert_eq!(std::fs::read_to_string(dst.path().join("kept.txt")).unwrap(), "target-only\n");
    assert_eq!(std::fs::read(dst.path().join(".git/index")).unwrap(), index_before);

    sh(dst.path(), "git restore kept.txt");
    let out = apply(dst.path(), &carry);
    assert!(out.ok, "retry after restoring the target: {}", out.stderr);
    assert!(sh(dst.path(), "git diff --cached -- kept.txt").contains("+two"));
    assert!(sh(dst.path(), "git diff -- kept.txt").contains("+three"));
}

#[test]
fn a_clean_checkout_carries_an_empty_patch() {
    let src = tempfile::tempdir().unwrap();
    repo(src.path());
    let carry = snapshot(&here, src.path(), true).unwrap();
    assert!(carry.patch.is_empty());
    assert!(carry.staged_patch.is_empty());
    assert_eq!(carry.files, 0);
}

#[test]
fn staged_only_work_arrives_staged() {
    let src = tempfile::tempdir().unwrap();
    let dst = tempfile::tempdir().unwrap();
    repo(src.path());
    sh(src.path(), "printf 'two\\n' >> kept.txt && git add kept.txt");
    let carry = snapshot(&here, src.path(), true).unwrap();
    assert!(!carry.staged_patch.is_empty());
    sh(dst.path(), &format!("git clone -q --branch lane/t {} .", src.path().display()));
    let out = apply(dst.path(), &carry);
    assert!(out.ok, "{}", out.stderr);
    assert!(sh(dst.path(), "git diff --cached -- kept.txt").contains("+two"));
    assert!(sh(dst.path(), "git diff --quiet && echo clean").contains("clean"));
}

#[test]
fn unstaged_only_work_arrives_unstaged() {
    let src = tempfile::tempdir().unwrap();
    let dst = tempfile::tempdir().unwrap();
    repo(src.path());
    sh(src.path(), "printf 'two\\n' >> kept.txt");
    let carry = snapshot(&here, src.path(), true).unwrap();
    assert!(carry.staged_patch.is_empty());
    sh(dst.path(), &format!("git clone -q --branch lane/t {} .", src.path().display()));
    let out = apply(dst.path(), &carry);
    assert!(out.ok, "{}", out.stderr);
    assert!(sh(dst.path(), "git diff --cached --quiet && echo clean").contains("clean"));
    assert!(sh(dst.path(), "git diff -- kept.txt").contains("+two"));
}

/// Compare the index and filesystem independently: a combined HEAD diff hides partial staging.
#[test]
fn index_and_worktree_snapshots_match_independently_for_every_change_kind() {
    let cases = [
        (
            "partial text",
            "printf 'two\\n' >> kept.txt && git add kept.txt && printf 'three\\n' >> kept.txt",
            1,
        ),
        (
            "partial binary",
            "printf '\\000\\004' > bin.dat && git add bin.dat && printf '\\000\\005' > bin.dat",
            1,
        ),
        ("staged deletion", "git rm -q gone.txt", 1),
        (
            "staged rename and edit",
            "git mv kept.txt renamed.txt && printf 'two\\n' >> renamed.txt",
            2,
        ),
        (
            "staged addition then deletion",
            "printf 'new\\n' > new.txt && git add new.txt && rm new.txt",
            1,
        ),
        (
            "staging canceled in worktree",
            "printf 'two\\n' >> kept.txt && git add kept.txt && git show HEAD:kept.txt > kept.txt",
            1,
        ),
        (
            "staged deletion then restoration",
            "git rm -q gone.txt && git show HEAD:gone.txt > gone.txt",
            1,
        ),
        ("intent to add", "printf 'new\\n' > new.txt && git add -N new.txt", 1),
        (
            "intent to add then delete",
            "printf 'new\\n' > new.txt && git add -N new.txt && rm new.txt",
            1,
        ),
        ("empty intent to add", "touch new.txt && git add -N new.txt", 1),
        (
            "executable intent to add",
            "printf 'new\\n' > new.txt && chmod +x new.txt && git add -N new.txt",
            1,
        ),
        (
            "intent and staged additions",
            "printf 'new\\n' > new.txt && git add -N new.txt && printf 'staged\\n' > renamed.txt && git add renamed.txt",
            2,
        ),
        ("intent replacing tracked file", "git rm -q --cached kept.txt && git add -N kept.txt", 1),
        (
            "intent replacing tracked empty file",
            "git rm -q --cached empty.txt && git add -N empty.txt",
            1,
        ),
        ("intent symlink", "ln -s kept.txt newlink && git add -N newlink", 1),
        ("deleted intent symlink", "ln -s kept.txt newlink && git add -N newlink && rm newlink", 1),
        ("untracked unusual names", "printf 'new\\n' > 'space name'", 2),
    ];
    for (name, setup, files) in cases {
        let src = tempfile::tempdir().unwrap();
        let dst = tempfile::tempdir().unwrap();
        repo(src.path());
        sh(src.path(), setup);
        if name == "untracked unusual names" {
            std::fs::write(src.path().join("line\nbreak"), b"newline name\n").unwrap();
        }
        let index_before = std::fs::read(src.path().join(".git/index")).unwrap();
        let refs_before = sh(src.path(), "git show-ref --head");
        let index_entries = "git --no-optional-locks ls-files --stage -z";
        let staged_diff = "git --no-optional-locks diff --cached --binary --no-ext-diff";
        let unstaged_diff = "git --no-optional-locks diff --binary --no-ext-diff";
        let source_state =
            [index_entries, staged_diff, unstaged_diff].map(|cmd| sh(src.path(), cmd));
        let paths = [
            "kept.txt",
            "empty.txt",
            "newlink",
            "gone.txt",
            "bin.dat",
            "renamed.txt",
            "new.txt",
            "space name",
            "line\nbreak",
        ];
        let source_bytes = paths.map(|p| std::fs::read(src.path().join(p)).ok());
        let source_links = paths.map(|p| std::fs::read_link(src.path().join(p)).ok());
        let carry = snapshot(&here, src.path(), true).unwrap();
        assert_eq!(carry.files, files, "{name}");
        assert_eq!(
            carry.record()["bytes"],
            carry.patch.len()
                + carry.staged_patch.len()
                + carry.intent_to_add.len()
                + carry.intent_placeholders.len(),
            "{name}"
        );
        sh(dst.path(), &format!("git clone -q --branch lane/t {} .", src.path().display()));
        let out = apply(dst.path(), &carry);
        assert!(out.ok, "{name}: {}", out.stderr);
        for (cmd, expected) in [index_entries, staged_diff, unstaged_diff].iter().zip(&source_state)
        {
            assert_eq!(&sh(dst.path(), cmd), expected, "{name}: {cmd}");
            assert_eq!(&sh(src.path(), cmd), expected, "{name}: source {cmd}");
        }
        for (path, bytes) in paths.iter().zip(&source_bytes) {
            assert_eq!(&std::fs::read(dst.path().join(path)).ok(), bytes, "{name}: {path}");
            assert_eq!(&std::fs::read(src.path().join(path)).ok(), bytes, "{name}: source {path}");
        }
        for (path, link) in paths.iter().zip(&source_links) {
            assert_eq!(
                &std::fs::read_link(dst.path().join(path)).ok(),
                link,
                "{name}: link {path}"
            );
        }
        assert_eq!(std::fs::read(src.path().join(".git/index")).unwrap(), index_before, "{name}");
        assert_eq!(sh(src.path(), "git show-ref --head"), refs_before, "{name}");
        assert_eq!(sh(dst.path(), "git rev-parse HEAD").trim(), carry.base, "{name}");
        // Retrying an already-applied carry must fail without changing either target snapshot.
        let retry = apply(dst.path(), &carry);
        if !carry.patch.is_empty() || !carry.staged_patch.is_empty() {
            assert!(!retry.ok, "{name}: repeated patch apply must refuse");
        } else {
            assert!(retry.ok, "{name}: replaying only flags is idempotent");
        }
        for (cmd, expected) in [index_entries, staged_diff, unstaged_diff].iter().zip(&source_state)
        {
            assert_eq!(&sh(dst.path(), cmd), expected, "{name}: retry {cmd}");
        }
        for (path, bytes) in paths.iter().zip(&source_bytes) {
            assert_eq!(&std::fs::read(dst.path().join(path)).ok(), bytes, "{name}: retry {path}");
        }
    }
}

#[test]
fn intent_paths_keep_non_utf8_bytes_and_line_breaks() {
    use std::os::unix::ffi::OsStringExt as _;
    let src = tempfile::tempdir().unwrap();
    let dst = tempfile::tempdir().unwrap();
    repo(src.path());
    let name = std::ffi::OsString::from_vec(b"intent-\xff\nfile".to_vec());
    std::fs::write(src.path().join(&name), b"intent bytes\n").unwrap();
    assert!(
        Command::new("git")
            .args(["add", "-N", "--"])
            .arg(&name)
            .current_dir(src.path())
            .status()
            .unwrap()
            .success()
    );
    let index = std::fs::read(src.path().join(".git/index")).unwrap();
    let carry = snapshot(&here, src.path(), true).unwrap();
    assert_eq!(carry.files, 1);
    sh(dst.path(), &format!("git clone -q --branch lane/t {} .", src.path().display()));
    let out = apply(dst.path(), &carry);
    assert!(out.ok, "{}", out.stderr);
    let entries = |dir: &Path| {
        let out = Command::new("git")
            .args(["ls-files", "--stage", "-z"])
            .current_dir(dir)
            .output()
            .unwrap();
        assert!(out.status.success());
        out.stdout
    };
    assert_eq!(entries(src.path()), entries(dst.path()));
    assert_eq!(std::fs::read(src.path().join(".git/index")).unwrap(), index);
    assert_eq!(std::fs::read(dst.path().join(&name)).unwrap(), b"intent bytes\n");
    assert_eq!(
        sh(src.path(), "git --no-optional-locks diff --binary"),
        sh(dst.path(), "git --no-optional-locks diff --binary")
    );
}

#[test]
fn worktree_apply_failure_preserves_the_original_index() {
    let src = tempfile::tempdir().unwrap();
    let dst = tempfile::tempdir().unwrap();
    repo(src.path());
    sh(
        src.path(),
        "printf 'two\\n' >> kept.txt && git add kept.txt && printf 'three\\n' >> kept.txt",
    );
    let carry = snapshot(&here, src.path(), true).unwrap();
    sh(dst.path(), &format!("git clone -q --branch lane/t {} .", src.path().display()));
    let before = std::fs::read(dst.path().join(".git/index")).unwrap();
    // Inject a failure only at the final write, after both real preflights and the index apply.
    let failing = APPLY_SCRIPT.replace(
        "if ! git -c core.fsmonitor=false -C \"$top\" apply --binary --whitespace=nowarn \"$s/patch\"; then",
        "if ! false; then",
    );
    assert_ne!(failing, APPLY_SCRIPT);
    let out = here(&failing, &apply_input(&dst.path().to_string_lossy(), &carry).unwrap()).unwrap();
    assert!(!out.ok);
    assert_eq!(std::fs::read(dst.path().join(".git/index")).unwrap(), before);
    assert!(!dst.path().join(".git/index.lock").exists());
    assert_eq!(std::fs::read(dst.path().join("kept.txt")).unwrap(), b"one\n");
    assert!(apply(dst.path(), &carry).ok, "the discarded candidate permits a fresh retry");
}

#[test]
fn failed_index_publication_restores_the_worktree() {
    let src = tempfile::tempdir().unwrap();
    let dst = tempfile::tempdir().unwrap();
    repo(src.path());
    sh(
        src.path(),
        "printf 'two\\n' >> kept.txt && git add kept.txt && printf 'three\\n' >> kept.txt",
    );
    let carry = snapshot(&here, src.path(), true).unwrap();
    sh(dst.path(), &format!("git clone -q --branch lane/t {} .", src.path().display()));
    let index = std::fs::read(dst.path().join(".git/index")).unwrap();
    let failing =
        APPLY_SCRIPT.replace("if ! mv -- \"$real.lock\" \"$real\"; then", "if ! false; then");
    assert_ne!(failing, APPLY_SCRIPT);
    let out = here(&failing, &apply_input(&dst.path().to_string_lossy(), &carry).unwrap()).unwrap();
    assert!(!out.ok);
    assert_eq!(std::fs::read(dst.path().join(".git/index")).unwrap(), index);
    assert_eq!(std::fs::read(dst.path().join("kept.txt")).unwrap(), b"one\n");
    assert!(!dst.path().join(".git/index.lock").exists());
    assert!(apply(dst.path(), &carry).ok);
}

#[test]
fn unresolved_conflicts_refuse_without_changing_the_source() {
    let src = tempfile::tempdir().unwrap();
    repo(src.path());
    sh(
        src.path(),
        "git checkout -qb side && printf 'side\\n' > kept.txt && git commit -qam side && git checkout -q lane/t && printf 'main\\n' > kept.txt && git commit -qam main && ! git merge side",
    );
    sh(src.path(), "printf 'staged\\n' > gone.txt && git add gone.txt");
    let index = std::fs::read(src.path().join(".git/index")).unwrap();
    let conflict = std::fs::read(src.path().join("kept.txt")).unwrap();
    let refs = sh(src.path(), "git show-ref --head");
    let error = snapshot(&here, src.path(), true).unwrap_err().to_string();
    assert!(error.contains("unresolved conflicts"), "{error}");
    assert_eq!(std::fs::read(src.path().join(".git/index")).unwrap(), index);
    assert_eq!(std::fs::read(src.path().join("kept.txt")).unwrap(), conflict);
    assert_eq!(sh(src.path(), "git show-ref --head"), refs);
}

#[test]
fn an_existing_target_index_lock_is_preserved() {
    let src = tempfile::tempdir().unwrap();
    let dst = tempfile::tempdir().unwrap();
    repo(src.path());
    sh(src.path(), "printf 'two\\n' >> kept.txt && git add kept.txt");
    let carry = snapshot(&here, src.path(), true).unwrap();
    sh(dst.path(), &format!("git clone -q --branch lane/t {} .", src.path().display()));
    let lock = dst.path().join(".git/index.lock");
    std::fs::write(&lock, b"another writer").unwrap();
    let index = std::fs::read(dst.path().join(".git/index")).unwrap();
    let out = apply(dst.path(), &carry);
    assert!(!out.ok && out.stderr.contains("index is locked"), "{}", out.stderr);
    assert_eq!(std::fs::read(&lock).unwrap(), b"another writer");
    assert_eq!(std::fs::read(dst.path().join(".git/index")).unwrap(), index);
    assert_eq!(std::fs::read(dst.path().join("kept.txt")).unwrap(), b"one\n");
}

/// Same payload and process harness for both transports; run explicitly on the fleet.
#[test]
#[ignore = "transport timing receipt, not a correctness gate"]
fn carry_transport_before_after() {
    let carry = Carry {
        base: "a".repeat(40),
        staged_patch: vec![b'x'; 8 * 1024 * 1024],
        patch: vec![b'y'; 8 * 1024 * 1024],
        intent_to_add: vec![],
        intent_placeholders: vec![],
        files: 1,
        left_out: vec![],
    };
    let old = format!(
        "{}\n{}\n",
        base64::engine::general_purpose::STANDARD.encode(&carry.staged_patch),
        base64::engine::general_purpose::STANDARD.encode(&carry.patch)
    );
    let new = apply_input("/tmp/transport-only", &carry).unwrap();
    let old_script = r#"s=$(mktemp -d); trap 'rm -rf -- "$s"' EXIT
read -r staged; read -r patch
printf '%s' "$staged" | base64 -d >"$s/staged"
printf '%s' "$patch" | base64 -d >"$s/patch""#;
    let new_script = r#"s=$(mktemp -d); trap 'rm -rf -- "$s"' EXIT
read -r d; read -r base
tar -xf - -C "$s" staged patch intent intent-placeholders"#;
    for round in 0..3 {
        let start = std::time::Instant::now();
        assert!(here(old_script, old.as_bytes()).unwrap().ok);
        let before = start.elapsed();
        let start = std::time::Instant::now();
        assert!(here(new_script, &new).unwrap().ok);
        eprintln!(
            "carry transport round {round}, 16 MiB: shell-base64={before:?}, tar={:?}",
            start.elapsed()
        );
    }
}

#[test]
fn nested_repositories_and_secrets_stay_at_the_source() {
    let src = tempfile::tempdir().unwrap();
    let dst = tempfile::tempdir().unwrap();
    repo(src.path());
    sh(
        src.path(),
        "mkdir nested && git -C nested init -q && printf 'private\\n' > nested/private && printf 'SECRET=1\\n' > .env && mkdir target && printf 'ignored\\n' > target/out && printf 'two\\n' >> kept.txt && git add kept.txt",
    );
    let carry = snapshot(&here, src.path(), true).unwrap();
    assert_eq!(carry.files, 1);
    assert!(carry.left_out.iter().any(|(p, _)| p == "nested/"));
    assert!(carry.left_out.iter().any(|(p, _)| p == ".env"));
    sh(dst.path(), &format!("git clone -q --branch lane/t {} .", src.path().display()));
    assert!(apply(dst.path(), &carry).ok);
    for path in ["nested", ".env", "target"] {
        assert!(src.path().join(path).exists());
        assert!(!dst.path().join(path).exists());
    }
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
fn a_checkout_with_no_index_carries_no_deletion_of_a_tracked_secret() {
    let src = tempfile::tempdir().unwrap();
    repo(src.path());
    sh(src.path(), "printf 'S=1\\n' > .env && git add -f .env && git commit -qm env");
    sh(src.path(), "printf 'two\\n' >> kept.txt && rm .git/index");
    let carry = snapshot(&here, src.path(), true).unwrap();
    let patch = String::from_utf8_lossy(&carry.patch);
    assert!(!patch.contains("deleted file"), "{patch}");
    assert!(patch.contains("kept.txt"), "{patch}");
}

#[test]
fn a_sparse_checkout_carries_its_changes() {
    let src = tempfile::tempdir().unwrap();
    repo(src.path());
    sh(
        src.path(),
        "mkdir -p in out && printf 'a\\n' > in/a && printf 'b\\n' > out/b && git add -A \\
         && git commit -qm dirs && git sparse-checkout set --cone in && printf 'more\\n' >> in/a \\
         && printf 'new\\n' > in/new",
    );
    let carry = snapshot(&here, src.path(), true).unwrap();
    let patch = String::from_utf8_lossy(&carry.patch);
    assert!(patch.contains("in/a") && patch.contains("in/new"), "{patch}");
    assert!(!patch.contains("out/b"), "{patch}");
}

#[test]
fn a_sparse_checkout_with_no_index_refuses_rather_than_delete_outside_its_cone() {
    let src = tempfile::tempdir().unwrap();
    repo(src.path());
    sh(
        src.path(),
        "mkdir -p in out && printf 'a\\n' > in/a && printf 'b\\n' > out/b && git add -A \\
         && git commit -qm dirs && git sparse-checkout set --cone in && printf 'more\\n' >> in/a \\
         && rm .git/index",
    );
    let e = snapshot(&here, src.path(), true).unwrap_err().to_string();
    assert!(e.contains("sparse checkout with no index"), "{e}");
    // The recovery the refusal names gives the index back with its sparse marks, edits kept,
    // and the carry then takes only the change inside the cone.
    sh(src.path(), "git reset -q && git sparse-checkout reapply");
    let carry = snapshot(&here, src.path(), true).unwrap();
    let patch = String::from_utf8_lossy(&carry.patch);
    assert!(patch.contains("in/a") && !patch.contains("out/b"), "{patch}");
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
    let carry = Carry {
        base: "a".repeat(40),
        patch: vec![],
        staged_patch: vec![],
        intent_to_add: vec![],
        intent_placeholders: vec![],
        files: 0,
        left_out: vec![],
    };
    assert!(check_base(&carry, &"a".repeat(40)).is_ok());
    assert!(check_base(&carry, &"b".repeat(40)).is_err());
}

/// Uncommitted work of any size goes with the chat: a move never refuses it for its size. The
/// file is random bytes, which do not compress, so its patch is past the 64 MiB a move once
/// refused at; it arrives byte for byte.
#[test]
fn uncommitted_work_of_any_size_is_carried_whole() {
    let src = tempfile::tempdir().unwrap();
    let dst = tempfile::tempdir().unwrap();
    repo(src.path());
    sh(src.path(), "mkdir -p data && head -c 62914560 /dev/urandom > data/large.bin");
    let carry = snapshot(&here, src.path(), true).unwrap();
    assert!(carry.patch.len() > 64 * 1024 * 1024, "{}", carry.patch.len());
    assert_eq!(carry.files, 1);
    sh(dst.path(), &format!("git clone -q --branch lane/t {} .", src.path().display()));
    let out = apply(dst.path(), &carry);
    assert!(out.ok, "{}", out.stderr);
    let read = |d: &Path| std::fs::read(d.join("data/large.bin")).unwrap();
    assert!(read(dst.path()) == read(src.path()), "the large file arrives byte for byte");
}
