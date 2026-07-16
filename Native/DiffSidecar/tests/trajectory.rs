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

fn prepare_common_directories(fixture: &FixtureRoot) {
    fs::create_dir_all(fixture.home().join(".cmuxterm")).expect("create hook store directory");
    fs::create_dir_all(fixture.repo()).expect("create repository directory");
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
