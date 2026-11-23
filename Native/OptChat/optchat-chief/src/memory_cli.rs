//! `optchat-chief memory ...`: the memory database from the command line.
//! Export, search and stats open a read-only connection, so they work while
//! the host runs; import needs the host stopped (it takes the chat's lock).

use std::path::{Path, PathBuf};

use optchat_host::db::{Hit, MIGRATION_KEY, ReadOnly, SCHEMA_VERSION};

use crate::cli::Flags;
use crate::paths::Paths;

pub const USAGE: &str = "optchat-chief memory export --text DIR [--mux-home DIR]   the memory as JSONL day files (main/, tree/; the old store's format)
optchat-chief memory import [--mux-home DIR] DIR          an old JSONL home or an export into an empty memory (host stopped)
optchat-chief memory import-from SOURCE dry-run|write   merge another memory into this one or the Cloud Chief (see memory_sync.rs)
optchat-chief memory search [--mux-home DIR] [--limit N] [--json] QUERY  full-text search: messages and summaries holding every word
                                                          (--json: an array of hits, messages with id, kind, date, snippet and full text)
optchat-chief memory stats [--mux-home DIR]               counts, schema version, migration record, file size
optchat-chief memory check [--mux-home DIR]               opens the memory as the host does (host stopped): how it loaded and how long it took
optchat-chief memory redescribe [--mux-home DIR] failed|ID...   the running host describes again the images these note lines
                                                          name (failed: every \"no description\" note), rewrites each note
                                                          and rebuilds the summaries above it (journaled, undoable)
optchat-chief memory place [--daemon-socket S]            whether the memory can move over a projected folder (projection-v1) here
optchat-chief memory hand-out --to MACHINE [--socket S --at REMOTE] DIR
                                                          the memory for another machine to project (host stopped; marks this home moved)
optchat-chief memory take-in                              copy a mounted hand-out to this machine's disk (the host does it at start)";

/// Runs `memory <verb>`; returns what to print.
pub fn run(flags: &Flags, home: &Path, json: bool) -> Result<String, String> {
    let paths = Paths::new(home);
    let words: Vec<&str> = flags.words.iter().skip(2).map(String::as_str).collect();
    match flags.words.get(1).map(String::as_str) {
        Some("export") => {
            let dir = flags
                .value("text")
                .map(PathBuf::from)
                .ok_or_else(|| format!("memory export needs --text DIR\n{USAGE}"))?;
            let stats = read_only(&paths)?
                .export_text(&dir)
                .map_err(|e| format!("exporting into {}: {e}", dir.display()))?;
            Ok(format!(
                "exported {} messages and {} nodes into {} ({} day files written)",
                stats.messages,
                stats.nodes,
                dir.display(),
                stats.files_written
            ))
        }
        Some("import-from") => crate::memory_sync::run(flags, home, json),
        Some("import") => {
            let [from] = words.as_slice() else {
                return Err(format!("memory import needs one directory\n{USAGE}"));
            };
            let chat = crate::browse::open_offline(&paths.chat, &paths.memory_db)?;
            let result = chat.import_jsonl(Path::new(from));
            chat.shutdown();
            let imported = result.map_err(|e| format!("importing {from}: {e}"))?;
            Ok(format!(
                "imported {} messages and {} nodes (hash {}, {} lines skipped)",
                imported.messages, imported.nodes, imported.hash, imported.skipped
            ))
        }
        Some("search") => {
            if words.is_empty() {
                return Err(format!("memory search needs a query\n{USAGE}"));
            }
            let limit = flags
                .value("limit")
                .map(|v| v.parse::<usize>().map_err(|e| format!("--limit {v}: {e}")))
                .transpose()?
                .unwrap_or(20);
            let db = read_only(&paths)?;
            let hits = db
                .search(&words.join(" "), limit)
                .map_err(|e| format!("searching: {e}"))?;
            if json {
                return search_json(&db, &hits);
            }
            Ok(hits
                .iter()
                .map(|h| match h {
                    Hit::Message { id, kind, snippet } => format!("{id} {kind}: {snippet}"),
                    Hit::Node { node, snippet } => format!("{} (summary): {snippet}", node.name()),
                })
                .collect::<Vec<_>>()
                .join("\n"))
        }
        Some("stats") => {
            let db = read_only(&paths)?;
            let counts = db.counts().map_err(|e| e.to_string())?;
            let migration = db
                .state(MIGRATION_KEY)
                .map_err(|e| e.to_string())?
                .unwrap_or_else(|| "none".to_owned());
            let bytes = std::fs::metadata(&paths.memory_db).map_or(0, |m| m.len());
            let backup = std::fs::read_to_string(paths.root.join("backup.json"))
                .unwrap_or_else(|_| "no attempt yet".to_owned());
            Ok(format!(
                "{}: {} messages, {} nodes, schema {SCHEMA_VERSION}, {bytes} bytes\nmigration: {migration}\nbackup: {backup}",
                paths.memory_db.display(),
                counts.messages,
                counts.nodes
            ))
        }
        Some("redescribe") => {
            let notes = match words.as_slice() {
                ["failed"] => failed_descriptions(&read_only(&paths)?)?,
                [] => {
                    return Err(format!(
                        "memory redescribe needs failed or note ids\n{USAGE}"
                    ));
                }
                ids => ids
                    .iter()
                    .map(|id| id.parse::<u64>().map_err(|e| format!("{id}: {e}")))
                    .collect::<Result<Vec<_>, _>>()?,
            };
            if notes.is_empty() {
                return Ok("no image note has a failed description".to_owned());
            }
            crate::tools::ask_redescribe(&paths.tools_socket, &notes)
        }
        Some("place") => {
            let capability = flags
                .value("daemon-socket")
                .map(str::to_owned)
                .or_else(|| crate::cli::env("CMUX_DAEMON_SOCKET"))
                .and_then(|s| crate::memory_place::daemon_capability(Path::new(&s)));
            Ok(crate::memory_place::status(&paths.root, capability))
        }
        Some("hand-out") => {
            let [out] = words.as_slice() else {
                return Err(format!("memory hand-out needs one directory\n{USAGE}"));
            };
            let to = flags.value("to").unwrap_or_default();
            let _lock = stopped_host(&paths)?;
            let writer = crate::memory_place::hand_out(home, to, Path::new(out))?;
            let name = crate::memory_place::projection_name(&writer.home_id, writer.epoch);
            let mut said = format!(
                "handed out epoch {} of the memory to {} in {out}; this home is marked moved\n\
                 project it at the target's optchat/{}: cmux link project serve --socket S --at REMOTE --name {name} {out}",
                writer.epoch,
                writer.to,
                crate::memory_place::FOLDER
            );
            if let (Some(socket), Some(at)) = (flags.value("socket"), flags.value("at")) {
                said.push_str(&format!("\n{}", serve(socket, at, &name, out)?));
            }
            Ok(said)
        }
        Some("take-in") => {
            let _lock = stopped_host(&paths)?;
            crate::memory_place::at_host_start(home, true)
        }
        Some("check") => {
            let started = std::time::Instant::now();
            let chat = crate::browse::open_offline(&paths.chat, &paths.memory_db)?;
            let ms = started.elapsed().as_secs_f64() * 1000.0;
            let status = chat.status();
            let loaded = chat.loaded();
            chat.shutdown();
            Ok(format!(
                "opened in {ms:.1} ms ({loaded:?}): {} messages, {} nodes, {} view lines ({} unbuilt)",
                status.messages, status.built, status.view_lines, status.unbuilt
            ))
        }
        _ => Err(USAGE.to_owned()),
    }
}

/// The hits as a JSON array: a message with its id, kind, date, snippet and
/// full text, a summary node with its name and snippet.
pub fn search_json(db: &ReadOnly, hits: &[Hit]) -> Result<String, String> {
    let mut out = Vec::with_capacity(hits.len());
    for hit in hits {
        out.push(match hit {
            Hit::Message { id, kind, snippet } => {
                let row = db
                    .message_row(*id)
                    .map_err(|e| format!("reading message {id}: {e}"))?;
                serde_json::json!({
                    "id": id,
                    "kind": kind,
                    "date": row.as_ref().map(|r| r.date.as_str()),
                    "snippet": snippet,
                    "text": row.as_ref().map(|r| r.text.as_str()),
                })
            }
            Hit::Node { node, snippet } => serde_json::json!({
                "node": node.name(),
                "kind": "summary",
                "snippet": snippet,
            }),
        });
    }
    Ok(serde_json::Value::Array(out).to_string())
}

/// The image note lines whose description failed (`... "<name>": no
/// description (<why>)`), oldest first.
pub fn failed_descriptions(db: &ReadOnly) -> Result<Vec<u64>, String> {
    let counts = db.counts().map_err(|e| e.to_string())?;
    let mut out = Vec::new();
    for id in 0..counts.messages {
        let Some(row) = db
            .message_row(id)
            .map_err(|e| format!("reading message {id}: {e}"))?
        else {
            continue;
        };
        if row.kind == "note" && crate::brain::redescribe::is_failed_description(&row.text) {
            out.push(id);
        }
    }
    Ok(out)
}

fn read_only(paths: &Paths) -> Result<ReadOnly, String> {
    ReadOnly::open(&paths.memory_db).map_err(|e| format!("{}: {e}", paths.memory_db.display()))
}

/// The host lock, so no host writes the memory while a place verb runs.
fn stopped_host(paths: &Paths) -> Result<crate::lock::HostLock, String> {
    let started = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64);
    crate::lock::HostLock::take(&paths.host_lock, started)
        .map_err(|e| format!("{e}: stop the Chief's host first"))
}

/// Starts `cmux link project serve` for a hand-out (the merged projection-v1 dial); it runs on
/// as the folder's server, in its own process group.
fn serve(socket: &str, at: &str, name: &str, out: &str) -> Result<String, String> {
    use std::io::BufRead as _;
    let cmux = crate::cli::env("CMUX_CLI").unwrap_or_else(|| "cmux".to_owned());
    let mut child = std::process::Command::new(&cmux)
        .args([
            "link", "project", "serve", "--socket", socket, "--at", at, "--name", name, out,
        ])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| format!("starting {cmux} link project serve: {e}"))?;
    let stdout = child
        .stdout
        .take()
        .ok_or("no pipe from the folder's server")?;
    let mut line = String::new();
    std::io::BufReader::new(stdout)
        .read_line(&mut line)
        .map_err(|e| format!("reading the folder's server: {e}"))?;
    let answer: serde_json::Value = serde_json::from_str(line.trim())
        .map_err(|_| format!("the folder's server answered {line:?}"))?;
    if answer.get("ok").and_then(serde_json::Value::as_bool) != Some(true) {
        let _ = child.wait();
        return Err(format!(
            "the target did not mount the memory: {}",
            line.trim()
        ));
    }
    Ok(format!("projected at {at} (server pid {})", child.id()))
}
