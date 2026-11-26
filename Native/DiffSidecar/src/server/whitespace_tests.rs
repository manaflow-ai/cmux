//! Hide white space (`OpenSessionRequest.ignoreWhitespace`): a git-backed
//! session diffs with `--ignore-all-space`, for every git source, and its
//! generated paths follow the same diff. Without it the diff is unchanged.

use std::path::PathBuf;
use std::process::Command;

use crate::protocol::{DiffCommand, DiffRequest, DiffSource, OpenSessionRequest, SessionOpened};

use super::{
    SESSION_GIT_TIMEOUT, SessionGit, Whitespace, git_generated_paths, run_git_patch_with_limit,
};

/// A fresh repository for one test, removed when dropped.
struct Repository(PathBuf);

impl Repository {
    /// `indent.txt` and `story.txt` committed on `main`.
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "cmux-diff-sidecar-whitespace-{}-{name}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&path).expect("create repository folder");
        let repository = Self(std::fs::canonicalize(&path).expect("canonical repository"));
        repository.git(&["init", "--quiet", "--initial-branch=main"]);
        repository.write("indent.txt", "alpha\nbeta\n");
        repository.write("story.txt", "one\ntwo\nthree\n");
        repository.git(&["add", "."]);
        repository.git(&["commit", "--quiet", "-m", "initial"]);
        repository
    }

    fn write(&self, name: &str, text: &str) {
        std::fs::write(self.0.join(name), text).expect("write file");
    }

    /// `indent.txt` changes only its white space; `story.txt` changes a word
    /// and the white space of another line.
    fn edit(&self) {
        self.write("indent.txt", "alpha\n    beta\n");
        self.write("story.txt", "one\n two\nTHREE\n");
    }

    /// Runs setup git, isolated from the machine's git config.
    fn git(&self, arguments: &[&str]) {
        let mut command = Command::new("/usr/bin/git");
        for (name, _) in std::env::vars_os() {
            if name.as_encoded_bytes().starts_with(b"GIT_") {
                command.env_remove(name);
            }
        }
        let output = command
            .args(arguments)
            .current_dir(&self.0)
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

    fn root(&self) -> String {
        self.0.to_string_lossy().into_owned()
    }

    /// The session patch of `source`, empty when git printed nothing.
    async fn patch(&self, source: &DiffSource, whitespace: Whitespace) -> String {
        let git = SessionGit::open(&self.0, SESSION_GIT_TIMEOUT)
            .await
            .expect("open the session's git");
        let patch_path = self.0.join(".git").join("session.patch");
        run_git_patch_with_limit(source, whitespace, &git, &patch_path, 1024 * 1024)
            .await
            .expect("write the patch");
        std::fs::read_to_string(&patch_path).expect("read the patch")
    }

    async fn generated(&self, source: &DiffSource, whitespace: Whitespace) -> Vec<String> {
        let git = SessionGit::open(&self.0, SESSION_GIT_TIMEOUT)
            .await
            .expect("open the session's git");
        git_generated_paths(source, whitespace, &git).await
    }
}

impl Drop for Repository {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// The edit with white space shown, then hidden, for one source.
async fn assert_hides_white_space(repository: &Repository, source: &DiffSource) {
    let shown = repository.patch(source, Whitespace::Show).await;
    assert!(shown.contains("b/indent.txt"), "{shown}");
    assert!(shown.contains("+    beta"), "{shown}");
    assert!(shown.contains("+ two"), "{shown}");
    assert!(shown.contains("+THREE"), "{shown}");

    let hidden = repository.patch(source, Whitespace::Ignore).await;
    // A file whose only change is white space leaves the diff.
    assert!(!hidden.contains("indent.txt"), "{hidden}");
    // The real change stays; the white space line is context now.
    assert!(hidden.contains("+THREE"), "{hidden}");
    assert!(hidden.contains("-three"), "{hidden}");
    assert!(!hidden.contains("+ two"), "{hidden}");
    assert!(!hidden.contains("-two"), "{hidden}");
}

#[tokio::test]
async fn unstaged_sessions_hide_white_space() {
    let repository = Repository::new("unstaged");
    repository.edit();
    let source = DiffSource::Unstaged {
        repo_root: repository.root(),
    };
    assert_hides_white_space(&repository, &source).await;
}

#[tokio::test]
async fn staged_sessions_hide_white_space() {
    let repository = Repository::new("staged");
    repository.edit();
    repository.git(&["add", "."]);
    let source = DiffSource::Staged {
        repo_root: repository.root(),
    };
    assert_hides_white_space(&repository, &source).await;
}

#[tokio::test]
async fn branch_sessions_hide_white_space() {
    let repository = Repository::new("branch");
    repository.git(&["checkout", "--quiet", "-b", "feature"]);
    repository.edit();
    repository.git(&["commit", "--quiet", "-am", "feature"]);
    let source = DiffSource::Branch {
        repo_root: repository.root(),
        base_ref: Some("main".to_owned()),
    };
    assert_hides_white_space(&repository, &source).await;
}

#[tokio::test]
async fn hidden_white_space_keeps_untracked_files() {
    let repository = Repository::new("untracked");
    repository.edit();
    repository.write("new.txt", "  brand new\n");
    let source = DiffSource::Unstaged {
        repo_root: repository.root(),
    };
    let hidden = repository.patch(&source, Whitespace::Ignore).await;
    assert!(hidden.contains("b/new.txt"), "{hidden}");
    assert!(hidden.contains("+  brand new"), "{hidden}");
}

#[tokio::test]
async fn only_white_space_changes_make_an_empty_patch() {
    let repository = Repository::new("only-space");
    repository.write("indent.txt", "alpha\n\tbeta\n");
    let source = DiffSource::Unstaged {
        repo_root: repository.root(),
    };
    assert!(!repository.patch(&source, Whitespace::Show).await.is_empty());
    // `open_session` answers an empty patch with `emptyDiff`.
    assert_eq!(repository.patch(&source, Whitespace::Ignore).await, "");
}

#[tokio::test]
async fn generated_paths_follow_the_hidden_white_space() {
    let repository = Repository::new("generated");
    repository.write(
        ".gitattributes",
        "indent.txt linguist-generated\nstory.txt linguist-generated\n",
    );
    repository.git(&["add", ".gitattributes"]);
    repository.git(&["commit", "--quiet", "-m", "attributes"]);
    repository.edit();
    let source = DiffSource::Unstaged {
        repo_root: repository.root(),
    };
    let mut shown = repository.generated(&source, Whitespace::Show).await;
    shown.sort();
    assert_eq!(shown, ["indent.txt", "story.txt"]);
    // indent.txt is not in the hidden diff, so it is not listed.
    assert_eq!(
        repository.generated(&source, Whitespace::Ignore).await,
        ["story.txt"]
    );
}

#[test]
fn only_an_explicit_true_hides_white_space() {
    assert_eq!(Whitespace::requested(None), Whitespace::Show);
    assert_eq!(Whitespace::requested(Some(false)), Whitespace::Show);
    assert_eq!(Whitespace::requested(Some(true)), Whitespace::Ignore);
    assert!(Whitespace::Show.diff_args().is_empty());
    assert_eq!(Whitespace::Ignore.diff_args(), ["--ignore-all-space"]);
}

#[test]
fn the_option_is_optional_on_the_wire() {
    let parse = |params: serde_json::Value| -> OpenSessionRequest {
        let request: DiffRequest = serde_json::from_value(serde_json::json!({
            "id": "open",
            "version": 1,
            "method": "sessionOpen",
            "params": params,
        }))
        .expect("parse the request");
        let DiffCommand::SessionOpen(open) = request.command else {
            panic!("expected sessionOpen");
        };
        open
    };
    let source = serde_json::json!({"kind": "unstaged", "repoRoot": "/repo"});
    let older = parse(serde_json::json!({"source": source, "capabilityToken": "t"}));
    assert_eq!(older.ignore_whitespace, None);
    let hiding = parse(serde_json::json!({
        "source": source,
        "capabilityToken": "t",
        "ignoreWhitespace": true,
    }));
    assert_eq!(hiding.ignore_whitespace, Some(true));
    // Not sent when unset, so an older sidecar reads the same request.
    let encoded = serde_json::to_value(&older).expect("encode the request");
    assert!(encoded.get("ignoreWhitespace").is_none(), "{encoded}");

    // An older sidecar's reply has no field: white space was shown.
    let opened: SessionOpened = serde_json::from_value(serde_json::json!({
        "sessionId": "s",
        "patch": {"id": "p", "mediaType": "text/x-diff", "byteLength": 1, "revision": 1},
        "source": source,
    }))
    .expect("parse the reply");
    assert!(!opened.ignore_whitespace);
}
