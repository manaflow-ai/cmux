//! `fileContents` (`file_contents.rs`): a session's two sides of a file, as its
//! patch compares them, for the token that owns the session and only for the
//! paths the patch names.

use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::PROTOCOL_VERSION;
use crate::protocol::{
    DiffCommand, DiffRequest, DiffResponse, DiffResult, DiffSource, FileContentsEncoding,
    FileContentsRequest, FileContentsResult, OpenSessionRequest, SessionRequest,
};

use super::file_contents::{
    MAX_FILE_SIDE_BYTES, Side, answer, base64, diff_git_names, patch_names_all, safe_relative_path,
    unquote,
};
use super::{AppState, ResourceScheme, ServerConfig, app_state, handle_protocol_request};

const TOKEN: &str = "0123456789abcdef-files";
const OTHER_TOKEN: &str = "fedcba9876543210-other";

/// A repository and a sidecar root for one test, both removed when dropped.
struct Fixture {
    repo: PathBuf,
    state: AppState,
}

impl Fixture {
    /// `story.txt` and `gone.txt` committed on `main`; `TOKEN` may diff the
    /// repository.
    fn new(name: &str) -> Self {
        let base = std::env::temp_dir().join(format!(
            "cmux-diff-sidecar-files-{}-{name}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        let repo = base.join("repo");
        let root = base.join("root");
        std::fs::create_dir_all(&repo).expect("create repository folder");
        std::fs::create_dir_all(&root).expect("create sidecar root");
        let repo = std::fs::canonicalize(&repo).expect("canonical repository");
        let root = std::fs::canonicalize(&root).expect("canonical root");
        for token in [TOKEN, OTHER_TOKEN] {
            std::fs::write(
                root.join(format!(".branch-session-{token}.json")),
                serde_json::json!({
                    "token": token,
                    "groupID": format!("group-{token}"),
                    "allowedRepoRoots": [repo.to_string_lossy()],
                })
                .to_string(),
            )
            .expect("authorize the token");
            // The host writes each token's manifest before any session opens.
            let seed = root.join(format!("seed-{token}.patch"));
            std::fs::write(&seed, "").expect("write the seed patch");
            std::fs::write(
                root.join(format!(".manifest-{token}.json")),
                serde_json::json!({
                    "token": token,
                    "files": [{
                        "request_path": format!("/seed-{token}.patch"),
                        "file_path": seed.to_string_lossy(),
                        "mime_type": "text/x-diff",
                        "remote_url": null,
                    }],
                })
                .to_string(),
            )
            .expect("write the manifest");
        }
        let config = ServerConfig {
            root: root.clone(),
            cmux_executable: "/nonexistent/cmux".into(),
            executable_path: "/nonexistent/sidecar".into(),
            resource_scheme: ResourceScheme::Page,
        };
        #[cfg(feature = "http-server")]
        let state = app_state(config, 0).expect("state");
        #[cfg(not(feature = "http-server"))]
        let state = app_state(config, 0);
        let fixture = Self { repo, state };
        fixture.git(&["init", "--quiet", "--initial-branch=main"]);
        fixture.write("story.txt", &numbered(1..=40));
        fixture.write("gone.txt", "old\n");
        fixture.git(&["add", "."]);
        fixture.git(&["commit", "--quiet", "-m", "initial"]);
        fixture
    }

    fn write(&self, name: &str, text: &str) {
        let path = self.repo.join(name);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).expect("create folder");
        }
        std::fs::write(path, text).expect("write file");
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
            .current_dir(&self.repo)
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

    fn repo_root(&self) -> String {
        self.repo.to_string_lossy().into_owned()
    }

    async fn send(&self, command: DiffCommand) -> DiffResponse {
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

    /// Opens a session on `source`; its id.
    async fn open(&self, source: DiffSource) -> String {
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
        opened.session_id
    }

    async fn contents(
        &self,
        session: &str,
        token: &str,
        path: &str,
        previous: Option<&str>,
        encoding: Option<FileContentsEncoding>,
    ) -> Result<FileContentsResult, String> {
        let response = self
            .send(DiffCommand::FileContents(FileContentsRequest {
                session_id: session.to_owned(),
                capability_token: token.to_owned(),
                path: path.to_owned(),
                previous_path: previous.map(str::to_owned),
                encoding,
            }))
            .await;
        match (response.result, response.error) {
            (Some(DiffResult::FileContents(result)), _) => Ok(result),
            (_, Some(error)) => Err(error.code),
            _ => Err("noAnswer".to_owned()),
        }
    }

    async fn text(&self, session: &str, path: &str) -> (Option<String>, Option<String>) {
        let result = self
            .contents(session, TOKEN, path, None, None)
            .await
            .expect("read the file");
        (
            result.old.map(|side| side.contents),
            result.new.map(|side| side.contents),
        )
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        if let Some(base) = self.repo.parent() {
            let _ = std::fs::remove_dir_all(base);
        }
    }
}

fn numbered(lines: std::ops::RangeInclusive<u32>) -> String {
    lines.fold(String::new(), |mut text, line| {
        let _ = writeln!(text, "row {line}");
        text
    })
}

/// `story.txt` with rows 5 and 30 changed, as the edits below write it.
fn edited_story() -> String {
    numbered(1..=40)
        .replace("row 5\n", "row five\n")
        .replace("row 30\n", "row thirty\n")
}

#[tokio::test]
async fn unstaged_sessions_read_the_index_against_the_work_tree() {
    let fixture = Fixture::new("unstaged");
    // The index has row five; the work tree also has row thirty.
    fixture.write(
        "story.txt",
        &numbered(1..=40).replace("row 5\n", "row five\n"),
    );
    fixture.git(&["add", "story.txt"]);
    fixture.write("story.txt", &edited_story());
    fixture.write("new.txt", "brand new\n");
    std::fs::remove_file(fixture.repo.join("gone.txt")).expect("delete gone.txt");
    let session = fixture
        .open(DiffSource::Unstaged {
            repo_root: fixture.repo_root(),
        })
        .await;

    let (old, new) = fixture.text(&session, "story.txt").await;
    assert_eq!(
        old.as_deref(),
        Some(numbered(1..=40).replace("row 5\n", "row five\n").as_str())
    );
    assert_eq!(new.as_deref(), Some(edited_story().as_str()));
    // An untracked file has no old side; a deleted one no new side.
    assert_eq!(
        fixture.text(&session, "new.txt").await,
        (None, Some("brand new\n".to_owned()))
    );
    assert_eq!(
        fixture.text(&session, "gone.txt").await,
        (Some("old\n".to_owned()), None)
    );
}

#[tokio::test]
async fn staged_sessions_read_head_against_the_index() {
    let fixture = Fixture::new("staged");
    fixture.write("story.txt", &edited_story());
    fixture.git(&["add", "story.txt"]);
    // A work tree change after staging is not the staged diff's new side.
    fixture.write("story.txt", "not staged\n");
    let session = fixture
        .open(DiffSource::Staged {
            repo_root: fixture.repo_root(),
        })
        .await;
    let (old, new) = fixture.text(&session, "story.txt").await;
    assert_eq!(old.as_deref(), Some(numbered(1..=40).as_str()));
    assert_eq!(new.as_deref(), Some(edited_story().as_str()));
}

#[tokio::test]
async fn branch_sessions_read_their_base_commit_against_the_work_tree() {
    let fixture = Fixture::new("branch");
    fixture.git(&["checkout", "--quiet", "-b", "feature"]);
    fixture.write(
        "story.txt",
        &numbered(1..=40).replace("row 5\n", "row five\n"),
    );
    fixture.git(&["commit", "--quiet", "-am", "feature"]);
    // Uncommitted on top of the branch: the branch diff shows it too.
    fixture.write("story.txt", &edited_story());
    let session = fixture
        .open(DiffSource::Branch {
            repo_root: fixture.repo_root(),
            base_ref: Some("main".to_owned()),
        })
        .await;
    let (old, new) = fixture.text(&session, "story.txt").await;
    assert_eq!(old.as_deref(), Some(numbered(1..=40).as_str()));
    assert_eq!(new.as_deref(), Some(edited_story().as_str()));

    // Uncommitted (the branch against HEAD): the old side is the branch tip.
    let uncommitted = fixture
        .open(DiffSource::Branch {
            repo_root: fixture.repo_root(),
            base_ref: Some("HEAD".to_owned()),
        })
        .await;
    let (old, _) = fixture.text(&uncommitted, "story.txt").await;
    assert_eq!(
        old.as_deref(),
        Some(numbered(1..=40).replace("row 5\n", "row five\n").as_str())
    );
}

#[tokio::test]
async fn a_rename_reads_its_old_side_from_its_previous_path() {
    let fixture = Fixture::new("rename");
    fixture.git(&["mv", "story.txt", "tale.txt"]);
    fixture.write("tale.txt", &edited_story());
    fixture.git(&["add", "tale.txt"]);
    let session = fixture
        .open(DiffSource::Staged {
            repo_root: fixture.repo_root(),
        })
        .await;
    let result = fixture
        .contents(&session, TOKEN, "tale.txt", Some("story.txt"), None)
        .await
        .expect("read the rename");
    assert_eq!(
        result.old.map(|side| side.contents).as_deref(),
        Some(numbered(1..=40).as_str())
    );
    assert_eq!(
        result.new.map(|side| side.contents).as_deref(),
        Some(edited_story().as_str())
    );
}

#[tokio::test]
async fn only_the_sessions_token_and_its_patch_paths_may_read() {
    let fixture = Fixture::new("refusals");
    fixture.write("story.txt", &edited_story());
    fixture.write("secret.txt", "not changed, not in the diff\n");
    fixture.git(&["add", "secret.txt"]);
    fixture.git(&["commit", "--quiet", "-m", "secret"]);
    let session = fixture
        .open(DiffSource::Unstaged {
            repo_root: fixture.repo_root(),
        })
        .await;
    let refused = |result: Result<FileContentsResult, String>| {
        assert_eq!(result.err().as_deref(), Some("notAllowed"));
    };
    // Another tab's token, a path the patch does not name, an escape, a
    // previous path outside the patch, and a session that does not exist.
    refused(
        fixture
            .contents(&session, OTHER_TOKEN, "story.txt", None, None)
            .await,
    );
    refused(
        fixture
            .contents(&session, TOKEN, "secret.txt", None, None)
            .await,
    );
    refused(
        fixture
            .contents(&session, TOKEN, "../root/x", None, None)
            .await,
    );
    refused(
        fixture
            .contents(&session, TOKEN, "/etc/hosts", None, None)
            .await,
    );
    refused(
        fixture
            .contents(&session, TOKEN, "story.txt", Some("secret.txt"), None)
            .await,
    );
    refused(
        fixture
            .contents(
                &uuid::Uuid::new_v4().to_string(),
                TOKEN,
                "story.txt",
                None,
                None,
            )
            .await,
    );
    // A closed session reads nothing.
    let closed = fixture
        .send(DiffCommand::SessionClose(SessionRequest {
            session_id: session.clone(),
            capability_token: TOKEN.to_owned(),
        }))
        .await;
    assert!(closed.error.is_none(), "{:?}", closed.error);
    refused(
        fixture
            .contents(&session, TOKEN, "story.txt", None, None)
            .await,
    );
}

#[tokio::test]
async fn a_side_over_the_limit_sends_neither_side() {
    let fixture = Fixture::new("large");
    let large = "x".repeat(usize::try_from(MAX_FILE_SIDE_BYTES).expect("limit") + 1);
    fixture.write("story.txt", &large);
    let session = fixture
        .open(DiffSource::Unstaged {
            repo_root: fixture.repo_root(),
        })
        .await;
    let result = fixture
        .contents(&session, TOKEN, "story.txt", None, None)
        .await
        .expect("answer");
    assert_eq!(result.too_large, Some(true));
    assert!(result.old.is_none() && result.new.is_none());
}

#[tokio::test]
async fn binary_files_read_as_base64() {
    let fixture = Fixture::new("binary");
    let pixel: &[u8] = &[0x89, b'P', b'N', b'G', 0, 1, 2, 0xff];
    std::fs::write(fixture.repo.join("dot.png"), pixel).expect("write image");
    let session = fixture
        .open(DiffSource::Unstaged {
            repo_root: fixture.repo_root(),
        })
        .await;
    let result = fixture
        .contents(
            &session,
            TOKEN,
            "dot.png",
            None,
            Some(FileContentsEncoding::Base64),
        )
        .await
        .expect("read the image");
    let new = result.new.expect("new side");
    assert_eq!(new.encoding, FileContentsEncoding::Base64);
    assert_eq!(new.contents, base64(pixel));
    assert!(result.old.is_none());
}

#[tokio::test]
async fn a_patch_session_has_no_sides() {
    let fixture = Fixture::new("patch-source");
    // A patch session is not recorded with sides; any id it might have is
    // refused like an unknown one.
    let result = fixture
        .contents(
            &uuid::Uuid::new_v4().to_string(),
            TOKEN,
            "story.txt",
            None,
            None,
        )
        .await;
    assert_eq!(result.err().as_deref(), Some("notAllowed"));
}

#[test]
fn paths_must_stay_inside_the_repository() {
    assert!(safe_relative_path("src/main.rs"));
    assert!(safe_relative_path("a b/c.txt"));
    for path in ["", "/etc/hosts", "../x", "a/../b", "./a", "a\0b"] {
        assert!(!safe_relative_path(path), "{path:?}");
    }
}

#[test]
fn headers_name_paths_and_hunk_bodies_do_not() {
    let base =
        std::env::temp_dir().join(format!("cmux-diff-sidecar-names-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&base).expect("folder");
    let patch = base.join("session.patch");
    std::fs::write(
        &patch,
        concat!(
            "diff --git a/one.txt b/one.txt\n",
            "index 1..2 100644\n",
            "--- a/one.txt\n",
            "+++ b/one.txt\n",
            "@@ -1 +1 @@\n",
            "--- a/hidden.txt\n",
            "+changed\n",
            "diff --git a/old name.txt b/new name.txt\n",
            "similarity index 90%\n",
            "rename from old name.txt\n",
            "rename to new name.txt\n",
            "diff --git a/image.png b/image.png\n",
            "GIT binary patch\n",
            "literal 1\n",
            "diff --git \"a/sp\\303\\251cial.txt\" \"b/sp\\303\\251cial.txt\"\n",
        ),
    )
    .expect("write patch");
    let names = |paths: &[&str]| {
        patch_names_all(
            &patch,
            &paths
                .iter()
                .map(|path| (*path).to_owned())
                .collect::<Vec<_>>(),
        )
    };
    assert!(names(&["one.txt"]));
    assert!(names(&["new name.txt", "old name.txt"]));
    assert!(names(&["image.png"]));
    assert!(names(&["spécial.txt"]));
    // A removed line that reads like a header is hunk content.
    assert!(!names(&["hidden.txt"]));
    assert!(!names(&["one.txt", "missing.txt"]));
    let _ = std::fs::remove_dir_all(base);
    assert!(!patch_names_all(
        Path::new("/nonexistent/patch"),
        &["one.txt".to_owned()]
    ));
}

#[test]
fn diff_git_lines_split_only_when_unambiguous() {
    assert_eq!(diff_git_names("a/x.txt b/x.txt"), ["x.txt"]);
    assert_eq!(diff_git_names("a/a b.txt b/a b.txt"), ["a b.txt"]);
    // A rename with a space can not be split by length; its other lines name it.
    assert!(diff_git_names("a/old b/new name").is_empty());
    assert_eq!(
        diff_git_names("\"a/q\\\"x\" \"b/q\\\"y\""),
        ["q\"x", "q\"y"]
    );
    assert_eq!(unquote("\"t\\tab\""), "t\tab");
    assert_eq!(unquote("plain"), "plain");
}

#[test]
fn base64_matches_the_standard_alphabet() {
    assert_eq!(base64(b""), "");
    assert_eq!(base64(b"f"), "Zg==");
    assert_eq!(base64(b"fo"), "Zm8=");
    assert_eq!(base64(b"foo"), "Zm9v");
    assert_eq!(base64(&[0xfb, 0xff]), "+/8=");
}

#[test]
fn answers_send_no_contents_when_too_large() {
    let large = answer(
        Side::TooLarge,
        Side::Bytes(b"x".to_vec()),
        FileContentsEncoding::Text,
    );
    assert_eq!(large.too_large, Some(true));
    assert!(large.old.is_none() && large.new.is_none());
    let added = answer(
        Side::Missing,
        Side::Bytes(b"new\n".to_vec()),
        FileContentsEncoding::Text,
    );
    assert!(added.old.is_none());
    assert_eq!(
        added.new.as_ref().map(|side| side.contents.as_str()),
        Some("new\n")
    );
    assert_eq!(added.too_large, None);
    // Not sent when unset, so the page reads a missing side as no file.
    let encoded = serde_json::to_value(&added).expect("encode");
    assert!(
        encoded.get("old").is_none() && encoded.get("tooLarge").is_none(),
        "{encoded}"
    );
}

#[test]
fn the_capability_is_in_the_handshake() {
    let response = crate::protocol::handshake("h".to_owned());
    let Some(DiffResult::Handshake(handshake)) = response.result else {
        panic!("no handshake");
    };
    assert!(
        handshake
            .capabilities
            .contains(&crate::protocol::FILE_CONTENTS_CAPABILITY.to_owned())
    );
}
