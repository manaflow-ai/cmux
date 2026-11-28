use super::*;
use std::io::Write as _;
use std::os::unix::fs::PermissionsExt as _;
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
                + carry.intent_placeholders.len()
                + carry.affected_paths.len()
                + carry.recovery_paths.len(),
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
        // A repeated carry refuses even when only intent flags differ from HEAD:
        // both index views protect staging already present on the target.
        let target_index_before_retry = std::fs::read(dst.path().join(".git/index")).unwrap();
        let target_refs_before_retry = sh(dst.path(), "git show-ref --head");
        let retry = apply(dst.path(), &carry);
        assert!(!retry.ok, "{name}: repeated carry must refuse");
        assert_eq!(
            std::fs::read(dst.path().join(".git/index")).unwrap(),
            target_index_before_retry,
            "{name}: retry index bytes"
        );
        assert_eq!(
            sh(dst.path(), "git show-ref --head"),
            target_refs_before_retry,
            "{name}: retry refs"
        );
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
fn intent_modes_survive_target_configuration_and_sparse_cones() {
    use std::os::unix::fs::PermissionsExt as _;
    for sparse in [false, true] {
        let src = tempfile::tempdir().unwrap();
        let dst = tempfile::tempdir().unwrap();
        repo(src.path());
        sh(
            src.path(),
            "mkdir included outside && touch included/base outside/base && git add . && git commit -qm dirs && printf 'echo hi\\n' > outside/run.sh && chmod +x outside/run.sh && ln -s run.sh outside/link && git add -N outside/run.sh outside/link",
        );
        let source_index = std::fs::read(src.path().join(".git/index")).unwrap();
        let source_refs = sh(src.path(), "git show-ref --head");
        let carry = snapshot(&here, src.path(), true).unwrap();
        sh(dst.path(), &format!("git clone -q --branch lane/t {} .", src.path().display()));
        sh(dst.path(), "git config core.filemode false && git config core.symlinks false");
        if sparse {
            sh(dst.path(), "git sparse-checkout set --cone included");
        }
        let out = apply(dst.path(), &carry);
        assert!(out.ok, "sparse={sparse}: {}", out.stderr);
        for command in [
            "git ls-files --stage -z",
            "git diff --cached --binary",
            "git -c core.filemode=true -c core.symlinks=true diff --binary",
        ] {
            assert_eq!(
                sh(dst.path(), command),
                sh(src.path(), command),
                "sparse={sparse}: {command}"
            );
        }
        assert_eq!(std::fs::read(dst.path().join("outside/run.sh")).unwrap(), b"echo hi\n");
        assert_ne!(
            std::fs::metadata(dst.path().join("outside/run.sh")).unwrap().permissions().mode()
                & 0o111,
            0
        );
        assert_eq!(
            std::fs::read_link(dst.path().join("outside/link")).unwrap(),
            Path::new("run.sh")
        );
        assert_eq!(sh(dst.path(), "git config core.filemode"), "false\n");
        assert_eq!(sh(dst.path(), "git config core.symlinks"), "false\n");
        if sparse {
            assert!(!dst.path().join("outside/base").exists());
        }
        assert_eq!(std::fs::read(src.path().join(".git/index")).unwrap(), source_index);
        assert_eq!(sh(src.path(), "git show-ref --head"), source_refs);
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
        "if ! git -c core.fsmonitor=false -c core.symlinks=true -C \"$top\" apply --binary --whitespace=nowarn \"$s/patch\"; then",
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

fn recovery_archive(out: &RemoteOut) -> std::path::PathBuf {
    let path = out
        .stderr
        .split("original files are in ")
        .nth(1)
        .unwrap()
        .split("; originally absent paths")
        .next()
        .unwrap();
    let archive = std::path::PathBuf::from(path);
    assert!(archive.is_file(), "{}", out.stderr);
    archive
}

/// The disposable fixture explicitly resolves an ambiguous failed write. The
/// caller keeps its current bytes separately before restoring the original tar.
fn recover_owned_fixture(dir: &Path, out: &RemoteOut) {
    let archive = recovery_archive(out);
    sh(dir, "git reset --hard -q HEAD && git clean -fdq");
    assert!(
        Command::new("tar")
            .args(["--xattrs", "--acls", "-xpf"])
            .arg(&archive)
            .arg("-C")
            .arg(dir)
            .status()
            .unwrap()
            .success()
    );
}

#[test]
fn recovery_preserves_target_files_saved_after_the_backup() {
    for (tracked, after_apply) in [(false, false), (false, true), (true, false), (true, true)] {
        let src = tempfile::tempdir().unwrap();
        let dst = tempfile::tempdir().unwrap();
        repo(src.path());
        if tracked {
            sh(src.path(), "printf original > note.txt && git add note.txt && git commit -qm note");
        }
        sh(src.path(), "printf carried > note.txt && git add note.txt");
        let source_index = std::fs::read(src.path().join(".git/index")).unwrap();
        let carry = snapshot(&here, src.path(), true).unwrap();
        sh(dst.path(), &format!("git clone -q --branch lane/t {} .", src.path().display()));
        let target_index = std::fs::read(dst.path().join(".git/index")).unwrap();
        let write = "if ! git -c core.fsmonitor=false -c core.symlinks=true -C \"$top\" apply --binary --whitespace=nowarn \"$s/patch\"; then";
        let racing = if after_apply {
            APPLY_SCRIPT.replace(
                "if ! mv -- \"$real.lock\" \"$real\"; then",
                "printf target-only-edit > note.txt\nif ! false; then",
            )
        } else {
            APPLY_SCRIPT.replace(write, &format!("printf target-only-edit > note.txt\n{write}"))
        };
        assert_ne!(racing, APPLY_SCRIPT);
        let out =
            here(&racing, &apply_input(&dst.path().to_string_lossy(), &carry).unwrap()).unwrap();
        assert!(!out.ok, "{}", out.stderr);
        assert!(
            out.stderr.contains("preserving ambiguous target path: note.txt"),
            "{}",
            out.stderr
        );
        assert!(out.stderr.contains("worktree recovery needs attention"), "{}", out.stderr);
        assert_eq!(std::fs::read(dst.path().join("note.txt")).unwrap(), b"target-only-edit");
        assert_eq!(std::fs::read(dst.path().join(".git/index")).unwrap(), target_index);
        assert_eq!(std::fs::read(src.path().join("note.txt")).unwrap(), b"carried");
        assert_eq!(std::fs::read(src.path().join(".git/index")).unwrap(), source_index);
        assert!(!dst.path().join(".git/index.lock").exists());
        // Resolve the owned fixture conflict explicitly, then a normal retry works.
        std::fs::rename(dst.path().join("note.txt"), dst.path().join("saved-target-note")).unwrap();
        if tracked {
            let archived = Command::new("tar")
                .args(["-xOf"])
                .arg(recovery_archive(&out))
                .arg("note.txt")
                .output()
                .unwrap();
            assert!(archived.status.success());
            assert_eq!(archived.stdout, b"original");
            sh(dst.path(), "git checkout -- note.txt");
        }
        assert!(apply(dst.path(), &carry).ok);
        assert_eq!(
            std::fs::read(dst.path().join("saved-target-note")).unwrap(),
            b"target-only-edit"
        );
    }
}

#[test]
fn an_unlink_warning_cannot_publish_a_deletion_that_did_not_happen() {
    let src = tempfile::tempdir().unwrap();
    let dst = tempfile::tempdir().unwrap();
    repo(src.path());
    sh(
        src.path(),
        "mkdir protected && printf original > protected/file && git add protected && git commit -qm protected && git rm -q protected/file",
    );
    let carry = snapshot(&here, src.path(), true).unwrap();
    sh(dst.path(), &format!("git clone -q --branch lane/t {} .", src.path().display()));
    let index = std::fs::read(dst.path().join(".git/index")).unwrap();
    let parent = dst.path().join("protected");
    std::fs::set_permissions(&parent, std::fs::Permissions::from_mode(0o500)).unwrap();
    let out = apply(dst.path(), &carry);
    std::fs::set_permissions(&parent, std::fs::Permissions::from_mode(0o700)).unwrap();
    assert!(!out.ok, "a failed unlink must refuse: {}", out.stderr);
    assert_eq!(std::fs::read(dst.path().join("protected/file")).unwrap(), b"original");
    assert_eq!(std::fs::read(dst.path().join(".git/index")).unwrap(), index);
    assert!(apply(dst.path(), &carry).ok);
    assert!(!dst.path().join("protected/file").exists());
}

#[cfg(target_os = "linux")]
#[test]
fn rollback_preserves_annotations_and_leaves_untouched_inodes_alone() {
    use std::ffi::CString;
    use std::os::unix::{ffi::OsStrExt as _, fs::MetadataExt as _};
    let annotation = CString::new("user.carry-proof").unwrap();
    for after_apply in [false, true] {
        let src = tempfile::tempdir().unwrap();
        let dst = tempfile::tempdir().unwrap();
        repo(src.path());
        sh(src.path(), "mkdir notes && git mv kept.txt notes/kept.txt && git commit -qm nested");
        // kept.txt is staged-only; gone.txt changes in the working tree too.
        sh(
            src.path(),
            "printf staged > notes/kept.txt && git add notes/kept.txt && git show HEAD:notes/kept.txt > notes/kept.txt && printf changed > gone.txt",
        );
        let carry = snapshot(&here, src.path(), true).unwrap();
        sh(dst.path(), &format!("git clone -q --branch lane/t {} .", src.path().display()));
        let kept_inode = std::fs::metadata(dst.path().join("notes/kept.txt")).unwrap().ino();
        for name in ["notes/kept.txt", "gone.txt"] {
            let path = CString::new(dst.path().join(name).as_os_str().as_bytes()).unwrap();
            // SAFETY: both C strings and the value buffer live through the call.
            assert_eq!(
                unsafe {
                    libc::setxattr(
                        path.as_ptr(),
                        annotation.as_ptr(),
                        b"saved".as_ptr().cast(),
                        5,
                        0,
                    )
                },
                0
            );
        }
        let index = std::fs::read(dst.path().join(".git/index")).unwrap();
        let failing = if after_apply {
            APPLY_SCRIPT.replace("if ! mv -- \"$real.lock\" \"$real\"; then", "if ! false; then")
        } else {
            APPLY_SCRIPT.replace("if ! git -c core.fsmonitor=false -c core.symlinks=true -C \"$top\" apply --binary --whitespace=nowarn \"$s/patch\"; then", "if ! false; then")
        };
        assert_ne!(failing, APPLY_SCRIPT);
        let out =
            here(&failing, &apply_input(&dst.path().to_string_lossy(), &carry).unwrap()).unwrap();
        assert!(!out.ok);
        assert!(!out.stderr.contains("worktree recovery needs attention"), "{}", out.stderr);
        assert_eq!(std::fs::metadata(dst.path().join("notes/kept.txt")).unwrap().ino(), kept_inode);
        assert_eq!(std::fs::read(dst.path().join(".git/index")).unwrap(), index);
        assert_eq!(std::fs::read(dst.path().join("gone.txt")).unwrap(), b"bye\n");
        for name in ["notes/kept.txt", "gone.txt"] {
            let path = CString::new(dst.path().join(name).as_os_str().as_bytes()).unwrap();
            let mut value = [0u8; 16];
            // SAFETY: the C strings and writable buffer live through the call.
            let len = unsafe {
                libc::getxattr(
                    path.as_ptr(),
                    annotation.as_ptr(),
                    value.as_mut_ptr().cast(),
                    value.len(),
                )
            };
            assert_eq!(len, 5, "{name}: {}", std::io::Error::last_os_error());
            assert_eq!(&value[..5], b"saved");
        }
    }
}

#[test]
fn failed_index_publication_restores_the_worktree() {
    let src = tempfile::tempdir().unwrap();
    let dst = tempfile::tempdir().unwrap();
    repo(src.path());
    sh(
        src.path(),
        "mkdir -p directory/deep/nested && printf original > directory/deep/nested/child && git add directory && git commit -qm directory",
    );
    sh(
        src.path(),
        "printf 'two\\n' >> kept.txt && git add kept.txt && printf 'three\\n' >> kept.txt && git mv gone.txt renamed.txt && git rm -q empty.txt && mkdir -p empty.txt/deep/nested && printf child > empty.txt/deep/nested/child && git add empty.txt && ln -s kept.txt newlink && git rm -qr directory && printf replacement > directory && git add directory",
    );
    let carry = snapshot(&here, src.path(), true).unwrap();
    sh(dst.path(), &format!("git clone -q --branch lane/t {} .", src.path().display()));
    let directory_modes =
        [("directory", 0o700), ("directory/deep", 0o710), ("directory/deep/nested", 0o750)];
    for (path, mode) in directory_modes {
        std::fs::set_permissions(dst.path().join(path), std::fs::Permissions::from_mode(mode))
            .unwrap();
    }
    let index = std::fs::read(dst.path().join(".git/index")).unwrap();
    let failing =
        APPLY_SCRIPT.replace("if ! mv -- \"$real.lock\" \"$real\"; then", "if ! false; then");
    assert_ne!(failing, APPLY_SCRIPT);
    let failing = format!("umask 002\n{failing}");
    let out = here(&failing, &apply_input(&dst.path().to_string_lossy(), &carry).unwrap()).unwrap();
    assert!(!out.ok);
    assert_eq!(std::fs::read(dst.path().join(".git/index")).unwrap(), index);
    for (path, mode) in directory_modes {
        assert_eq!(
            std::fs::metadata(dst.path().join(path)).unwrap().permissions().mode() & 0o777,
            mode,
            "{path}"
        );
    }

    assert_eq!(std::fs::read(dst.path().join("kept.txt")).unwrap(), b"one\n");
    assert!(!dst.path().join(".git/index.lock").exists());
    assert_eq!(sh(dst.path(), "git --no-optional-locks status --porcelain"), "");
    assert!(!dst.path().join("newlink").exists());
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

#[test]
fn intent_only_changes_never_overwrite_target_staging() {
    for (source, target) in [
        (
            "printf staged > empty.txt && git add empty.txt",
            "git rm -q --cached empty.txt && git add -N empty.txt",
        ),
        (
            "git rm -q --cached empty.txt && git add -N empty.txt",
            "printf 'target-only-edit' > empty.txt && git add empty.txt && : > empty.txt",
        ),
        (
            "touch new.txt && git add -N new.txt",
            "printf 'target-only-edit' > new.txt && git add new.txt && rm new.txt",
        ),
        ("git rm -q --cached empty.txt && git add -N empty.txt", "git rm -q --cached empty.txt"),
    ] {
        let src = tempfile::tempdir().unwrap();
        let dst = tempfile::tempdir().unwrap();
        repo(src.path());
        sh(src.path(), source);
        let carry = snapshot(&here, src.path(), true).unwrap();
        sh(dst.path(), &format!("git clone -q --branch lane/t {} .", src.path().display()));
        sh(dst.path(), target);
        let index = std::fs::read(dst.path().join(".git/index")).unwrap();
        let source_index = std::fs::read(src.path().join(".git/index")).unwrap();
        let worktree = sh(dst.path(), "git diff HEAD --binary");
        let refs = sh(dst.path(), "git show-ref --head");
        let out = apply(dst.path(), &carry);
        assert!(!out.ok && out.stderr.contains("target index changed"), "{}", out.stderr);
        assert_eq!(std::fs::read(dst.path().join(".git/index")).unwrap(), index);
        assert_eq!(std::fs::read(src.path().join(".git/index")).unwrap(), source_index);
        assert_eq!(sh(dst.path(), "git diff HEAD --binary"), worktree);
        assert_eq!(sh(dst.path(), "git show-ref --head"), refs);
        assert!(!dst.path().join(".git/index.lock").exists());
        // Save the conflicting staging before resolving this owned fixture.
        // A mixed reset can retain an intent flag whose blob already matches
        // HEAD; reading the tree constructs the clean index the retry requires.
        let saved = tempfile::tempdir().unwrap();
        std::fs::write(saved.path().join("target-index"), &index).unwrap();
        let staged = sh(dst.path(), "git diff --cached --binary --ita-invisible-in-index");
        std::fs::write(saved.path().join("target-staging.patch"), &staged).unwrap();
        sh(dst.path(), "git read-tree HEAD");
        let retry = apply(dst.path(), &carry);
        assert!(retry.ok, "{source} / {target}: retry failed: {}", retry.stderr);
        assert_eq!(std::fs::read(saved.path().join("target-index")).unwrap(), index);
        assert_eq!(
            std::fs::read_to_string(saved.path().join("target-staging.patch")).unwrap(),
            staged
        );
    }
}

#[test]
fn rename_to_intent_never_discards_target_only_staged_content() {
    let src = tempfile::tempdir().unwrap();
    let dst = tempfile::tempdir().unwrap();
    repo(src.path());
    sh(src.path(), "git rm -q empty.txt && touch new.txt && git add -N new.txt");
    let carry = snapshot(&here, src.path(), true).unwrap();
    sh(dst.path(), &format!("git clone -q --branch lane/t {} .", src.path().display()));
    sh(
        dst.path(),
        "printf 'only saved in index' > empty.txt && git add empty.txt && : > empty.txt",
    );
    let index = std::fs::read(dst.path().join(".git/index")).unwrap();
    let out = apply(dst.path(), &carry);
    assert!(!out.ok && out.stderr.contains("target index changed"), "{}", out.stderr);
    assert_eq!(std::fs::read(dst.path().join(".git/index")).unwrap(), index);
    assert_eq!(sh(dst.path(), "git show :empty.txt"), "only saved in index");
    assert_eq!(std::fs::read(dst.path().join("empty.txt")).unwrap(), b"");
    assert!(!dst.path().join("new.txt").exists());
    assert!(!dst.path().join(".git/index.lock").exists());
}

#[test]
fn a_real_partial_write_keeps_recovery_data_and_allows_retry() {
    let src = tempfile::tempdir().unwrap();
    let dst = tempfile::tempdir().unwrap();
    repo(src.path());
    sh(
        src.path(),
        "printf 'base first\\n' > a-first.txt && printf 'base last\\n' > z-last.txt && mkdir -p b-directory/deep/nested && printf original > b-directory/deep/nested/child && git add . && git commit -qm files",
    );
    std::fs::remove_file(src.path().join("a-first.txt")).unwrap();
    std::fs::create_dir_all(src.path().join("a-first.txt/deep/nested")).unwrap();
    std::fs::write(src.path().join("a-first.txt/deep/nested/child"), b"changed first\n").unwrap();
    std::fs::write(src.path().join("z-last.txt"), vec![b'x'; 128 * 1024]).unwrap();
    sh(
        src.path(),
        "git rm -qr b-directory && printf replacement > b-directory && git add a-first.txt b-directory z-last.txt",
    );
    let carry = snapshot(&here, src.path(), true).unwrap();
    sh(dst.path(), &format!("git clone -q --branch lane/t {} .", src.path().display()));
    let directory_modes =
        [("b-directory", 0o700), ("b-directory/deep", 0o710), ("b-directory/deep/nested", 0o750)];
    for (path, mode) in directory_modes {
        std::fs::set_permissions(dst.path().join(path), std::fs::Permissions::from_mode(mode))
            .unwrap();
    }
    let index = std::fs::read(dst.path().join(".git/index")).unwrap();
    let index_entries = sh(dst.path(), "git --no-optional-locks ls-files --stage -z");
    // A real file-size write limit applies only to the final Git child. Its first
    // write succeeds; the second hits SIGXFSZ after preflight and snapshotting.
    let write = "git -c core.fsmonitor=false -c core.symlinks=true -C \"$top\" apply --binary --whitespace=nowarn \"$s/patch\"";
    let failing = APPLY_SCRIPT.replace(
        &format!("if ! {write}; then"),
        &format!("if ! (ulimit -f 2; {write}); then\n    printf 'PARTIAL_WRITE:'; cat a-first.txt/deep/nested/child"),
    );
    assert_ne!(failing, APPLY_SCRIPT);
    let failing = format!("umask 002\n{failing}");
    let out = here(&failing, &apply_input(&dst.path().to_string_lossy(), &carry).unwrap()).unwrap();
    assert!(!out.ok);
    assert!(out.stdout.contains("PARTIAL_WRITE:changed first"), "{} / {}", out.stdout, out.stderr);
    // Check carry preservation before the explicit recovery helper refreshes stat data.
    assert_eq!(std::fs::read(dst.path().join(".git/index")).unwrap(), index);
    if out.stderr.contains("worktree recovery needs attention") {
        assert!(
            out.stderr.contains("preserving ambiguous target path: z-last.txt"),
            "{}",
            out.stderr
        );
        let saved = tempfile::tempdir().unwrap();
        let current = std::fs::read(dst.path().join("z-last.txt")).unwrap();
        std::fs::write(saved.path().join("partial-write"), &current).unwrap();
        recover_owned_fixture(dst.path(), &out);
        assert_eq!(std::fs::read(saved.path().join("partial-write")).unwrap(), current);
    }
    assert_eq!(std::fs::read(dst.path().join("a-first.txt")).unwrap(), b"base first\n");
    assert_eq!(
        std::fs::read(dst.path().join("b-directory/deep/nested/child")).unwrap(),
        b"original"
    );
    assert_eq!(std::fs::read(dst.path().join("z-last.txt")).unwrap(), b"base last\n");
    assert_eq!(sh(dst.path(), "git --no-optional-locks ls-files --stage -z"), index_entries);
    for (path, mode) in directory_modes {
        assert_eq!(
            std::fs::metadata(dst.path().join(path)).unwrap().permissions().mode() & 0o777,
            mode,
            "{path}"
        );
    }

    assert!(!dst.path().join(".git/index.lock").exists());
    assert!(apply(dst.path(), &carry).ok, "retry after actual partial writes");
    assert_eq!(std::fs::read(dst.path().join("z-last.txt")).unwrap(), vec![b'x'; 128 * 1024]);
}

#[test]
fn failed_apply_never_recovers_through_new_symlink_ancestors() {
    for partial_write in [false, true] {
        let src = tempfile::tempdir().unwrap();
        let dst = tempfile::tempdir().unwrap();
        repo(src.path());
        sh(src.path(), "printf original > z-last.txt && git add z-last.txt && git commit -qm last");
        // The staged child is absent from the final worktree, which instead has
        // a symlink. Its destination contains target-only data outside the repo.
        let outside = tempfile::tempdir().unwrap();
        std::fs::write(outside.path().join("child"), b"target-only edit").unwrap();
        std::fs::create_dir(src.path().join("dir")).unwrap();
        std::fs::write(src.path().join("dir/child"), b"staged").unwrap();
        sh(src.path(), "git add dir/child");
        std::fs::remove_file(src.path().join("dir/child")).unwrap();
        std::fs::remove_dir(src.path().join("dir")).unwrap();
        std::os::unix::fs::symlink(outside.path(), src.path().join("dir")).unwrap();
        std::fs::write(src.path().join("z-last.txt"), vec![b'x'; 128 * 1024]).unwrap();
        let carry = snapshot(&here, src.path(), true).unwrap();
        sh(dst.path(), &format!("git clone -q --branch lane/t {} .", src.path().display()));
        let index = std::fs::read(dst.path().join(".git/index")).unwrap();
        let write = "git -c core.fsmonitor=false -c core.symlinks=true -C \"$top\" apply --binary --whitespace=nowarn \"$s/patch\"";
        let failing = if partial_write {
            APPLY_SCRIPT.replace(
                &format!("if ! {write}; then"),
                &format!(
                    "if ! (ulimit -f 2; {write}); then\n    test -L dir && printf SYMLINK_CREATED"
                ),
            )
        } else {
            APPLY_SCRIPT.replace("if ! mv -- \"$real.lock\" \"$real\"; then", "if ! false; then")
        };
        assert_ne!(failing, APPLY_SCRIPT);
        let out =
            here(&failing, &apply_input(&dst.path().to_string_lossy(), &carry).unwrap()).unwrap();
        assert!(!out.ok);
        if partial_write {
            assert!(out.stdout.contains("SYMLINK_CREATED"), "{} / {}", out.stdout, out.stderr);
        }
        assert_eq!(std::fs::read(outside.path().join("child")).unwrap(), b"target-only edit");
        assert_eq!(std::fs::read(dst.path().join(".git/index")).unwrap(), index);
        if out.stderr.contains("worktree recovery needs attention") {
            assert!(partial_write, "{}", out.stderr);
            assert!(
                out.stderr.contains("preserving ambiguous target path: z-last.txt"),
                "{}",
                out.stderr
            );
            let saved = tempfile::tempdir().unwrap();
            let current = std::fs::read(dst.path().join("z-last.txt")).unwrap();
            std::fs::write(saved.path().join("partial-write"), &current).unwrap();
            recover_owned_fixture(dst.path(), &out);
            assert_eq!(std::fs::read(saved.path().join("partial-write")).unwrap(), current);
        }
        assert!(!dst.path().join("dir").exists());
        assert_eq!(sh(dst.path(), "git --no-optional-locks status --porcelain"), "");
        assert!(apply(dst.path(), &carry).ok, "retry after symlink-safe recovery");
        assert_eq!(std::fs::read(outside.path().join("child")).unwrap(), b"target-only edit");
    }
}

#[test]
fn submodule_patch_format_and_paths_ignore_display_preferences() {
    let src = tempfile::tempdir().unwrap();
    let module = tempfile::tempdir().unwrap();
    let dst = tempfile::tempdir().unwrap();
    repo(src.path());
    repo(module.path());
    sh(
        src.path(),
        &format!(
            "git -c protocol.file.allow=always submodule add -q {} module && git commit -qm module",
            module.path().display()
        ),
    );
    sh(src.path(), "git config submodule.module.ignore all && printf hidden >> module/kept.txt");
    assert_eq!(sh(src.path(), "git --no-optional-locks status --porcelain"), "");
    let error = snapshot(&here, src.path(), true).unwrap_err().to_string();
    assert!(error.contains("unstaged submodule changes cannot be carried"), "{error}");
    sh(
        src.path(),
        "git -C module checkout -- kept.txt && git config --unset submodule.module.ignore",
    );
    sh(module.path(), "printf 'next\\n' >> kept.txt && git commit -qam next");
    let next = sh(module.path(), "git rev-parse HEAD");
    sh(
        src.path(),
        &format!(
            "git -C module fetch -q && git -C module checkout -q {} && git add module && printf 'staged\\n' >> kept.txt && git add kept.txt && git config diff.submodule log && git config diff.ignoreSubmodules all",
            next.trim()
        ),
    );
    // An unstaged gitlink change cannot be reproduced by applying a superproject
    // patch. Refuse even when display preferences would hide the submodule.
    sh(src.path(), "git reset -q HEAD -- module");
    let unstaged_index = std::fs::read(src.path().join(".git/index")).unwrap();
    let error = snapshot(&here, src.path(), true).unwrap_err().to_string();
    assert!(error.contains("unstaged submodule changes cannot be carried"), "{error}");
    assert_eq!(std::fs::read(src.path().join(".git/index")).unwrap(), unstaged_index);
    assert_eq!(sh(src.path(), "git -C module rev-parse HEAD"), next);
    sh(src.path(), "git add module");
    let index = std::fs::read(src.path().join(".git/index")).unwrap();
    let carry = snapshot(&here, src.path(), true).unwrap();
    assert!(carry.affected_paths.split(|b| *b == 0).any(|p| p == b"module"));
    assert!(String::from_utf8_lossy(&carry.staged_patch).contains("Subproject commit"));
    sh(dst.path(), &format!("git clone -q --branch lane/t {} .", src.path().display()));
    let out = apply(dst.path(), &carry);
    assert!(out.ok, "{}", out.stderr);
    assert_eq!(sh(dst.path(), "git ls-files --stage"), sh(src.path(), "git ls-files --stage"));
    assert_eq!(std::fs::read(src.path().join(".git/index")).unwrap(), index);
    assert_eq!(std::fs::read(dst.path().join("kept.txt")).unwrap(), b"one\nstaged\n");

    // A fresh uninitialized gitlink is supported, but an initialized checkout
    // at the old commit must not silently gain unstaged submodule differences.
    let initialized = tempfile::tempdir().unwrap();
    sh(
        initialized.path(),
        &format!(
            "git clone -q --branch lane/t {} . && git -c protocol.file.allow=always submodule update --init -q",
            src.path().display()
        ),
    );
    let before_index = std::fs::read(initialized.path().join(".git/index")).unwrap();
    let before_module = sh(initialized.path(), "git -C module rev-parse HEAD");
    let before_bytes = std::fs::read(initialized.path().join("module/kept.txt")).unwrap();
    let out = apply(initialized.path(), &carry);
    assert!(
        !out.ok && out.stderr.contains("initialized target submodule needs commit"),
        "{}",
        out.stderr
    );
    assert_eq!(std::fs::read(initialized.path().join(".git/index")).unwrap(), before_index);
    assert_eq!(sh(initialized.path(), "git -C module rev-parse HEAD"), before_module);
    assert_eq!(std::fs::read(initialized.path().join("module/kept.txt")).unwrap(), before_bytes);
    assert_eq!(std::fs::read(initialized.path().join("kept.txt")).unwrap(), b"one\n");
    sh(initialized.path(), &format!("git -C module checkout -q {}", next.trim()));
    let out = apply(initialized.path(), &carry);
    assert!(out.ok, "{}", out.stderr);
    assert_eq!(
        sh(initialized.path(), "git --no-optional-locks status --porcelain"),
        sh(src.path(), "git --no-optional-locks status --porcelain")
    );
}

#[test]
fn intent_changes_preserve_unrelated_target_staging() {
    let src = tempfile::tempdir().unwrap();
    let dst = tempfile::tempdir().unwrap();
    repo(src.path());
    sh(src.path(), "git rm -q --cached empty.txt && git add -N empty.txt");
    let carry = snapshot(&here, src.path(), true).unwrap();
    sh(dst.path(), &format!("git clone -q --branch lane/t {} .", src.path().display()));
    sh(
        dst.path(),
        "printf 'target-only-edit' > kept.txt && git add kept.txt && git show HEAD:kept.txt > kept.txt",
    );
    let out = apply(dst.path(), &carry);
    assert!(out.ok, "{}", out.stderr);
    assert_eq!(sh(dst.path(), "git show :kept.txt"), "target-only-edit");
    assert_eq!(std::fs::read(dst.path().join("kept.txt")).unwrap(), b"one\n");
    assert_eq!(sh(dst.path(), "git diff --cached --name-status -- empty.txt"), "D\tempty.txt\n");
}

#[test]
fn target_head_moving_during_payload_receipt_refuses_under_the_lock() {
    let src = tempfile::tempdir().unwrap();
    let dst = tempfile::tempdir().unwrap();
    repo(src.path());
    sh(src.path(), "printf 'staged\\n' >> kept.txt && git add kept.txt");
    let carry = snapshot(&here, src.path(), true).unwrap();
    sh(dst.path(), &format!("git clone -q --branch lane/t {} .", src.path().display()));
    let next = sh(
        dst.path(),
        "git -c user.name=t -c user.email=t@t commit-tree HEAD^{tree} -p HEAD -m moved",
    );
    let index = std::fs::read(dst.path().join(".git/index")).unwrap();
    let receipt = "tar -xf - -C \"$s\" staged patch intent intent-placeholders paths recovery-paths || exit 2";
    let racing = APPLY_SCRIPT.replace(
        receipt,
        &format!("{receipt}\ngit -C \"$top\" update-ref HEAD {} || exit 2", next.trim()),
    );
    assert_ne!(racing, APPLY_SCRIPT);
    let out = here(&racing, &apply_input(&dst.path().to_string_lossy(), &carry).unwrap()).unwrap();
    assert!(!out.ok && out.stderr.contains("the new worktree is at"), "{}", out.stderr);
    assert_eq!(sh(dst.path(), "git rev-parse HEAD"), next);
    assert_eq!(std::fs::read(dst.path().join(".git/index")).unwrap(), index);
    assert_eq!(std::fs::read(dst.path().join("kept.txt")).unwrap(), b"one\n");
    assert!(!dst.path().join(".git/index.lock").exists());
}

#[test]
fn index_flag_transfer_excludes_unchanged_files() {
    let src = tempfile::tempdir().unwrap();
    repo(src.path());
    for i in 0..2000 {
        std::fs::write(src.path().join(format!("unchanged-{i}")), b"unchanged\n").unwrap();
    }
    sh(
        src.path(),
        "git add . && git commit -qm many && git rm -q --cached empty.txt && git add -N empty.txt",
    );
    let bounded = |script: &str, input: &[u8]| {
        let out = here(script, input)?;
        if script == PATCH_SCRIPT {
            let metadata = decode(out.stdout.lines().nth(1).unwrap()).unwrap();
            assert!(metadata.len() < 1024, "{} metadata bytes for one intent", metadata.len());
            assert!(!metadata.windows(b"unchanged-".len()).any(|w| w == b"unchanged-"));
        }
        Ok(out)
    };
    let carry = snapshot(&bounded, src.path(), true).unwrap();
    assert_eq!(carry.intent_to_add, b"empty.txt\0");
    assert_eq!(carry.files, 1);
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
        affected_paths: vec![],
        recovery_paths: vec![],
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
tar -xf - -C "$s" staged patch intent intent-placeholders paths"#;
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
        affected_paths: vec![],
        recovery_paths: vec![],
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

/// Git trusts a file's size and time only when the file is older than the index, and reads one as
/// old as the index again. The scratch index is a copy: with a newer time of its own it would
/// trust them, and an edit that kept the size in the second the file was indexed would stay
/// behind.
#[test]
fn an_edit_of_the_same_size_in_the_second_the_file_was_indexed_is_carried() {
    let src = tempfile::tempdir().unwrap();
    repo(src.path());
    // A file's change time cannot be set, so this checkout does not compare it. What is left is
    // what git compares where times are whole seconds: the size and the time of the last write.
    sh(src.path(), "git config core.trustctime false");
    let (file, index) = (src.path().join("kept.txt"), src.path().join(".git/index"));
    let at = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_000_000_000);
    let stamp = |path: &Path| {
        let file = std::fs::File::options().write(true).open(path).unwrap();
        file.set_modified(at).unwrap();
    };
    // The file is indexed in one second, and edited in that second with the size it had.
    stamp(&file);
    sh(src.path(), "git update-index --refresh");
    stamp(&index);
    std::fs::write(&file, "two\n").unwrap();
    stamp(&file);

    let carry = snapshot(&here, src.path(), true).unwrap();
    assert_eq!(carry.files, 1, "the edit is carried");
    assert!(String::from_utf8_lossy(&carry.patch).contains("+two"));
}
