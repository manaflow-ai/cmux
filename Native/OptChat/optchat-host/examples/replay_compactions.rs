//! Replays compactions of a COPY of a Chief memory through Claude Code and
//! measures how often the compactor refuses (writes "I can't write this
//! line ..." instead of the line) and what the host finally keeps.
//!
//! ```text
//! cargo run --release --example replay_compactions -- \
//!     --db /tmp/scratch/memory.sqlite3 --system /tmp/scratch/system.md \
//!     --nodes 6638+1,6656+16 [--jobs 8] [--model claude-haiku-5-5] \
//!     [--fallback claude-sonnet-5] [--out results.jsonl]
//! ```
//!
//! Never point `--db` at a live Chief home: loading folds a checkpoint into
//! the file. Copy it first (`sqlite3 LIVE ".backup COPY"`).
//!
//! Each node's request is the one the host would send now
//! (`compact_request` over the copy's view), and its build is the host's own
//! (`optchat_host::build_node`, the main model with the size loop, then the
//! fallback model). A JSON line per node says what was kept: a model line,
//! a refusal, or the stand-in for a node no model would write.

use std::collections::HashMap;
use std::io::Write as _;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use optchat_core::{compact_request, is_refusal};
use optchat_host::db::{checkpoint, Db};
use optchat_host::{CompactModel, CompactRequest, Followup, ModelError, NodeId, Reply};

/// One Claude Code model, as the compactor's acpmux session runs it: no
/// tools, no MCP, no user settings, the system prompt replaced, Claude
/// Code's own refusal fallback off. A size retry resumes the same session.
struct ClaudeCli {
    model: String,
    effort: String,
    system_file: PathBuf,
    cwd: PathBuf,
    sessions: Mutex<HashMap<NodeId, String>>,
    calls: AtomicUsize,
    refusals: AtomicUsize,
}

impl ClaudeCli {
    fn run(&self, args: &[&str], input: &str) -> Result<serde_json::Value, ModelError> {
        let mut child = Command::new("claude")
            .args(["-p", "--output-format", "json", "--model", &self.model])
            .args([
                "--effort",
                &self.effort,
                "--tools",
                "",
                "--strict-mcp-config",
            ])
            .args(["--setting-sources", "project", "--disable-slash-commands"])
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
        child
            .stdin
            .take()
            .expect("piped")
            .write_all(input.as_bytes())
            .map_err(|e| ModelError::new(format!("claude stdin: {e}")))?;
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
        let system = self.system_file.display().to_string();
        let resume = self.sessions.lock().unwrap().get(&request.node).cloned();
        let value = match (followups.last(), resume) {
            (Some(f), Some(sid)) => self.run(&["--resume", &sid], &f.retry)?,
            _ => {
                let prompt = format!("{}\n\n{}", request.context, request.step);
                self.run(&["--system-prompt-file", &system], &prompt)?
            }
        };
        if let Some(sid) = value["session_id"].as_str() {
            self.sessions
                .lock()
                .unwrap()
                .insert(request.node, sid.to_owned());
        }
        self.calls.fetch_add(1, Ordering::SeqCst);
        if value["stop_reason"] == "refusal" {
            self.refusals.fetch_add(1, Ordering::SeqCst);
            return Err(ModelError::refusal("stop_reason refusal"));
        }
        if value["is_error"] == true {
            return Err(ModelError::new(
                value["result"].as_str().unwrap_or("error").to_owned(),
            ));
        }
        let text = value["result"].as_str().unwrap_or("").trim().to_owned();
        if is_refusal(&text) {
            self.refusals.fetch_add(1, Ordering::SeqCst);
        }
        Ok(Reply::text(text))
    }

    fn end(&self, request: &CompactRequest) {
        self.sessions.lock().unwrap().remove(&request.node);
    }
}

fn parse_node(name: &str) -> NodeId {
    let (start, n) = name.split_once('+').expect("id+n");
    let (start, n): (u64, u64) = (start.parse().unwrap(), n.parse().unwrap());
    let level = n.trailing_zeros();
    NodeId::new(level, start >> level)
}

fn main() {
    let mut args = std::env::args().skip(1);
    let (mut db, mut system, mut nodes, mut out) = (None, None, Vec::new(), None);
    let (mut model, mut fallback, mut jobs) = (
        "claude-haiku-5-5".to_owned(),
        Some("claude-sonnet-5".to_owned()),
        8usize,
    );
    while let Some(flag) = args.next() {
        let mut value = || {
            args.next()
                .unwrap_or_else(|| panic!("{flag} needs a value"))
        };
        match flag.as_str() {
            "--db" => db = Some(PathBuf::from(value())),
            "--system" => system = Some(PathBuf::from(value())),
            "--nodes" => nodes = value().split(',').map(parse_node).collect(),
            "--model" => model = value(),
            "--fallback" => fallback = Some(value()).filter(|m| m != "none"),
            "--jobs" => jobs = value().parse().unwrap(),
            "--out" => out = Some(PathBuf::from(value())),
            other => panic!("unknown flag {other}"),
        }
    }
    let db_path = db.expect("--db COPY");
    let system_file = system.expect("--system FILE");
    let system_text = std::fs::read_to_string(&system_file).expect("system file");
    let mut store = Db::open(&db_path).expect("open the copy");
    let (memory, _) = checkpoint::load(&mut store, None, optchat_core::VIEW).expect("load");
    let cwd = std::env::temp_dir().join("optchat-replay-cwd");
    std::fs::create_dir_all(&cwd).unwrap();
    let cli = |m: &str| {
        Arc::new(ClaudeCli {
            model: m.to_owned(),
            effort: optchat_host::DEFAULT_EFFORT.to_owned(),
            system_file: system_file.clone(),
            cwd: cwd.clone(),
            sessions: Mutex::default(),
            calls: AtomicUsize::new(0),
            refusals: AtomicUsize::new(0),
        })
    };
    let main_model = cli(&model);
    let fallback_model = fallback.as_deref().map(cli);
    let requests: Vec<(CompactRequest, String)> = nodes
        .iter()
        .map(|n| {
            let old = optchat_core::Store::node(&store, *n).unwrap_or_default();
            (
                compact_request(&memory, &store, *n, system_text.clone()).expect("request"),
                old,
            )
        })
        .collect();
    let queue = Mutex::new(requests.into_iter());
    let lines = Mutex::new(Vec::new());
    std::thread::scope(|s| {
        for _ in 0..jobs {
            s.spawn(|| loop {
                let Some((request, old)) = queue.lock().unwrap().next() else {
                    return;
                };
                let started = Instant::now();
                let fb = fallback_model.clone().map(|f| f as Arc<dyn CompactModel>);
                let built = optchat_host::build_node(&*main_model, fb.as_deref(), &request);
                let (outcome, text) = match &built {
                    Ok(b) if is_refusal(&b.text) => ("refusal_kept", b.text.clone()),
                    Ok(b) if b.stand_in => ("stand_in", b.text.clone()),
                    Ok(b) if b.by_fallback => ("fallback_line", b.text.clone()),
                    Ok(b) => ("line", b.text.clone()),
                    Err(e) if e.refused => ("refused_error", e.message.clone()),
                    Err(e) => ("error", e.message.clone()),
                };
                let line = serde_json::json!({
                    "node": request.node.name(),
                    "old_refusal": is_refusal(&old),
                    "outcome": outcome,
                    "bytes": text.len(),
                    "secs": started.elapsed().as_secs(),
                    "text": text,
                });
                eprintln!("{} {outcome} {}B", request.node.name(), text.len());
                lines.lock().unwrap().push(line);
            });
        }
    });
    let lines = lines.into_inner().unwrap();
    let mut counts: std::collections::BTreeMap<(bool, &str), usize> = Default::default();
    for l in &lines {
        *counts
            .entry((
                l["old_refusal"].as_bool().unwrap(),
                l["outcome"].as_str().unwrap(),
            ))
            .or_default() += 1;
    }
    for ((old, outcome), n) in &counts {
        let set = if *old { "refused-before" } else { "control" };
        println!("{set:15} {outcome:14} {n}");
    }
    let calls = |m: &ClaudeCli| {
        (
            m.calls.load(Ordering::SeqCst),
            m.refusals.load(Ordering::SeqCst),
        )
    };
    let (c, r) = calls(&main_model);
    println!("main model calls {c}, refusal replies {r}");
    if let Some(f) = &fallback_model {
        let (c, r) = calls(f);
        println!("fallback model calls {c}, refusal replies {r}");
    }
    if let Some(out) = out {
        let body: String = lines.iter().map(|l| format!("{l}\n")).collect();
        std::fs::write(out, body).expect("write --out");
    }
}
