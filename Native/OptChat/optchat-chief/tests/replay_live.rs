//! Log replay of the compactor prompts through the Chief's real compactor
//! route (deny-all claude-sr sessions in acpmux), before any host uses the
//! `cmux` prompt (decisions.md, DO-AUDIT-2 answers). Ignored: real tokens.
//!
//! OPTCHAT_REPLAY_LOG=<JSONL of {"kind","text"}> OPTCHAT_REPLAY_OUT=<dir>
//! ACPMUX_BIN=<acpmux> cargo test --release --test replay_live -- --ignored --nocapture
//!
//! Starts its own acpmux daemon in `<out>/acpmux`, builds the log once per
//! prompt (`taelin`, `cmux`) into `<out>/<prompt>/memory.sqlite3` (every
//! node), and writes each final view to `<out>/<prompt>.view.txt`.

use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use optchat_chief::acpmux::{Acpmux, AgentEvent, AgentPort, Family};
use optchat_chief::compactor::{AcpmuxCompactor, Slots, compactor_presets, compactor_spec};
use optchat_chief::paths::Paths;
use optchat_core::CompactPrompt;
use optchat_host::{Config, Kind, OptChat, SystemClock};

#[test]
#[ignore = "spends real tokens; needs acpmux and a signed-in claude-sr"]
fn replay_a_log_through_both_compactor_prompts_in_acpmux() {
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
    let home = out.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let acpmux_home = out.join("acpmux");
    std::fs::create_dir_all(&acpmux_home).unwrap();
    // SAFETY: this test binary runs this one test; nothing reads the env meanwhile.
    unsafe { std::env::set_var("ACPMUX_HOME", &acpmux_home) };
    let paths = Paths::new(&home);
    paths.create().unwrap();
    optchat_chief::compactor::prepare_config(&paths.compactor_config).unwrap();
    let presets = compactor_presets(&paths, &home, "claude-sr", Family::Claude);
    let agents = Acpmux::new(acpmux_home.join("acpmux.sock"), None, presets);
    let up = Arc::new((Mutex::new(false), Condvar::new()));
    let signal = up.clone();
    agents.spawn_link(
        Arc::new(move |e| {
            if matches!(e, AgentEvent::Up(_)) {
                *signal.0.lock().unwrap() = true;
                signal.1.notify_all();
            }
        }),
        Arc::new(|line: &str| eprintln!("acpmux: {line}")),
    );
    {
        let (lock, cv) = &*up;
        let linked = cv
            .wait_timeout_while(lock.lock().unwrap(), Duration::from_secs(60), |up| !*up)
            .unwrap()
            .0;
        assert!(*linked, "acpmux did not come up");
    }
    let port: Arc<dyn AgentPort> = agents.clone();
    let compactor = Arc::new(AcpmuxCompactor::new(
        port,
        compactor_spec(
            &paths,
            &home,
            "claude-sr",
            Family::Claude,
            Some("claude-sonnet-5-5"),
        ),
        Slots::new(optchat_chief::compactor::COMPACTOR_SESSIONS),
    ));
    for prompt in [CompactPrompt::Taelin, CompactPrompt::Cmux] {
        let dir = out.join(prompt.name());
        let _ = std::fs::remove_dir_all(&dir);
        let config = Config {
            agent: "Chief".into(),
            prompt: prompt.clone(),
            budget,
            reporter: Arc::new(|r| eprintln!("report: {r}")),
            ..Config::default()
        };
        let chat =
            OptChat::open_with(&dir, config, compactor.clone(), Arc::new(SystemClock)).unwrap();
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
            "{}: {} messages, {} nodes built, view {} B, {} s",
            prompt.name(),
            messages.len(),
            chat.status().built,
            view.len(),
            started.elapsed().as_secs()
        );
    }
}
