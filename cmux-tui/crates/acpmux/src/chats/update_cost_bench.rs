//! What one chat activity change costs a chat window as the chats grow (Leo 2026-11-04: "never
//! ... acceptable ... linear time growth degradation"): a 50-row window's recompute at 100,
//! 1,000 and 3,000 chats. Manual:
//! `cargo test -p acpmux --lib update_cost -- --ignored --nocapture --test-threads=1`.

use super::*;
use cmux_chat_index::ChatRoot;
use std::time::Instant;

fn line(i: usize) -> String {
    let (m, s) = (i / 60 % 60, i % 60);
    format!(
        r#"{{"type":"user","isSidechain":false,"cwd":"/work/p{}","sessionId":"00000000-0000-4000-8000-{i:012}","timestamp":"2026-10-01T01:{m:02}:{s:02}.000Z","message":{{"role":"user","content":"chat {i}"}}}}"#,
        i % 50
    )
}

fn index_of(n: usize) -> (tempfile::TempDir, ChatIndex) {
    let home = tempfile::tempdir().unwrap();
    let projects = home.path().join("projects");
    for i in 0..n {
        let file = projects
            .join(format!("-work-p{}", i % 50))
            .join(format!("00000000-0000-4000-8000-{i:012}.jsonl"));
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(&file, format!("{}\n", line(i))).unwrap();
    }
    let root = ChatRoot {
        harness: AdapterKind::ClaudeCode,
        real_path: projects.canonicalize().unwrap(),
        path: projects,
        source: RootSource::Default,
        aliases: Vec::new(),
        accounts: Vec::new(),
    };
    let mut index = ChatIndex::new(vec![root]);
    index.rescan_all();
    (home, index)
}

#[test]
#[ignore = "manual per-event cost measurement"]
fn update_cost_chat_window_recompute() {
    let cfg: crate::config::Config =
        serde_json::from_value(json!({"store": {"mode": "memory"}})).unwrap();
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = crate::hub::Hub::new(cfg, store);
    let activity = hub.chat_activity();
    let spec =
        WindowSpec::from_params(&json!({"window": "w", "limit": 50, "topLevel": true})).unwrap();
    for n in [100, 1_000, 3_000] {
        let (_home, index) = index_of(n);
        assert_eq!(index.chats().len(), n);
        let rounds = 200;
        let started = Instant::now();
        for _ in 0..rounds {
            std::hint::black_box(window::rows(&spec, &index, &activity, None));
        }
        let per = started.elapsed().as_secs_f64() * 1e6 / rounds as f64;
        eprintln!("UPDATE-COST chat_window_recompute n={n} per_event_us={per:.1}");
    }
}
