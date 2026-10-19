//! Agent memory end to end on a real OptChat index: sources in, hits out
//! with their source, date and full text; notes appended under the lock;
//! the index rebuilt when a source changes; the MCP server's answers when
//! its owner answers, fails, or is not set.

use std::path::Path;

use optchat_chief::agent_memory::index::Index;
use optchat_chief::agent_memory::mcp::{self, Owner, Server};
use optchat_chief::agent_memory::notes::Provenance;
use optchat_chief::agent_memory::sources::Sources;
use serde_json::{Value, json};

/// Under /tmp: the index's chat lock is a Unix socket, and a macOS
/// per-user temp folder is too deep for its path.
fn short_home() -> tempfile::TempDir {
    tempfile::Builder::new()
        .prefix("am")
        .tempdir_in("/tmp")
        .unwrap()
}

fn write(home: &Path, rel: &str, text: &str) {
    let path = home.join(rel);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

fn index(home: &Path) -> Index {
    Index::new(
        home.join(".cmux/agent-memory"),
        Sources {
            home: home.to_owned(),
            claude: home.join(".claude"),
            codex: home.join(".codex"),
            extra: vec![home.join("decisions")],
            notes: home.join(".cmux/agent-memory-notes.jsonl"),
        },
    )
}

fn seed(home: &Path) {
    write(
        home,
        ".claude/projects/-repo/memory/merge.md",
        "---\nname: merge\n---\nReviewed and green means merge; never --admin.",
    );
    write(
        home,
        ".codex/memories/MEMORY.md",
        "# Task Group: fleet\nbig-red builds need the heavy wrapper.\n# Task Group: ci\nOne background wait per run, never a polling loop.",
    );
    write(
        home,
        "decisions/2026-10-18-memory.md",
        "Agent memory lives in cmux-next.",
    );
}

#[test]
fn search_names_the_source_and_returns_the_full_text() {
    let home = short_home();
    seed(home.path());
    let index = index(home.path());
    assert!(index.stale());
    let hits = index.search("polling loop", 10).unwrap();
    assert_eq!(hits.len(), 1, "{hits:?}");
    let hit = &hits[0];
    assert_eq!(
        hit.source,
        "~/.codex/memories/MEMORY.md group 1: # Task Group: ci"
    );
    assert_eq!(
        hit.text,
        "# Task Group: ci\nOne background wait per run, never a polling loop."
    );
    assert!(hit.snippet.contains("[polling]"), "{}", hit.snippet);
    assert!(
        chrono::DateTime::parse_from_rfc3339(&hit.date).is_ok(),
        "{}",
        hit.date
    );
    assert_eq!(
        index.get(hit.id).unwrap(),
        optchat_chief::agent_memory::index::Hit {
            snippet: String::new(),
            ..hit.clone()
        }
    );
    // A word that looks like a flag is plain text.
    assert_eq!(
        index.search("--admin", 10).unwrap()[0].source,
        "~/.claude/projects/-repo/memory/merge.md"
    );
    assert!(!index.stale());
    assert_eq!(index.refresh(false).unwrap(), "index already current");
}

#[test]
fn a_deleted_or_added_source_rebuilds_the_index() {
    let home = short_home();
    seed(home.path());
    let index = index(home.path());
    assert_eq!(index.search("cmux-next", 10).unwrap().len(), 1);
    std::fs::remove_file(home.path().join("decisions/2026-10-18-memory.md")).unwrap();
    assert!(index.stale(), "a deleted file changes the source list");
    assert!(index.search("cmux-next", 10).unwrap().is_empty());
    write(
        home.path(),
        ".claude/projects/-other/memory/new.md",
        "Huge Blue is take-what's-free.",
    );
    assert_eq!(index.search("take-what's-free", 10).unwrap().len(), 1);
}

#[test]
fn remember_appends_one_entry_with_provenance_and_refuses_secrets() {
    let home = short_home();
    seed(home.path());
    let index = index(home.path());
    index.refresh(false).unwrap();
    let from = Provenance {
        host: Some("air-blue".into()),
        session: Some("sess-1".into()),
        cwd: Some("/repo".into()),
    };
    let said = index
        .remember("cosmic-gray owns the agent memory index.", &from)
        .unwrap();
    // Appended to a current index, not rebuilt: it names the new entry.
    assert!(said.starts_with("saved note 0 as entry #4"), "{said}");
    assert!(!index.stale());
    let hits = index.search("owns", 10).unwrap();
    assert_eq!(hits[0].source, "note 0");
    assert_eq!(hits[0].id, 4);
    let log = std::fs::read_to_string(home.path().join(".cmux/agent-memory-notes.jsonl")).unwrap();
    let note: Value = serde_json::from_str(log.trim()).unwrap();
    assert_eq!(note["host"], "air-blue");
    assert_eq!(note["session"], "sess-1");
    assert!(
        index
            .remember("ghp_0123456789abcdefABCDEF0123", &from)
            .unwrap_err()
            .contains("credential")
    );
    assert_eq!(
        log,
        std::fs::read_to_string(home.path().join(".cmux/agent-memory-notes.jsonl")).unwrap()
    );
}

#[test]
fn an_old_prototype_index_is_rebuilt() {
    let home = short_home();
    seed(home.path());
    let index = index(home.path());
    index.refresh(false).unwrap();
    // The leo-workspace prototype's manifest: a bare list of labels.
    std::fs::write(
        home.path()
            .join(".cmux/agent-memory/agent-memory-manifest.json"),
        "[\"x\"]",
    )
    .unwrap();
    assert!(index.stale());
    assert!(
        index
            .refresh(false)
            .unwrap()
            .starts_with("indexed 4 memory entries")
    );
}

struct Down;

impl Owner for Down {
    fn call(&mut self, _: &Value) -> Result<Value, String> {
        Err("ssh: connect to host owner: refused".into())
    }
    fn name(&self) -> String {
        "ssh://owner".into()
    }
}

struct Up(Vec<Value>);

impl Owner for Up {
    fn call(&mut self, message: &Value) -> Result<Value, String> {
        self.0.push(message.clone());
        Ok(
            json!({"jsonrpc": "2.0", "id": message["id"], "result": {"content": [{"type": "text", "text": "from the owner"}], "isError": false}}),
        )
    }
    fn name(&self) -> String {
        "ssh://owner".into()
    }
}

fn call(server: &mut Server, name: &str, args: Value) -> Value {
    server
        .handle(&json!({"jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": {"name": name, "arguments": args}}))
        .unwrap()
}

#[test]
fn the_server_answers_startup_locally_and_relays_only_tool_calls() {
    let home = short_home();
    seed(home.path());
    let mut server = Server {
        index: index(home.path()),
        remember: true,
        owner: Some(Box::new(Up(Vec::new()))),
    };
    let init = server
        .handle(&json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26"}}))
        .unwrap();
    assert_eq!(init["result"]["protocolVersion"], "2025-03-26");
    let list = server
        .handle(&json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}))
        .unwrap();
    let names: Vec<&str> = list["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, ["memory_search", "memory_get", "memory_remember"]);
    assert!(
        server
            .handle(&json!({"jsonrpc": "2.0", "method": "notifications/initialized"}))
            .is_none()
    );
    let answer = call(&mut server, "memory_remember", json!({"text": "a lesson"}));
    assert_eq!(answer["result"]["content"][0]["text"], "from the owner");
    // Nothing was written here: the owner keeps the notes.
    assert!(!home.path().join(".cmux/agent-memory-notes.jsonl").exists());
}

#[test]
fn an_unreachable_owner_falls_back_for_reads_and_refuses_notes() {
    let home = short_home();
    seed(home.path());
    let mut server = Server {
        index: index(home.path()),
        remember: true,
        owner: Some(Box::new(Down)),
    };
    let answer = call(
        &mut server,
        "memory_search",
        json!({"query": "heavy wrapper"}),
    );
    let text = answer["result"]["content"][0]["text"].as_str().unwrap();
    assert_eq!(answer["result"]["isError"], false);
    assert!(
        text.contains("did not answer") && text.contains("refused"),
        "{text}"
    );
    assert!(text.contains("group 0: # Task Group: fleet"), "{text}");
    let answer = call(&mut server, "memory_remember", json!({"text": "a lesson"}));
    assert_eq!(answer["result"]["isError"], true);
    assert!(
        answer["result"]["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("nothing was saved")
    );
    assert!(!home.path().join(".cmux/agent-memory-notes.jsonl").exists());
}

#[test]
fn notes_off_hides_and_refuses_remember() {
    let home = short_home();
    seed(home.path());
    let mut server = Server {
        index: index(home.path()),
        remember: false,
        owner: None,
    };
    assert_eq!(mcp::tool_list(false).as_array().unwrap().len(), 2);
    let answer = call(&mut server, "memory_remember", json!({"text": "x"}));
    assert_eq!(answer["result"]["isError"], true);
    let answer = call(&mut server, "memory_get", json!({"id": 0}));
    assert!(
        answer["result"]["content"][0]["text"]
            .as_str()
            .unwrap()
            .starts_with("[~/.claude/projects/-repo/memory/merge.md]")
    );
    // The CLI's JSON form through the same call.
    let answer = call(
        &mut server,
        "memory_search",
        json!({"query": "merge", "format": "json"}),
    );
    let hits: Value =
        serde_json::from_str(answer["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(
        hits[0]["source"],
        "~/.claude/projects/-repo/memory/merge.md"
    );
    assert!(hits[0]["text"].as_str().unwrap().contains("never --admin"));
}

#[test]
fn the_chief_tool_list_is_unchanged() {
    // Section 7.2: the Chief's own server keeps exactly its tools.
    let names: Vec<String> = optchat_chief::mcp::tool_list()
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(names, ["zoom", "date", "spawn", "tell"]);
}

/// A memory file written while a rebuild reads the sources: its mtime is
/// before the manifest's, but after the build started reading, so the index
/// is stale. A note saved through `remember` keeps the index current.
#[test]
fn an_edit_during_a_rebuild_is_not_missed() {
    let home = short_home();
    seed(home.path());
    let index = index(home.path());
    index.refresh(false).unwrap();
    let from = Provenance::default();
    index.remember("a lesson about hooks", &from).unwrap();
    assert!(!index.stale());
    let manifest: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(
            home.path()
                .join(".cmux/agent-memory/agent-memory-manifest.json"),
        )
        .unwrap(),
    )
    .unwrap();
    let read_at = manifest["read_at"].as_u64().unwrap();
    let file = home.path().join(".claude/projects/-repo/memory/merge.md");
    std::fs::write(&file, "Edited mid-build.").unwrap();
    let during = std::time::UNIX_EPOCH + std::time::Duration::from_nanos(read_at + 1_000);
    std::fs::File::options()
        .write(true)
        .open(&file)
        .unwrap()
        .set_modified(during)
        .unwrap();
    assert!(index.stale());
    assert_eq!(index.search("mid-build", 5).unwrap().len(), 1);
}
