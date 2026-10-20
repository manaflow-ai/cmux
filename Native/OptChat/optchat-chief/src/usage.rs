//! Chief usage analytics (plans/cmux-next/chief-usage-analytics-DESIGN.md).
//! Red stub: the types and entry points the tests call; the next commit
//! implements them.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// One billable unit: a Chief turn, a compactor node or a subagent prompt.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Line {
    pub v: u32,
    pub ts: u64,
    pub kind: String,
    pub key: String,
    pub agent: Option<String>,
    pub model: Option<String>,
    pub harness: Option<String>,
    pub status: Option<String>,
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_write: u64,
    pub usd: Option<f64>,
    pub usd_cum: Option<f64>,
    pub ms: Option<u64>,
    pub start_ms: Option<u64>,
    pub ttft_ms: Option<u64>,
    pub src: String,
}

/// Turns trace events into ledger lines.
#[derive(Default)]
pub struct Fold;

impl Fold {
    pub fn new() -> Fold {
        Fold
    }

    pub fn observe(&mut self, _event: &Value, _src: &str) -> Option<Line> {
        None
    }
}

/// `<optchat root>/usage`.
pub fn dir(root: &Path) -> PathBuf {
    root.join("usage")
}

pub fn read(_dir: &Path, _since_ms: u64, _until_ms: u64) -> Result<Vec<Line>, String> {
    Ok(Vec::new())
}

#[derive(Debug, Default)]
pub struct Backfill {
    pub lines: u64,
}

pub fn backfill(_root: &Path, _force: bool) -> Result<Backfill, String> {
    Ok(Backfill::default())
}

pub fn prune(_dir: &Path, _month: &str, _keep_months: u32, _max_bytes: u64) -> Vec<PathBuf> {
    Vec::new()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Bucket {
    Hour,
    Day,
    Week,
    Month,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum By {
    Chief,
    Agent,
    Model,
    Harness,
    Kind,
}

#[derive(Clone, Debug)]
pub struct Chief {
    pub id: String,
    pub label: String,
    pub home: String,
}

#[derive(Clone, Copy, Debug)]
pub struct Query {
    pub since_ms: u64,
    pub until_ms: u64,
    pub bucket: Bucket,
    pub by: By,
    pub top: usize,
    pub offset_s: i32,
}

pub fn summarize(_chiefs: &[(Chief, Vec<Line>)], _q: &Query) -> Value {
    Value::Null
}

pub fn run(_args: &[String]) -> Result<String, String> {
    Ok(String::new())
}
