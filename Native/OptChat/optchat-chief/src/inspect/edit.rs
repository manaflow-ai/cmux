//! The owner's changes to the memory (plans/cmux-next/memory-inspector-native-DESIGN.md):
//! edit or delete one message, note or summary line, and undo a change.
//!
//! A tree address never moves: an edit replaces a text in place, a delete
//! replaces it with `TOMBSTONE`. Every built summary above the change then
//! holds old content, so it is marked stale and built again bottom-up by
//! the Chief's own compactor (`OptChat::rebuild_node`) on one worker thread.
//!
//! Safety: before the first change of a process, a full copy of the
//! database goes to `optchat/backups/` (`OptChat::snapshot`). Every change
//! appends its record to `optchat/memory-edits.jsonl` (0600, synced) before
//! the database write, with the old text, so the journal alone can undo it.
//! Rebuilt summaries append their own records (old and new text). An undo
//! puts back every text the change wrote, exactly, and is refused while a
//! later change still holds one of those rows.
//!
//! Callers: the inspector's POST paths, which the tools socket serves only
//! to a caller that is not one of the Chief's own turn or subagent sessions.

use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex};

use optchat_core::NodeId;
use optchat_host::OptChat;
use serde_json::{Value, json};

use super::turns::parse_name;
use super::{Answer, bad, not_found};

/// The text a deleted message, note or summary line keeps.
pub const TOMBSTONE: &str = "(deleted by the user)";
/// Largest message text an edit takes.
pub const MAX_MESSAGE_BYTES: usize = 1024 * 1024;
/// The journal's file name in `optchat/`.
pub const JOURNAL: &str = "memory-edits.jsonl";
/// The backups' directory name in `optchat/`.
pub const BACKUPS: &str = "backups";

/// What a change targets.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Target {
    Message(u64),
    Node(NodeId),
}

impl Target {
    fn json(self) -> Value {
        match self {
            Target::Message(id) => json!({"message": id}),
            Target::Node(n) => json!({"node": n.name()}),
        }
    }

    fn parse(v: &Value) -> Option<Target> {
        if let Some(id) = v.get("message").and_then(Value::as_u64) {
            return Some(Target::Message(id));
        }
        v.get("node")
            .and_then(Value::as_str)
            .and_then(parse_name)
            .map(Target::Node)
    }

    /// The built summaries above it, lowest first (a message's own line
    /// first): the ones a change to it makes stale.
    fn above(self, chat: &OptChat) -> Vec<NodeId> {
        let (first, l0) = match self {
            Target::Message(id) => (NodeId::new(0, id), 0),
            Target::Node(n) => (n.parent(), n.l + 1),
        };
        let start = first.start();
        let mut out = Vec::new();
        for l in l0..63 {
            let node = NodeId::new(l, start >> l);
            if chat.node(node).is_none() {
                break;
            }
            out.push(node);
        }
        out
    }
}

/// One change as the journal and `/api/memory/changes` show it.
#[derive(Clone, Debug)]
struct Change {
    id: u64,
    at: String,
    op: String,
    target: Target,
    old: String,
    new: String,
    /// Summaries it made stale, lowest first.
    stale: Vec<NodeId>,
    /// Summaries built again for it: node -> (old, new).
    rebuilt: BTreeMap<NodeId, (String, String)>,
    undone: bool,
}

impl Change {
    fn json(&self) -> Value {
        let pending: Vec<String> = self.pending().map(NodeId::name).collect();
        json!({
            "id": self.id,
            "at": self.at,
            "op": self.op,
            "target": self.target.json(),
            "old": self.old,
            "new": self.new,
            "stale": pending,
            "rebuilt": self.rebuilt.keys().map(|n| n.name()).collect::<Vec<_>>(),
            "undone": self.undone,
        })
    }

    fn pending(&self) -> impl Iterator<Item = NodeId> + '_ {
        self.stale
            .iter()
            .copied()
            .filter(|n| !self.undone && !self.rebuilt.contains_key(n))
    }
}

#[derive(Default)]
struct Book {
    changes: Vec<Change>,
    /// A full copy of the database was written by this process.
    backed_up: bool,
    /// Rebuilds still to do: (change id, node), in order.
    queue: VecDeque<(u64, NodeId)>,
    /// The rebuild running now, if any.
    running: Option<(u64, NodeId)>,
}

/// The owner's change book for one Chief's memory.
pub struct Editor {
    chat: Arc<OptChat>,
    dir: PathBuf,
    book: Mutex<Book>,
    work: Condvar,
}

impl Editor {
    /// The editor of `chat`, whose journal and backups live in `dir`
    /// (`optchat/`). Reads the journal; stale summaries left by an earlier
    /// process are queued, and a worker thread builds them.
    pub fn open(chat: Arc<OptChat>, dir: &Path) -> Arc<Editor> {
        let changes = read_journal(&dir.join(JOURNAL));
        let mut book = Book {
            changes,
            ..Book::default()
        };
        book.queue = book
            .changes
            .iter()
            .flat_map(|c| c.pending().map(move |n| (c.id, n)))
            .collect();
        let editor = Arc::new(Editor {
            chat,
            dir: dir.to_owned(),
            book: Mutex::new(book),
            work: Condvar::new(),
        });
        let weak = Arc::downgrade(&editor);
        let _ = std::thread::Builder::new()
            .name("memory-rebuild".into())
            .spawn(move || rebuild_loop(weak));
        editor
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Book> {
        self.book
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// The summaries waiting to be built again.
    pub fn stale(&self) -> BTreeSet<NodeId> {
        let book = self.lock();
        book.changes.iter().flat_map(Change::pending).collect()
    }

    /// Waits until no rebuild is queued or running (tests, `settle`).
    pub fn wait_rebuilt(&self, timeout: std::time::Duration) -> bool {
        let deadline = std::time::Instant::now() + timeout;
        let mut book = self.lock();
        while !book.queue.is_empty() || book.running.is_some() {
            let left = deadline.saturating_duration_since(std::time::Instant::now());
            if left.is_zero() {
                return false;
            }
            book = self
                .work
                .wait_timeout(book, left.min(std::time::Duration::from_millis(50)))
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .0;
        }
        true
    }

    /// `/api/memory/changes`: the change list, newest first, and the stale count.
    pub fn changes(&self) -> Value {
        let book = self.lock();
        let list: Vec<Value> = book.changes.iter().rev().map(Change::json).collect();
        let stale: Vec<String> = book
            .changes
            .iter()
            .flat_map(Change::pending)
            .map(NodeId::name)
            .collect();
        json!({"changes": list, "stale": stale, "journal": self.dir.join(JOURNAL)})
    }

    /// The POST paths: `/api/memory/edit` (`target`, `text`),
    /// `/api/memory/delete` (`target`), `/api/memory/undo` (`change`).
    /// `target` is `message:<id>` or `node:<id+n>`.
    pub fn answer(&self, path: &str, query: &[(String, String)]) -> Answer {
        let q = |key: &str| {
            query
                .iter()
                .find(|(k, _)| k == key)
                .map(|(_, v)| v.as_str())
        };
        match path {
            "/api/memory/edit" => {
                let target = parse_target(q("target"))?;
                let text = q("text").ok_or_else(|| bad("edit needs text"))?;
                self.change("edit", target, text)
            }
            "/api/memory/delete" => {
                let target = parse_target(q("target"))?;
                self.change("delete", target, TOMBSTONE)
            }
            "/api/memory/undo" => {
                let id = q("change")
                    .and_then(|c| c.parse::<u64>().ok())
                    .ok_or_else(|| bad("undo needs change=<id>"))?;
                self.undo(id)
            }
            "/api/memory/changes" => Ok(self.changes()),
            _ => Err(not_found(format!("no API {path}"))),
        }
    }

    /// The current text of `target`, or 404.
    fn current(&self, target: Target) -> Result<String, (u16, String)> {
        match target {
            Target::Message(id) => self
                .chat
                .message(id)
                .map(|(_, t)| t)
                .ok_or_else(|| not_found(format!("No message {id}."))),
            Target::Node(n) => self
                .chat
                .node(n)
                .ok_or_else(|| not_found(format!("No built line {}.", n.name()))),
        }
    }

    /// Writes `text` over `target` (backup, journal, database, stale marks).
    fn change(&self, op: &str, target: Target, text: &str) -> Answer {
        let text = text.trim_end();
        if text.trim().is_empty() {
            return Err(bad("the new text is empty: delete it instead"));
        }
        let limit = match target {
            Target::Message(_) => MAX_MESSAGE_BYTES,
            Target::Node(_) => optchat_core::NODE,
        };
        if text.len() > limit {
            return Err(bad(format!(
                "the new text is {} bytes; at most {limit} fit here",
                text.len()
            )));
        }
        let mut book = self.lock();
        let old = self.current(target)?;
        if old == text {
            return Err(bad("nothing changed"));
        }
        self.backup(&mut book)?;
        let stale = target.above(&self.chat);
        let change = Change {
            id: book.changes.iter().map(|c| c.id).max().unwrap_or(0) + 1,
            at: chrono::Local::now().to_rfc3339(),
            op: op.to_owned(),
            target,
            old: old.clone(),
            new: text.to_owned(),
            stale: stale.clone(),
            rebuilt: BTreeMap::new(),
            undone: false,
        };
        self.journal(&json!({
            "rec": "change", "id": change.id, "at": change.at, "op": op,
            "target": target.json(), "old": old, "new": text,
            "stale": stale.iter().map(|n| n.name()).collect::<Vec<_>>(),
        }))?;
        self.write(target, text)?;
        let answer = change.json();
        book.queue.extend(stale.iter().map(|n| (change.id, *n)));
        book.changes.push(change);
        drop(book);
        self.work.notify_all();
        Ok(answer)
    }

    /// Puts back every text change `id` wrote, if no later change holds one.
    fn undo(&self, id: u64) -> Answer {
        let mut book = self.lock();
        let Some(k) = book.changes.iter().position(|c| c.id == id) else {
            return Err(not_found(format!("No change {id}.")));
        };
        if book.changes[k].undone {
            return Err(bad(format!("change {id} is already undone")));
        }
        if book.running.is_some_and(|(c, _)| c == id) {
            return Err((
                409,
                "its summaries are being rebuilt; try again in a moment".into(),
            ));
        }
        let change = book.changes[k].clone();
        // Rows a later live change wrote (its target or its rebuilt lines).
        let later: BTreeSet<Target> = book.changes[k + 1..]
            .iter()
            .filter(|c| !c.undone)
            .flat_map(|c| {
                std::iter::once(c.target).chain(c.rebuilt.keys().map(|n| Target::Node(*n)))
            })
            .collect();
        let mine: Vec<(Target, String, String)> =
            std::iter::once((change.target, change.old.clone(), change.new.clone()))
                .chain(
                    change
                        .rebuilt
                        .iter()
                        .map(|(n, (o, w))| (Target::Node(*n), o.clone(), w.clone())),
                )
                .collect();
        if let Some((t, _, _)) = mine.iter().find(|(t, _, _)| later.contains(t)) {
            return Err((
                409,
                format!(
                    "a later change also wrote {}; undo that one first",
                    match t {
                        Target::Message(m) => format!("message {m}"),
                        Target::Node(n) => format!("line {}", n.name()),
                    }
                ),
            ));
        }
        self.backup(&mut book)?;
        self.journal(&json!({"rec": "undo", "id": id, "at": chrono::Local::now().to_rfc3339()}))?;
        // Highest summary first, the target last: a reader never sees a
        // summary newer than what it summarizes.
        for (target, old, _) in mine.iter().rev() {
            self.write(*target, old)?;
        }
        book.queue.retain(|(c, _)| *c != id);
        book.changes[k].undone = true;
        Ok(book.changes[k].json())
    }

    fn write(&self, target: Target, text: &str) -> Result<(), (u16, String)> {
        let result = match target {
            Target::Message(id) => self.chat.rewrite_message(id, text),
            Target::Node(n) => self.chat.rewrite_node(n, text),
        };
        match result {
            Ok(Some(_)) => Ok(()),
            Ok(None) => Err(not_found("the line is gone")),
            Err(e) => Err((500, format!("writing the memory: {e}"))),
        }
    }

    /// The full copy before this process's first change.
    fn backup(&self, book: &mut Book) -> Result<(), (u16, String)> {
        if book.backed_up {
            return Ok(());
        }
        let stamp = chrono::Utc::now().format("%Y%m%dT%H%M%S%.3fZ");
        let to = self
            .dir
            .join(BACKUPS)
            .join(format!("memory-{stamp}.sqlite3"));
        self.chat
            .snapshot(&to)
            .map_err(|e| (500, format!("backing up the memory before the change: {e}")))?;
        book.backed_up = true;
        Ok(())
    }

    /// Appends one record and syncs it before the database write it covers. The
    /// line goes out in one write, so a reader never sees half of it beside a
    /// whole one (the rebuild worker appends while the inspector reads).
    fn journal(&self, record: &Value) -> Result<(), (u16, String)> {
        use std::os::unix::fs::OpenOptionsExt;
        let path = self.dir.join(JOURNAL);
        let write = || -> std::io::Result<()> {
            let mut f = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .mode(0o600)
                .open(&path)?;
            f.write_all(format!("{record}\n").as_bytes())?;
            f.sync_all()
        };
        write().map_err(|e| (500, format!("writing the change journal: {e}")))
    }
}

fn parse_target(value: Option<&str>) -> Result<Target, (u16, String)> {
    let value = value.ok_or_else(|| bad("needs target=message:<id> or target=node:<id+n>"))?;
    let parsed = match value.split_once(':') {
        Some(("message", id)) => id.parse().ok().map(Target::Message),
        Some(("node", name)) => parse_name(name).map(Target::Node),
        _ => None,
    };
    parsed.ok_or_else(|| bad(format!("{value:?} is not message:<id> or node:<id+n>")))
}

/// The changes the journal records (a torn last line is skipped).
fn read_journal(path: &Path) -> Vec<Change> {
    let Ok(text) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    let mut changes: Vec<Change> = Vec::new();
    for line in text.lines() {
        let Ok(rec) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        let id = rec["id"].as_u64().unwrap_or(0);
        let s = |k: &str| rec[k].as_str().unwrap_or("").to_owned();
        match rec["rec"].as_str() {
            Some("change") => {
                let Some(target) = Target::parse(&rec["target"]) else {
                    continue;
                };
                let stale = rec["stale"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|n| n.as_str().and_then(parse_name))
                    .collect();
                changes.push(Change {
                    id,
                    at: s("at"),
                    op: s("op"),
                    target,
                    old: s("old"),
                    new: s("new"),
                    stale,
                    rebuilt: BTreeMap::new(),
                    undone: false,
                });
            }
            Some("rebuild") => {
                let node = rec["node"].as_str().and_then(parse_name);
                if let (Some(node), Some(c)) = (node, changes.iter_mut().find(|c| c.id == id)) {
                    c.rebuilt.insert(node, (s("old"), s("new")));
                }
            }
            Some("undo") => {
                if let Some(c) = changes.iter_mut().find(|c| c.id == id) {
                    c.undone = true;
                }
            }
            _ => {}
        }
    }
    changes
}

/// Builds the queued stale summaries, one at a time, until the editor goes.
fn rebuild_loop(editor: std::sync::Weak<Editor>) {
    loop {
        let Some(ed) = editor.upgrade() else { return };
        let next = {
            let mut book = ed.lock();
            match book.queue.pop_front() {
                Some(job) => {
                    book.running = Some(job);
                    Some(job)
                }
                None => {
                    let _ = ed
                        .work
                        .wait_timeout(book, std::time::Duration::from_millis(500))
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    None
                }
            }
        };
        let Some((change, node)) = next else {
            drop(ed);
            continue;
        };
        let built = ed.chat.rebuild_node(node);
        let mut book = ed.lock();
        book.running = None;
        let live = book.changes.iter().any(|c| c.id == change && !c.undone);
        match built {
            Ok(Some((old, new))) if live => {
                let record = json!({"rec": "rebuild", "id": change, "node": node.name(), "old": old, "new": new});
                if ed.journal(&record).is_ok()
                    && let Some(c) = book.changes.iter_mut().find(|c| c.id == change)
                {
                    c.rebuilt.insert(node, (old, new));
                }
            }
            Ok(Some((old, _))) => {
                // Undone while it ran: put the text back.
                let _ = ed.chat.rewrite_node(node, &old);
            }
            Ok(None) => {
                // Not built, or changed meanwhile (that change rebuilds it).
                if let Some(c) = book.changes.iter_mut().find(|c| c.id == change) {
                    c.stale.retain(|n| *n != node);
                }
            }
            Err(_) => {
                // Tried again later (a model error passes; a restart retries too).
                book.queue.push_back((change, node));
                drop(book);
                ed.work.notify_all();
                std::thread::sleep(std::time::Duration::from_secs(5));
                continue;
            }
        }
        drop(book);
        ed.work.notify_all();
    }
}
