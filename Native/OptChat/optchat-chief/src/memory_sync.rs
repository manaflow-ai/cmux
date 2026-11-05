//! `optchat-chief memory import-from SOURCE dry-run|write`: bring another
//! memory (another Chief's, Claude Code's, Codex's, an export zip) into a
//! memory that already has messages. Incremental (a key per item), merge not
//! replace, secrets dropped, a backup before a write.
//! Design: plans/cmux-next/chief-memory-import-DESIGN.md.

use std::collections::HashSet;
use std::io::Read;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::agent_memory::notes::looks_secret;
use crate::browse::Imported;
use crate::paths::Paths;

/// One thing to bring over.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Item {
    /// `sha256(kind \0 date_ms \0 text)`: same on the client and the server.
    pub key: String,
    pub kind: String,
    pub text: String,
    /// RFC 3339.
    pub date: String,
    /// Where it came from (`chief`, `claude-code`, `zip:x.zip`).
    pub source: String,
}

/// The date as milliseconds since the epoch (an undated item is 0).
pub fn date_ms(date: &str) -> i64 {
    chrono::DateTime::parse_from_rfc3339(date)
        .map(|d| d.timestamp_millis())
        .unwrap_or(0)
}

/// The key of a message: the same hash the server makes of a stored one.
pub fn item_key(kind: &str, date: &str, text: &str) -> String {
    let mut h = Sha256::new();
    h.update(kind.as_bytes());
    h.update([0]);
    h.update(date_ms(date).to_string().as_bytes());
    h.update([0]);
    h.update(text.as_bytes());
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

pub fn item(kind: &str, text: &str, date: &str, source: &str) -> Item {
    Item {
        key: item_key(kind, date, text),
        kind: kind.to_owned(),
        text: text.to_owned(),
        date: date.to_owned(),
        source: source.to_owned(),
    }
}

/// What a dry run found.
#[derive(Clone, Debug, Default, PartialEq, Eq, serde::Serialize)]
pub struct Plan {
    pub source: String,
    pub total: usize,
    pub new: usize,
    pub duplicate: usize,
    pub secrets: usize,
    pub new_bytes: usize,
    pub first: Option<String>,
    pub last: Option<String>,
    /// Estimated model tokens the target's compactor reads / writes to build the side's summaries.
    pub est_input_tokens: u64,
    pub est_output_tokens: u64,
}

/// Dollars per million tokens (input, output) of the compactor model.
#[derive(Clone, Copy, Debug)]
pub struct Price {
    pub input: f64,
    pub output: f64,
}

impl Default for Price {
    fn default() -> Price {
        Price {
            input: 1.0,
            output: 5.0,
        }
    }
}

impl Plan {
    pub fn cost(&self, price: Price) -> f64 {
        self.est_input_tokens as f64 / 1e6 * price.input
            + self.est_output_tokens as f64 / 1e6 * price.output
    }

    pub fn line(&self, price: Price) -> String {
        format!(
            "{}: {} items, {} new ({} bytes), {} already there, {} dropped as secrets, {} to {}; est. {} tokens in / {} out, about ${:.2}",
            self.source,
            self.total,
            self.new,
            self.new_bytes,
            self.duplicate,
            self.secrets,
            self.first.as_deref().unwrap_or("-"),
            self.last.as_deref().unwrap_or("-"),
            self.est_input_tokens,
            self.est_output_tokens,
            self.cost(price)
        )
    }
}

/// Sorts `items` into what to write (new, oldest first) and the counts: an
/// item whose key is in `known` (or repeats an earlier item of the batch) is a
/// duplicate; one whose text looks like a credential is dropped.
pub fn make_plan(source: &str, items: Vec<Item>, known: &HashSet<String>) -> (Plan, Vec<Item>) {
    let mut plan = Plan {
        source: source.to_owned(),
        total: items.len(),
        ..Plan::default()
    };
    let mut seen: HashSet<&str> = HashSet::new();
    let mut fresh = Vec::new();
    for it in &items {
        if looks_secret(&it.text) {
            plan.secrets += 1;
        } else if known.contains(&it.key) || !seen.insert(&it.key) {
            plan.duplicate += 1;
        } else {
            fresh.push(it.clone());
        }
    }
    fresh.sort_by_key(|i| date_ms(&i.date));
    plan.new = fresh.len();
    plan.new_bytes = fresh.iter().map(|i| i.text.len()).sum();
    plan.first = fresh.first().map(|i| i.date.clone());
    plan.last = fresh.last().map(|i| i.date.clone());
    // Leaf summaries read each message once; the levels above read the summaries (about +50%).
    plan.est_input_tokens = (plan.new_bytes as u64 / 4) * 3 / 2;
    plan.est_output_tokens = plan.est_input_tokens / 7;
    (plan, fresh)
}

/// The keys of the messages a memory holds, from its text export's `main/` lines.
pub fn keys_of_export_lines<'a>(lines: impl Iterator<Item = &'a str>) -> HashSet<String> {
    lines
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .filter_map(|v| {
            Some(item_key(
                v["kind"].as_str()?,
                v["date"].as_str()?,
                v["text"].as_str()?,
            ))
        })
        .collect()
}

/// The header an imported item carries in the target (a side, never a live line).
pub fn side_text(it: &Item) -> String {
    format!(
        "[imported from {} · {} · {}]\n{}",
        it.source, it.kind, it.date, it.text
    )
}

/// Reads `side_text` back: (kind, date, text) of an imported note.
pub fn parse_side_text(note: &str) -> Option<(&str, &str, &str)> {
    let (header, text) = note.split_once('\n')?;
    let inner = header.strip_prefix("[imported from ")?.strip_suffix(']')?;
    let mut parts = inner.rsplitn(3, " · ");
    let date = parts.next()?;
    let kind = parts.next()?;
    parts.next()?;
    Some((kind, date, text))
}

/// Keys of the items a memory export holds as imported notes.
fn keys_of_side_notes<'a>(lines: impl Iterator<Item = &'a str>) -> HashSet<String> {
    lines
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .filter_map(|v| {
            let (kind, date, text) = parse_side_text(v["text"].as_str()?)?;
            Some(item_key(kind, date, text))
        })
        .collect()
}

fn keys_file(paths: &Paths) -> PathBuf {
    paths.root.join("import-keys.txt")
}

/// Keys of what this memory holds or imported before.
pub fn local_known(paths: &Paths) -> Result<HashSet<String>, String> {
    let mut known = HashSet::new();
    if paths.memory_db.exists() {
        let (main, _) = crate::migrate_cloud::memory_lines(&paths.memory_db)?;
        known = keys_of_export_lines(main.iter().map(String::as_str));
        // Imported notes carry their item's key in their header, so a write cut
        // off before import-keys.txt was appended still counts as done.
        known.extend(keys_of_side_notes(main.iter().map(String::as_str)));
    }
    if let Ok(text) = std::fs::read_to_string(keys_file(paths)) {
        known.extend(text.lines().map(str::to_owned));
    }
    Ok(known)
}

/// Writes `fresh` into the local memory after its existing messages (host
/// stopped), after a backup of the database. Existing messages and nodes stay.
/// Returns (written, backup path).
pub fn write_local(paths: &Paths, fresh: &[Item]) -> Result<(usize, Option<PathBuf>), String> {
    if fresh.is_empty() {
        return Ok((0, None));
    }
    let mut backup = None;
    if paths.memory_db.exists() {
        let stamp = chrono::Utc::now().timestamp_millis();
        let mut to = paths
            .memory_db
            .with_extension(format!("sqlite3.import-backup-{stamp}"));
        let mut suffix = 1;
        while to.exists() {
            to = paths
                .memory_db
                .with_extension(format!("sqlite3.import-backup-{stamp}-{suffix}"));
            suffix += 1;
        }
        std::fs::copy(&paths.memory_db, &to)
            .map_err(|e| format!("backup {}: {e}", to.display()))?;
        backup = Some(to);
    }
    let items: Vec<Imported> = fresh
        .iter()
        .map(|i| Imported {
            kind: optchat_core::Kind::Note,
            text: side_text(i),
            date: Some(i.date.clone()).filter(|d| date_ms(d) != 0),
        })
        .collect();
    let n = crate::browse::import(&paths.chat, &paths.memory_db, &items)?;
    use std::io::Write;
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(keys_file(paths))
        .map_err(|e| e.to_string())?;
    for i in fresh {
        writeln!(f, "{}", i.key).map_err(|e| e.to_string())?;
    }
    Ok((n, backup))
}

// ---------------------------------------------------------------- sources

/// The Mac (or any) Chief's own messages.
pub fn items_from_chief(db: &Path) -> Result<Vec<Item>, String> {
    let (main, _) = crate::migrate_cloud::memory_lines(db)?;
    Ok(main
        .iter()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .filter_map(|v| {
            Some(item(
                v["kind"].as_str()?,
                v["text"].as_str()?,
                v["date"].as_str()?,
                "chief",
            ))
        })
        .collect())
}

/// Claude Code's and Codex's memory files (one note per unit).
pub fn items_from_memory_files(user_home: &Path, codex_only: bool) -> Vec<Item> {
    let sources = crate::agent_memory::sources::Sources::new(user_home, Vec::new(), PathBuf::new());
    sources
        .entries()
        .into_iter()
        .filter(|e| e.source.contains("/.codex/") == codex_only)
        .filter(|e| !e.source.starts_with("note "))
        .map(|e| {
            item(
                "note",
                &format!("{}\n{}", e.source, e.text),
                &e.date,
                if codex_only { "codex" } else { "claude-memory" },
            )
        })
        .collect()
}

/// Claude Code transcripts.
pub fn items_from_claude_code(projects: &Path) -> Result<Vec<Item>, String> {
    let (imported, _) =
        crate::claude_import::convert_projects(projects).map_err(|e| e.to_string())?;
    Ok(imported
        .into_iter()
        .map(|i| {
            let date = i.date.unwrap_or_default();
            item(i.kind.as_str(), &i.text, &date, "claude-code")
        })
        .collect())
}

/// A pasted self-summary from an assistant that has no export API. Empty
/// paragraphs are ignored and each paragraph becomes one note so the Chief's
/// compactor can keep preferences, people and projects as separate memories.
/// The origin is deliberately part of the item source (and therefore the
/// imported side header), while the key remains content based for idempotent
/// re-imports from a newly-created temporary file.
pub fn items_from_text(text: &str, origin: &str) -> Result<Vec<Item>, String> {
    let origin = match origin {
        "grok-bot" | "muse" | "dots" | "instinct" => origin,
        _ => {
            return Err(format!(
                "unknown text origin {origin}; use grok-bot, muse, dots or instinct"
            ));
        }
    };
    let date = "1970-01-01T00:00:00Z"; // source exports do not carry a trustworthy date
    let mut paragraphs = Vec::new();
    let mut current = String::new();
    for line in text.lines() {
        if line.trim().is_empty() {
            if !current.trim().is_empty() {
                paragraphs.push(std::mem::take(&mut current));
            }
        } else {
            if !current.is_empty() {
                current.push('\n');
            }
            current.push_str(line.trim_end());
        }
    }
    if !current.trim().is_empty() {
        paragraphs.push(current);
    }
    Ok(paragraphs
        .into_iter()
        .map(|paragraph| item("note", paragraph.trim(), date, origin))
        .collect())
}

/// Reads `text:FILE`; `text:-` and `text:stdin` read standard input. The
/// origin is required so a pasted summary is never detached from its source.
pub fn items_from_text_source(path: &str, origin: Option<&str>) -> Result<Vec<Item>, String> {
    let origin = origin.ok_or("text:FILE needs --origin grok-bot|muse|dots|instinct")?;
    let mut text = String::new();
    if path == "-" || path == "stdin" {
        std::io::stdin()
            .read_to_string(&mut text)
            .map_err(|e| format!("reading text from stdin: {e}"))?;
    } else {
        text = std::fs::read_to_string(path)
            .map_err(|e| format!("reading text {}: {e}", Path::new(path).display()))?;
    }
    items_from_text(&text, origin)
}

/// Codex chat transcripts (`codex_sessions_import`).
pub fn items_from_codex_sessions(dir: &Path) -> Vec<Item> {
    crate::codex_sessions_import::convert_sessions(dir)
        .into_iter()
        .map(|i| item(i.kind, &i.text, &i.date, "codex-sessions"))
        .collect()
}

/// A claude.ai or ChatGPT export (`conversations.json` text).
pub fn items_from_export_json(json_text: &str, source: &str) -> Result<Vec<Item>, String> {
    let v: Value = serde_json::from_str(json_text).map_err(|e| format!("{source}: {e}"))?;
    let list = v
        .as_array()
        .ok_or_else(|| format!("{source}: not a list of conversations"))?;
    let mut out = Vec::new();
    for conv in list {
        let title = conv["name"]
            .as_str()
            .or(conv["title"].as_str())
            .unwrap_or("untitled");
        let mut msgs: Vec<(String, &'static str, String)> = Vec::new();
        if let Some(chat) = conv["chat_messages"].as_array() {
            for m in chat {
                let kind = if m["sender"] == "human" { "user" } else { "ai" };
                let text = m["text"].as_str().unwrap_or("");
                if !text.trim().is_empty() {
                    msgs.push((
                        m["created_at"].as_str().unwrap_or("").to_owned(),
                        kind,
                        text.to_owned(),
                    ));
                }
            }
        } else if let Some(map) = conv["mapping"].as_object() {
            for node in map.values() {
                let m = &node["message"];
                let role = m["author"]["role"].as_str().unwrap_or("");
                let kind = match role {
                    "user" => "user",
                    "assistant" => "ai",
                    _ => continue,
                };
                let text: String = m["content"]["parts"]
                    .as_array()
                    .map(|p| {
                        p.iter()
                            .filter_map(Value::as_str)
                            .collect::<Vec<_>>()
                            .join("\n")
                    })
                    .unwrap_or_default();
                let at = m["create_time"].as_f64().unwrap_or(0.0);
                let date = chrono::DateTime::from_timestamp(at as i64, 0)
                    .map(|d| d.to_rfc3339())
                    .unwrap_or_default();
                if !text.trim().is_empty() {
                    msgs.push((date, kind, text));
                }
            }
        }
        msgs.sort_by_key(|m| date_ms(&m.0));
        let first = msgs.first().map(|m| m.0.clone()).unwrap_or_default();
        if !msgs.is_empty() {
            out.push(item("note", &format!("Session: {title}"), &first, source));
        }
        for (date, kind, text) in msgs {
            out.push(item(kind, &text, &date, source));
        }
    }
    Ok(out)
}

/// An export zip, read through `unzip -p` (never extracted to disk).
pub fn items_from_zip(zip: &Path) -> Result<Vec<Item>, String> {
    let out = std::process::Command::new("unzip")
        .arg("-p")
        .arg(zip)
        .arg("conversations.json")
        .output()
        .map_err(|e| format!("unzip: {e}"))?;
    if !out.status.success() {
        return Err(format!("{}: no conversations.json inside", zip.display()));
    }
    items_from_export_json(
        &String::from_utf8_lossy(&out.stdout),
        &format!(
            "zip:{}",
            zip.file_name().and_then(|n| n.to_str()).unwrap_or("export")
        ),
    )
}

/// Reads a source named on the command line.
pub fn read_source(
    source: &str,
    user_home: &Path,
    chief_db: &Path,
    origin: Option<&str>,
) -> Result<Vec<Item>, String> {
    match source {
        "claude-memory" => Ok(items_from_memory_files(user_home, false)),
        "codex" => Ok(items_from_memory_files(user_home, true)),
        "claude-code" => items_from_claude_code(&crate::claude_import::default_projects_dir(
            user_home,
            std::env::var("CLAUDE_CONFIG_DIR").ok(),
        )),
        "codex-sessions" => Ok(items_from_codex_sessions(
            &crate::codex_sessions_import::default_sessions_dir(
                user_home,
                std::env::var("CODEX_HOME").ok(),
            ),
        )),
        "chief" => items_from_chief(chief_db),
        s => {
            if let Some(z) = s.strip_prefix("zip:") {
                items_from_zip(Path::new(z))
            } else if let Some(path) = s.strip_prefix("text:") {
                items_from_text_source(path, origin)
            } else if let Some(d) = s.strip_prefix("chief:") {
                items_from_chief(&Paths::new(Path::new(d)).memory_db)
            } else {
                Err(format!(
                    "unknown source {s}: chief, chief:MUX_HOME, claude-memory, claude-code, codex, codex-sessions, zip:FILE or text:FILE"
                ))
            }
        }
    }
}

// ---------------------------------------------------------------- cloud

const BATCH_ITEMS: usize = 200;
const BATCH_BYTES: usize = 700_000;

/// The server's answer to one append batch.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Appended {
    pub added: usize,
    pub duplicate: usize,
    pub rejected: usize,
}

/// Sends `items` to the Cloud Chief's memory (`mode: append`), in batches;
/// with `dry_run` the server writes nothing and only counts.
pub fn cloud_append(
    api: &crate::migrate_cloud::Api,
    chief: &str,
    conversation: &str,
    items: &[Item],
    dry_run: bool,
    max_items: Option<usize>,
    batch_id: Option<&str>,
) -> Result<Appended, String> {
    let mut total = Appended::default();
    let mut sent = 0usize;
    let mut i = 0;
    while i < items.len() {
        if max_items.is_some_and(|m| sent >= m) {
            break;
        }
        let mut batch = Vec::new();
        let mut bytes = 0;
        while i < items.len() && batch.len() < BATCH_ITEMS {
            let it = &items[i];
            if !batch.is_empty() && bytes + it.text.len() > BATCH_BYTES {
                break;
            }
            bytes += it.text.len();
            batch.push(json!({"key": it.key, "kind": it.kind, "text": it.text, "date": it.date, "source": it.source}));
            i += 1;
        }
        sent += batch.len();
        let mut body = json!({"mode": "append", "dry_run": dry_run, "items": batch});
        if let Some(id) = batch_id {
            body["batch"] = json!(id);
        }
        let mut tries = 0;
        let value = loop {
            let (status, value) = api.put_memory(chief, conversation, &body)?;
            if value["ok"] == true {
                break value;
            }
            tries += 1;
            if value["error"]["code"] == "brain_busy" && tries < 30 {
                std::thread::sleep(std::time::Duration::from_secs(10));
                continue;
            }
            return Err(format!("memory append: HTTP {status} {}", value["error"]));
        };
        let v = &value["value"];
        total.added += v["added"].as_u64().unwrap_or(0) as usize;
        total.duplicate += v["duplicate"].as_u64().unwrap_or(0) as usize;
        total.rejected += v["rejected"].as_u64().unwrap_or(0) as usize;
    }
    Ok(total)
}

// ---------------------------------------------------------------- command

pub const USAGE: &str = "optchat-chief memory import-from detect [--exports] [--json]   what this Mac holds (Claude Code, Claude memory, Codex; --exports also claude.ai / ChatGPT export zips in ~/Downloads and ~/Desktop, which macOS guards)
optchat-chief memory import-from undo [--to local|cloud[:staging|:URL]] [--chief agent_ID] [--batch ID]   take the last write back
optchat-chief memory import-from SOURCE dry-run|write [--to local|cloud[:staging|:URL]] [--chief agent_ID]
    [--stop-host] [--max-cost USD] [--max-items N] [--price-in USD --price-out USD] [--session-token-file F] [--mux-home DIR] [--json]
  SOURCE: chief (this home's memory), chief:MUX_HOME, claude-memory, claude-code, codex (memories), codex-sessions (chat transcripts), zip:FILE (claude.ai / ChatGPT export), text:FILE or text:- (pasted summary; requires --origin)
  --origin grok-bot|muse|dots|instinct tags pasted text with its source assistant.
  --to local (default) merges into this home's memory (host stopped); --to cloud appends to the Cloud Chief --chief names.
  Incremental: a key per item, so a re-run brings only what is new. Secrets are dropped. A write backs up first.";

pub fn run(flags: &crate::cli::Flags, home: &Path, json_out: bool) -> Result<String, String> {
    let words: Vec<&str> = flags.words.iter().skip(2).map(String::as_str).collect();
    match words.as_slice() {
        ["detect"] => {
            let user_home = std::env::var_os("HOME")
                .map(PathBuf::from)
                .unwrap_or_default();
            let claude_config_dir = std::env::var("CLAUDE_CONFIG_DIR").ok();
            // `--exports`: the person opened the import dialog, so ~/Downloads and ~/Desktop
            // may be listed (and macOS may ask); never without it (LAUNCH-NO-TCC-PROMPTS).
            let found = if flags.value("exports").is_some() {
                crate::memory_sync_state::detect_with_exports(&user_home, claude_config_dir)
            } else {
                crate::memory_sync_state::detect(&user_home, claude_config_dir)
            };
            return Ok(if json_out {
                crate::memory_sync_state::detect_json(&found).to_string()
            } else if found.is_empty() {
                "nothing found on this Mac".to_owned()
            } else {
                found
                    .iter()
                    .map(|d| format!("{}: {} ({} bytes) {}", d.source, d.count, d.bytes, d.path))
                    .collect::<Vec<_>>()
                    .join("\n")
            });
        }
        ["undo"] => return undo(flags, home, json_out),
        _ => {}
    }
    let [source, mode] = words.as_slice() else {
        return Err(USAGE.to_owned());
    };
    let batch = flags
        .value("batch")
        .map(str::to_owned)
        .unwrap_or_else(|| format!("b{}", chrono::Utc::now().timestamp_millis()));
    let write = match *mode {
        "write" => true,
        "dry-run" => false,
        _ => return Err(USAGE.to_owned()),
    };
    let paths = Paths::new(home);
    let user_home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_default();
    let price = Price {
        input: flags
            .value("price-in")
            .and_then(|v| v.parse().ok())
            .unwrap_or(Price::default().input),
        output: flags
            .value("price-out")
            .and_then(|v| v.parse().ok())
            .unwrap_or(Price::default().output),
    };
    let max_cost: f64 = flags
        .value("max-cost")
        .and_then(|v| v.parse().ok())
        .unwrap_or(20.0);
    let max_items = flags
        .value("max-items")
        .and_then(|v| v.parse::<usize>().ok());
    let items = read_source(source, &user_home, &paths.memory_db, flags.value("origin"))?;
    let to = flags.value("to").unwrap_or("local");
    if to == "local" {
        if *source == "chief" {
            return Err(
                "--to local with source chief imports a memory into itself: name chief:MUX_HOME"
                    .into(),
            );
        }
        let known = local_known(&paths)?;
        let (plan, mut fresh) = make_plan(source, items, &known);
        let cost = plan.cost(price);
        if json_out {
            // fall through to the common print below
        }
        if !write {
            return Ok(render(&plan, price, json_out));
        }
        if cost > max_cost {
            return Err(format!(
                "refused: estimated ${cost:.2} is over --max-cost {max_cost}"
            ));
        }
        if let Some(m) = max_items {
            fresh.truncate(m);
        }
        let (before, n, backup) = crate::memory_sync_state::with_host_stopped(
            &paths,
            flags.value("stop-host").is_some(),
            || {
                let before =
                    crate::claude_import::existing_messages(&paths.chat, &paths.memory_db)?;
                let (n, backup) = write_local(&paths, &fresh)?;
                Ok((before, n, backup))
            },
        )?;
        if n > 0 {
            crate::memory_sync_state::record(
                &paths,
                &crate::memory_sync_state::Run {
                    batch: batch.clone(),
                    to: "local".into(),
                    source: (*source).to_owned(),
                    written: n,
                    messages_before: before,
                    backup: backup.clone(),
                    chief: None,
                    keys: fresh.iter().map(|i| i.key.clone()).collect(),
                },
            )?;
        }
        if json_out {
            return Ok(json!({"plan": plan, "est_cost_usd": cost, "written": n, "batch": batch, "to": "local",
                "backup": backup}).to_string());
        }
        return Ok(format!(
            "{}\nwrote {n} items as notes (backup {})",
            render(&plan, price, json_out),
            backup
                .map(|b| b.display().to_string())
                .unwrap_or_else(|| "none: empty memory".into())
        ));
    }
    // Cloud: the server dedupes (existing messages and earlier keys).
    let chief = flags
        .value("chief")
        .ok_or("--to cloud needs --chief agent_ID")?
        .to_owned();
    let base = crate::migrate_cloud::api_base(to)?;
    let token = crate::migrate_cloud::session_token(
        flags.value("session-token-file").map(Path::new),
        Some(&base),
    )?;
    let api = crate::migrate_cloud::Api::new(base, token);
    let conversation = crate::migrate_cloud::chief_main_conversation(&chief);
    let (mut plan, fresh) = make_plan(source, items, &HashSet::new());
    let dry = cloud_append(&api, &chief, &conversation, &fresh, true, None, None)?;
    plan.duplicate += dry.duplicate;
    plan.new = dry.added;
    // Cost for what the server will take: scale by the share of bytes.
    if !fresh.is_empty() {
        plan.est_input_tokens = plan.est_input_tokens * dry.added as u64 / fresh.len() as u64;
        plan.est_output_tokens = plan.est_output_tokens * dry.added as u64 / fresh.len() as u64;
    }
    if !write {
        return Ok(render(&plan, price, json_out));
    }
    let cost = plan.cost(price);
    if cost > max_cost {
        return Err(format!(
            "refused: estimated ${cost:.2} is over --max-cost {max_cost}"
        ));
    }
    let done = cloud_append(
        &api,
        &chief,
        &conversation,
        &fresh,
        false,
        max_items,
        Some(&batch),
    )?;
    if done.added > 0 {
        crate::memory_sync_state::record(
            &paths,
            &crate::memory_sync_state::Run {
                batch: batch.clone(),
                to: "cloud".into(),
                source: (*source).to_owned(),
                written: done.added,
                messages_before: 0,
                backup: None,
                chief: Some(chief.clone()),
                keys: Vec::new(),
            },
        )?;
    }
    if json_out {
        return Ok(json!({"plan": plan, "est_cost_usd": cost, "written": done.added, "batch": batch, "to": "cloud",
            "already_there": done.duplicate, "rejected": done.rejected}).to_string());
    }
    Ok(format!(
        "{}\nwrote {} items to {chief} ({} already there, {} rejected by the server)",
        render(&plan, price, json_out),
        done.added,
        done.duplicate,
        done.rejected
    ))
}

/// `import-from undo`: the last write into this memory (local), or the last append to a Cloud Chief.
fn undo(flags: &crate::cli::Flags, home: &Path, json_out: bool) -> Result<String, String> {
    let paths = Paths::new(home);
    let to = flags.value("to").unwrap_or("local");
    if to == "local" {
        let (removed, text) = crate::memory_sync_state::with_host_stopped(
            &paths,
            flags.value("stop-host").is_some(),
            || crate::memory_sync_state::undo_local(&paths, flags.value("batch")),
        )?;
        return Ok(if json_out {
            json!({"removed": removed, "to": "local"}).to_string()
        } else {
            text
        });
    }
    let chief = flags
        .value("chief")
        .ok_or("--to cloud needs --chief agent_ID")?;
    let all = crate::memory_sync_state::runs(&paths);
    let run = all
        .iter()
        .rev()
        .find(|r| {
            r.to == "cloud"
                && r.chief.as_deref() == Some(chief)
                && flags.value("batch").is_none_or(|b| b == r.batch)
        })
        .ok_or("nothing to undo: no earlier import into this Cloud Chief")?;
    let base = crate::migrate_cloud::api_base(to)?;
    let token = crate::migrate_cloud::session_token(
        flags.value("session-token-file").map(Path::new),
        Some(&base),
    )?;
    let api = crate::migrate_cloud::Api::new(base, token);
    let conversation = crate::migrate_cloud::chief_main_conversation(chief);
    let (status, value) = api.put_memory(
        chief,
        &conversation,
        &json!({"mode": "undo", "batch": run.batch}),
    )?;
    if value["ok"] != true {
        return Err(format!("undo: HTTP {status} {}", value["error"]));
    }
    crate::memory_sync_state::forget(&paths, &run.batch)?;
    let removed = value["value"]["removed"].as_u64().unwrap_or(0);
    if json_out {
        return Ok(json!({"removed": removed, "to": "cloud"}).to_string());
    }
    Ok(format!("took back {removed} imported items from {chief}"))
}

fn render(plan: &Plan, price: Price, json_out: bool) -> String {
    if json_out {
        json!({"plan": plan, "est_cost_usd": plan.cost(price)}).to_string()
    } else {
        plan.line(price)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn items(texts: &[(&str, &str)]) -> Vec<Item> {
        texts
            .iter()
            .enumerate()
            .map(|(n, (k, t))| item(k, t, &format!("2026-10-2{n}T10:00:00.000Z"), "t"))
            .collect()
    }

    fn temp_paths(name: &str) -> Paths {
        let dir = std::env::temp_dir().join(format!("a634-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        Paths::new(&dir)
    }

    #[test]
    fn secrets_are_dropped_and_counted() {
        let key = format!("ghp_{}", "a1".repeat(15));
        let list = items(&[("note", "plain fact"), ("note", &format!("token {key}"))]);
        let (plan, fresh) = make_plan("t", list, &HashSet::new());
        assert_eq!((plan.secrets, plan.new), (1, 1));
        assert!(fresh.iter().all(|i| !i.text.contains("ghp_")));
    }

    #[test]
    fn codex_sessions_become_items_with_stable_keys() {
        let dir = std::env::temp_dir().join(format!("a-codex-items-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("2026/11/02")).unwrap();
        std::fs::write(
            dir.join("2026/11/02/rollout-a.jsonl"),
            concat!(
                r#"{"timestamp":"2026-11-02T10:00:00.000Z","type":"session_meta","payload":{"id":"s","cwd":"/w","source":"cli"}}"#,
                "\n",
                r#"{"timestamp":"2026-11-02T10:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}}"#,
                "\n",
            ),
        )
        .unwrap();
        let first = items_from_codex_sessions(&dir);
        assert_eq!(first.len(), 2);
        assert!(first.iter().all(|i| i.source == "codex-sessions"));
        let known: HashSet<String> = first.iter().map(|i| i.key.clone()).collect();
        let (plan, fresh) = make_plan("codex-sessions", items_from_codex_sessions(&dir), &known);
        assert_eq!((plan.new, fresh.len()), (0, 0));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn known_keys_make_duplicates() {
        let list = items(&[("note", "a"), ("note", "b")]);
        let known: HashSet<String> = [list[0].key.clone()].into();
        let (plan, fresh) = make_plan("t", list, &known);
        assert_eq!((plan.duplicate, plan.new, fresh.len()), (1, 1, 1));
    }

    #[test]
    fn key_ignores_date_notation() {
        assert_eq!(
            item_key("user", "2026-10-06T15:57:35.949-07:00", "x"),
            item_key("user", "2026-10-06T22:57:35.949Z", "x")
        );
    }

    #[test]
    fn local_merge_keeps_existing_and_reimport_adds_nothing() {
        let paths = temp_paths("merge");
        crate::browse::import(
            &paths.chat,
            &paths.memory_db,
            &[
                Imported {
                    kind: optchat_core::Kind::Note,
                    text: "old one".into(),
                    date: Some("2026-10-01T00:00:00Z".into()),
                },
                Imported {
                    kind: optchat_core::Kind::Note,
                    text: "old two".into(),
                    date: Some("2026-10-02T00:00:00Z".into()),
                },
            ],
        )
        .unwrap();
        let list = items(&[("note", "new a"), ("note", "new b")]);
        let (plan, fresh) = make_plan("t", list.clone(), &local_known(&paths).unwrap());
        assert_eq!(plan.new, 2);
        let (n, backup) = write_local(&paths, &fresh).unwrap();
        assert_eq!(n, 2);
        assert!(backup.unwrap().exists());
        let count = crate::claude_import::existing_messages(&paths.chat, &paths.memory_db).unwrap();
        assert_eq!(count, 4, "the two old messages stay, two new ones follow");
        // Again: nothing new.
        let (plan2, fresh2) = make_plan("t", list, &local_known(&paths).unwrap());
        assert_eq!((plan2.new, plan2.duplicate), (0, 2));
        assert_eq!(write_local(&paths, &fresh2).unwrap().0, 0);
        assert_eq!(
            crate::claude_import::existing_messages(&paths.chat, &paths.memory_db).unwrap(),
            4
        );
    }

    /// A write cut off after the items reached the memory but before their keys
    /// reached import-keys.txt (a crash, a quit, a restart) resumes without
    /// copying them twice: the imported notes themselves carry their keys.
    #[test]
    fn interrupted_write_resumes_without_duplicates() {
        let paths = temp_paths("resume");
        let list = items(&[("user", "first"), ("ai", "second"), ("user", "third")]);
        // The first two reached the memory; the keys file never got them.
        let done: Vec<Imported> = list[..2]
            .iter()
            .map(|i| Imported {
                kind: optchat_core::Kind::Note,
                text: side_text(i),
                date: Some(i.date.clone()),
            })
            .collect();
        crate::browse::import(&paths.chat, &paths.memory_db, &done).unwrap();
        assert!(!keys_file(&paths).exists());
        let (plan, fresh) = make_plan("t", list, &local_known(&paths).unwrap());
        assert_eq!((plan.duplicate, plan.new), (2, 1));
        assert_eq!(fresh[0].text, "third");
    }

    #[test]
    fn export_json_claude_ai_and_chatgpt() {
        let claude = r#"[{"name":"Plan","chat_messages":[{"sender":"human","text":"hi","created_at":"2026-10-01T00:00:00Z"},{"sender":"assistant","text":"hello","created_at":"2026-10-01T00:00:05Z"}]}]"#;
        let got = items_from_export_json(claude, "zip:c").unwrap();
        assert_eq!(got.len(), 3);
        assert_eq!(got[1].kind, "user");
        let gpt = r#"[{"title":"T","mapping":{"a":{"message":{"author":{"role":"user"},"content":{"parts":["q"]},"create_time":1760000000.0}},"b":{"message":{"author":{"role":"tool"},"content":{"parts":["x"]},"create_time":1760000001.0}}}}]"#;
        assert_eq!(items_from_export_json(gpt, "zip:g").unwrap().len(), 2);
        let fixture =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/chatgpt-conversations.zip");
        assert_eq!(items_from_zip(&fixture).unwrap().len(), 3);
    }

    #[test]
    fn pasted_text_is_split_and_tagged_with_a_stable_key() {
        let first = items_from_text(
            "Likes short answers.\r\n \r\nWorks on cmux.\r\n",
            "grok-bot",
        )
        .unwrap();
        let second =
            items_from_text("Likes short answers.\n\nWorks on cmux.\n", "grok-bot").unwrap();
        assert_eq!(first.len(), 2);
        assert_eq!(first[0].source, "grok-bot");
        assert_eq!(first[0].kind, "note");
        assert_eq!(first[0].key, second[0].key);
        let known: HashSet<String> = first.iter().map(|i| i.key.clone()).collect();
        let (plan, fresh) = make_plan("text:stdin", second, &known);
        assert_eq!((plan.new, plan.duplicate), (0, 2));
        assert!(fresh.is_empty());
        let secret = format!("token ghp_{}", "a1".repeat(15));
        let (secret_plan, secret_fresh) = make_plan(
            "text:stdin",
            items_from_text(&secret, "muse").unwrap(),
            &HashSet::new(),
        );
        assert_eq!(secret_plan.secrets, 1);
        assert!(secret_fresh.is_empty());
    }

    #[test]
    fn pasted_text_requires_a_known_origin() {
        assert!(items_from_text("a", "chatgpt").is_err());
        assert!(items_from_text_source("-", None).is_err());
    }
}
