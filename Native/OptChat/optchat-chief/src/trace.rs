//! The monitoring trace: one append-only JSON line per event under
//! `$MUX_HOME/optchat/traces/YYYY-MM-DD.jsonl` (local date, mode 0600 in the
//! 0700 `optchat/` directory). Every turn, model request, tool call,
//! compactor node, subagent spawn, tell and report, and every cache usage
//! report the harness gives, so `optchat-chief trace` and `stats` can show
//! latency, tool use and whether the cache works.
//!
//! Safe to read: no message, reply or tool input appears in full. A text is
//! `{"bytes", "hash", "prefix"}` (FNV-1a 64 of its bytes and its first
//! `PREFIX` characters); tool arguments and results are sizes only.
//! `OPTCHAT_TRACE_FULL=1` adds the full texts and tool arguments, for
//! debugging only (off by default).
//!
//! Cache stability: each turn records the view's byte length, the hash and
//! size of each cached piece (the cuts at the cache marks, section 8), the
//! system prompt's hash, and how many leading bytes of the view are the same
//! as the previous turn's in this host.

use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use serde_json::{Map, Value, json};

use crate::fold::Usage;

/// Characters of a text kept in the trace (its prefix).
pub const PREFIX: usize = 40;

/// The trace sink. `Trace::off()` writes nothing; clones share one writer.
#[derive(Clone, Default)]
pub struct Trace {
    inner: Option<Arc<Inner>>,
}

struct Inner {
    dir: PathBuf,
    full: bool,
    write: Mutex<()>,
}

impl std::fmt::Debug for Trace {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match &self.inner {
            Some(inner) => write!(f, "Trace({})", inner.dir.display()),
            None => f.write_str("Trace(off)"),
        }
    }
}

/// `$MUX_HOME/optchat/traces`.
pub fn dir(home: &Path) -> PathBuf {
    crate::paths::Paths::new(home).root.join("traces")
}

impl Trace {
    pub fn off() -> Trace {
        Trace::default()
    }

    /// A trace written into `dir` (created 0700). `full` adds whole texts.
    pub fn open(dir: &Path, full: bool) -> std::io::Result<Trace> {
        use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(dir)?;
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
        Ok(Trace {
            inner: Some(Arc::new(Inner {
                dir: dir.to_owned(),
                full,
                write: Mutex::new(()),
            })),
        })
    }

    pub fn is_on(&self) -> bool {
        self.inner.is_some()
    }

    /// Whether whole texts are traced (`OPTCHAT_TRACE_FULL=1`).
    pub fn full(&self) -> bool {
        self.inner.as_ref().is_some_and(|i| i.full)
    }

    /// A text as the trace keeps it: size, hash and prefix (and the whole
    /// text when `full`).
    pub fn text(&self, text: &str) -> Value {
        let mut v = json!({
            "bytes": text.len(),
            "hash": hash(text),
            "prefix": prefix(text),
        });
        if self.full() {
            v["text"] = json!(text);
        }
        v
    }

    /// Tool arguments: their size, and the arguments themselves when `full`.
    pub fn args(&self, args: &Value, into: &mut Map<String, Value>) {
        let text = args.to_string();
        into.insert("args_bytes".into(), json!(text.len()));
        if self.full() {
            into.insert("args".into(), args.clone());
        }
    }

    /// Writes one event: `{"ts": ms, "ev": ev, ...fields}`. A failed write
    /// is dropped (the trace never stops the Chief).
    pub fn emit(&self, ev: &str, fields: Value) {
        let Some(inner) = &self.inner else { return };
        let now = chrono::Local::now();
        let mut line = Map::new();
        line.insert("ts".into(), json!(now.timestamp_millis()));
        line.insert("ev".into(), json!(ev));
        if let Value::Object(map) = fields {
            line.extend(map);
        }
        let file = inner.dir.join(format!("{}.jsonl", now.format("%Y-%m-%d")));
        let mut bytes = Value::Object(line).to_string().into_bytes();
        bytes.push(b'\n');
        let _guard = inner
            .write
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let opened = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .open(&file);
        if let Ok(mut f) = opened {
            // One write per line: O_APPEND keeps lines whole.
            let _ = f.write_all(&bytes);
        }
    }
}

/// FNV-1a 64 of `text`, 16 hex digits: enough to tell two pieces apart
/// across turns, not a secret-safe digest.
pub fn hash(text: &str) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in text.as_bytes() {
        h ^= u64::from(*b);
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{h:016x}")
}

/// The first `PREFIX` characters of `text`, newlines as spaces.
pub fn prefix(text: &str) -> String {
    let mut out: String = text.chars().take(PREFIX).collect();
    if text.chars().count() > PREFIX {
        out.push('…');
    }
    out.replace(['\n', '\r', '\t'], " ")
}

/// A token use as the trace keeps it.
pub fn usage(u: &Usage) -> Value {
    json!({"input": u.input, "cache_read": u.cache_read, "cache_write": u.cache_write, "output": u.output})
}

/// Emits one `tool` event per finished call, with `scope` (`{"turn": ..}`
/// or `{"subagent": ..}`) merged in.
pub fn tools(trace: &Trace, scope: &Value, calls: Vec<crate::fold::ToolTrace>) {
    if !trace.is_on() {
        return;
    }
    for call in calls {
        let mut f = Map::new();
        if let Value::Object(s) = scope {
            f.extend(s.clone());
        }
        f.insert("name".into(), json!(call.name));
        f.insert("id".into(), json!(call.id));
        trace.args(&call.input, &mut f);
        f.insert("result_bytes".into(), json!(call.result_bytes));
        f.insert("ok".into(), json!(call.ok));
        if let Some(error) = &call.error {
            f.insert("error".into(), trace.text(error));
        }
        f.insert("ms".into(), json!(call.ms));
        trace.emit("tool", Value::Object(f));
    }
}

/// Emits one `request` event per model request, with `scope` merged in.
pub fn requests(trace: &Trace, scope: &Value, requests: &[crate::fold::Request]) {
    for (n, r) in requests.iter().enumerate() {
        let mut f = Map::new();
        if let Value::Object(s) = scope {
            f.extend(s.clone());
        }
        f.insert("n".into(), json!(n + 1));
        f.insert("model".into(), json!(r.model));
        f.insert("usage".into(), usage(&r.usage));
        f.insert("headers_ms".into(), json!(r.headers_ms));
        f.insert("ttft_ms".into(), json!(r.ttft_ms));
        trace.emit("request", Value::Object(f));
    }
}

/// Each cached piece of `view` (cut at its cache marks): `{bytes, hash}`.
pub fn pieces(view: &str) -> Vec<Value> {
    optchat_core::cache_pieces(view)
        .into_iter()
        .map(|p| json!({"bytes": p.len(), "hash": hash(p)}))
        .collect()
}

/// Leading bytes `a` and `b` share, on a char boundary.
pub fn common_prefix(a: &str, b: &str) -> usize {
    let mut n = a.bytes().zip(b.bytes()).take_while(|(x, y)| x == y).count();
    while n > 0 && !a.is_char_boundary(n) {
        n -= 1;
    }
    n
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn texts_are_hashed_and_cut() {
        let t = Trace::off();
        let v = t.text(&"secret ".repeat(20));
        assert_eq!(v["bytes"], 140);
        assert_eq!(v["prefix"].as_str().unwrap().chars().count(), PREFIX + 1);
        assert!(v.get("text").is_none());
        assert_eq!(hash("a"), hash("a"));
        assert_ne!(hash("a"), hash("b"));
    }

    #[test]
    fn the_file_is_private_and_append_only() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let t = Trace::open(&dir.path().join("traces"), false).unwrap();
        t.emit("x", json!({"a": 1}));
        t.emit("y", json!({}));
        let files: Vec<_> = std::fs::read_dir(dir.path().join("traces"))
            .unwrap()
            .flatten()
            .collect();
        assert_eq!(files.len(), 1);
        let meta = files[0].metadata().unwrap();
        assert_eq!(meta.permissions().mode() & 0o777, 0o600);
        let text = std::fs::read_to_string(files[0].path()).unwrap();
        let lines: Vec<Value> = text
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
        assert_eq!(lines[0]["ev"], "x");
        assert_eq!(lines[0]["a"], 1);
        assert_eq!(lines[1]["ev"], "y");
    }

    #[test]
    fn common_prefix_respects_utf8() {
        assert_eq!(common_prefix("abcé", "abcè"), 3);
        assert_eq!(common_prefix("same", "same"), 4);
    }
}
