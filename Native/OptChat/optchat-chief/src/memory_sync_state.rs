//! What the import UI needs around `memory import-from`: finding what a Mac
//! already holds (`detect`), a log of each write, and taking the last write back
//! (`undo`). The log holds keys and counts only, never text.

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use crate::paths::Paths;

/// One memory source found on this Mac.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
pub struct Detected {
    /// The `import-from` source name: `claude-code`, `claude-memory`, `codex`, `zip:/path`.
    pub source: String,
    /// `claude-code`, `claude-memory`, `codex`, `chatgpt-export`, `claude-ai-export`, `export`.
    pub kind: String,
    /// Conversations (claude-code), notes (memory kinds) or 1 (a zip).
    pub count: usize,
    pub bytes: u64,
    /// The folder or file it was found in.
    pub path: String,
}

/// Finds what this Mac holds, fast (no transcript is converted): Claude Code
/// transcripts and memory notes, Codex memory notes, and export zips of
/// claude.ai or ChatGPT in `~/Downloads` and `~/Desktop`.
pub fn detect(user_home: &Path, claude_config_dir: Option<String>) -> Vec<Detected> {
    let mut found = Vec::new();
    let projects = crate::claude_import::default_projects_dir(user_home, claude_config_dir);
    let (sessions, bytes) = count_transcripts(&projects);
    if sessions > 0 {
        found.push(Detected {
            source: "claude-code".into(),
            kind: "claude-code".into(),
            count: sessions,
            bytes,
            path: projects.display().to_string(),
        });
    }
    for (codex, kind, dir) in [
        (false, "claude-memory", projects.clone()),
        (true, "codex", user_home.join(".codex").join("memories")),
    ] {
        let notes = crate::memory_sync::items_from_memory_files(user_home, codex);
        if !notes.is_empty() {
            found.push(Detected {
                source: kind.into(),
                kind: kind.into(),
                count: notes.len(),
                bytes: notes.iter().map(|n| n.text.len() as u64).sum(),
                path: dir.display().to_string(),
            });
        }
    }
    found.extend(detect_zips(user_home));
    found
}

/// `*.jsonl` sessions under `projects/<project>/` (one level, as Claude Code writes them).
fn count_transcripts(projects: &Path) -> (usize, u64) {
    let (mut n, mut bytes) = (0, 0);
    let Ok(dirs) = std::fs::read_dir(projects) else {
        return (0, 0);
    };
    for dir in dirs.flatten() {
        let Ok(files) = std::fs::read_dir(dir.path()) else {
            continue;
        };
        for f in files.flatten() {
            let path = f.path();
            if path.extension().is_some_and(|e| e == "jsonl")
                && let Ok(meta) = f.metadata()
                && meta.len() > 0
            {
                n += 1;
                bytes += meta.len();
            }
        }
    }
    (n, bytes)
}

const ZIP_FOLDERS: [&str; 2] = ["Downloads", "Desktop"];
/// An export older than this is probably not what the person means to bring now.
const ZIP_MAX_AGE_DAYS: u64 = 400;
const ZIP_LIMIT: usize = 8;

fn detect_zips(user_home: &Path) -> Vec<Detected> {
    let mut out = Vec::new();
    let now = std::time::SystemTime::now();
    for folder in ZIP_FOLDERS {
        let Ok(entries) = std::fs::read_dir(user_home.join(folder)) else {
            continue;
        };
        let mut zips: Vec<(std::time::SystemTime, PathBuf, u64)> = entries
            .flatten()
            .filter_map(|e| {
                let path = e.path();
                let meta = e.metadata().ok()?;
                (path
                    .extension()
                    .is_some_and(|x| x.eq_ignore_ascii_case("zip"))
                    && meta.is_file())
                .then(|| (meta.modified().unwrap_or(now), path, meta.len()))
            })
            .filter(|(m, _, _)| {
                now.duration_since(*m)
                    .map_or(true, |a| a.as_secs() < ZIP_MAX_AGE_DAYS * 86_400)
            })
            .collect();
        zips.sort_by_key(|z| std::cmp::Reverse(z.0));
        for (_, path, size) in zips.into_iter().take(ZIP_LIMIT) {
            if let Some(kind) = export_kind(&path) {
                out.push(Detected {
                    source: format!("zip:{}", path.display()),
                    kind: kind.into(),
                    count: 1,
                    bytes: size,
                    path: path.display().to_string(),
                });
            }
        }
    }
    out
}

/// What kind of chat export a zip is (read from its table of contents only), or
/// None when it holds no `conversations.json`.
fn export_kind(zip: &Path) -> Option<&'static str> {
    let out = std::process::Command::new("unzip")
        .arg("-Z1")
        .arg(zip)
        .stdin(std::process::Stdio::null())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let names = String::from_utf8_lossy(&out.stdout);
    let has = |n: &str| names.lines().any(|l| l == n);
    if !has("conversations.json") {
        return None;
    }
    Some(if has("chat.html") || has("message_feedback.json") {
        "chatgpt-export"
    } else if has("projects.json") || has("users.json") {
        "claude-ai-export"
    } else {
        "export"
    })
}

/// One write, as the log keeps it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Run {
    pub batch: String,
    /// `local` or `cloud`.
    pub to: String,
    pub source: String,
    pub written: usize,
    /// Local: messages before the write and the backup file. Cloud: the Chief.
    pub messages_before: u64,
    pub backup: Option<PathBuf>,
    pub chief: Option<String>,
    pub keys: Vec<String>,
}

pub fn log_file(paths: &Paths) -> PathBuf {
    paths.root.join("import-log.jsonl")
}

fn run_json(r: &Run) -> Value {
    json!({"batch": r.batch, "to": r.to, "source": r.source, "written": r.written,
        "messages_before": r.messages_before, "backup": r.backup, "chief": r.chief, "keys": r.keys,
        "at": chrono::Utc::now().to_rfc3339()})
}

fn run_of(v: &Value) -> Option<Run> {
    Some(Run {
        batch: v["batch"].as_str()?.to_owned(),
        to: v["to"].as_str()?.to_owned(),
        source: v["source"].as_str().unwrap_or("").to_owned(),
        written: v["written"].as_u64()? as usize,
        messages_before: v["messages_before"].as_u64().unwrap_or(0),
        backup: v["backup"].as_str().map(PathBuf::from),
        chief: v["chief"].as_str().map(str::to_owned),
        keys: v["keys"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|k| k.as_str().map(str::to_owned))
                    .collect()
            })
            .unwrap_or_default(),
    })
}

pub fn record(paths: &Paths, run: &Run) -> Result<(), String> {
    use std::io::Write;
    let file = log_file(paths);
    if let Some(dir) = file.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&file)
        .map_err(|e| format!("{}: {e}", file.display()))?;
    writeln!(f, "{}", run_json(run)).map_err(|e| e.to_string())
}

/// The runs that were not undone, oldest first.
pub fn runs(paths: &Paths) -> Vec<Run> {
    std::fs::read_to_string(log_file(paths))
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .filter(|v| v["undone"] != true)
        .filter_map(|v| run_of(&v))
        .collect()
}

/// Takes `batch` out of the log (a rewrite without its line).
pub fn forget(paths: &Paths, batch: &str) -> Result<(), String> {
    let file = log_file(paths);
    let text = std::fs::read_to_string(&file).unwrap_or_default();
    let kept: Vec<&str> = text
        .lines()
        .filter(|l| serde_json::from_str::<Value>(l).map_or(true, |v| v["batch"] != batch))
        .collect();
    let mut out = kept.join("\n");
    if !out.is_empty() {
        out.push('\n');
    }
    std::fs::write(&file, out).map_err(|e| e.to_string())
}

/// Restores a local write: the memory returns to its backup when nothing came
/// after the write (host stopped); the write's keys leave `import-keys.txt`.
/// Returns what it did.
pub fn undo_local(paths: &Paths, batch: Option<&str>) -> Result<(usize, String), String> {
    let all = runs(paths);
    let run = match batch {
        Some(b) => all.iter().rev().find(|r| r.batch == b),
        None => all.iter().rev().find(|r| r.to == "local"),
    }
    .ok_or("nothing to undo: no earlier import into this memory")?
    .clone();
    if run.to != "local" {
        return Err(format!(
            "batch {} went to the cloud: undo it with --to cloud",
            run.batch
        ));
    }
    let now = crate::claude_import::existing_messages(&paths.chat, &paths.memory_db)?;
    if now != run.messages_before + run.written as u64 {
        return Err(format!(
            "the memory holds {now} messages, not {}: messages came after this import, so it cannot be taken back",
            run.messages_before + run.written as u64
        ));
    }
    // Keep what is there now, then put the earlier memory back.
    let stamp = chrono::Utc::now().format("%Y%m%dT%H%M%SZ");
    if paths.memory_db.exists() {
        let keep = paths
            .memory_db
            .with_extension(format!("sqlite3.undo-backup-{stamp}"));
        std::fs::copy(&paths.memory_db, &keep)
            .map_err(|e| format!("backup {}: {e}", keep.display()))?;
    }
    match &run.backup {
        Some(b) => {
            if !b.exists() {
                return Err(format!("the backup {} is gone", b.display()));
            }
            std::fs::copy(b, &paths.memory_db)
                .map_err(|e| format!("restoring {}: {e}", b.display()))?;
        }
        None => {
            // The memory was empty before: it is empty again.
            for ext in ["", "-wal", "-shm"] {
                let mut name = paths.memory_db.clone().into_os_string();
                name.push(ext);
                let _ = std::fs::remove_file(PathBuf::from(name));
            }
        }
    }
    let keys_path = paths.root.join("import-keys.txt");
    if let Ok(text) = std::fs::read_to_string(&keys_path) {
        let drop: std::collections::HashSet<&str> = run.keys.iter().map(String::as_str).collect();
        let kept: Vec<&str> = text.lines().filter(|l| !drop.contains(l)).collect();
        let mut out = kept.join("\n");
        if !out.is_empty() {
            out.push('\n');
        }
        std::fs::write(&keys_path, out).map_err(|e| e.to_string())?;
    }
    forget(paths, &run.batch)?;
    Ok((
        run.written,
        format!(
            "took back {} imported items from {} (the memory is as before; a copy of the memory with them stays as {}.undo-backup-{stamp})",
            run.written,
            run.source,
            paths
                .memory_db
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("memory.sqlite3")
        ),
    ))
}

/// Runs `f` with the Chief host of `paths` stopped (the memory's writer lock is
/// the host's). A running host is refused unless `stop_host`; then it is asked
/// to stop (SIGTERM, as `move --stop-host`), the app is told not to start it
/// again while `f` runs (`state/shutdown`), and the marker goes away after `f`.
/// The app starts the host again on the person's next message.
pub fn with_host_stopped<T>(
    paths: &Paths,
    stop_host: bool,
    f: impl FnOnce() -> Result<T, String>,
) -> Result<T, String> {
    if !crate::lock::held(&paths.host_lock) {
        return f();
    }
    if !stop_host {
        return Err(
            "the Chief host is running: stop it (cmux chief stop) or pass --stop-host".into(),
        );
    }
    let marker = paths.home.join(crate::migrate::SHUTDOWN_FILE);
    if let Some(dir) = marker.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    std::fs::write(&marker, b"memory import\n").map_err(|e| e.to_string())?;
    let result = (|| {
        let pid = std::fs::read_to_string(&paths.host_lock)
            .ok()
            .and_then(|t| t.lines().next().and_then(|l| l.trim().parse::<i32>().ok()))
            .ok_or("the host lock names no pid")?;
        // SAFETY: plain kill(2) with a pid read from our own lock file.
        unsafe {
            libc::kill(pid, libc::SIGTERM);
        }
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        while crate::lock::held(&paths.host_lock) {
            if std::time::Instant::now() > deadline {
                return Err(format!(
                    "the host (pid {pid}) did not stop within 30 seconds"
                ));
            }
            std::thread::sleep(std::time::Duration::from_millis(200));
        }
        f()
    })();
    let _ = std::fs::remove_file(&marker);
    result
}

pub fn detect_json(found: &[Detected]) -> Value {
    json!({"sources": found})
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::browse::Imported;
    use crate::memory_sync::*;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("a665-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn write(path: &Path, text: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }

    fn zip_of(stage: &Path, out: &Path, files: &[&str]) {
        std::fs::create_dir_all(out.parent().unwrap()).unwrap();
        let ok = std::process::Command::new("zip")
            .current_dir(stage)
            .arg("-q")
            .arg(out)
            .args(files)
            .status()
            .unwrap();
        assert!(ok.success());
    }

    #[test]
    fn detect_finds_claude_code_notes_codex_and_export_zips() {
        let home = temp("detect");
        write(
            &home.join(".claude/projects/-Users-me-app/s1.jsonl"),
            "{\"type\":\"user\"}\n",
        );
        write(
            &home.join(".claude/projects/-Users-me-app/s2.jsonl"),
            "{\"type\":\"user\"}\n",
        );
        write(
            &home.join(".claude/projects/-Users-me-app/memory/prefs.md"),
            "I like Rust",
        );
        write(&home.join(".codex/memories/MEMORY.md"), "codex note");
        let stage = temp("stage");
        write(&stage.join("conversations.json"), "[]");
        write(&stage.join("chat.html"), "<html>");
        write(&stage.join("a.txt"), "x");
        // A ChatGPT export: conversations.json next to chat.html.
        zip_of(
            &stage,
            &home.join("Downloads/data-2026.zip"),
            &["conversations.json", "chat.html"],
        );
        // A zip with no conversations.json is not an export.
        zip_of(&stage, &home.join("Downloads/photos.zip"), &["a.txt"]);
        let found = detect(&home, None);
        let kinds: Vec<&str> = found.iter().map(|d| d.kind.as_str()).collect();
        assert!(kinds.contains(&"claude-code"), "{kinds:?}");
        assert!(kinds.contains(&"claude-memory"), "{kinds:?}");
        assert!(kinds.contains(&"codex"), "{kinds:?}");
        assert!(kinds.contains(&"chatgpt-export"), "{kinds:?}");
        assert_eq!(found.len(), 4, "photos.zip is not an export: {found:?}");
        let code = found.iter().find(|d| d.kind == "claude-code").unwrap();
        assert_eq!(code.count, 2);
        assert!(
            found
                .iter()
                .any(|d| d.source.starts_with("zip:") && d.source.ends_with("data-2026.zip"))
        );
    }

    #[test]
    fn detect_on_an_empty_mac_finds_nothing() {
        assert!(detect(&temp("none"), None).is_empty());
    }

    #[test]
    fn undo_local_restores_the_backup_and_forgets_the_keys() {
        let dir = temp("undo");
        let paths = Paths::new(&dir);
        crate::browse::import(
            &paths.chat,
            &paths.memory_db,
            &[Imported {
                kind: optchat_core::Kind::Note,
                text: "mine".into(),
                date: Some("2026-10-01T00:00:00Z".into()),
            }],
        )
        .unwrap();
        let before =
            crate::claude_import::existing_messages(&paths.chat, &paths.memory_db).unwrap();
        let list = vec![item(
            "note",
            "from claude",
            "2026-10-02T00:00:00.000Z",
            "claude-code",
        )];
        let (plan, fresh) = make_plan("claude-code", list, &local_known(&paths).unwrap());
        assert_eq!(plan.new, 1);
        let (n, backup) = write_local(&paths, &fresh).unwrap();
        record(
            &paths,
            &Run {
                batch: "b1".into(),
                to: "local".into(),
                source: "claude-code".into(),
                written: n,
                messages_before: before,
                backup,
                chief: None,
                keys: fresh.iter().map(|i| i.key.clone()).collect(),
            },
        )
        .unwrap();
        assert_eq!(runs(&paths).len(), 1);
        let (removed, msg) = undo_local(&paths, None).unwrap();
        assert_eq!(removed, 1);
        assert!(msg.contains('1'), "{msg}");
        let after = crate::claude_import::existing_messages(&paths.chat, &paths.memory_db).unwrap();
        assert_eq!(after, before, "the memory is what it was");
        assert!(runs(&paths).is_empty());
        // The same item is new again: its key left import-keys.txt and the memory.
        let again = make_plan(
            "claude-code",
            vec![item(
                "note",
                "from claude",
                "2026-10-02T00:00:00.000Z",
                "claude-code",
            )],
            &local_known(&paths).unwrap(),
        );
        assert_eq!(again.0.new, 1);
    }

    #[test]
    fn undo_local_refuses_when_messages_came_after_the_write() {
        let dir = temp("undo-late");
        let paths = Paths::new(&dir);
        let list = vec![item("note", "x", "2026-10-02T00:00:00.000Z", "codex")];
        let (_, fresh) = make_plan("codex", list, &Default::default());
        let (n, backup) = write_local(&paths, &fresh).unwrap();
        record(
            &paths,
            &Run {
                batch: "b1".into(),
                to: "local".into(),
                source: "codex".into(),
                written: n,
                messages_before: 0,
                backup,
                chief: None,
                keys: vec![fresh[0].key.clone()],
            },
        )
        .unwrap();
        crate::browse::import(
            &paths.chat,
            &paths.memory_db,
            &[Imported {
                kind: optchat_core::Kind::Note,
                text: "later".into(),
                date: None,
            }],
        )
        .unwrap();
        let err = undo_local(&paths, None).unwrap_err();
        assert!(err.contains("after"), "{err}");
        assert_eq!(
            crate::claude_import::existing_messages(&paths.chat, &paths.memory_db).unwrap(),
            2
        );
    }

    #[test]
    fn the_log_holds_keys_and_counts_never_text() {
        let dir = temp("log");
        let paths = Paths::new(&dir);
        record(
            &paths,
            &Run {
                batch: "b".into(),
                to: "cloud".into(),
                source: "codex".into(),
                written: 3,
                messages_before: 0,
                backup: None,
                chief: Some("agent_1".into()),
                keys: vec!["k1".into()],
            },
        )
        .unwrap();
        let raw = std::fs::read_to_string(log_file(&paths)).unwrap();
        assert!(raw.contains("k1") && raw.contains("agent_1"));
        assert_eq!(runs(&paths)[0].chief.as_deref(), Some("agent_1"));
    }

    #[test]
    fn a_running_host_is_refused_without_stop_host() {
        let dir = temp("host");
        let paths = Paths::new(&dir);
        std::fs::create_dir_all(paths.host_lock.parent().unwrap()).unwrap();
        let _lock = crate::lock::HostLock::take(&paths.host_lock, 1).unwrap();
        let err = with_host_stopped(&paths, false, || Ok(())).unwrap_err();
        assert!(err.contains("--stop-host"), "{err}");
        // With no host the closure just runs.
        drop(_lock);
        assert_eq!(with_host_stopped(&paths, false, || Ok(7)).unwrap(), 7);
        assert!(!paths.home.join("state/shutdown").exists());
    }
}
