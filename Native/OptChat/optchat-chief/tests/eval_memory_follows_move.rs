//! Bench, RFD 0167 row 17 ("Memory shared by local and cloud"): a chat moved to a Cloud machine,
//! memory on vs off, on a fixed task set. Each of the 10 tasks needs one fact a prior session
//! saved on the owner machine (`memory_remember`), among 20 other notes. Two of the facts are also
//! in the moved chat's folder, which an agent without memory can still read.
//!
//! The arms, as the moved chat sees its tools:
//! - off: no `cmux-agent-memory` server (a Cloud machine with no memory setting, before
//!   acpmux's `memory_follow.rs`): only the folder.
//! - local: the server, searching the Cloud machine's own (empty) index: what a target with
//!   memory on gave before the owner's route followed the chat.
//! - followed: the server with the owner's route the move carried (`CMUX_AGENT_MEMORY_OWNER`),
//!   relaying to the owner's index (in-process here; `cmux remote rpc` in the product).
//!
//! The agent searches memory twice per task, with its whole question and with its keywords, as
//! an agent does. A task is answered when the answer is in the folder lines matching the
//! keywords, or in the top 3 memory hits of either search. The hits' snippets mark the words
//! that matched in `[` `]` (`optchat_host::db::search`); the answer is read without those marks,
//! as the agent reads it (`docs/[decisions]` is `docs/decisions`). The bench also prints the
//! first run's way, keywords only and the marks kept, which scored 8/10. Run: `cargo test -p optchat-chief --test
//! eval_memory_follows_move -- --nocapture`.

use std::path::Path;

use optchat_chief::agent_memory::index::Index;
use optchat_chief::agent_memory::mcp::{Owner, Server};
use optchat_chief::agent_memory::notes::Provenance;
use optchat_chief::agent_memory::sources::Sources;
use serde_json::{Value, json};

fn short_home() -> tempfile::TempDir {
    tempfile::Builder::new()
        .prefix("amf")
        .tempdir_in("/tmp")
        .unwrap()
}

fn index(home: &Path) -> Index {
    Index::new(
        home.join(".cmux/agent-memory"),
        Sources {
            home: home.to_owned(),
            claude: home.join(".claude"),
            codex: home.join(".codex"),
            extra: vec![],
            notes: home.join(".cmux/agent-memory-notes.jsonl"),
        },
    )
}

/// (the task, the words the agent searches for, the fact the prior session saved, the answer).
const TASKS: [(&str, &str, &str, &str); 10] = [
    (
        "Which port does the staging API listen on?",
        "staging port",
        "The staging API listens on port 8443, not 443.",
        "8443",
    ),
    (
        "Which flag makes the flaky ws test pass in CI?",
        "flaky ws test",
        "The flaky ws test needs --test-threads=1 in CI.",
        "--test-threads=1",
    ),
    (
        "Who approves billing migrations?",
        "billing migrations approved",
        "Billing migrations are approved by the payments owner, Priya.",
        "Priya",
    ),
    (
        "Which branch do PRs target?",
        "PRs target branch",
        "PRs target branch feat-cmux-next, never main.",
        "feat-cmux-next",
    ),
    (
        "How long may a fleet compile wait?",
        "fleet compile wait",
        "A fleet compile may wait up to 40 minutes in the queue.",
        "40 minutes",
    ),
    (
        "What does the person want in reports?",
        "person reports",
        "The person wants reports as one short bullet list.",
        "bullet list",
    ),
    (
        "Which region do Cloud VMs run in?",
        "Cloud VMs region",
        "Cloud VMs run in region us-east-2.",
        "us-east-2",
    ),
    (
        "Which tool lands PRs?",
        "lands PRs tool",
        "The tool that lands PRs is glaeda-gh land.",
        "glaeda-gh",
    ),
    (
        "What broke the last nightly?",
        "last nightly broke",
        "The last nightly broke on a stale GhosttyKit checksum.",
        "GhosttyKit",
    ),
    (
        "Where do decisions get written down?",
        "decisions written",
        "Decisions are written in docs/decisions, one file each.",
        "docs/decisions",
    ),
];

/// The moved chat's folder: two of the facts are in it.
const FOLDER: &str = "# Project\nPRs target branch feat-cmux-next, never main.\n\
Cloud VMs run in region us-east-2.\nRun tests with cargo test.\n";

const OTHER_NOTES: [&str; 20] = [
    "The sidebar redraws on every workspace switch.",
    "Prefer Rust for new daemon logic.",
    "The iOS app mirrors every Mac feature.",
    "Screenshots go in the PR body.",
    "Use one background waiter per PR.",
    "The settings file is JSONC.",
    "Billing webhooks retry three times.",
    "Never kill the person's running app.",
    "Nightly builds sign on one Mac.",
    "The chat pane is React.",
    "Release notes need one highlight file.",
    "Ghostty is a submodule.",
    "The relay denies unknown methods.",
    "Worktrees are APFS clones.",
    "Logs go to Axiom.",
    "The API port in dev is 8080.",
    "Tests for scripts are Python.",
    "Flaky tests get a rerun first.",
    "The region for backups is eu-west-1.",
    "Reports link the PR.",
];

/// The owner, reached over the route the move carried: its own memory server on its own index.
struct OwnerLink(Server);

impl Owner for OwnerLink {
    fn call(&mut self, message: &Value) -> Result<Value, String> {
        self.0.handle(message).ok_or_else(|| "no answer".to_owned())
    }
    fn name(&self) -> String {
        "owner".into()
    }
}

fn search(server: &mut Server, query: &str) -> String {
    let answer = server
        .handle(&json!({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": "memory_search", "arguments": {"query": query, "limit": 3}}}))
        .unwrap();
    answer["result"]["content"].to_string()
}

/// How the agent asks memory and reads its hits.
#[derive(Clone, Copy)]
enum Asking {
    /// The first run's way: its keywords only, the hit marks kept.
    Keywords,
    /// Its whole question and its keywords, the hits read without the marks.
    QuestionAndKeywords,
}

fn from_folder(query: &str) -> String {
    let words: Vec<String> = query.split_whitespace().map(str::to_lowercase).collect();
    FOLDER
        .lines()
        .filter(|line| words.iter().all(|w| line.to_lowercase().contains(w)))
        .collect::<Vec<_>>()
        .join("\n")
}

/// The tasks answered, and the questions of those missed.
fn score(mut server: Option<&mut Server>, asking: Asking) -> (usize, Vec<&'static str>) {
    let mut missed = Vec::new();
    for (task, query, _, answer) in TASKS {
        let mut seen = from_folder(query);
        if let Some(server) = server.as_deref_mut() {
            match asking {
                Asking::Keywords => seen.push_str(&search(server, query)),
                Asking::QuestionAndKeywords => {
                    let hits = search(server, task) + &search(server, query);
                    seen.push_str(&hits.replace(['[', ']'], ""));
                }
            }
        }
        if !seen.contains(answer) {
            missed.push(task);
        }
    }
    (TASKS.len() - missed.len(), missed)
}

#[test]
fn memory_that_follows_a_moved_chat_answers_what_a_prior_session_saved() {
    // The owner machine: a prior session saved the facts, among other notes.
    let owner_home = short_home();
    let owner_index = index(owner_home.path());
    let from = Provenance::here();
    for note in OTHER_NOTES.iter().copied().chain(TASKS.iter().map(|t| t.2)) {
        owner_index.remember(note, &from).unwrap();
    }
    // The Cloud machine the chat moved to: an index of its own with nothing in it.
    let cloud_home = short_home();

    let asking = Asking::QuestionAndKeywords;
    let off = score(None, asking);
    let mut local = Server {
        index: index(cloud_home.path()),
        remember: true,
        owner: None,
    };
    let local = score(Some(&mut local), asking);
    let owner = Server {
        index: owner_index,
        remember: true,
        owner: None,
    };
    let mut followed = Server {
        index: index(cloud_home.path()),
        remember: true,
        owner: Some(Box::new(OwnerLink(owner))),
    };
    let (first_way, first_missed) = score(Some(&mut followed), Asking::Keywords);
    let followed = score(Some(&mut followed), asking);

    let ((off, _), (local, _), (followed, missed)) = (off, local, followed);
    let n = TASKS.len();
    let pct = |k: usize| k * 100 / n;
    println!("memory-follows-move bench, n={n} tasks");
    println!(
        "  off (no memory server):          {off}/{n} = {}%",
        pct(off)
    );
    println!(
        "  local (Cloud machine's index):   {local}/{n} = {}%",
        pct(local)
    );
    println!(
        "  followed (owner route carried):  {followed}/{n} = {}%",
        pct(followed)
    );
    println!(
        "  gain, followed vs off: {} points",
        pct(followed) as i64 - pct(off) as i64
    );
    println!("  missed with memory followed: {missed:?}");
    println!(
        "  followed, the first run's way (keywords only, marks kept): {first_way}/{n} = {}%, missed {first_missed:?}",
        pct(first_way)
    );
    assert_eq!(
        (off, local),
        (2, 2),
        "only the folder's two facts without the owner"
    );
    // RFD 0167 row 17's bar: memory on beats memory off by at least 20% of the tasks.
    assert!(
        followed * 5 >= off * 5 + n,
        "followed {followed}/{n} vs off {off}/{n}"
    );
}
