//! Superrepo diffs (CMUX-5, `submodules.rs`): a session in a repository with
//! submodules shows the files changed inside each checked-out submodule as
//! paths under its folder, for every git source, and Load full files reads
//! them from the submodule's own commits.

use std::path::{Path, PathBuf};
use std::process::Command;

use crate::PROTOCOL_VERSION;
use crate::protocol::{
    DiffCommand, DiffRequest, DiffResult, DiffSource, FileContentsRequest, OpenSessionRequest,
};

use super::{AppState, ResourceScheme, ServerConfig, app_state, handle_protocol_request};

const TOKEN: &str = "0123456789abcdef-super";

/// A superproject `super` with `top.txt` and the submodule `libs/sub`
/// (`f.txt`), itself holding the submodule `deep` (`d.txt`), all committed on
/// `main`; plus a sidecar root where `TOKEN` may diff `super`.
struct Fixture {
    base: PathBuf,
    repo: PathBuf,
    state: AppState,
}

impl Fixture {
    fn new(name: &str) -> Self {
        let base = std::env::temp_dir().join(format!(
            "cmux-diff-sidecar-submodules-{}-{name}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&base).expect("create base");
        let base = std::fs::canonicalize(&base).expect("canonical base");
        let repo = base.join("super");
        let root = base.join("root");
        for folder in [
            &repo,
            &root,
            &base.join("deep-origin"),
            &base.join("sub-origin"),
        ] {
            std::fs::create_dir_all(folder).expect("create folder");
        }

        let deep_origin = base.join("deep-origin");
        git(&deep_origin, &["init", "--quiet", "--initial-branch=main"]);
        std::fs::write(deep_origin.join("d.txt"), "deep one\n").expect("write d.txt");
        git(&deep_origin, &["add", "."]);
        git(&deep_origin, &["commit", "--quiet", "-m", "deep"]);

        let sub_origin = base.join("sub-origin");
        git(&sub_origin, &["init", "--quiet", "--initial-branch=main"]);
        std::fs::write(sub_origin.join("f.txt"), "one\n").expect("write f.txt");
        git(&sub_origin, &["add", "."]);
        git(
            &sub_origin,
            &[
                "submodule",
                "--quiet",
                "add",
                &path_text(&deep_origin),
                "deep",
            ],
        );
        git(&sub_origin, &["commit", "--quiet", "-m", "sub"]);

        git(&repo, &["init", "--quiet", "--initial-branch=main"]);
        std::fs::write(repo.join("top.txt"), "top\n").expect("write top.txt");
        git(&repo, &["add", "."]);
        git(
            &repo,
            &[
                "submodule",
                "--quiet",
                "add",
                &path_text(&sub_origin),
                "libs/sub",
            ],
        );
        git(
            &repo,
            &["submodule", "--quiet", "update", "--init", "--recursive"],
        );
        git(&repo, &["commit", "--quiet", "-m", "initial"]);

        std::fs::write(
            root.join(format!(".branch-session-{TOKEN}.json")),
            serde_json::json!({
                "token": TOKEN,
                "groupID": format!("group-{TOKEN}"),
                "allowedRepoRoots": [path_text(&repo)],
            })
            .to_string(),
        )
        .expect("authorize the token");
        let seed = root.join(format!("seed-{TOKEN}.patch"));
        std::fs::write(&seed, "").expect("write the seed patch");
        std::fs::write(
            root.join(format!(".manifest-{TOKEN}.json")),
            serde_json::json!({
                "token": TOKEN,
                "files": [{
                    "request_path": format!("/seed-{TOKEN}.patch"),
                    "file_path": path_text(&seed),
                    "mime_type": "text/x-diff",
                    "remote_url": null,
                }],
            })
            .to_string(),
        )
        .expect("write the manifest");
        let config = ServerConfig {
            root,
            cmux_executable: "/nonexistent/cmux".into(),
            executable_path: "/nonexistent/sidecar".into(),
            resource_scheme: ResourceScheme::Page,
        };
        #[cfg(feature = "http-server")]
        let state = app_state(config, 0).expect("state");
        #[cfg(not(feature = "http-server"))]
        let state = app_state(config, 0);
        Self { base, repo, state }
    }

    fn sub(&self) -> PathBuf {
        self.repo.join("libs/sub")
    }

    fn repo_root(&self) -> String {
        path_text(&self.repo)
    }

    async fn send(&self, command: DiffCommand) -> crate::protocol::DiffResponse {
        handle_protocol_request(
            DiffRequest {
                id: "test".to_owned(),
                version: PROTOCOL_VERSION,
                command,
            },
            Some(&self.state),
        )
        .await
    }

    /// Opens a session on `source`: its id and its patch.
    async fn open(&self, source: DiffSource) -> (String, String) {
        let response = self
            .send(DiffCommand::SessionOpen(OpenSessionRequest {
                source,
                capability_token: TOKEN.to_owned(),
                session_id: None,
                ignore_whitespace: None,
            }))
            .await;
        let Some(DiffResult::SessionOpened(opened)) = response.result else {
            panic!("session did not open: {:?}", response.error);
        };
        let patch = std::fs::read_to_string(
            self.state
                .config
                .root
                .join(format!("diff-session-{}.patch", opened.session_id)),
        )
        .expect("read the session patch");
        (opened.session_id, patch)
    }

    /// Both sides of `path`, as Load full files reads them.
    async fn sides(&self, session: &str, path: &str) -> (Option<String>, Option<String>) {
        let response = self
            .send(DiffCommand::FileContents(FileContentsRequest {
                session_id: session.to_owned(),
                capability_token: TOKEN.to_owned(),
                path: path.to_owned(),
                previous_path: None,
                encoding: None,
            }))
            .await;
        let Some(DiffResult::FileContents(result)) = response.result else {
            panic!("no file contents for {path}: {:?}", response.error);
        };
        (
            result.old.map(|side| side.contents),
            result.new.map(|side| side.contents),
        )
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.base);
    }
}

fn path_text(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

/// Runs setup git in `folder`, isolated from the machine's git config; local
/// submodule clones need the file transport.
fn git(folder: &Path, arguments: &[&str]) {
    let mut command = Command::new("/usr/bin/git");
    for (name, _) in std::env::vars_os() {
        if name.as_encoded_bytes().starts_with(b"GIT_") {
            command.env_remove(name);
        }
    }
    let output = command
        .args(["-c", "protocol.file.allow=always"])
        .args(arguments)
        .current_dir(folder)
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
}

#[tokio::test]
async fn unstaged_sessions_show_files_changed_inside_submodules() {
    let fixture = Fixture::new("unstaged");
    std::fs::write(fixture.repo.join("top.txt"), "top\nmore\n").expect("edit top.txt");
    std::fs::write(fixture.sub().join("f.txt"), "one\ntwo\n").expect("edit f.txt");
    std::fs::write(fixture.sub().join("new.txt"), "brand new\n").expect("write new.txt");
    std::fs::write(fixture.sub().join("deep/d.txt"), "deep one\ndeep two\n").expect("edit d.txt");

    let (session, patch) = fixture
        .open(DiffSource::Unstaged {
            repo_root: fixture.repo_root(),
        })
        .await;

    // The superproject's own change and gitlink line are still there.
    assert!(patch.contains("diff --git a/top.txt b/top.txt"), "{patch}");
    assert!(patch.contains("Subproject commit"), "{patch}");
    // Files inside the submodule, named under its folder.
    assert!(
        patch.contains("diff --git a/libs/sub/f.txt b/libs/sub/f.txt"),
        "{patch}"
    );
    assert!(patch.contains("+two"), "{patch}");
    // Its untracked files, like the repository's own.
    assert!(patch.contains("b/libs/sub/new.txt"), "{patch}");
    assert!(patch.contains("+brand new"), "{patch}");
    // A nested submodule's files, under both folders.
    assert!(
        patch.contains("diff --git a/libs/sub/deep/d.txt b/libs/sub/deep/d.txt"),
        "{patch}"
    );
    assert!(patch.contains("+deep two"), "{patch}");

    // Load full files reads a submodule file from the submodule's commit
    // and the work tree.
    assert_eq!(
        fixture.sides(&session, "libs/sub/f.txt").await,
        (Some("one\n".to_owned()), Some("one\ntwo\n".to_owned()))
    );
    assert_eq!(
        fixture.sides(&session, "libs/sub/deep/d.txt").await,
        (
            Some("deep one\n".to_owned()),
            Some("deep one\ndeep two\n".to_owned())
        )
    );
}

#[tokio::test]
async fn staged_sessions_diff_between_the_recorded_submodule_commits() {
    let fixture = Fixture::new("staged");
    std::fs::write(fixture.sub().join("f.txt"), "one\nstaged\n").expect("edit f.txt");
    git(&fixture.sub(), &["commit", "--quiet", "-am", "sub change"]);
    git(&fixture.repo, &["add", "libs/sub"]);
    // A later, unstaged edit inside the submodule is not part of the
    // staged diff.
    std::fs::write(fixture.sub().join("f.txt"), "one\nstaged\nlater\n").expect("edit again");

    let (session, patch) = fixture
        .open(DiffSource::Staged {
            repo_root: fixture.repo_root(),
        })
        .await;

    assert!(
        patch.contains("diff --git a/libs/sub/f.txt b/libs/sub/f.txt"),
        "{patch}"
    );
    assert!(patch.contains("+staged"), "{patch}");
    assert!(!patch.contains("+later"), "{patch}");
    assert_eq!(
        fixture.sides(&session, "libs/sub/f.txt").await,
        (Some("one\n".to_owned()), Some("one\nstaged\n".to_owned()))
    );
}

#[tokio::test]
async fn branch_sessions_diff_submodules_from_the_merge_base() {
    let fixture = Fixture::new("branch");
    git(&fixture.repo, &["checkout", "--quiet", "-b", "feature"]);
    std::fs::write(fixture.sub().join("f.txt"), "one\ncommitted\n").expect("edit f.txt");
    git(&fixture.sub(), &["commit", "--quiet", "-am", "sub change"]);
    git(&fixture.repo, &["commit", "--quiet", "-am", "bump sub"]);
    std::fs::write(fixture.sub().join("f.txt"), "one\ncommitted\nworking\n").expect("edit again");

    let (_, patch) = fixture
        .open(DiffSource::Branch {
            repo_root: fixture.repo_root(),
            base_ref: Some("main".to_owned()),
        })
        .await;

    assert!(
        patch.contains("diff --git a/libs/sub/f.txt b/libs/sub/f.txt"),
        "{patch}"
    );
    assert!(patch.contains("+committed"), "{patch}");
    assert!(patch.contains("+working"), "{patch}");
}

#[tokio::test]
async fn a_submodule_that_is_not_checked_out_keeps_only_its_gitlink_line() {
    let fixture = Fixture::new("deinit");
    std::fs::write(fixture.sub().join("f.txt"), "one\ntwo\n").expect("edit f.txt");
    git(&fixture.sub(), &["commit", "--quiet", "-am", "sub change"]);
    git(&fixture.repo, &["add", "libs/sub"]);
    git(
        &fixture.repo,
        &["submodule", "--quiet", "deinit", "--force", "libs/sub"],
    );
    std::fs::write(fixture.repo.join("top.txt"), "top\nmore\n").expect("edit top.txt");

    let (_, patch) = fixture
        .open(DiffSource::Staged {
            repo_root: fixture.repo_root(),
        })
        .await;

    // The empty folder of a submodule that is not checked out must never
    // run git in the superproject, which would list `top.txt` under it.
    assert!(patch.contains("Subproject commit"), "{patch}");
    assert!(!patch.contains("libs/sub/"), "{patch}");
}
