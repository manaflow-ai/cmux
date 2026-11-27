//! A repository's own config must not make a diff session run a program.
//! Each test builds a repository whose config would run `touch <marker>`,
//! opens a session on it the way the viewer does (the patch, then the
//! generated paths), and checks the marker was never made.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::protocol::DiffSource;

use super::{
    SESSION_GIT_TIMEOUT, SessionGit, Whitespace, git_generated_paths, run_git_patch_with_limit,
};

/// A fresh folder for one test, removed when dropped.
struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "cmux-diff-sidecar-hostile-{}-{name}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&path).expect("create scratch folder");
        Self(std::fs::canonicalize(&path).expect("canonical scratch folder"))
    }

    fn marker(&self) -> PathBuf {
        self.0.join("marker")
    }

    /// A shell command that makes the marker.
    fn touch_marker(&self) -> String {
        format!("touch '{}'", self.marker().display())
    }

    fn assert_no_marker(&self) {
        assert!(
            !self.marker().exists(),
            "opening a session ran a program from the repository's config ({} exists)",
            self.marker().display()
        );
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Runs setup git in `directory`, isolated from the machine's git config,
/// and returns its trimmed output.
fn git(directory: &Path, arguments: &[&str]) -> String {
    let mut command = Command::new("/usr/bin/git");
    for (name, _) in std::env::vars_os() {
        if name.as_encoded_bytes().starts_with(b"GIT_") {
            command.env_remove(name);
        }
    }
    let output = command
        .args(arguments)
        .current_dir(directory)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_AUTHOR_NAME", "cmux tests")
        .env("GIT_AUTHOR_EMAIL", "cmux@example.invalid")
        .env("GIT_COMMITTER_NAME", "cmux tests")
        .env("GIT_COMMITTER_EMAIL", "cmux@example.invalid")
        .output()
        .expect("run git");
    assert!(
        output.status.success(),
        "git {arguments:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}

/// A repository at `path` with `file.txt` committed as `one` on `main`.
fn new_repository(path: &Path) {
    std::fs::create_dir_all(path).expect("create repository folder");
    git(path, &["init", "--quiet", "--initial-branch=main"]);
    std::fs::write(path.join("file.txt"), "one\n").expect("write file");
    git(path, &["add", "."]);
    git(path, &["commit", "--quiet", "-m", "one"]);
}

/// Backdates `file`, so git must hash it again (through its clean filter)
/// to learn whether it changed.
fn make_stat_dirty(file: &Path) {
    // 2001-01-01, long before the checkout.
    let old = std::time::SystemTime::UNIX_EPOCH + std::time::Duration::from_hours(271_752);
    std::fs::File::options()
        .write(true)
        .open(file)
        .and_then(|handle| handle.set_modified(old))
        .expect("age the file");
}

fn unstaged(repo: &Path) -> DiffSource {
    DiffSource::Unstaged {
        repo_root: repo.to_string_lossy().into_owned(),
    }
}

fn staged(repo: &Path) -> DiffSource {
    DiffSource::Staged {
        repo_root: repo.to_string_lossy().into_owned(),
    }
}

fn branch(repo: &Path, base: &str) -> DiffSource {
    DiffSource::Branch {
        repo_root: repo.to_string_lossy().into_owned(),
        base_ref: Some(base.to_owned()),
    }
}

/// What one session open on `source` produced: the patch, or `None` when
/// the open failed, and the generated paths.
struct Session {
    patch: Option<String>,
    generated: Vec<String>,
}

/// Opens a session on `source` the way `open_session` does once the source
/// is resolved: the patch, then the generated paths.
async fn open(scratch: &Scratch, source: &DiffSource, repo: &Path) -> Session {
    let git = SessionGit::open(repo, SESSION_GIT_TIMEOUT)
        .await
        .expect("open the session's git");
    let patch_path = scratch.0.join("session.patch");
    let written =
        run_git_patch_with_limit(source, Whitespace::Show, &git, &patch_path, 1024 * 1024).await;
    let patch = written
        .ok()
        .map(|()| std::fs::read_to_string(&patch_path).expect("read the patch"));
    let generated = git_generated_paths(source, Whitespace::Show, &git).await;
    Session { patch, generated }
}

/// `core.fsmonitor` naming a hook makes every index refresh run it.
#[tokio::test]
async fn hostile_repository_fsmonitor_hook_never_runs() {
    let scratch = Scratch::new("fsmonitor");
    let repo = scratch.0.join("repository");
    new_repository(&repo);
    let hook = scratch.0.join("fsmonitor-hook");
    std::fs::write(
        &hook,
        format!("#!/bin/sh\n{}\nexit 1\n", scratch.touch_marker()),
    )
    .expect("write the hook");
    std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o755))
        .expect("make the hook executable");
    git(
        &repo,
        &["config", "core.fsmonitor", &hook.to_string_lossy()],
    );
    std::fs::write(repo.join("file.txt"), "two\n").expect("write file");

    open(&scratch, &unstaged(&repo), &repo).await;

    scratch.assert_no_marker();
}

/// `-c filter.a=b.clean=` splits at the first `=`, so blanking on the
/// command line never blanks a driver whose name has one. The clean filter
/// runs on a stat-dirty tracked file and on an untracked file's patch.
#[tokio::test]
async fn hostile_repository_filter_driver_name_with_equals_sign_never_runs() {
    let scratch = Scratch::new("filter-equals");
    let repo = scratch.0.join("repository");
    new_repository(&repo);
    std::fs::write(repo.join(".gitattributes"), "* filter=a=b\n").expect("write attributes");
    git(&repo, &["add", ".gitattributes"]);
    git(&repo, &["commit", "--quiet", "-m", "attributes"]);
    let clean = format!("{}; cat", scratch.touch_marker());
    git(&repo, &["config", "filter.a=b.clean", &clean]);
    make_stat_dirty(&repo.join("file.txt"));

    open(&scratch, &unstaged(&repo), &repo).await;
    scratch.assert_no_marker();

    std::fs::write(repo.join("untracked.txt"), "new\n").expect("write untracked file");
    open(&scratch, &unstaged(&repo), &repo).await;
    scratch.assert_no_marker();
}

/// A file the repository's config includes is repository config too: its
/// filter driver never runs. (cmux-git's tests cover global drivers, with
/// an isolated home.)
#[tokio::test]
async fn hostile_repository_included_filter_driver_never_runs() {
    let scratch = Scratch::new("filter-include");
    let repo = scratch.0.join("repository");
    new_repository(&repo);
    std::fs::write(repo.join(".gitattributes"), "* filter=inc\n").expect("write attributes");
    git(&repo, &["add", ".gitattributes"]);
    git(&repo, &["commit", "--quiet", "-m", "attributes"]);
    let included = scratch.0.join("included.config");
    let clean = format!("{}; cat", scratch.touch_marker());
    std::fs::write(
        &included,
        format!("[filter \"inc\"]\n\tclean = \"{clean}\"\n"),
    )
    .expect("write the included config");
    git(
        &repo,
        &["config", "include.path", &included.to_string_lossy()],
    );
    make_stat_dirty(&repo.join("file.txt"));
    std::fs::write(repo.join("untracked.txt"), "new\n").expect("write untracked file");

    open(&scratch, &unstaged(&repo), &repo).await;

    scratch.assert_no_marker();
}

/// A long-running `process` filter starts on the first file git filters.
#[tokio::test]
async fn hostile_repository_process_filter_never_starts() {
    let scratch = Scratch::new("filter-process");
    let repo = scratch.0.join("repository");
    new_repository(&repo);
    std::fs::write(repo.join(".gitattributes"), "* filter=p\n").expect("write attributes");
    git(&repo, &["add", ".gitattributes"]);
    git(&repo, &["commit", "--quiet", "-m", "attributes"]);
    let process = format!("{}; exit 1", scratch.touch_marker());
    git(&repo, &["config", "filter.p.process", &process]);
    make_stat_dirty(&repo.join("file.txt"));

    open(&scratch, &unstaged(&repo), &repo).await;

    scratch.assert_no_marker();
}

/// A diff driver's `textconv` runs on both sides of every patch it covers:
/// unstaged, staged, branch and untracked files alike.
#[tokio::test]
async fn hostile_repository_textconv_never_runs() {
    let scratch = Scratch::new("textconv");
    let repo = scratch.0.join("repository");
    new_repository(&repo);
    std::fs::write(repo.join(".gitattributes"), "* diff=t\n").expect("write attributes");
    git(&repo, &["add", ".gitattributes"]);
    git(&repo, &["commit", "--quiet", "-m", "attributes"]);
    git(&repo, &["switch", "--quiet", "-c", "feature"]);
    std::fs::write(repo.join("file.txt"), "two\n").expect("write file");
    git(&repo, &["commit", "--quiet", "-a", "-m", "two"]);
    std::fs::write(repo.join("file.txt"), "three\n").expect("write file");
    git(&repo, &["add", "file.txt"]);
    std::fs::write(repo.join("file.txt"), "four\n").expect("write file");
    std::fs::write(repo.join("untracked.txt"), "new\n").expect("write untracked file");
    let textconv = format!("{}; cat", scratch.touch_marker());
    git(&repo, &["config", "diff.t.textconv", &textconv]);

    for source in [unstaged(&repo), staged(&repo), branch(&repo, "main")] {
        let session = open(&scratch, &source, &repo).await;
        assert!(session.patch.is_some(), "{source:?} opened no patch");
    }

    scratch.assert_no_marker();
}

/// `diff.external` and a diff driver's `command` replace git's own patch.
#[tokio::test]
async fn hostile_repository_external_diff_never_runs() {
    let scratch = Scratch::new("external-diff");
    let repo = scratch.0.join("repository");
    new_repository(&repo);
    std::fs::write(repo.join(".gitattributes"), "*.md diff=x\n").expect("write attributes");
    std::fs::write(repo.join("notes.md"), "one\n").expect("write file");
    git(&repo, &["add", "."]);
    git(&repo, &["commit", "--quiet", "-m", "attributes"]);
    git(&repo, &["switch", "--quiet", "-c", "feature"]);
    std::fs::write(repo.join("file.txt"), "two\n").expect("write file");
    std::fs::write(repo.join("notes.md"), "two\n").expect("write file");
    git(&repo, &["commit", "--quiet", "-a", "-m", "two"]);
    std::fs::write(repo.join("file.txt"), "three\n").expect("write file");
    std::fs::write(repo.join("notes.md"), "three\n").expect("write file");
    git(&repo, &["add", "."]);
    std::fs::write(repo.join("file.txt"), "four\n").expect("write file");
    std::fs::write(repo.join("notes.md"), "four\n").expect("write file");
    std::fs::write(repo.join("untracked.txt"), "new\n").expect("write untracked file");
    let command = format!("{}; true", scratch.touch_marker());
    git(&repo, &["config", "diff.external", &command]);
    git(&repo, &["config", "diff.x.command", &command]);

    for source in [unstaged(&repo), staged(&repo), branch(&repo, "main")] {
        let session = open(&scratch, &source, &repo).await;
        assert!(session.patch.is_some(), "{source:?} opened no patch");
    }

    scratch.assert_no_marker();
}

/// The superproject's diff runs `git status` inside a submodule to learn
/// whether it is dirty, which hashes a stat-dirty file through the
/// submodule's own clean filter.
#[tokio::test]
async fn hostile_repository_submodule_filter_never_runs() {
    let scratch = Scratch::new("submodule-filter");
    let submodule = scratch.0.join("submodule");
    new_repository(&submodule);
    std::fs::write(submodule.join(".gitattributes"), "* filter=s\n").expect("write attributes");
    git(&submodule, &["add", ".gitattributes"]);
    git(&submodule, &["commit", "--quiet", "-m", "attributes"]);
    let repo = scratch.0.join("repository");
    new_repository(&repo);
    let source = submodule.to_string_lossy().into_owned();
    git(
        &repo,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            "--quiet",
            &source,
            "sub",
        ],
    );
    git(&repo, &["commit", "--quiet", "-m", "add the submodule"]);
    let checkout = repo.join("sub");
    let clean = format!("{}; cat", scratch.touch_marker());
    git(&checkout, &["config", "filter.s.clean", &clean]);
    make_stat_dirty(&checkout.join("file.txt"));
    std::fs::write(repo.join("file.txt"), "two\n").expect("write file");

    open(&scratch, &unstaged(&repo), &repo).await;

    scratch.assert_no_marker();
}

/// `diff.submodule=diff` makes git run `git diff` inside the submodule,
/// with the submodule's own diff drivers.
#[tokio::test]
async fn hostile_repository_submodule_inline_diff_runs_no_driver() {
    let scratch = Scratch::new("submodule-diff");
    let submodule = scratch.0.join("submodule");
    new_repository(&submodule);
    std::fs::write(submodule.join(".gitattributes"), "* diff=x\n").expect("write attributes");
    git(&submodule, &["add", ".gitattributes"]);
    git(&submodule, &["commit", "--quiet", "-m", "attributes"]);
    let repo = scratch.0.join("repository");
    new_repository(&repo);
    let source = submodule.to_string_lossy().into_owned();
    git(
        &repo,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            "--quiet",
            &source,
            "sub",
        ],
    );
    git(&repo, &["commit", "--quiet", "-m", "add the submodule"]);
    // A new submodule commit is a change the superproject's diff shows.
    let checkout = repo.join("sub");
    std::fs::write(checkout.join("file.txt"), "two\n").expect("write file");
    git(&checkout, &["commit", "--quiet", "-a", "-m", "two"]);
    let command = format!("{}; true", scratch.touch_marker());
    git(&checkout, &["config", "diff.x.command", &command]);
    let textconv = format!("{}; cat", scratch.touch_marker());
    git(&checkout, &["config", "diff.x.textconv", &textconv]);
    git(&repo, &["config", "diff.submodule", "diff"]);

    open(&scratch, &unstaged(&repo), &repo).await;

    scratch.assert_no_marker();
}

/// A partial clone fetches a missing object on demand, through the
/// repository's own `core.sshCommand`. The branch session needs the merge
/// base's blob, which a blobless clone never had.
#[tokio::test]
async fn hostile_repository_partial_clone_lazy_fetch_runs_no_ssh_command() {
    let scratch = Scratch::new("lazy-fetch");
    let repo = scratch.0.join("repository");
    new_repository(&repo);
    git(&repo, &["switch", "--quiet", "-c", "feature"]);
    std::fs::write(repo.join("file.txt"), "two\n").expect("write file");
    git(&repo, &["commit", "--quiet", "-a", "-m", "two"]);
    let blob = git(&repo, &["rev-parse", "main:file.txt"]);
    let object = repo.join(".git/objects").join(&blob[..2]).join(&blob[2..]);
    std::fs::remove_file(&object).expect("remove the blob");
    git(&repo, &["config", "core.repositoryformatversion", "1"]);
    git(&repo, &["config", "extensions.partialClone", "origin"]);
    git(
        &repo,
        &[
            "config",
            "remote.origin.url",
            "ssh://example.invalid/repository",
        ],
    );
    git(&repo, &["config", "remote.origin.promisor", "true"]);
    let ssh = format!("{}; false", scratch.touch_marker());
    git(&repo, &["config", "core.sshCommand", &ssh]);

    open(&scratch, &branch(&repo, "main"), &repo).await;

    scratch.assert_no_marker();
}

/// `core.attributesFile` and `diff.orderFile` name files a diff reads to the
/// end: `/dev/zero` would be read until the session's deadline. A missing
/// order file (git stops) and an attributes file that marks text binary
/// and generated show whether git read them, without risking the memory.
#[tokio::test]
async fn hostile_repository_attributes_and_order_files_are_never_read() {
    let scratch = Scratch::new("config-files");
    let repo = scratch.0.join("repository");
    new_repository(&repo);
    std::fs::write(repo.join("file.txt"), "two\n").expect("write file");
    let attributes = scratch.0.join("attributes");
    std::fs::write(&attributes, "*.txt -diff linguist-generated\n").expect("write attributes");
    git(
        &repo,
        &[
            "config",
            "core.attributesFile",
            &attributes.to_string_lossy(),
        ],
    );
    let order = scratch.0.join("missing-order-file");
    git(
        &repo,
        &["config", "diff.orderFile", &order.to_string_lossy()],
    );

    let session = open(&scratch, &unstaged(&repo), &repo).await;

    let patch = session
        .patch
        .expect("the session opens without reading the order file");
    assert!(
        patch.contains("+two"),
        "the attributes file made the diff binary: {patch}"
    );
    assert!(
        session.generated.is_empty(),
        "the attributes file marked paths generated: {:?}",
        session.generated
    );
}

/// The confinement changes nothing a normal repository's session shows.
#[tokio::test]
async fn normal_repository_session_is_unchanged() {
    let scratch = Scratch::new("normal");
    let repo = scratch.0.join("repository");
    new_repository(&repo);
    std::fs::write(repo.join(".gitattributes"), "dist/* linguist-generated\n")
        .expect("write attributes");
    std::fs::create_dir_all(repo.join("dist")).expect("create dist");
    std::fs::write(repo.join("dist/out.js"), "one\n").expect("write file");
    std::fs::write(repo.join("caf\u{e9}.txt"), "one\n").expect("write file");
    git(&repo, &["add", "."]);
    git(&repo, &["commit", "--quiet", "-m", "more"]);
    std::fs::write(repo.join("file.txt"), "two\n").expect("write file");
    std::fs::write(repo.join("dist/out.js"), "two\n").expect("write file");
    std::fs::write(repo.join("caf\u{e9}.txt"), "two\n").expect("write file");
    std::fs::write(repo.join("untracked.txt"), "new\n").expect("write untracked file");

    let session = open(&scratch, &unstaged(&repo), &repo).await;

    let patch = session.patch.expect("the session opens");
    // git quotes a non-ASCII path in patch headers unless core.quotePath is
    // off; the viewer has always received it quoted.
    assert!(patch.contains("\"a/caf\\303\\251.txt\""), "{patch}");
    assert!(patch.contains("+two"), "{patch}");
    assert!(patch.contains("b/untracked.txt"), "{patch}");
    assert_eq!(session.generated, vec!["dist/out.js".to_owned()]);
}

/// Writes an executable `post-index-change` hook in `hooks` that makes the
/// marker.
fn write_index_hook(scratch: &Scratch, hooks: &Path) {
    std::fs::create_dir_all(hooks).expect("create the hooks folder");
    let hook = hooks.join("post-index-change");
    std::fs::write(&hook, format!("#!/bin/sh\n{}\n", scratch.touch_marker()))
        .expect("write the hook");
    std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o755))
        .expect("make the hook executable");
}

/// An unstaged diff refreshes a stale index and writes it, which runs the
/// repository's `post-index-change` hook; `.git/hooks` needs no config.
#[tokio::test]
async fn hostile_repository_index_hook_never_runs() {
    let scratch = Scratch::new("index-hook");
    let repo = scratch.0.join("repository");
    new_repository(&repo);
    write_index_hook(&scratch, &repo.join(".git/hooks"));
    make_stat_dirty(&repo.join("file.txt"));

    open(&scratch, &unstaged(&repo), &repo).await;

    scratch.assert_no_marker();
}

/// The same hook from a folder the repository's `core.hooksPath` names.
#[tokio::test]
async fn hostile_repository_hooks_path_index_hook_never_runs() {
    let scratch = Scratch::new("hooks-path");
    let repo = scratch.0.join("repository");
    new_repository(&repo);
    let hooks = scratch.0.join("hooks");
    write_index_hook(&scratch, &hooks);
    git(
        &repo,
        &["config", "core.hooksPath", &hooks.to_string_lossy()],
    );
    make_stat_dirty(&repo.join("file.txt"));

    open(&scratch, &unstaged(&repo), &repo).await;

    scratch.assert_no_marker();
}

/// The superproject's diff runs `git status` inside a submodule, which
/// writes the submodule's stale index and runs the submodule's hook.
#[tokio::test]
async fn hostile_repository_submodule_index_hook_never_runs() {
    let scratch = Scratch::new("submodule-hook");
    let submodule = scratch.0.join("submodule");
    new_repository(&submodule);
    let repo = scratch.0.join("repository");
    new_repository(&repo);
    let source = submodule.to_string_lossy().into_owned();
    git(
        &repo,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            "--quiet",
            &source,
            "sub",
        ],
    );
    git(&repo, &["commit", "--quiet", "-m", "add the submodule"]);
    let checkout = repo.join("sub");
    let hooks = git(
        &checkout,
        &["rev-parse", "--path-format=absolute", "--git-path", "hooks"],
    );
    write_index_hook(&scratch, Path::new(&hooks));
    make_stat_dirty(&checkout.join("file.txt"));

    open(&scratch, &unstaged(&repo), &repo).await;

    scratch.assert_no_marker();
}
