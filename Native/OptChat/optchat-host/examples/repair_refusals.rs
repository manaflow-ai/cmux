//! Rebuilds the memory lines a compactor wrote as a refusal ("I can't write
//! this memory line ...") and touches no other line.
//!
//! Two steps, so the model work never runs against a live memory:
//!
//! ```text
//! # 1. Plan, on a COPY (sqlite3 "file:LIVE?mode=ro" ".backup COPY"):
//! cargo run --release --example repair_refusals -- plan \
//!     --db COPY --system SYSTEM.md --out plan.jsonl [--jobs 16]
//! # 2. Apply the plan to the live memory, with its Chief host stopped
//! #    (the tool takes the chat lock, so it refuses while the host runs):
//! cargo run --release --example repair_refusals -- apply \
//!     --dir ~/.cmux/chief/default/optchat --plan plan.jsonl
//! ```
//!
//! `plan` finds every model-built line that is a refusal (`is_refusal`; a
//! short message kept verbatim is not one), lowest level first, and builds
//! each again from its children as the host does (`build_node`: the main
//! model, then the fallback model; when both refuse, the input stands in).
//! A level's new lines go into the copy before the next level, so a merge
//! reads its repaired children. `apply` writes a line only while its live
//! text is still the plan's old text, so a line changed since the plan is
//! skipped.

use std::collections::BTreeMap;
use std::io::Write as _;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use optchat_core::{compact_request, free_node_text, is_refusal};
use optchat_host::db::{checkpoint, Db};
use optchat_host::{
    build_node, CompactModel, CompactRequest, Config, Followup, ManualClock, ModelError, NodeId,
    OptChat, Reply,
};

/// Claude Code as the compactor's acpmux session runs it (see
/// `replay_compactions.rs`); a size retry resumes the same session.
struct ClaudeCli {
    model: String,
    system_file: PathBuf,
    cwd: PathBuf,
    sessions: Mutex<BTreeMap<NodeId, String>>,
    calls: AtomicUsize,
}

impl ClaudeCli {
    fn run(&self, args: &[&str], input: &str) -> Result<serde_json::Value, ModelError> {
        let mut child = Command::new("claude")
            .args(["-p", "--output-format", "json", "--model", &self.model])
            .args(["--effort", optchat_host::DEFAULT_EFFORT, "--tools", ""])
            .args(["--strict-mcp-config", "--setting-sources", "project"])
            .args(["--disable-slash-commands"])
            .args(args)
            .current_dir(&self.cwd)
            .env("CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK", "1")
            .env("CLAUDE_CODE_DISABLE_AUTO_MEMORY", "1")
            .env("CLAUDE_CODE_DISABLE_CLAUDE_MDS", "1")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| ModelError::new(format!("claude: {e}")))?;
        let mut stdin = child.stdin.take().expect("piped");
        stdin
            .write_all(input.as_bytes())
            .map_err(|e| ModelError::new(format!("claude stdin: {e}")))?;
        drop(stdin);
        let out = child
            .wait_with_output()
            .map_err(|e| ModelError::new(format!("claude: {e}")))?;
        let text = String::from_utf8_lossy(&out.stdout);
        let line = text
            .lines()
            .rev()
            .find(|l| l.starts_with('{'))
            .unwrap_or("");
        serde_json::from_str(line)
            .map_err(|_| ModelError::new(format!("claude printed no result: {}", text.trim())))
    }
}

impl CompactModel for ClaudeCli {
    fn call(&self, request: &CompactRequest, followups: &[Followup]) -> Result<Reply, ModelError> {
        let resume = self.sessions.lock().unwrap().get(&request.node).cloned();
        let value = match (followups.last(), resume) {
            (Some(f), Some(sid)) => self.run(&["--resume", &sid], &f.retry)?,
            _ => {
                let system = self.system_file.display().to_string();
                let prompt = format!("{}\n\n{}", request.context, request.step);
                self.run(&["--system-prompt-file", &system], &prompt)?
            }
        };
        self.calls.fetch_add(1, Ordering::SeqCst);
        if let Some(sid) = value["session_id"].as_str() {
            self.sessions
                .lock()
                .unwrap()
                .insert(request.node, sid.to_owned());
        }
        if value["stop_reason"] == "refusal" {
            return Err(ModelError::refusal("stop_reason refusal"));
        }
        if value["is_error"] == true {
            return Err(ModelError::new(
                value["result"].as_str().unwrap_or("error").to_owned(),
            ));
        }
        Ok(Reply::text(value["result"].as_str().unwrap_or("").trim()))
    }

    fn end(&self, request: &CompactRequest) {
        self.sessions.lock().unwrap().remove(&request.node);
    }
}

/// A model that never answers: `apply` opens the live chat only to write
/// lines, and its compactor must build nothing meanwhile.
struct Never;

impl CompactModel for Never {
    fn call(&self, _: &CompactRequest, _: &[Followup]) -> Result<Reply, ModelError> {
        Err(ModelError::new("repair_refusals builds no node"))
    }
}

/// Whether a line holds a refusal: a model line that is one, or a free
/// merge (two lines joined by a newline) that copied one from a child.
fn holds_refusal(text: &str) -> bool {
    text.lines().any(is_refusal)
}

/// Every line of `path`, lowest level first.
fn lines(path: &PathBuf) -> Vec<(NodeId, String)> {
    let conn =
        rusqlite::Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .expect("open read-only");
    let mut stmt = conn
        .prepare("SELECT level, idx, text FROM nodes ORDER BY level, idx")
        .unwrap();
    let rows = stmt
        .query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, String>(2)?,
            ))
        })
        .unwrap();
    rows.filter_map(Result::ok)
        .map(|(l, i, t)| (NodeId::new(l as u32, i as u64), t))
        .collect()
}

/// The lines to repair, lowest level first, each with whether it was free
/// (its text is its source verbatim): any line with a line in it that is a
/// refusal (a model may write a lead-in first). A model line that only
/// read a refused child is not one, and stays as it is.
fn targets(path: &PathBuf, store: &Db) -> Vec<(NodeId, String, bool)> {
    lines(path)
        .into_iter()
        .filter_map(|(n, t)| {
            let free = free_node_text(n, store).as_deref() == Some(t.as_str());
            holds_refusal(&t).then_some((n, t, free))
        })
        .collect()
}

fn flag(args: &[String], name: &str) -> Option<String> {
    args.iter()
        .position(|a| a == name)
        .and_then(|i| args.get(i + 1))
        .cloned()
}

fn plan(args: &[String]) {
    let db_path = PathBuf::from(flag(args, "--db").expect("--db COPY"));
    let system_file = PathBuf::from(flag(args, "--system").expect("--system FILE"));
    let out = PathBuf::from(flag(args, "--out").expect("--out plan.jsonl"));
    let jobs: usize = flag(args, "--jobs").map_or(16, |j| j.parse().unwrap());
    let system = std::fs::read_to_string(&system_file).expect("system file");
    let mut store = Db::open(&db_path).expect("open the copy");
    let (memory, _) = checkpoint::load(&mut store, None, optchat_core::VIEW).expect("load");
    let cwd = std::env::temp_dir().join("optchat-repair-cwd");
    std::fs::create_dir_all(&cwd).unwrap();
    let cli = |m: &str| ClaudeCli {
        model: m.to_owned(),
        system_file: system_file.clone(),
        cwd: cwd.clone(),
        sessions: Mutex::default(),
        calls: AtomicUsize::new(0),
    };
    let main_model = cli(&flag(args, "--model").unwrap_or(optchat_host::DEFAULT_MODEL.into()));
    let fallback =
        cli(&flag(args, "--fallback").unwrap_or(optchat_host::DEFAULT_FALLBACK_MODEL.into()));
    let count = |p: &PathBuf| lines(p).iter().filter(|(_, t)| holds_refusal(t)).count();
    println!("lines holding a refusal before: {}", count(&db_path));
    let before = targets(&db_path, &store);
    println!(
        "targets: {} ({} model lines, {} free merges)",
        before.len(),
        before.iter().filter(|t| !t.2).count(),
        before.iter().filter(|t| t.2).count()
    );
    let mut by_level: BTreeMap<u32, Vec<(NodeId, String, bool)>> = BTreeMap::new();
    for t in before {
        by_level.entry(t.0.l).or_default().push(t);
    }
    let mut plan_file = std::fs::File::create(&out).expect("--out");
    let mut outcomes: BTreeMap<&'static str, usize> = BTreeMap::new();
    for (level, nodes) in by_level {
        // A merge of two lines that fit together is their join, no model.
        let mut work = Vec::new();
        let mut done: Vec<(NodeId, String, String, &'static str)> = Vec::new();
        for (n, old, was_free) in nodes {
            // A free line is its children joined again, now repaired; one
            // that no longer fits, or a model line, goes to the model.
            match free_node_text(n, &store).filter(|_| was_free) {
                Some(text) => done.push((n, old, text, "free")),
                None => {
                    let request =
                        compact_request(&memory, &store, n, system.clone()).expect("request");
                    work.push((n, old, request));
                }
            }
        }
        let queue = Mutex::new(work.into_iter());
        let results = Mutex::new(Vec::new());
        std::thread::scope(|s| {
            for _ in 0..jobs {
                s.spawn(|| loop {
                    let Some((n, old, request)) = queue.lock().unwrap().next() else {
                        return;
                    };
                    let built = build_node(&main_model, Some(&fallback), &request);
                    let item = match built {
                        Ok(b) if is_refusal(&b.text) => (n, old, b.text, "still_refusal"),
                        Ok(b) if b.stand_in => (n, old, b.text, "stand_in"),
                        Ok(b) if b.by_fallback => (n, old, b.text, "fallback_line"),
                        Ok(b) => (n, old, b.text, "line"),
                        Err(e) => {
                            eprintln!("{} failed: {e}", n.name());
                            (n, old.clone(), old, "failed")
                        }
                    };
                    eprintln!("{} {} {}B", n.name(), item.3, item.2.len());
                    results.lock().unwrap().push(item);
                });
            }
        });
        done.extend(results.into_inner().unwrap());
        done.sort_by_key(|d| d.0);
        for (n, old, new, outcome) in done {
            *outcomes.entry(outcome).or_default() += 1;
            if outcome == "failed" || outcome == "still_refusal" || new == old {
                continue;
            }
            store.rewrite_node(n, &new).expect("write the copy");
            let line = serde_json::json!({"node": n.name(), "level": n.l, "outcome": outcome, "old": old, "new": new});
            writeln!(plan_file, "{line}").unwrap();
        }
        println!("level {level} done: {outcomes:?}");
    }
    println!("lines holding a refusal after (copy): {}", count(&db_path));
    println!("outcomes: {outcomes:?}");
    println!(
        "calls: main {}, fallback {}",
        main_model.calls.load(Ordering::SeqCst),
        fallback.calls.load(Ordering::SeqCst)
    );
}

/// Writes one line as the host's store does (`Db::rewrite_node`: the text,
/// its size and the search index, in one transaction).
enum Writer {
    /// The host is stopped: through the chat, which also updates its sizes.
    Chat(OptChat),
    /// The host runs: through the store alone. SQLite's WAL and the host's
    /// 10 s busy wait let the host go on; it reads the new texts at once and
    /// its in-memory line sizes again at its next start.
    Store(Db),
}

impl Writer {
    fn node(&self, node: NodeId) -> Option<String> {
        match self {
            Writer::Chat(chat) => chat.node(node),
            Writer::Store(db) => optchat_core::Store::node(db, node),
        }
    }

    fn write(&mut self, node: NodeId, text: &str) {
        match self {
            Writer::Chat(chat) => {
                chat.rewrite_node(node, text).expect("rewrite");
            }
            Writer::Store(db) => {
                db.rewrite_node(node, text).expect("rewrite");
            }
        }
    }
}

fn apply(args: &[String]) {
    let dir = PathBuf::from(flag(args, "--dir").expect("--dir OPTCHAT_DIR"));
    let plan = std::fs::read_to_string(flag(args, "--plan").expect("--plan FILE")).expect("plan");
    let db = dir.join("memory.sqlite3");
    let config = Config {
        db: Some(db.clone()),
        ..Config::default()
    };
    let mut writer =
        match OptChat::open_with(&dir, config, Arc::new(Never), Arc::new(ManualClock::new())) {
            Ok(chat) => Writer::Chat(chat),
            Err(optchat_host::Error::Locked) => {
                println!("the Chief host runs: writing through the store");
                Writer::Store(Db::open(&db).expect("open the live store"))
            }
            Err(e) => panic!("cannot open {}: {e:?}", dir.display()),
        };
    let (mut written, mut skipped) = (0, 0);
    for line in plan.lines() {
        let entry: serde_json::Value = serde_json::from_str(line).expect("plan line");
        let name = entry["node"].as_str().unwrap();
        let (start, n) = name.split_once('+').unwrap();
        let (start, n): (u64, u64) = (start.parse().unwrap(), n.parse().unwrap());
        let node = NodeId::new(n.trailing_zeros(), start >> n.trailing_zeros());
        let (old, new) = (
            entry["old"].as_str().unwrap(),
            entry["new"].as_str().unwrap(),
        );
        // Only a line still holding the plan's refusal text is written.
        if writer.node(node).as_deref() != Some(old) || !holds_refusal(old) {
            skipped += 1;
            continue;
        }
        writer.write(node, new);
        written += 1;
    }
    if let Writer::Chat(chat) = writer {
        chat.shutdown();
    }
    println!("written {written}, skipped {skipped} (changed since the plan)");
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("plan") => plan(&args),
        Some("apply") => apply(&args),
        _ => eprintln!("usage: repair_refusals plan --db COPY --system FILE --out PLAN | apply --dir DIR --plan PLAN"),
    }
}
