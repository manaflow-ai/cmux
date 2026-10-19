//! The notes log (`~/.cmux/agent-memory-notes.jsonl`): the one durable thing
//! agent memory writes. Everything else in the index is derived from the
//! agents' own memory files and is rebuilt. One JSON object per line,
//! owner-only, appended under the index lock.
//!
//! A note is refused, never redacted, when it is empty, longer than
//! [`NOTE_LIMIT`] characters, holds a NUL or other control characters, or
//! looks like a credential ([`looks_secret`]). Each note records where it
//! came from: the date, and when known the host, the agent session and the
//! working directory of the caller (for a relayed call, the caller's, not
//! the owner's).

use std::io::Write;
use std::path::Path;

use serde_json::{Map, Value, json};

/// The longest note, in characters.
pub const NOTE_LIMIT: usize = 4000;

/// One saved note.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Note {
    /// RFC 3339, local time with offset.
    pub date: String,
    pub text: String,
    /// Where it came from: host, session, cwd (and `source`, the free-form
    /// provenance of notes written before 2026-10-18).
    pub provenance: Map<String, Value>,
}

impl Note {
    fn to_json(&self) -> Value {
        let mut object = Map::new();
        object.insert("date".into(), json!(self.date));
        object.insert("text".into(), json!(self.text));
        for (key, value) in &self.provenance {
            if key != "date" && key != "text" {
                object.insert(key.clone(), value.clone());
            }
        }
        Value::Object(object)
    }
}

/// The caller of `remember`: who saved the note, and from where.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Provenance {
    pub host: Option<String>,
    pub session: Option<String>,
    pub cwd: Option<String>,
}

impl Provenance {
    /// This process: its host name, its agent session (`CMUX_AGENT_SESSION`,
    /// which cmux gives every server it registers, else Codex's
    /// `CODEX_THREAD_ID`) and its working directory.
    pub fn here() -> Provenance {
        Provenance {
            host: hostname(),
            session: crate::cli::env("CMUX_AGENT_SESSION")
                .or_else(|| crate::cli::env("CODEX_THREAD_ID")),
            cwd: std::env::current_dir()
                .ok()
                .map(|p| p.display().to_string()),
        }
    }

    pub fn to_json(&self) -> Value {
        let mut object = Map::new();
        for (key, value) in [
            ("host", &self.host),
            ("session", &self.session),
            ("cwd", &self.cwd),
        ] {
            if let Some(value) = value {
                object.insert(key.into(), json!(value));
            }
        }
        Value::Object(object)
    }

    /// What a relayed call carried (`_meta`), bounded: only the three
    /// string fields, each at most 512 characters.
    pub fn from_json(value: &Value) -> Provenance {
        let field = |key: &str| {
            value
                .get(key)
                .and_then(Value::as_str)
                .map(|s| {
                    s.chars()
                        .filter(|c| !c.is_control())
                        .take(512)
                        .collect::<String>()
                })
                .filter(|s| !s.is_empty())
        };
        Provenance {
            host: field("host"),
            session: field("session"),
            cwd: field("cwd"),
        }
    }
}

/// Every note in the log; a line that is not a note object is skipped.
pub fn read(path: &Path) -> Vec<Note> {
    let Ok(text) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    text.lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .filter_map(|value| {
            let Value::Object(mut object) = value else {
                return None;
            };
            let text = object.remove("text")?.as_str()?.to_owned();
            let date = object
                .remove("date")
                .and_then(|d| d.as_str().map(str::to_owned))
                .unwrap_or_default();
            Some(Note {
                date,
                text,
                provenance: object,
            })
        })
        .collect()
}

/// Why `text` cannot be a note, or the trimmed text.
pub fn check(text: &str) -> Result<String, String> {
    let text = text.trim();
    if text.is_empty() {
        return Err("a note needs text".into());
    }
    if text.chars().count() > NOTE_LIMIT {
        return Err(format!(
            "a note holds at most {NOTE_LIMIT} characters; split it or link the evidence"
        ));
    }
    if text
        .chars()
        .any(|c| c.is_control() && c != '\n' && c != '\t')
    {
        return Err("a note holds plain text only (no control characters)".into());
    }
    if looks_secret(text) {
        return Err("this looks like a credential; memory never holds secrets".into());
    }
    Ok(text.to_owned())
}

/// Appends a checked note; the caller holds the index lock. Returns the
/// note, its position in the log, and whether it was added: a note whose
/// text the log already holds (an agent that retried after a lost answer)
/// is that note, not a second copy.
pub fn append(path: &Path, text: &str, from: &Provenance) -> Result<(usize, Note, bool), String> {
    let text = check(text)?;
    if let Some((i, note)) = read(path)
        .into_iter()
        .enumerate()
        .find(|(_, note)| note.text == text)
    {
        return Ok((i, note, false));
    }
    let note = Note {
        date: chrono::Local::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, false),
        text,
        provenance: match from.to_json() {
            Value::Object(object) => object,
            _ => Map::new(),
        },
    };
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    let shown = |e: std::io::Error| format!("{}: {e}", path.display());
    let mut file = {
        use std::os::unix::fs::OpenOptionsExt;
        std::fs::OpenOptions::new()
            .append(true)
            .create(true)
            .mode(0o600)
            .open(path)
            .map_err(shown)?
    };
    // Never glue a note onto a last line a hand edit left without a newline.
    let existing = std::fs::read(path).map_err(shown)?;
    let mut line = String::new();
    if !existing.is_empty() && !existing.ends_with(b"\n") {
        line.push('\n');
    }
    line.push_str(&note.to_json().to_string());
    line.push('\n');
    file.write_all(line.as_bytes()).map_err(shown)?;
    file.sync_data().map_err(shown)?;
    let saved = read(path);
    match saved.last() {
        Some(last) if last.text == note.text && last.date == note.date => {
            Ok((saved.len() - 1, note, true))
        }
        _ => Err(format!(
            "the note did not read back from {}; check that file",
            path.display()
        )),
    }
}

/// A credential shape: its prefixes, the characters of its body and the
/// body's shortest length.
type Rule<'a> = (&'a [&'a str], &'a dyn Fn(char) -> bool, usize);

/// Obvious credential shapes: GitHub, OpenAI/Anthropic-style `sk-`, Slack,
/// AWS access key ids, Google API keys and PEM private keys.
pub fn looks_secret(text: &str) -> bool {
    let token = |c: char| c.is_ascii_alphanumeric() || c == '_' || c == '-';
    let alnum_ = |c: char| c.is_ascii_alphanumeric() || c == '_';
    let upper_digit = |c: char| c.is_ascii_uppercase() || c.is_ascii_digit();
    let rules: [Rule; 7] = [
        (&["ghp_", "gho_", "ghu_", "ghs_", "ghr_"], &alnum_, 20),
        (&["github_pat_"], &alnum_, 20),
        (&["sk-"], &token, 20),
        (&["xoxa-", "xoxb-", "xoxp-", "xoxr-", "xoxs-"], &token, 10),
        (&["AKIA"], &upper_digit, 16),
        (&["AIza"], &token, 35),
        (&["glpat-"], &token, 20),
    ];
    for (prefixes, class, min) in rules {
        for prefix in prefixes {
            let mut from = 0;
            while let Some(at) = text[from..].find(prefix) {
                let begin = from + at;
                let start = begin + prefix.len();
                // A key starts a word ("risk-averse" holds no `sk-` key).
                let starts_word = text[..begin].chars().next_back().is_none_or(|c| !token(c));
                let run: String = text[start..].chars().take_while(|c| class(*c)).collect();
                // Generated keys mix in digits; prose after `sk-` does not.
                let keyish = *prefix != "sk-" || run.chars().any(|c| c.is_ascii_digit());
                if starts_word && keyish && run.chars().count() >= min {
                    return true;
                }
                from = start;
            }
        }
    }
    text.contains("-----BEGIN") && text.contains("PRIVATE KEY-----")
}

fn hostname() -> Option<String> {
    let mut buf = [0u8; 256];
    // SAFETY: gethostname writes at most buf.len() bytes into buf.
    let rc = unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len()) };
    if rc != 0 {
        return None;
    }
    let end = buf.iter().position(|b| *b == 0).unwrap_or(buf.len());
    let name = String::from_utf8_lossy(&buf[..end]);
    let short = name.split('.').next().unwrap_or("").to_owned();
    (!short.is_empty()).then_some(short)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refuses_empty_long_control_and_secret_notes() {
        assert!(check("  ").is_err());
        assert!(check(&"x".repeat(NOTE_LIMIT + 1)).is_err());
        assert!(check(&"x".repeat(NOTE_LIMIT)).is_ok());
        assert!(check("bell \u{7} here").is_err());
        assert_eq!(check(" a\n\tb ").unwrap(), "a\n\tb");
        for secret in [
            "token ghp_0123456789abcdefABCDEF0123 leaked",
            "github_pat_11ABCDEFG0123456789_abcdefghij",
            "key sk-ant-api03-abcdefghijklmnopqrstuvwxyz",
            "xoxb-1234567890-abcdef",
            "AKIAABCDEFGHIJKLMNOP",
            "AIzaSyA-0123456789abcdefghijklmnopqrstu",
            "-----BEGIN OPENSSH PRIVATE KEY-----\nabc",
        ] {
            assert!(looks_secret(secret), "{secret}");
            assert!(check(secret).is_err());
        }
        for fine in [
            "use sk-learn for this",
            "the ghp_ prefix marks GitHub tokens",
            "AKIA is the AWS key id prefix",
            "risk-averse-task-runner-for-builds",
            "the sk-learn-pipeline-for-cross-validation docs",
        ] {
            assert!(!looks_secret(fine), "{fine}");
        }
    }

    #[test]
    fn appends_owner_only_with_provenance_and_reads_old_notes() {
        let dir = tempfile::tempdir().unwrap();
        let log = dir.path().join("notes.jsonl");
        // An old prototype note, cut short without its newline.
        std::fs::write(
            &log,
            "{\"date\":\"2026-10-17\",\"text\":\"old\",\"source\":\"/repo\"}",
        )
        .unwrap();
        let from = Provenance {
            host: Some("box".into()),
            session: Some("s1".into()),
            cwd: None,
        };
        let (i, note, added) = append(&log, " new lesson ", &from).unwrap();
        assert!(added);
        assert_eq!(i, 1);
        assert_eq!(note.text, "new lesson");
        let notes = read(&log);
        assert_eq!(notes.len(), 2);
        assert_eq!(notes[0].provenance.get("source"), Some(&json!("/repo")));
        assert_eq!(notes[1].provenance.get("host"), Some(&json!("box")));
        assert_eq!(notes[1].provenance.get("session"), Some(&json!("s1")));
        use std::os::unix::fs::PermissionsExt;
        // A new log is owner-only.
        let fresh = dir.path().join("fresh.jsonl");
        append(&fresh, "x", &Provenance::default()).unwrap();
        assert_eq!(
            std::fs::metadata(&fresh).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert!(append(&log, "ghp_0123456789abcdefABCDEF0123", &from).is_err());
        assert_eq!(read(&log).len(), 2);
    }

    #[test]
    fn relayed_provenance_is_bounded() {
        let p = Provenance::from_json(
            &json!({"host": "a\u{1b}b", "session": "x".repeat(600), "cwd": 3}),
        );
        assert_eq!(p.host.as_deref(), Some("ab"));
        assert_eq!(p.session.unwrap().len(), 512);
        assert_eq!(p.cwd, None);
    }
}
