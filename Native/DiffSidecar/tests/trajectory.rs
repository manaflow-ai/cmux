use std::fs;
use std::path::{Path, PathBuf};

use cmux_diff_sidecar::protocol::{AgentProvider, DiffSource};
use cmux_diff_sidecar::trajectory::{AgentTurnIdentity, TrajectoryRoots, resolve_last_turn_patch};
use rusqlite::Connection;

struct FixtureRoot {
    path: PathBuf,
}

impl FixtureRoot {
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "cmux-diff-trajectory-{name}-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        fs::create_dir_all(&path).expect("create fixture root");
        Self { path }
    }

    fn home(&self) -> PathBuf {
        self.path.join("home")
    }

    fn repo(&self) -> PathBuf {
        self.path.join("repo")
    }
}

impl Drop for FixtureRoot {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

#[test]
fn agent_turn_source_carries_identity_without_a_git_baseline() {
    let source: DiffSource = serde_json::from_value(serde_json::json!({
        "kind": "agentTurn",
        "provider": "codex",
        "sessionId": "session-123"
    }))
    .expect("decode agent turn source");

    assert_eq!(
        source,
        DiffSource::AgentTurn {
            provider: AgentProvider::Codex,
            session_id: "session-123".to_owned(),
        }
    );
    let encoded = serde_json::to_value(source).expect("encode agent turn source");
    assert!(encoded.get("repoRoot").is_none());
    assert!(encoded.get("baseCommit").is_none());
}

#[test]
fn codex_resolver_uses_patch_events_from_the_latest_turn_id() {
    let fixture = FixtureRoot::new("codex");
    prepare_common_directories(&fixture);
    let transcript = fixture.home().join("codex-latest.jsonl");
    let repo = fixture.repo();
    let old_path = repo.join("old.txt");
    let current_path = repo.join("current.txt");
    write_lines(
        &transcript,
        &[
            serde_json::json!({"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-old"}}),
            serde_json::json!({"type":"event_msg","payload":{"type":"patch_apply_end","turn_id":"turn-old","success":true,"status":"completed","changes":{
                old_path.to_string_lossy(): {"type":"update","move_path":null,"unified_diff":"@@ -1 +1 @@\n-old\n+stale\n"},
                "/tmp/outside-repository.txt": {"type":"update","move_path":null,"unified_diff":"@@ -1 +1 @@\n-old\n+outside\n"}
            }}}),
            serde_json::json!({"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-old"}}),
            serde_json::json!({"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-current"}}),
            serde_json::json!({"type":"event_msg","payload":{"type":"patch_apply_end","turn_id":"turn-current","success":true,"status":"completed","changes":{
                current_path.to_string_lossy(): {"type":"update","move_path":null,"unified_diff":"@@ -1 +1 @@\n-before\n+after\n"},
                repo.join("created.txt").to_string_lossy(): {"type":"add","content":"created\n"}
            }}}),
        ],
    );
    write_hook_store(
        &fixture.home(),
        "codex",
        "codex-session",
        &repo,
        Some(&transcript),
    );

    let resolved = resolve_last_turn_patch(
        &AgentTurnIdentity::new(AgentProvider::Codex, "codex-session"),
        &TrajectoryRoots::for_home(fixture.home()),
    )
    .expect("resolve Codex turn patch");

    assert_eq!(
        resolved.repo_root,
        repo.canonicalize().expect("canonical repo")
    );
    assert!(
        resolved
            .patch
            .contains("diff --git a/current.txt b/current.txt")
    );
    assert!(resolved.patch.contains("+after"));
    assert!(
        resolved
            .patch
            .contains("diff --git a/created.txt b/created.txt")
    );
    assert!(resolved.patch.contains("+created"));
    assert!(!resolved.patch.contains("old.txt"));
    assert!(!resolved.patch.contains("+stale"));
}

#[test]
fn codex_resolver_fails_closed_when_latest_turn_has_no_id() {
    let fixture = FixtureRoot::new("codex-missing-turn-id");
    prepare_common_directories(&fixture);
    let transcript = fixture.home().join("codex-missing-turn-id.jsonl");
    let repo = fixture.repo();
    write_lines(
        &transcript,
        &[
            serde_json::json!({"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-old"}}),
            codex_patch_event("turn-old", &repo.join("old.txt"), "+stale"),
            serde_json::json!({"type":"event_msg","payload":{"type":"task_started"}}),
        ],
    );
    write_hook_store(
        &fixture.home(),
        "codex",
        "session",
        &repo,
        Some(&transcript),
    );

    let error = resolve_last_turn_patch(
        &AgentTurnIdentity::new(AgentProvider::Codex, "session"),
        &TrajectoryRoots::for_home(fixture.home()),
    )
    .expect_err("missing latest turn identity must not return the prior patch");

    assert_eq!(error.to_string(), "agent trajectory is invalid");
}

#[test]
fn codex_resolver_uses_hook_or_database_record_atomically() {
    let fixture = FixtureRoot::new("codex-atomic-record");
    prepare_common_directories(&fixture);
    let home = fixture.home();
    let database_repo = fixture.repo();
    let hook_repo = fixture.path.join("hook-repo");
    fs::create_dir_all(&hook_repo).expect("create hook repo");
    let database_transcript = home.join("database.jsonl");
    let hook_transcript = home.join("hook.jsonl");
    write_lines(
        &database_transcript,
        &[
            serde_json::json!({"type":"event_msg","payload":{"type":"task_started","turn_id":"turn"}}),
            codex_patch_event("turn", &database_repo.join("database.txt"), "+database"),
        ],
    );
    write_lines(
        &hook_transcript,
        &[
            serde_json::json!({"type":"event_msg","payload":{"type":"task_started","turn_id":"turn"}}),
            codex_patch_event("turn", &hook_repo.join("hook.txt"), "+hook"),
        ],
    );
    write_partial_hook_store(&home, "codex", "session", None, Some(&hook_transcript));
    let database_path = home.join(".codex/state_5.sqlite");
    fs::create_dir_all(database_path.parent().expect("database parent"))
        .expect("create Codex database directory");
    let database = Connection::open(database_path).expect("open Codex database");
    database
        .execute_batch(
            "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, cwd TEXT);",
        )
        .expect("create Codex schema");
    database
        .execute(
            "INSERT INTO threads (id, rollout_path, cwd) VALUES (?1, ?2, ?3)",
            (
                "session",
                database_transcript.to_string_lossy().as_ref(),
                database_repo.to_string_lossy().as_ref(),
            ),
        )
        .expect("insert Codex record");

    let resolved = resolve_last_turn_patch(
        &AgentTurnIdentity::new(AgentProvider::Codex, "session"),
        &TrajectoryRoots::for_home(home),
    )
    .expect("fall back to the complete database record");

    assert_eq!(
        resolved.repo_root,
        database_repo.canonicalize().expect("canonical repo")
    );
    assert!(resolved.patch.contains("+database"));
    assert!(!resolved.patch.contains("+hook"));
}

#[test]
fn codex_resolver_normalizes_a_nested_cwd_to_the_repository_root() {
    let fixture = FixtureRoot::new("codex-nested-cwd");
    prepare_common_directories(&fixture);
    init_git_repository(&fixture.repo());
    let nested = fixture.repo().join("Sources/Feature");
    fs::create_dir_all(&nested).expect("create nested working directory");
    let transcript = fixture.home().join("codex-nested.jsonl");
    write_lines(
        &transcript,
        &[
            serde_json::json!({"type":"event_msg","payload":{"type":"task_started","turn_id":"turn"}}),
            codex_patch_event("turn", &fixture.repo().join("README.md"), "+changed"),
        ],
    );
    write_hook_store(
        &fixture.home(),
        "codex",
        "session",
        &nested,
        Some(&transcript),
    );

    let resolved = resolve_last_turn_patch(
        &AgentTurnIdentity::new(AgentProvider::Codex, "session"),
        &TrajectoryRoots::for_home(fixture.home()),
    )
    .expect("resolve from a nested launch directory");

    assert_eq!(
        resolved.repo_root,
        fixture.repo().canonicalize().expect("canonical repo")
    );
    assert!(
        resolved
            .patch
            .contains("diff --git a/README.md b/README.md")
    );
}

#[test]
fn codex_deletion_uses_recorded_content_when_unified_diff_is_absent() {
    let fixture = FixtureRoot::new("codex-delete-content");
    prepare_common_directories(&fixture);
    let transcript = fixture.home().join("codex-delete.jsonl");
    let deleted_path = fixture.repo().join("deleted.txt");
    write_lines(
        &transcript,
        &[
            serde_json::json!({"type":"event_msg","payload":{"type":"task_started","turn_id":"turn"}}),
            serde_json::json!({
                "type":"event_msg",
                "payload":{
                    "type":"patch_apply_end",
                    "turn_id":"turn",
                    "success":true,
                    "changes":{
                        deleted_path.to_string_lossy(): {
                            "type":"delete",
                            "content":"first\nsecond"
                        }
                    }
                }
            }),
        ],
    );
    write_hook_store(
        &fixture.home(),
        "codex",
        "session",
        &fixture.repo(),
        Some(&transcript),
    );

    let resolved = resolve_last_turn_patch(
        &AgentTurnIdentity::new(AgentProvider::Codex, "session"),
        &TrajectoryRoots::for_home(fixture.home()),
    )
    .expect("resolve deletion from recorded content");

    assert!(resolved.patch.contains("@@ -1,2 +0,0 @@"));
    assert!(resolved.patch.contains("-first\n-second\n"));
    assert!(resolved.patch.contains("\\ No newline at end of file"));
}

#[test]
fn claude_resolver_uses_structured_patches_from_the_latest_prompt_id() {
    let fixture = FixtureRoot::new("claude");
    prepare_common_directories(&fixture);
    let transcript = fixture.home().join("claude-latest.jsonl");
    let repo = fixture.repo();
    write_lines(
        &transcript,
        &[
            claude_prompt("prompt-old", "old request"),
            claude_patch_result("prompt-old", &repo.join("old.txt"), "-stale", "+older"),
            claude_prompt("prompt-current", "current request"),
            serde_json::json!({
                "type": "user",
                "promptId": "prompt-current",
                "toolUseResult": {"stdout": "command output", "interrupted": false}
            }),
            claude_patch_result(
                "prompt-current",
                &repo.join("current.txt"),
                "-before",
                "+after",
            ),
        ],
    );
    write_hook_store(
        &fixture.home(),
        "claude",
        "claude-session",
        &repo,
        Some(&transcript),
    );

    let resolved = resolve_last_turn_patch(
        &AgentTurnIdentity::new(AgentProvider::Claude, "claude-session"),
        &TrajectoryRoots::for_home(fixture.home()),
    )
    .expect("resolve Claude turn patch");

    assert!(
        resolved
            .patch
            .contains("diff --git a/current.txt b/current.txt")
    );
    assert!(resolved.patch.contains("+after"));
    assert!(!resolved.patch.contains("old.txt"));
    assert!(!resolved.patch.contains("+older"));
}

#[test]
fn claude_resolver_does_not_reuse_patch_after_prompt_without_id() {
    let fixture = FixtureRoot::new("claude-missing-prompt-id");
    prepare_common_directories(&fixture);
    let transcript = fixture.home().join("claude-missing-prompt-id.jsonl");
    let repo = fixture.repo();
    write_lines(
        &transcript,
        &[
            claude_prompt("prompt-old", "old request"),
            claude_patch_result("prompt-old", &repo.join("old.txt"), "-old", "+stale"),
            serde_json::json!({"type":"user","message":{"role":"user","content":"latest request"}}),
        ],
    );
    write_hook_store(
        &fixture.home(),
        "claude",
        "session",
        &repo,
        Some(&transcript),
    );

    let error = resolve_last_turn_patch(
        &AgentTurnIdentity::new(AgentProvider::Claude, "session"),
        &TrajectoryRoots::for_home(fixture.home()),
    )
    .expect_err("missing latest prompt identity must not return the prior patch");

    assert_eq!(error.to_string(), "agent turn has no recorded patches");
}

#[test]
fn claude_resolver_rejects_malformed_jsonl() {
    let fixture = FixtureRoot::new("claude-malformed-jsonl");
    prepare_common_directories(&fixture);
    let transcript = fixture.home().join("claude-malformed.jsonl");
    let repo = fixture.repo();
    fs::write(
        &transcript,
        format!(
            "{}\nnot-json\n",
            claude_patch_result("prompt", &repo.join("old.txt"), "-old", "+stale")
        ),
    )
    .expect("write malformed transcript");
    write_hook_store(
        &fixture.home(),
        "claude",
        "session",
        &repo,
        Some(&transcript),
    );

    let error = resolve_last_turn_patch(
        &AgentTurnIdentity::new(AgentProvider::Claude, "session"),
        &TrajectoryRoots::for_home(fixture.home()),
    )
    .expect_err("malformed records must fail closed");

    assert_eq!(error.to_string(), "agent trajectory is invalid");
}

#[test]
fn claude_resolver_rejects_a_jsonl_record_over_the_line_limit() {
    let fixture = FixtureRoot::new("claude-oversized-jsonl-record");
    prepare_common_directories(&fixture);
    let transcript = fixture.home().join("claude-oversized.jsonl");
    let repo = fixture.repo();
    let oversized = serde_json::json!({
        "type": "user",
        "cwd": repo,
        "padding": "x".repeat(16 * 1024 * 1024)
    });
    fs::write(&transcript, oversized.to_string()).expect("write oversized transcript record");
    write_hook_store(
        &fixture.home(),
        "claude",
        "session",
        &repo,
        Some(&transcript),
    );

    let error = resolve_last_turn_patch(
        &AgentTurnIdentity::new(AgentProvider::Claude, "session"),
        &TrajectoryRoots::for_home(fixture.home()),
    )
    .expect_err("oversized JSONL records must fail closed");

    assert_eq!(error.to_string(), "agent trajectory is invalid");
}

#[test]
fn claude_resolver_skips_out_of_repo_patch_results() {
    let fixture = FixtureRoot::new("claude-outside-repo");
    prepare_common_directories(&fixture);
    let transcript = fixture.home().join("claude-outside-repo.jsonl");
    let repo = fixture.repo();
    write_lines(
        &transcript,
        &[
            claude_prompt("prompt", "request"),
            claude_patch_result(
                "prompt",
                &fixture.path.join("outside.txt"),
                "-old",
                "+outside",
            ),
            claude_patch_result("prompt", &repo.join("inside.txt"), "-old", "+inside"),
        ],
    );
    write_hook_store(
        &fixture.home(),
        "claude",
        "session",
        &repo,
        Some(&transcript),
    );

    let resolved = resolve_last_turn_patch(
        &AgentTurnIdentity::new(AgentProvider::Claude, "session"),
        &TrajectoryRoots::for_home(fixture.home()),
    )
    .expect("keep authorized patch results");

    assert!(resolved.patch.contains("inside.txt"));
    assert!(resolved.patch.contains("+inside"));
    assert!(!resolved.patch.contains("outside.txt"));
}

#[test]
fn claude_insertion_only_update_is_not_rendered_as_new_file() {
    let fixture = FixtureRoot::new("claude-insertion-update");
    prepare_common_directories(&fixture);
    let transcript = fixture.home().join("claude-insertion-update.jsonl");
    let repo = fixture.repo();
    let mut result = claude_patch_result(
        "prompt",
        &repo.join("existing.txt"),
        " context",
        "+inserted",
    );
    result["toolUseResult"]["type"] = serde_json::json!("update");
    result["toolUseResult"]["structuredPatch"][0]["oldLines"] = serde_json::json!(0);
    result["toolUseResult"]["structuredPatch"][0]["newLines"] = serde_json::json!(1);
    write_lines(&transcript, &[claude_prompt("prompt", "request"), result]);
    write_hook_store(
        &fixture.home(),
        "claude",
        "session",
        &repo,
        Some(&transcript),
    );

    let resolved = resolve_last_turn_patch(
        &AgentTurnIdentity::new(AgentProvider::Claude, "session"),
        &TrajectoryRoots::for_home(fixture.home()),
    )
    .expect("resolve insertion-only update");

    assert!(resolved.patch.contains("--- a/existing.txt"));
    assert!(!resolved.patch.contains("new file mode"));
    assert!(!resolved.patch.contains("--- /dev/null"));
}

#[test]
fn claude_create_with_empty_structured_patch_uses_recorded_content() {
    let fixture = FixtureRoot::new("claude-create-content");
    prepare_common_directories(&fixture);
    let transcript = fixture.home().join("claude-create.jsonl");
    let repo = fixture.repo();
    write_lines(
        &transcript,
        &[
            claude_prompt("prompt", "create a file"),
            serde_json::json!({
                "type":"user",
                "promptId":"prompt",
                "toolUseResult":{
                    "type":"create",
                    "filePath":repo.join("created.txt"),
                    "content":"created\n",
                    "structuredPatch":[]
                }
            }),
        ],
    );
    write_hook_store(
        &fixture.home(),
        "claude",
        "session",
        &repo,
        Some(&transcript),
    );

    let resolved = resolve_last_turn_patch(
        &AgentTurnIdentity::new(AgentProvider::Claude, "session"),
        &TrajectoryRoots::for_home(fixture.home()),
    )
    .expect("resolve create from recorded content");

    assert!(resolved.patch.contains("new file mode 100644"));
    assert!(resolved.patch.contains("+++ b/created.txt"));
    assert!(resolved.patch.contains("+created"));
}

#[test]
fn generated_patch_headers_quote_ambiguous_paths() {
    let fixture = FixtureRoot::new("quoted-paths");
    prepare_common_directories(&fixture);
    let transcript = fixture.home().join("quoted-paths.jsonl");
    let repo = fixture.repo();
    write_lines(
        &transcript,
        &[
            serde_json::json!({"type":"event_msg","payload":{"type":"task_started","turn_id":"turn"}}),
            codex_patch_event("turn", &repo.join("quoted \"name\".txt"), "+quoted"),
        ],
    );
    write_hook_store(
        &fixture.home(),
        "codex",
        "session",
        &repo,
        Some(&transcript),
    );

    let resolved = resolve_last_turn_patch(
        &AgentTurnIdentity::new(AgentProvider::Codex, "session"),
        &TrajectoryRoots::for_home(fixture.home()),
    )
    .expect("resolve quoted path");

    assert!(
        resolved
            .patch
            .contains("diff --git \"a/quoted \\\"name\\\".txt\" \"b/quoted \\\"name\\\".txt\"")
    );
    assert!(resolved.patch.contains("--- \"a/quoted \\\"name\\\".txt\""));
}

#[test]
fn session_ids_must_be_single_path_components() {
    let fixture = FixtureRoot::new("invalid-session-path");
    prepare_common_directories(&fixture);

    let error = resolve_last_turn_patch(
        &AgentTurnIdentity::new(AgentProvider::Claude, "../../outside"),
        &TrajectoryRoots::for_home(fixture.home()),
    )
    .expect_err("path-bearing identity must be rejected before transcript lookup");

    assert_eq!(error.to_string(), "agent trajectory is invalid");
}

#[test]
fn opencode_resolver_uses_diffs_parented_to_the_latest_user_message() {
    let fixture = FixtureRoot::new("opencode");
    prepare_common_directories(&fixture);
    let home = fixture.home();
    let repo = fixture.repo();
    let database_path = home.join(".local/share/opencode/opencode.db");
    fs::create_dir_all(database_path.parent().expect("database parent"))
        .expect("create database parent");
    let database = Connection::open(&database_path).expect("open fixture database");
    database
        .execute_batch(
            "CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT NOT NULL);\n\
             CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, data TEXT NOT NULL);\n\
             CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, data TEXT NOT NULL);",
        )
        .expect("create OpenCode schema");
    database
        .execute(
            "INSERT INTO session (id, directory) VALUES (?1, ?2)",
            ("opencode-session", repo.to_string_lossy().as_ref()),
        )
        .expect("insert session");
    insert_opencode_message(
        &database,
        "user-old",
        1,
        &serde_json::json!({"role":"user"}),
    );
    insert_opencode_message(
        &database,
        "assistant-old",
        2,
        &serde_json::json!({"role":"assistant","parentID":"user-old"}),
    );
    insert_opencode_part(
        &database,
        "part-old",
        "assistant-old",
        3,
        "Index: old.txt\n--- a/old.txt\n+++ b/old.txt\n@@ -1 +1 @@\n-stale\n+older\n",
    );
    insert_opencode_message(
        &database,
        "user-current",
        4,
        &serde_json::json!({"role":"user"}),
    );
    insert_opencode_message(
        &database,
        "assistant-current",
        5,
        &serde_json::json!({"role":"assistant","parentID":"user-current"}),
    );
    insert_opencode_part(
        &database,
        "part-current",
        "assistant-current",
        6,
        "Index: current.txt\n--- a/current.txt\n+++ b/current.txt\n@@ -1 +1 @@\n-before\n+after\n",
    );
    drop(database);

    let resolved = resolve_last_turn_patch(
        &AgentTurnIdentity::new(AgentProvider::OpenCode, "opencode-session"),
        &TrajectoryRoots::for_home(home),
    )
    .expect("resolve OpenCode turn patch");

    assert!(resolved.patch.contains("Index: current.txt"));
    assert!(resolved.patch.contains("+after"));
    assert!(!resolved.patch.contains("old.txt"));
    assert!(!resolved.patch.contains("+older"));
}

#[test]
fn opencode_resolver_rejects_patch_paths_outside_the_repository() {
    let fixture = FixtureRoot::new("opencode-outside-repo");
    prepare_common_directories(&fixture);
    let home = fixture.home();
    let repo = fixture.repo();
    let database_path = home.join(".local/share/opencode/opencode.db");
    fs::create_dir_all(database_path.parent().expect("database parent"))
        .expect("create database parent");
    let database = Connection::open(&database_path).expect("open fixture database");
    database
        .execute_batch(
            "CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT NOT NULL);\n\
             CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, data TEXT NOT NULL);\n\
             CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, data TEXT NOT NULL);",
        )
        .expect("create OpenCode schema");
    database
        .execute(
            "INSERT INTO session (id, directory) VALUES (?1, ?2)",
            ("opencode-session", repo.to_string_lossy().as_ref()),
        )
        .expect("insert session");
    insert_opencode_message(
        &database,
        "user-current",
        1,
        &serde_json::json!({"role":"user"}),
    );
    insert_opencode_message(
        &database,
        "assistant-current",
        2,
        &serde_json::json!({"role":"assistant","parentID":"user-current"}),
    );
    insert_opencode_part(
        &database,
        "part-current",
        "assistant-current",
        3,
        "Index: /tmp/outside.txt\n--- /tmp/outside.txt\n+++ /tmp/outside.txt\n@@ -1 +1 @@\n-before\n+after\n",
    );
    drop(database);

    let error = resolve_last_turn_patch(
        &AgentTurnIdentity::new(AgentProvider::OpenCode, "opencode-session"),
        &TrajectoryRoots::for_home(home),
    )
    .expect_err("outside-repository OpenCode paths must be rejected");

    assert_eq!(error.to_string(), "agent trajectory is invalid");
}

fn prepare_common_directories(fixture: &FixtureRoot) {
    fs::create_dir_all(fixture.home().join(".cmuxterm")).expect("create hook store directory");
    fs::create_dir_all(fixture.repo()).expect("create repository directory");
}

fn init_git_repository(path: &Path) {
    let status = std::process::Command::new("git")
        .args(["init", "--quiet"])
        .current_dir(path)
        .status()
        .expect("run git init");
    assert!(status.success(), "git init failed");
}

fn write_lines(path: &Path, lines: &[serde_json::Value]) {
    let contents = lines
        .iter()
        .map(serde_json::Value::to_string)
        .collect::<Vec<_>>()
        .join("\n")
        + "\n";
    fs::write(path, contents).expect("write JSONL fixture");
}

fn write_hook_store(
    home: &Path,
    provider: &str,
    session_id: &str,
    repo: &Path,
    transcript: Option<&Path>,
) {
    let mut record = serde_json::json!({
        "sessionId": session_id,
        "workspaceId": "workspace",
        "surfaceId": "surface",
        "cwd": repo,
        "updatedAt": 1,
    });
    if let Some(transcript) = transcript {
        record["transcriptPath"] = serde_json::json!(transcript);
    }
    let store = serde_json::json!({
        "version": 1,
        "sessions": {session_id: record}
    });
    fs::write(
        home.join(format!(".cmuxterm/{provider}-hook-sessions.json")),
        serde_json::to_vec(&store).expect("encode hook store"),
    )
    .expect("write hook store");
}

fn write_partial_hook_store(
    home: &Path,
    provider: &str,
    session_id: &str,
    repo: Option<&Path>,
    transcript: Option<&Path>,
) {
    let mut record = serde_json::json!({});
    if let Some(repo) = repo {
        record["cwd"] = serde_json::json!(repo);
    }
    if let Some(transcript) = transcript {
        record["transcriptPath"] = serde_json::json!(transcript);
    }
    let store = serde_json::json!({
        "version": 1,
        "sessions": {session_id: record}
    });
    fs::write(
        home.join(format!(".cmuxterm/{provider}-hook-sessions.json")),
        serde_json::to_vec(&store).expect("encode partial hook store"),
    )
    .expect("write partial hook store");
}

fn codex_patch_event(turn_id: &str, file_path: &Path, added: &str) -> serde_json::Value {
    serde_json::json!({
        "type": "event_msg",
        "payload": {
            "type": "patch_apply_end",
            "turn_id": turn_id,
            "success": true,
            "changes": {
                file_path.to_string_lossy(): {
                    "type": "update",
                    "move_path": null,
                    "unified_diff": format!("@@ -1 +1 @@\n-old\n{added}\n")
                }
            }
        }
    })
}

fn claude_prompt(prompt_id: &str, text: &str) -> serde_json::Value {
    serde_json::json!({
        "type": "user",
        "promptId": prompt_id,
        "message": {"role":"user","content":text}
    })
}

fn claude_patch_result(
    prompt_id: &str,
    file_path: &Path,
    removed: &str,
    added: &str,
) -> serde_json::Value {
    serde_json::json!({
        "type": "user",
        "promptId": prompt_id,
        "message": {"role":"user","content":[{"type":"tool_result","tool_use_id":"tool"}]},
        "toolUseResult": {
            "filePath": file_path,
            "structuredPatch": [{
                "oldStart": 1,
                "oldLines": 1,
                "newStart": 1,
                "newLines": 1,
                "lines": [removed, added]
            }]
        }
    })
}

fn insert_opencode_message(
    database: &Connection,
    id: &str,
    time_created: i64,
    data: &serde_json::Value,
) {
    database
        .execute(
            "INSERT INTO message (id, session_id, time_created, data) VALUES (?1, ?2, ?3, ?4)",
            (id, "opencode-session", time_created, data.to_string()),
        )
        .expect("insert message");
}

fn insert_opencode_part(
    database: &Connection,
    id: &str,
    message_id: &str,
    time_created: i64,
    diff: &str,
) {
    let data = serde_json::json!({
        "type": "tool",
        "tool": "edit",
        "state": {"metadata": {"diff": diff}}
    });
    database
        .execute(
            "INSERT INTO part (id, message_id, session_id, time_created, data) VALUES (?1, ?2, ?3, ?4, ?5)",
            (id, message_id, "opencode-session", time_created, data.to_string()),
        )
        .expect("insert part");
}
