#![allow(dead_code)]

use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use optchat_host::*;

/// A compactor model driven by a closure.
pub struct Fake<F>(pub F);

impl<F> CompactModel for Fake<F>
where
    F: Fn(&CompactRequest, &[Followup]) -> Result<Reply, ModelError> + Send + Sync,
{
    fn call(&self, request: &CompactRequest, followups: &[Followup]) -> Result<Reply, ModelError> {
        (self.0)(request, followups)
    }
}

/// A deterministic summary of `node`, `len` bytes long.
pub fn summary(node: NodeId, len: usize) -> String {
    let mut s = format!("sum {}: ", node.name());
    while s.len() < len {
        s.push_str("item; ");
    }
    s.truncate(len);
    s
}

/// A model that answers every node with a summary of `len` bytes.
pub fn instant(len: usize) -> Arc<dyn CompactModel> {
    Arc::new(Fake(move |r: &CompactRequest, _: &[Followup]| {
        Ok(Reply::text(summary(r.node, len)))
    }))
}

/// A config whose reports are collected.
pub fn config(budget: usize) -> (Config, Arc<Mutex<Vec<Report>>>) {
    let reports = Arc::new(Mutex::new(Vec::new()));
    let sink = reports.clone();
    let config = Config {
        budget,
        reporter: Arc::new(move |r: &Report| sink.lock().unwrap().push(r.clone())),
        ..Config::default()
    };
    (config, reports)
}

/// A message too long to be its own node, so it needs a model call.
pub fn long(n: u64) -> String {
    format!("message {n}: {}", "words ".repeat(120))
}

pub fn open(dir: &Path, budget: usize, model: Arc<dyn CompactModel>) -> OptChat {
    OptChat::open_with(dir, config(budget).0, model, Arc::new(SystemClock)).unwrap()
}

pub const WAIT: Option<Duration> = Some(Duration::from_secs(30));

/// When set, a crash test runs as the child: it works in this directory
/// and is aborted at `OPTCHAT_FAULT`.
pub const CRASH_DIR: &str = "OPTCHAT_CRASH_DIR";

/// The child's directory, when this process is a crash test's child.
pub fn crash_dir() -> Option<std::path::PathBuf> {
    std::env::var_os(CRASH_DIR).map(std::path::PathBuf::from)
}

/// Runs test `name` of this test binary in a child process working in
/// `dir`, aborted at `point` (`OPTCHAT_FAULT`). True when it was aborted
/// (a child that never reached the point exits normally).
pub fn crash_child(name: &str, point: &str, dir: &Path) -> bool {
    let out = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", name, "--nocapture", "--test-threads", "1"])
        .env(CRASH_DIR, dir)
        .env(FAULT_ENV, point)
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    let aborted = !out.status.success();
    assert!(
        !aborted || stderr.contains("fault injected"),
        "the child failed without the fault: {stderr}"
    );
    aborted
}

/// Every message in `chat`: (kind, text).
pub fn log_of(chat: &OptChat) -> Vec<(Kind, String)> {
    (0..chat.status().messages)
        .map(|i| chat.message(i).unwrap())
        .collect()
}
