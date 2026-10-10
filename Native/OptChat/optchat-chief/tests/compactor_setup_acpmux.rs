//! Chief 2026-10-10: a user turn never waits more than 10 s on compaction.
//! The compactor runs over the real acpmux daemon (`ACPMUX_BIN`, started in
//! a home of its own) with a harness that daemon does not have, so no
//! compactor session can ever start: each node is stuck on its first failure
//! with a typed setup error, both turns start at once, and the conversation
//! is told why the lines stay unsummarized.
//!
//! Run: `ACPMUX_BIN=<cmux-tui target>/debug/acpmux cargo test --test
//! compactor_setup_acpmux -- --ignored`.

mod common;

use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::acpmux::{Acpmux, AgentEvent, Family};
use optchat_chief::compactor::{
    AcpmuxCompactor, COMPACTOR_SESSIONS, Slots, compactor_presets, compactor_spec,
};
use optchat_chief::paths::Paths;
use optchat_core::{Kind, PLACEHOLDER};
use optchat_host::{Config, OptChat, SystemClock};
use serde_json::Value;

const HARNESS: &str = "no-such-harness";
/// How a setup error reads in the status (optchat-host `SETUP_ERROR`).
const SETUP_ERROR: &str = "setup error: ";

fn prompt_text(h: &Harness, turn: usize) -> String {
    h.agents.inner.lock().unwrap().prompts[turn]
        .iter()
        .map(|b: &Value| b["text"].as_str().unwrap_or_default().to_owned())
        .collect::<Vec<_>>()
        .join("\n")
}

fn until_prompt(h: &mut Harness, n: usize) -> Duration {
    let asked = Instant::now();
    while h.agents.inner.lock().unwrap().prompts.len() < n {
        h.step();
    }
    asked.elapsed()
}

#[test]
#[ignore = "needs the real acpmux binary: ACPMUX_BIN"]
fn a_compactor_that_cannot_start_holds_no_turn_and_says_why() {
    let bin = std::env::var("ACPMUX_BIN").expect("ACPMUX_BIN names the real acpmux binary");
    assert!(std::path::Path::new(&bin).is_file(), "no acpmux at {bin}");
    let dir = tempfile::tempdir().unwrap();
    let daemon_home = dir.path().join("acpmux");
    std::fs::create_dir_all(&daemon_home).unwrap();
    // SAFETY: this test binary runs this one test; nothing reads the env meanwhile.
    unsafe {
        std::env::set_var("ACPMUX_HOME", &daemon_home);
        std::env::remove_var("OPTCHAT_ACPMUX_SUPERVISED");
    }
    let socket = daemon_home.join("acpmux.sock");
    let home = dir.path().join("mux");
    let paths = Paths::new(&home);
    paths.create().unwrap();

    // The compactor's own presets and link, as the host makes them.
    let presets = compactor_presets(&paths, &home, HARNESS, Family::Claude);
    let agents = Acpmux::new(socket, None, presets);
    let up = Arc::new((Mutex::new(None::<bool>), Condvar::new()));
    let signal = up.clone();
    let lines = Arc::new(Mutex::new(Vec::<String>::new()));
    let link_lines = lines.clone();
    agents.spawn_link(
        Arc::new(move |event| {
            let state = match event {
                AgentEvent::Up(_) => Some(true),
                AgentEvent::Down => Some(false),
                _ => None,
            };
            if state.is_some() {
                *signal.0.lock().unwrap() = state;
                signal.1.notify_all();
            }
        }),
        Arc::new(move |line: &str| link_lines.lock().unwrap().push(format!("acpmux: {line}"))),
    );
    let connected = {
        let guard = up.0.lock().unwrap();
        *up.1
            .wait_timeout_while(guard, WAIT, |s| s.is_none())
            .unwrap()
            .0
    };
    assert_eq!(
        connected,
        Some(true),
        "the real acpmux did not come up: {:?}",
        lines.lock().unwrap()
    );
    let compactor_lines = lines.clone();
    let compactor = Arc::new(
        AcpmuxCompactor::new(
            agents.clone(),
            compactor_spec(&paths, &home, HARNESS, Family::Claude, None),
            Slots::new(COMPACTOR_SESSIONS),
        )
        .with_log(Arc::new(move |line: &str| {
            compactor_lines
                .lock()
                .unwrap()
                .push(format!("compactor: {line}"))
        })),
    );
    let config = Config {
        reporter: Arc::new(|_| {}),
        ..Config::default()
    };
    let chat = Arc::new(
        OptChat::open_with(
            &dir.path().join("chat"),
            config,
            compactor,
            Arc::new(SystemClock),
        )
        .unwrap(),
    );
    let started = Instant::now();
    for i in 0..4 {
        let kind = if i % 2 == 0 { Kind::User } else { Kind::Talk };
        let text = format!(
            "message {i}: {}",
            "the release script copies build output to /srv/releases and restarts the unit; "
                .repeat(30)
        );
        chat.append(kind, &text).unwrap();
    }

    // Stuck on the first failure, with the typed error: no retries first.
    assert!(
        chat.settle(None, Some(Duration::from_secs(5))),
        "no line holds a turn: {:?}",
        chat.status()
    );
    println!("settled in {} ms", started.elapsed().as_millis());
    let status = chat.status();
    assert!(!status.stuck.is_empty(), "{status:?}");
    assert!(
        status
            .failures
            .iter()
            .all(|f| f.error.starts_with(SETUP_ERROR)),
        "every failure is a setup error: {:?}",
        status.failures
    );
    println!("failure: {}", status.failures[0].error);

    // The brain over that memory: both turns start at once.
    let settings = settings(dir.path());
    let owner = Arc::new(Mutex::new(Owner {
        summary: Some(summary()),
        ..Owner::default()
    }));
    let brain_dir = tempfile::tempdir().unwrap();
    let mut h = Harness::over_chat(
        brain_dir,
        default_script(),
        owner.clone(),
        settings,
        Arc::new(|_: &str| {}),
        chat.clone(),
    );
    h.connect();
    h.say("user_local", "where do releases go?");
    let first = until_prompt(&mut h, 1);
    h.settle();
    h.say("user_local", "and the unit?");
    let second = until_prompt(&mut h, 2);
    h.settle();
    println!("turn 1 waited {first:?}, turn 2 {second:?}");
    assert!(first < Duration::from_secs(3), "turn 1 waited {first:?}");
    assert!(second < Duration::from_secs(3), "turn 2 waited {second:?}");
    assert!(prompt_text(&h, 0).contains(PLACEHOLDER));
    assert!(prompt_text(&h, 1).contains(PLACEHOLDER));
    let sends = owner.lock().unwrap().sends();
    assert!(
        sends.iter().any(|(_, t)| t.contains(SETUP_ERROR)),
        "the conversation is told it is a setup error: {sends:?}"
    );

    assert!(
        optchat_chief::acpmux_daemon::shutdown_started(&|_| {}),
        "the test's own acpmux stops"
    );
}
