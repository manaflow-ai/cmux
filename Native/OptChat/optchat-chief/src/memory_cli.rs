//! `optchat-chief memory ...`: the memory database from the command line.
//! Export, search and stats open a read-only connection, so they work while
//! the host runs; import needs the host stopped (it takes the chat's lock).

use std::path::{Path, PathBuf};

use optchat_host::db::{Hit, MIGRATION_KEY, ReadOnly, SCHEMA_VERSION};

use crate::cli::Flags;
use crate::paths::Paths;

pub const USAGE: &str = "optchat-chief memory export --text DIR [--mux-home DIR]   the memory as JSONL day files (main/, tree/; the old store's format)
optchat-chief memory import [--mux-home DIR] DIR          an old JSONL home or an export into an empty memory (host stopped)
optchat-chief memory search [--mux-home DIR] [--limit N] [--json] QUERY  full-text search: messages and summaries holding every word
                                                          (--json: an array of hits, messages with id, kind, date, snippet and full text)
optchat-chief memory stats [--mux-home DIR]               counts, schema version, migration record, file size
optchat-chief memory check [--mux-home DIR]               opens the memory as the host does (host stopped): how it loaded and how long it took
optchat-chief memory fork --mux-home SRC --to-home DST --chief ID --name NAME --by BY [--key CONV#SEQ] [--at RFC3339] [--json]
                                                          a new Chief's memory at DST: SRC's log up to that message (else now),
                                                          the summaries wholly before it and the attachments it names (works while SRC's host runs)";

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
        Some("fork") => fork(flags, &paths, json),
        _ => Err(USAGE.to_owned()),
    }
}

/// `memory fork`: a new Chief home's memory from this one's, cut at a
/// message (optchat_host::db::fork). The daemon runs it before the new
/// Chief's brain first starts (`chief.profile.create` with `fork`).
fn fork(flags: &Flags, source: &Paths, json: bool) -> Result<String, String> {
    use optchat_host::db::fork::{ForkPoint, Provenance, fork_memory};
    let need = |key: &str| {
        flags
            .value(key)
            .filter(|v| !v.trim().is_empty())
            .map(str::to_owned)
            .ok_or_else(|| format!("memory fork needs --{key}\n{USAGE}"))
    };
    let target = Paths::new(Path::new(&need("to-home")?));
    if target.home == source.home {
        return Err("memory fork: --to-home is the source home".to_owned());
    }
    let point = ForkPoint {
        key: flags.value("key").map(str::to_owned),
        at: flags.value("at").map(str::to_owned),
    };
    let provenance = Provenance {
        chief: need("chief")?,
        name: need("name")?,
        message: point.key.clone(),
        by: need("by")?,
    };
    let from_root = format!("{}/", source.root.join("attachments").display());
    let to_root = format!("{}/", target.root.join("attachments").display());
    let stats = fork_memory(
        &source.memory_db,
        &target.memory_db,
        &point,
        &provenance,
        Some((&from_root, &to_root)),
    )
    .map_err(|e| format!("memory fork: {e}"))?;
    let copied = copy_attachments(
        &source.root.join("attachments"),
        &target.root.join("attachments"),
        &stats.attachments,
    )?;
    if json {
        return Ok(serde_json::json!({
            "cut": stats.cut,
            "source_messages": stats.source_messages,
            "nodes": stats.nodes,
            "nodes_left_out": stats.nodes_left_out,
            "attachments": copied,
            "note": stats.note,
            "memory": target.memory_db.display().to_string(),
        })
        .to_string());
    }
    Ok(format!(
        "forked {} of {} messages and {} summaries ({} left out, rebuilt by the new Chief), {copied} attachment folders, into {}",
        stats.cut,
        stats.source_messages,
        stats.nodes,
        stats.nodes_left_out,
        target.memory_db.display()
    ))
}

/// Copies the attachment folders `hashes` from `from` into `to` (each a
/// content hash, so a folder present already is the same files). Files are
/// copied, not linked: the new Chief shares nothing with the source.
fn copy_attachments(from: &Path, to: &Path, hashes: &[String]) -> Result<usize, String> {
    let mut copied = 0;
    for hash in hashes {
        let (src, dst) = (from.join(hash), to.join(hash));
        let Ok(entries) = std::fs::read_dir(&src) else {
            continue;
        };
        std::fs::create_dir_all(&dst).map_err(|e| format!("{}: {e}", dst.display()))?;
        for entry in entries.flatten() {
            let file = entry.path();
            // Regular files only: a link would point back into the source.
            let regular = std::fs::symlink_metadata(&file).is_ok_and(|m| m.file_type().is_file());
            if !regular {
                continue;
            }
            let target = dst.join(entry.file_name());
            if !target.exists() {
                std::fs::copy(&file, &target).map_err(|e| format!("{}: {e}", file.display()))?;
            }
        }
        copied += 1;
    }
    Ok(copied)
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

fn read_only(paths: &Paths) -> Result<ReadOnly, String> {
    ReadOnly::open(&paths.memory_db).map_err(|e| format!("{}: {e}", paths.memory_db.display()))
}
