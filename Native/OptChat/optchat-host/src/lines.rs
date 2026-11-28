//! The JSON lines of the two streams (section 2):
//! `main/YYYY-MM-DD.jsonl` holds `{i, kind, text, size, date}` and
//! `tree/YYYY-MM-DD.jsonl` holds `{l, i, text, size}`.

use chrono::{DateTime, Local, SecondsFormat};
use serde::{Deserialize, Serialize};

use optchat_core::{Kind, NodeId};

#[derive(Serialize)]
struct MainOut<'a> {
    i: u64,
    kind: &'a str,
    text: &'a str,
    /// Bytes of `kind + ": " + text`.
    size: usize,
    /// ISO time with the local offset.
    date: &'a str,
}

/// A whole message line, as the import reads it.
#[derive(Deserialize)]
pub struct MainLine {
    pub i: u64,
    pub kind: String,
    pub text: String,
    pub date: String,
}

#[derive(Serialize)]
struct TreeOut<'a> {
    l: u32,
    i: u64,
    text: &'a str,
    size: usize,
}

#[derive(Deserialize)]
pub struct TreeIn {
    pub l: u32,
    pub i: u64,
    pub text: String,
}

/// One message line, newline included. serde_json escapes newlines in the
/// text, so a message is always exactly one line.
pub fn main_line(i: u64, kind: Kind, text: &str, date: &str) -> std::io::Result<String> {
    let kind = kind.as_str();
    let out = MainOut {
        i,
        kind,
        text,
        size: kind.len() + 2 + text.len(),
        date,
    };
    let mut line = serde_json::to_string(&out).map_err(std::io::Error::other)?;
    line.push('\n');
    Ok(line)
}

/// One node line, newline included.
pub fn tree_line(node: NodeId, text: &str) -> std::io::Result<String> {
    let out = TreeOut {
        l: node.l,
        i: node.i,
        text,
        size: text.len(),
    };
    let mut line = serde_json::to_string(&out).map_err(std::io::Error::other)?;
    line.push('\n');
    Ok(line)
}

/// The local day a line written now goes to.
pub fn today() -> String {
    Local::now().format("%Y-%m-%d").to_string()
}

/// The day file a message with this stored `date` goes to: the date's own
/// local day (its first ten characters), so the day and the date never
/// disagree around midnight; today for a date in another format.
pub fn day_of(date: &str) -> String {
    let day = date.get(..10).unwrap_or("");
    let ok = day.len() == 10
        && day.bytes().enumerate().all(|(k, b)| {
            if k == 4 || k == 7 {
                b == b'-'
            } else {
                b.is_ascii_digit()
            }
        });
    if ok {
        day.to_owned()
    } else {
        today()
    }
}

/// The `date` field for a message written now.
pub fn now_iso() -> String {
    Local::now().to_rfc3339_opts(SecondsFormat::Millis, false)
}

/// Whether `date` is an ISO (RFC 3339) time, as every written `date` is.
pub fn is_iso(date: &str) -> bool {
    DateTime::parse_from_rfc3339(date).is_ok()
}

/// A stored `date` as local date and time, for the agent's `date(id)` tool.
pub fn local_date(iso: &str) -> String {
    match DateTime::parse_from_rfc3339(iso) {
        Ok(t) => t
            .with_timezone(&Local)
            .format("%Y-%m-%d %H:%M:%S %:z")
            .to_string(),
        // An imported note may carry a date in another format; show it as stored.
        Err(_) => iso.to_string(),
    }
}
