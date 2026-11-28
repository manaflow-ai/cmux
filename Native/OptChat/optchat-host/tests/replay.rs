//! Log replay for the compactor prompt (decisions.md, DO-AUDIT-2 answers:
//! the `cmux` prompt is checked on a replayed log before any host uses it).
//! Ignored by default: it spends real tokens.
//!
//! OPTCHAT_REPLAY_LOG=<JSONL of {"kind","text"}> OPTCHAT_REPLAY_OUT=<dir>
//! cargo test --release --test replay -- --ignored --nocapture
//!
//! Builds the same log twice, once per prompt (`taelin`, `cmux`), into
//! `<out>/<prompt>/` (its memory.sqlite3 holds every node) and writes the
//! final view to `<out>/<prompt>.view.txt`. The budget is small so the
//! log merges up several levels.

use std::sync::Arc;
use std::time::Duration;

use optchat_core::CompactPrompt;
use optchat_host::{Config, Kind, OptChat};

#[test]
#[ignore = "spends real tokens; run with --ignored on a host that reaches the subrouter"]
fn replay_a_log_through_both_compactor_prompts() {
    let log = std::env::var("OPTCHAT_REPLAY_LOG").expect("OPTCHAT_REPLAY_LOG");
    let out =
        std::path::PathBuf::from(std::env::var("OPTCHAT_REPLAY_OUT").expect("OPTCHAT_REPLAY_OUT"));
    let budget = std::env::var("OPTCHAT_REPLAY_BUDGET")
        .ok()
        .and_then(|b| b.parse().ok())
        .unwrap_or(8_000);
    let messages: Vec<(Kind, String)> = std::fs::read_to_string(&log)
        .unwrap()
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| {
            let v: serde_json::Value = serde_json::from_str(l).unwrap();
            (
                Kind::parse(v["kind"].as_str().unwrap()).unwrap(),
                v["text"].as_str().unwrap().to_owned(),
            )
        })
        .collect();
    for prompt in [CompactPrompt::Taelin, CompactPrompt::Cmux] {
        let dir = out.join(prompt.name());
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let config = Config {
            agent: "Chief".into(),
            prompt: prompt.clone(),
            budget,
            reporter: Arc::new(|r| eprintln!("report: {r}")),
            ..Config::default()
        };
        let chat = OptChat::open(&dir, config).unwrap();
        let started = std::time::Instant::now();
        for (kind, text) in &messages {
            chat.append(*kind, text).unwrap();
        }
        assert!(
            chat.wait_idle(None, Some(Duration::from_secs(3_600))),
            "{}: not built: {:?}",
            prompt.name(),
            chat.status().failures
        );
        let view = chat.render_view().text;
        std::fs::write(out.join(format!("{}.view.txt", prompt.name())), &view).unwrap();
        println!(
            "{}: {} messages, view {} B, {} s",
            prompt.name(),
            messages.len(),
            view.len(),
            started.elapsed().as_secs()
        );
    }
}
