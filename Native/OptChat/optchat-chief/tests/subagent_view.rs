//! acp-chief-issues.md #12: a subagent's first turn cost ~108k input tokens
//! (a203, 2026-10-20: 94,080 cache written + 14,053 read), ~40k of them the
//! Chief's whole view (130 KB). A subagent gets the compaction view instead:
//! the same summary tree, merged coarser (an eighth to a quarter of the
//! budget, 16-32 KB at 128 KB), with every line still zoomable.

mod common;

use std::sync::Arc;
use std::time::Duration;

use common::*;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::Orchestrator;
use optchat_host::{
    CompactModel, CompactRequest, Config, Followup, Kind, ModelError, OptChat, Reply, SystemClock,
};

/// Summaries of about 300 bytes, so a merged view stays the size of its lines.
struct Wordy;

impl CompactModel for Wordy {
    fn call(&self, request: &CompactRequest, _: &[Followup]) -> Result<Reply, ModelError> {
        Ok(Reply::text(format!(
            "summary of {}: {}",
            request.node.name(),
            "detail ".repeat(42)
        )))
    }
}

const BUDGET: usize = 32_000;
/// Messages in the chat: enough to fill several views.
const MESSAGES: u64 = 960;

#[test]
fn a_subagent_reads_the_coarser_compaction_view() {
    let dir = tempfile::tempdir().unwrap();
    let config = Config {
        budget: BUDGET,
        reporter: Arc::new(|_| {}),
        ..Config::default()
    };
    let chat = Arc::new(
        OptChat::open_with(
            dir.path().join("chat"),
            config,
            Arc::new(Wordy),
            Arc::new(SystemClock),
        )
        .unwrap(),
    );
    for i in 0..MESSAGES {
        let kind = if i % 2 == 0 { Kind::User } else { Kind::Talk };
        chat.append(kind, &format!("message {i}: {}", "words ".repeat(100)))
            .unwrap();
    }
    assert!(chat.wait_idle(None, Some(Duration::from_secs(60))));
    let chief_view = chat.render_view().text;
    assert!(
        chief_view.len() > BUDGET / 4 + 1_000,
        "the Chief's view is the large one: {} B",
        chief_view.len()
    );
    let settings = settings(dir.path());
    let owner = Arc::new(std::sync::Mutex::new(Owner {
        summary: Some(summary()),
        ..Owner::default()
    }));
    let mut h = Harness::over_chat(
        dir,
        default_script(),
        owner,
        settings,
        Arc::new(|_: &str| {}),
        chat.clone(),
    );
    let sp = Arc::new(Spawner::new(
        h.chat.clone(),
        h.agents.clone(),
        SubagentSettings {
            harness: "claude".into(),
            policy: "approve-all".into(),
            model: None,
            effort: None,
            preset: Some("optchat-sub-h0me".into()),
            cwd: h.dir.path().join("subagent"),
            prefix: "optchat-sub-h0me".into(),
            parent: optchat_chief::brain::PARENT.into(),
            claude_md: None,
        },
        h.tx.clone(),
        Arc::new(|_: &str| {}),
    ));
    let worker = std::thread::spawn(move || sp.spawn(vec!["say hello".into()], None));
    while !worker.is_finished() {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    assert!(worker.join().unwrap().unwrap().contains("Started a1"));
    let first: String = h.agents.inner.lock().unwrap().prompts[0]
        .iter()
        .map(|b| b["text"].as_str().unwrap_or_default().to_owned())
        .collect();
    let (start, end) = (
        first.find("<chat>").expect("a view"),
        first.find("</chat>").expect("a view"),
    );
    let view = &first[start..end];
    // The compaction view aims at an eighth to a quarter of the budget; the
    // newest parts may still be finer while the compactor merges them, so
    // the bound is half the budget and well under the Chief's view.
    assert!(
        view.len() <= BUDGET / 2 && view.len() * 4 < chief_view.len() * 3,
        "the subagent's view is the compaction view: {} B (the Chief's {} B)\n{view}",
        view.len(),
        chief_view.len()
    );
    // Its last line reaches the newest message (ids 0..MESSAGES),
    // and the task follows.
    let last = view.lines().last().unwrap_or_default();
    let reach = last.split('|').next().and_then(|id| {
        let (start, n) = id.split_once('+')?;
        Some(start.parse::<u64>().ok()? + n.parse::<u64>().ok()?)
    });
    assert_eq!(reach, Some(MESSAGES), "{view}");
    assert!(first.contains("say hello"));
}
