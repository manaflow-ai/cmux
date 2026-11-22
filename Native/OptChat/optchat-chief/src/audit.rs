//! The Chief's audit log: who made the Chief do what, where, with what
//! result. Tamper-evident: each record carries the SHA-256 of the record
//! before it, so an edit, a removal or a reorder anywhere breaks the chain
//! at that point ([`verify`]).
//!
//! `$MUX_HOME/optchat/audit/audit.jsonl` (directory 0700, file 0600), one
//! JSON object per line:
//!
//! ```json
//! {"seq": 7, "at": 1762100000000, "who": ["user_ben"], "via": "turn:..",
//!  "host": "cmux-chief-1", "cwd": "/srv/chief/ws", "tool": "Bash",
//!  "what": "run `git status`", "input_sha256": "..", "decision": "allow",
//!  "by": "grant:Bash(git status*)", "output_sha256": "..", "output_bytes": 120,
//!  "prev": "<hash of seq 6>", "hash": "<sha256 of this line without hash>"}
//! ```
//!
//! - `decision` is `allow`, `deny` or `result` (a call's output, recorded
//!   after it ran; `output_sha256` is the digest of the output text, never the
//!   text itself).
//! - Writers append under an exclusive `flock` of `audit.lock`, so the host
//!   and the turn's hooks never fork the chain.
//! - A chain can be rewritten whole by whoever can write the file. The head
//!   ([`head`]) is what anchors it: `/audit` and `optchat-chief audit` print
//!   it, and the host keeps the last head it wrote in its log, so a rewrite
//!   shows as a head nobody saw.

use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

/// The hash before the first record.
pub const GENESIS: &str = "0000000000000000000000000000000000000000000000000000000000000000";

/// One record as written (every field but `seq`, `at`, `prev` and `hash` is
/// the caller's).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Entry {
    /// The people whose text the turn carried (the owner alone for theirs).
    #[serde(default)]
    pub who: Vec<String>,
    /// The turn or session it ran in, or `host` for the host's own act.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub via: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    pub tool: String,
    /// The call in a few words (`approval::describe`): the command, the file.
    #[serde(default)]
    pub what: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input_sha256: Option<String>,
    /// `allow`, `deny` or `result`.
    pub decision: String,
    /// Who allowed it (`owner`, `approver`, `grant:<pattern>`) or why not.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub by: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_sha256: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_bytes: Option<u64>,
    /// A `spend` record's cost in USD.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usd: Option<f64>,
}

/// A record as read back.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Record {
    pub seq: u64,
    pub at: i64,
    #[serde(flatten)]
    pub entry: Entry,
    pub prev: String,
    pub hash: String,
}

/// The log's directory under the optchat root.
pub fn dir(optchat_root: &Path) -> PathBuf {
    optchat_root.join("audit")
}

pub fn path(optchat_root: &Path) -> PathBuf {
    dir(optchat_root).join("audit.jsonl")
}

/// Hex SHA-256 of `bytes`.
pub fn sha256(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    digest.iter().map(|b| format!("{b:02x}")).collect()
}

/// The hash of a record: SHA-256 over `prev`, a NUL, and the record's JSON
/// with keys sorted and `hash` left out.
fn hash_of(value: &Value) -> String {
    let mut body = value.clone();
    if let Value::Object(m) = &mut body {
        m.remove("hash");
    }
    let prev = value.get("prev").and_then(Value::as_str).unwrap_or(GENESIS);
    let mut bytes = prev.as_bytes().to_vec();
    bytes.push(0);
    bytes.extend(canonical(&body).as_bytes());
    sha256(&bytes)
}

/// JSON with object keys sorted at every level (serde_json's map keeps
/// insertion order unless preserve_order is off; sort explicitly).
fn canonical(value: &Value) -> String {
    fn sorted(v: &Value) -> Value {
        match v {
            Value::Object(m) => {
                let mut keys: Vec<&String> = m.keys().collect();
                keys.sort();
                let mut out = Map::new();
                for k in keys {
                    out.insert(k.clone(), sorted(&m[k]));
                }
                Value::Object(out)
            }
            Value::Array(a) => Value::Array(a.iter().map(sorted).collect()),
            other => other.clone(),
        }
    }
    sorted(value).to_string()
}

/// The open log, locked for one append.
struct Locked {
    _lock: File,
    file: File,
}

fn open_locked(root: &Path) -> std::io::Result<Locked> {
    let d = dir(root);
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&d)?;
    let lock = OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(d.join("audit.lock"))?;
    // SAFETY: flock on a file descriptor we own; blocks until held.
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    let file = OpenOptions::new()
        .create(true)
        .read(true)
        .append(true)
        .mode(0o600)
        .open(path(root))?;
    Ok(Locked { _lock: lock, file })
}

/// The last record's `(seq, hash)`, read from the end of the file.
fn last_of(file: &mut File) -> std::io::Result<(u64, String)> {
    let len = file.seek(SeekFrom::End(0))?;
    if len == 0 {
        return Ok((0, GENESIS.to_owned()));
    }
    let mut back = 8192u64.min(len);
    loop {
        file.seek(SeekFrom::Start(len - back))?;
        let mut buf = vec![0u8; back as usize];
        file.read_exact(&mut buf)?;
        let text = String::from_utf8_lossy(&buf);
        let trimmed = text.trim_end_matches('\n');
        let line = match trimmed.rfind('\n') {
            Some(i) => &trimmed[i + 1..],
            None if back == len => trimmed,
            None => {
                back = (back * 4).min(len);
                continue;
            }
        };
        let v: Value = serde_json::from_str(line).map_err(|e| {
            std::io::Error::new(std::io::ErrorKind::InvalidData, format!("audit tail: {e}"))
        })?;
        let seq = v.get("seq").and_then(Value::as_u64).unwrap_or(0);
        let hash = v
            .get("hash")
            .and_then(Value::as_str)
            .unwrap_or(GENESIS)
            .to_owned();
        return Ok((seq, hash));
    }
}

/// Appends `entry` and answers the record written.
pub fn append(root: &Path, entry: &Entry) -> std::io::Result<Record> {
    let mut locked = open_locked(root)?;
    let (seq, prev) = last_of(&mut locked.file)?;
    let mut value = serde_json::to_value(entry)?;
    if let Value::Object(m) = &mut value {
        m.insert("seq".into(), json!(seq + 1));
        m.insert("at".into(), json!(chrono::Utc::now().timestamp_millis()));
        m.insert("prev".into(), json!(prev));
    }
    let hash = hash_of(&value);
    if let Value::Object(m) = &mut value {
        m.insert("hash".into(), json!(hash));
    }
    let line = format!("{}\n", canonical(&value));
    locked.file.write_all(line.as_bytes())?;
    locked.file.sync_data()?;
    serde_json::from_value(value).map_err(std::io::Error::other)
}

/// Reads every record (a line that does not parse is an error).
pub fn read(root: &Path) -> Result<Vec<Record>, String> {
    let file = match File::open(path(root)) {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e.to_string()),
    };
    let mut out = Vec::new();
    for (i, line) in BufReader::new(file).lines().enumerate() {
        let line = line.map_err(|e| e.to_string())?;
        if line.trim().is_empty() {
            continue;
        }
        out.push(serde_json::from_str(&line).map_err(|e| format!("line {}: {e}", i + 1))?);
    }
    Ok(out)
}

/// The result of walking the chain.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Verified {
    pub records: u64,
    pub head: String,
    /// The first broken line (1-based) and why; None: the chain holds.
    pub broken: Option<(u64, String)>,
}

/// Walks the chain from the start and recomputes every hash.
pub fn verify(root: &Path) -> Result<Verified, String> {
    let file = match File::open(path(root)) {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Ok(Verified {
                records: 0,
                head: GENESIS.into(),
                broken: None,
            });
        }
        Err(e) => return Err(e.to_string()),
    };
    let mut prev = GENESIS.to_owned();
    let mut n = 0u64;
    for (i, line) in BufReader::new(file).lines().enumerate() {
        let line_no = i as u64 + 1;
        let line = line.map_err(|e| e.to_string())?;
        let broken = |why: String| {
            Ok(Verified {
                records: n,
                head: prev.clone(),
                broken: Some((line_no, why)),
            })
        };
        let v: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(e) => return broken(format!("not JSON: {e}")),
        };
        if v.get("prev").and_then(Value::as_str) != Some(prev.as_str()) {
            return broken("its prev is not the hash of the record before it".into());
        }
        if v.get("seq").and_then(Value::as_u64) != Some(n + 1) {
            return broken(format!("seq is not {}", n + 1));
        }
        let hash = v.get("hash").and_then(Value::as_str).unwrap_or("");
        if hash != hash_of(&v) {
            return broken("its hash does not match its content".into());
        }
        prev = hash.to_owned();
        n += 1;
    }
    Ok(Verified {
        records: n,
        head: prev,
        broken: None,
    })
}

/// `(records, head hash)` without a full verify.
pub fn head(root: &Path) -> Result<(u64, String), String> {
    match File::open(path(root)) {
        Ok(mut f) => last_of(&mut f).map_err(|e| e.to_string()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok((0, GENESIS.into())),
        Err(e) => Err(e.to_string()),
    }
}

/// Records for a person to read: the last `n`, only those that name `who`
/// when given, newest last.
pub fn query<'a>(records: &'a [Record], who: Option<&str>, n: usize) -> Vec<&'a Record> {
    let mut hits: Vec<&Record> = records
        .iter()
        .filter(|r| who.is_none_or(|w| r.entry.who.iter().any(|x| x == w)))
        .collect();
    let skip = hits.len().saturating_sub(n);
    hits.drain(..skip);
    hits
}

/// One record as a line for `/audit`.
pub fn line(r: &Record, name_of: &dyn Fn(&str) -> String) -> String {
    let when = chrono::DateTime::from_timestamp_millis(r.at)
        .map(|t| {
            t.with_timezone(&chrono::Local)
                .format("%m-%d %H:%M:%S")
                .to_string()
        })
        .unwrap_or_default();
    let who = if r.entry.who.is_empty() {
        "the host".to_owned()
    } else {
        r.entry
            .who
            .iter()
            .map(|w| name_of(w))
            .collect::<Vec<_>>()
            .join(" + ")
    };
    let mut s = format!(
        "#{} {when} {who}: {} {}",
        r.seq, r.entry.decision, r.entry.what
    );
    if let Some(by) = &r.entry.by {
        s.push_str(&format!(" ({by})"));
    }
    if let Some(h) = &r.entry.host {
        s.push_str(&format!(" on {h}"));
    }
    if let Some(cwd) = &r.entry.cwd {
        s.push_str(&format!(" in {cwd}"));
    }
    if let Some(o) = &r.entry.output_sha256 {
        s.push_str(&format!(" -> sha256:{}", &o[..12.min(o.len())]));
    }
    s
}

/// `optchat-chief audit ...`:
///
/// ```text
/// optchat-chief audit [--last N] [--who PERSON] [--json]   the newest records
/// optchat-chief audit verify                               walk the chain
/// optchat-chief audit head                                 records and head hash
/// optchat-chief audit append                               one Entry as JSON on stdin
/// ```
pub fn run(words: &[String], root: &Path, stdin: &mut dyn std::io::Read) -> Result<String, String> {
    let mut last = 20usize;
    let mut who: Option<String> = None;
    let mut json = false;
    let mut rest = Vec::new();
    let mut it = words.iter();
    while let Some(w) = it.next() {
        match w.as_str() {
            "--last" => {
                last = it
                    .next()
                    .and_then(|n| n.parse().ok())
                    .ok_or("--last takes a number")?
            }
            "--who" => who = Some(it.next().ok_or("--who takes a person")?.clone()),
            "--json" => json = true,
            other => rest.push(other.to_owned()),
        }
    }
    match rest
        .iter()
        .map(String::as_str)
        .collect::<Vec<_>>()
        .as_slice()
    {
        [] | ["show"] => {
            let records = read(root)?;
            let hits = query(&records, who.as_deref(), last);
            if json {
                return serde_json::to_string_pretty(&hits).map_err(|e| e.to_string());
            }
            let names =
                crate::rights::Rights::load(&crate::rights::Rights::path(root)).unwrap_or_default();
            let name_of = |id: &str| names.name_of(id).to_owned();
            let mut out: Vec<String> = hits.iter().map(|r| line(r, &name_of)).collect();
            let (n, h) = head(root)?;
            out.push(format!("{n} records, head {}", &h[..16]));
            Ok(out.join("\n"))
        }
        ["verify"] => {
            let v = verify(root)?;
            match v.broken {
                None => Ok(format!("ok: {} records, head {}", v.records, v.head)),
                Some((line, why)) => Err(format!(
                    "BROKEN at line {line}: {why} ({} records verified before it, head {})",
                    v.records, v.head
                )),
            }
        }
        ["head"] => {
            let (n, h) = head(root)?;
            Ok(format!("{n} {h}"))
        }
        ["append"] => {
            let mut text = String::new();
            stdin.read_to_string(&mut text).map_err(|e| e.to_string())?;
            let entry: Entry = serde_json::from_str(&text).map_err(|e| format!("entry: {e}"))?;
            let r = append(root, &entry).map_err(|e| e.to_string())?;
            Ok(format!("{} {}", r.seq, r.hash))
        }
        _ => Err("usage: audit [--last N] [--who PERSON] [--json] | verify | head | append".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("audit-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        d
    }

    fn entry(who: &str, what: &str, decision: &str) -> Entry {
        Entry {
            who: vec![who.into()],
            tool: "Bash".into(),
            what: what.into(),
            decision: decision.into(),
            host: Some("box".into()),
            ..Entry::default()
        }
    }

    #[test]
    fn records_chain_and_verify() {
        let root = tmp("chain");
        let a = append(&root, &entry("user_ben", "run `ls`", "deny")).unwrap();
        let b = append(&root, &entry("user_ben", "run `ls`", "allow")).unwrap();
        assert_eq!((a.seq, b.seq), (1, 2));
        assert_eq!(a.prev, GENESIS);
        assert_eq!(b.prev, a.hash);
        let v = verify(&root).unwrap();
        assert_eq!(
            v,
            Verified {
                records: 2,
                head: b.hash.clone(),
                broken: None
            }
        );
        assert_eq!(head(&root).unwrap(), (2, b.hash));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn an_edit_a_removal_or_a_reorder_breaks_the_chain() {
        let root = tmp("tamper");
        for i in 0..4 {
            append(
                &root,
                &entry("user_ben", &format!("run `echo {i}`"), "allow"),
            )
            .unwrap();
        }
        let p = path(&root);
        let good = std::fs::read_to_string(&p).unwrap();
        let lines: Vec<&str> = good.lines().collect();

        // An edit of one record's content.
        std::fs::write(&p, good.replacen("echo 1", "echo X", 1)).unwrap();
        assert_eq!(verify(&root).unwrap().broken.unwrap().0, 2);

        // A removal.
        let removed = [lines[0], lines[2], lines[3]].join("\n") + "\n";
        std::fs::write(&p, removed).unwrap();
        assert_eq!(verify(&root).unwrap().broken.unwrap().0, 2);

        // A reorder.
        let swapped = [lines[0], lines[2], lines[1], lines[3]].join("\n") + "\n";
        std::fs::write(&p, swapped).unwrap();
        assert!(verify(&root).unwrap().broken.is_some());

        // An edit that also fixes its own hash still breaks the next link.
        let mut v: Value = serde_json::from_str(lines[1]).unwrap();
        v["what"] = json!("run `echo X`");
        let h = hash_of(&v);
        v["hash"] = json!(h);
        let forged = [
            lines[0].to_owned(),
            canonical(&v),
            lines[2].to_owned(),
            lines[3].to_owned(),
        ]
        .join("\n")
            + "\n";
        std::fs::write(&p, forged).unwrap();
        assert_eq!(verify(&root).unwrap().broken.unwrap().0, 3);

        std::fs::write(&p, good).unwrap();
        assert!(verify(&root).unwrap().broken.is_none());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn concurrent_writers_keep_one_chain() {
        let root = tmp("race");
        let threads: Vec<_> = (0..8)
            .map(|t| {
                let root = root.clone();
                std::thread::spawn(move || {
                    for i in 0..25 {
                        append(&root, &entry("user_ben", &format!("{t}/{i}"), "allow")).unwrap();
                    }
                })
            })
            .collect();
        for t in threads {
            t.join().unwrap();
        }
        let v = verify(&root).unwrap();
        assert_eq!(v.records, 200);
        assert!(v.broken.is_none());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn query_filters_by_person_and_keeps_the_newest() {
        let root = tmp("query");
        append(&root, &entry("user_ben", "a", "deny")).unwrap();
        append(&root, &entry("user_ana", "b", "allow")).unwrap();
        append(&root, &entry("user_ben", "c", "allow")).unwrap();
        let records = read(&root).unwrap();
        let ben: Vec<_> = query(&records, Some("user_ben"), 10)
            .iter()
            .map(|r| r.entry.what.clone())
            .collect();
        assert_eq!(ben, ["a", "c"]);
        assert_eq!(query(&records, None, 1)[0].entry.what, "c");
        let text = run(
            &["--who".into(), "user_ben".into()],
            &root,
            &mut std::io::empty(),
        )
        .unwrap();
        assert!(text.contains("user_ben: deny a"), "{text}");
        assert!(text.contains("3 records, head"), "{text}");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn the_log_is_private() {
        use std::os::unix::fs::PermissionsExt;
        let root = tmp("mode");
        append(&root, &entry("user_ben", "a", "deny")).unwrap();
        assert_eq!(
            std::fs::metadata(path(&root)).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            std::fs::metadata(dir(&root)).unwrap().permissions().mode() & 0o777,
            0o700
        );
        let _ = std::fs::remove_dir_all(&root);
    }
}
