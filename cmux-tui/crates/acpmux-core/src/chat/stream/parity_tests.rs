//! The parity corpus (decision 233): each raw v1 log in it, through the real translator and actor,
//! the daemon's frame encoders and the client core, as the change strings a page gets. The page's
//! parity test (webviews rows/parity.test.ts) feeds them to its row store and compares what the
//! adapter draws with what the v1 model draws from the same log. A changed byte fails here; bless
//! with `ACPMUX_PARITY_BLESS=1`.
//!
//! A page opens the chat at its end, then reads each settled turn's fold as open, as a person who
//! opens every "Worked for" does: the v1 model holds every row, so the store must too.

use super::*;
use acpmux_client::chat::{ChatChange, ChatPageRequest, ChatSubRequest};
use acpmux_client::{Change, Client as Core};

/// Each log, and the change strings blessed for it (read with `include_str!`, so a changed file
/// rebuilds this test and the spec workflow's path list names it).
const CORPUS: [(&str, &str, &str); 4] = [
    (
        "seed-turn",
        include_str!("../../../../acpmux-book/src/translate/fixtures/seed-turn.ndjson"),
        include_str!(
            "../../../../../../webviews/src/agent-session/acpmux/rows/parity/seed-turn.changes.jsonl"
        ),
    ),
    (
        "r1-reply-1",
        include_str!("../../../../acpmux-book/src/translate/fixtures/r1-reply-1.ndjson"),
        include_str!(
            "../../../../../../webviews/src/agent-session/acpmux/rows/parity/r1-reply-1.changes.jsonl"
        ),
    ),
    (
        "r1-reply-2",
        include_str!("../../../../acpmux-book/src/translate/fixtures/r1-reply-2.ndjson"),
        include_str!(
            "../../../../../../webviews/src/agent-session/acpmux/rows/parity/r1-reply-2.changes.jsonl"
        ),
    ),
    (
        "parity",
        include_str!("../../../../acpmux-book/src/translate/fixtures/parity.ndjson"),
        include_str!(
            "../../../../../../webviews/src/agent-session/acpmux/rows/parity/parity.changes.jsonl"
        ),
    ),
];
const SID: &str = "rows.1";
const BLESS: &str = "ACPMUX_PARITY_BLESS";

fn changes_path(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../webviews/src/agent-session/acpmux/rows/parity")
        .join(format!("{name}.changes.jsonl"))
}

/// A change as `acpmux_client_next_change` gives it: its JSON, and for a blob a newline and the
/// bytes. One line of the file holds it as a JSON string.
fn change_line(change: Change<Value>) -> (ChatChange, String) {
    let Change::Chat(change) = change else { panic!("not a chat change: {change:?}") };
    let mut bytes = serde_json::to_vec(&change).unwrap();
    if let ChatChange::Blob { bytes: body, .. } = &change {
        bytes.push(b'\n');
        bytes.extend_from_slice(body);
    }
    let text = String::from_utf8(bytes).unwrap();
    (change, serde_json::to_string(&text).unwrap())
}

/// Sends what the core queued, then feeds it frames until `done` takes one of its changes.
async fn pump(
    core: &mut Core<Value>,
    daemon: &mut Client,
    out: &mut Vec<String>,
    done: impl Fn(&ChatChange) -> bool,
) -> Vec<ChatChange> {
    let mut taken = Vec::new();
    loop {
        while let Some(bytes) = core.take_send() {
            daemon.io.write_all(&bytes).await.unwrap();
        }
        let encoded = daemon.recv().await.encode();
        assert_eq!(core.received(&encoded), encoded.len());
        let mut finished = false;
        while let Some(change) = core.next_change() {
            let (change, line) = change_line(change);
            finished |= done(&change);
            out.push(line);
            taken.push(change);
        }
        if finished {
            return taken;
        }
    }
}

/// The settled group rows a window holds: each a fold to read as open.
fn folds(window: &ChatChange) -> Vec<u64> {
    let value = serde_json::to_value(window).unwrap();
    value["window"]["rows"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|row| row["kind"] == "group" && row["open"] != true)
        .filter_map(|row| row["id"].as_u64())
        .collect()
}

async fn changes_of(log: &str) -> Vec<String> {
    let lines: Vec<String> =
        log.lines().filter(|line| !line.trim().is_empty()).map(str::to_owned).collect();
    let chat = Chat::new(&lines);
    {
        let mut config = chat.config.lock().unwrap();
        config.edition_random = Arc::new(|| 7);
        // The book holds the whole log before the page opens it: no `not_ready`, no live ops.
        crate::chat::tests::catch_up(config.clone());
    }
    let mut daemon = chat.connect(1, &["chat"]);
    let mut core = Core::<Value>::connected_v2();
    let mut out = Vec::new();
    // The hello's reply.
    while let Some(bytes) = core.take_send() {
        daemon.io.write_all(&bytes).await.unwrap();
    }
    let hello = daemon.recv().await.encode();
    assert_eq!(core.received(&hello), hello.len());
    while let Some(change) = core.next_change() {
        out.push(change_line(change).1);
    }
    core.subscribe_chat(ChatSubRequest {
        sid: SID.into(),
        chat: "chat".into(),
        anchor: None,
        window: Some(acpmux_client::chat::MAX_CHAT_ROWS as u16),
    })
    .unwrap();
    let taken = pump(&mut core, &mut daemon, &mut out, |change| {
        matches!(change, ChatChange::Window { .. })
    })
    .await;
    let window = taken.last().unwrap();
    for fold in folds(window) {
        core.chat_page(ChatPageRequest {
            sid: SID.into(),
            after: Some(fold),
            fold: Some(fold),
            ..Default::default()
        })
        .unwrap();
        pump(&mut core, &mut daemon, &mut out, |change| {
            matches!(change, ChatChange::Page { .. } | ChatChange::Error { .. })
        })
        .await;
    }
    out
}

#[test]
fn each_corpus_log_gives_the_changes_a_page_gets() {
    let bless = std::env::var_os(BLESS).is_some();
    let mut stale = Vec::new();
    for (name, log, blessed) in CORPUS {
        let out = runtime().block_on(changes_of(log));
        let text = out.iter().map(|line| format!("{line}\n")).collect::<String>();
        let path = changes_path(name);
        if bless {
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(&path, &text).unwrap();
            continue;
        }
        if blessed != text {
            stale.push(name);
        }
    }
    assert!(stale.is_empty(), "the page's changes moved for {stale:?}; bless with {BLESS}=1");
}
