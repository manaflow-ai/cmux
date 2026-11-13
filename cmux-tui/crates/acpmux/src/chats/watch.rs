//! The file-system watch over every chat root real path. No timers and no polling: the event
//! thread blocks until an event arrives, then gathers a short burst (debounce) and hands the
//! changed paths to the index.
//!
//! Only what the index reads reaches that thread (lead order, 2026-11-12; found by lane idle).
//! The roots hold more than chats: `~/.codex` holds Codex's logs and databases, which every
//! running Codex writes several times a second, and a Claude Code project folder holds its
//! subagents' transcripts and its tools' results. An idle daemon on a fleet Mac took 400-570
//! context switches and 18-20 ms of CPU per 12 s for 20 such writes a second.
//!
//! - A root whose adapter names its session folders (`cmux_chat_index::session_folders`, Codex)
//!   is watched as those folders, whole, plus the root's own entries and the root-level files
//!   the index reads (`classify_path`), each by a kqueue vnode watch (`record_watch::DirWatch`,
//!   macOS): a write to another file of the root never reaches the daemon. A change of the
//!   root's entries (a store file or a session folder created, renamed or removed) arms the
//!   watch again for what the root holds now.
//! - Every other root, and every root on Linux, is watched whole: it may hold thousands of
//!   transcripts, too many for a watch per file. The callback drops each path the index does
//!   not read before anything is handed on: those paths cost the callback, never the chat watch
//!   thread or the index.
//! - A folder watched whole (`Trees`): on macOS an FSEvents stream of our own with a coalescing
//!   [`LATENCY`] (`fsevents.rs`): with many agents at work a Claude Code project folder changes
//!   hundreds of times a second, and notify's stream (latency 0) woke the daemon for each change.
//!   The first change after a quiet spell still comes at once. Elsewhere notify's watcher
//!   (inotify on Linux), as before.
//! - A folder made in, or moved into, a tree notify watches whole (`Message::Folder`): inotify
//!   gives each folder a watch of its own, which notify adds only after it handed on the event
//!   that made the folder, so a file written into a new folder before then has no event (Codex
//!   makes `sessions/YYYY/MM/DD` and writes the day's first rollout into it at once). The chat
//!   watch thread first waits until notify's thread has added those watches (`Trees::settle`),
//!   then lists the folder and hands on each file in it the index reads: a file written before
//!   the watch is listed, one written after it has its event.
//! - The chat watch thread coalesces what arrives into one index pass per burst (`coalesce`,
//!   behind the `Source` seam its tests drive with a script and no clock).

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Weak};
use std::time::{Duration, Instant};

use cmux_chat_index::{AdapterKind, PathRole, classify_path};

use super::ChatService;

/// A burst ends after this much quiet...
const QUIET: Duration = Duration::from_millis(300);
/// ...or after this long, so a harness that writes without pause still
/// shows its progress.
const MAX_BURST: Duration = Duration::from_secs(2);
/// macOS: how long FSEvents gathers the changes of a busy folder into one delivery (`fsevents.rs`).
/// The smallest latency that brought the watch of 170 agents' Claude Code projects (340 writes a
/// second) to about 20 ms of CPU per 12 s on a fleet Mac (`watch_bench_tests.rs`, 2026-11-12:
/// notify 96.6 ms and 1,745 context switches; 0 s 123 ms; 0.25 s 30.7 ms; 0.5 s 20.8 ms and 299;
/// 1 s 22.9 ms; 2 s 25.3 ms). Past 0.25 s FSEvents still delivers about 12 times a second, so a
/// longer latency only delays a chat row; what remains is the cost of each changed path.
#[cfg(target_os = "macos")]
pub(super) const LATENCY: Duration = Duration::from_millis(500);

/// One root to watch: its real path and its adapter.
#[derive(Clone, Debug)]
pub(super) struct WatchedRoot {
    pub path: PathBuf,
    pub kind: AdapterKind,
}

/// Keeps the watch alive; dropping it stops the events, and its thread ends.
pub(super) struct RootWatcher {
    /// The roots watched whole.
    _whole: Vec<Tree>,
    _trees: Arc<Trees>,
    /// Ends the chat watch thread's loop even while a watch still holds a sender.
    _stop: Sender<Message>,
}

impl Drop for RootWatcher {
    fn drop(&mut self) {
        let _ = self._stop.send(Message::Stop);
    }
}

#[derive(Debug)]
enum Message {
    /// Changed paths the index reads; `rescan`: events may have been lost there.
    Paths {
        paths: Vec<PathBuf>,
        rescan: bool,
    },
    /// A root watched by its folders: its entries or one of its own store files changed.
    /// Sent only by the macOS directory watch, so the variant exists only there.
    #[cfg(target_os = "macos")]
    RootEntries(usize),
    /// A folder made in, or moved into, a tree notify watches whole: what it holds may have no
    /// event (the module's text).
    #[cfg(not(target_os = "macos"))]
    Folder(PathBuf),
    Stop,
}

/// Watches `roots`. Returns the watcher (None when there is nothing to
/// watch or it cannot start) and one message per root it cannot watch.
pub(super) fn start(
    roots: &[WatchedRoot],
    service: Weak<ChatService>,
) -> (Option<RootWatcher>, Vec<String>) {
    if roots.is_empty() {
        return (None, Vec::new());
    }
    let (tx, rx) = std::sync::mpsc::channel();
    let filter = Arc::new(Filter { roots: roots.to_vec() });
    let trees = match Trees::new(filter, tx.clone(), platform_latency()) {
        Ok(trees) => Arc::new(trees),
        Err(e) => return (None, vec![format!("the chat watcher cannot start: {e}")]),
    };
    let mut errors = Vec::new();
    let mut by_folders = Vec::new();
    let mut whole = Vec::new();
    for (at, root) in roots.iter().enumerate() {
        match folders_of(root) {
            Some(folders) => {
                let mut watch = FolderWatch::new(at, root.clone(), folders);
                watch.arm(&trees, &mut errors);
                by_folders.push(watch);
            }
            None => match trees.watch(&root.path) {
                Ok(tree) => whole.push(tree),
                Err(e) => errors.push(format!("{}: {e}", root.path.display())),
            },
        }
    }
    let thread_trees = trees.clone();
    // task-owner: the chat service's RootWatcher; ends when it is dropped (its Stop message) or
    // the service is gone.
    if let Err(e) = std::thread::Builder::new()
        .name("acpmux-chat-watch".into())
        .spawn(move || run(&mut Channel(rx), &service, by_folders, &thread_trees))
    {
        errors.push(format!("the chat watcher thread cannot start: {e}"));
        return (None, errors);
    }
    (Some(RootWatcher { _whole: whole, _trees: trees, _stop: tx }), errors)
}

#[cfg(target_os = "macos")]
fn platform_latency() -> Duration {
    LATENCY
}

#[cfg(not(target_os = "macos"))]
fn platform_latency() -> Duration {
    Duration::ZERO
}

/// The session folders `root` is watched by, on a platform with a watch per file (macOS).
fn folders_of(root: &WatchedRoot) -> Option<&'static [&'static str]> {
    if cfg!(target_os = "macos") { cmux_chat_index::session_folders(root.kind) } else { None }
}

/// Which paths the index reads: run in the watch's callback, before any hand-off.
struct Filter {
    roots: Vec<WatchedRoot>,
}

impl Filter {
    /// The paths of `paths` the index reads.
    fn keep(&self, paths: Vec<PathBuf>) -> Vec<PathBuf> {
        paths.into_iter().filter(|path| self.reads(path)).collect()
    }

    /// What one notify event hands on, if anything.
    #[cfg_attr(target_os = "macos", allow(dead_code))]
    fn handed_from_notify(&self, event: notify::Result<notify::Event>) -> Option<Message> {
        let Ok(event) = event else {
            // A watcher error may have dropped events: the index scans again.
            return Some(Message::Paths { paths: Vec::new(), rescan: true });
        };
        // Access events (inotify's open and close) change no data: the index's own reads of
        // a store made them, so taking them as changes made every scan trigger the next one.
        // A close after write is dropped too: SQLite opens a WAL read-write even for a
        // read-only connection, so it closes "for write" with no write. Every real write also
        // reports a Modify.
        if matches!(event.kind, notify::EventKind::Access(_)) {
            return None;
        }
        #[cfg(not(target_os = "macos"))]
        if let Some(folder) = self.folder_came(&event) {
            return Some(Message::Folder(folder));
        }
        let rescan = event.need_rescan();
        let paths = self.keep(event.paths);
        (rescan || !paths.is_empty()).then_some(Message::Paths { paths, rescan })
    }

    /// The folder `event` made in a root, or moved into one: notify names a folder made, and a
    /// path moved in with no kind, so that one is looked at. In a root whose adapter names its
    /// session folders (Codex), only a folder that is or is under one of them: the root's other
    /// folders (its logs, a checkout) hold nothing the index reads and end here.
    #[cfg(not(target_os = "macos"))]
    fn folder_came(&self, event: &notify::Event) -> Option<PathBuf> {
        use notify::event::{CreateKind, ModifyKind, RenameMode};
        let path = event.paths.last()?;
        let made = match event.kind {
            notify::EventKind::Create(CreateKind::Folder) => true,
            notify::EventKind::Modify(ModifyKind::Name(RenameMode::To)) => path.is_dir(),
            _ => false,
        };
        let inside = self.roots.iter().any(|root| {
            path.starts_with(&root.path)
                && path != &root.path
                && cmux_chat_index::session_folders(root.kind).is_none_or(|folders| {
                    folders.iter().any(|folder| path.starts_with(root.path.join(folder)))
                })
        });
        (made && inside).then(|| path.clone())
    }

    /// What one delivery of the own FSEvents stream hands on, if anything.
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    fn handed_from_delivery(&self, paths: Vec<PathBuf>, rescan: bool) -> Option<Message> {
        let paths = self.keep(paths);
        (rescan || !paths.is_empty()).then_some(Message::Paths { paths, rescan })
    }

    /// Whether `path` is a file the index reads, or a root itself (gone, or made again).
    fn reads(&self, path: &Path) -> bool {
        self.roots.iter().any(|root| {
            path == root.path
                || (path.starts_with(&root.path)
                    && classify_path(root.kind, &root.path, path) != PathRole::Ignore)
        })
    }
}

/// Starts the watches of folders, whole; each hands what the index reads to the chat watch
/// thread.
struct Trees {
    filter: Arc<Filter>,
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    tx: Sender<Message>,
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    latency: Duration,
    #[cfg(not(target_os = "macos"))]
    watcher: Arc<std::sync::Mutex<notify::RecommendedWatcher>>,
}

/// One folder watched whole; dropping it ends that watch.
struct Tree {
    #[cfg(target_os = "macos")]
    _stream: super::fsevents::Stream,
    #[cfg(not(target_os = "macos"))]
    watcher: Arc<std::sync::Mutex<notify::RecommendedWatcher>>,
    #[cfg(not(target_os = "macos"))]
    path: PathBuf,
}

#[cfg(not(target_os = "macos"))]
impl Drop for Tree {
    fn drop(&mut self) {
        use notify::Watcher as _;
        let mut watcher = self.watcher.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let _ = watcher.unwatch(&self.path);
    }
}

impl Trees {
    fn new(filter: Arc<Filter>, tx: Sender<Message>, latency: Duration) -> Result<Self, String> {
        #[cfg(not(target_os = "macos"))]
        let watcher = {
            let (filter, tx) = (filter.clone(), tx.clone());
            let watcher = notify::recommended_watcher(move |event| {
                if let Some(message) = filter.handed_from_notify(event) {
                    let _ = tx.send(message);
                }
            })
            .map_err(|e| e.to_string())?;
            Arc::new(std::sync::Mutex::new(watcher))
        };
        Ok(Self {
            filter,
            tx,
            latency,
            #[cfg(not(target_os = "macos"))]
            watcher,
        })
    }

    #[cfg(target_os = "macos")]
    fn watch(&self, folder: &Path) -> Result<Tree, String> {
        let (filter, tx) = (self.filter.clone(), self.tx.clone());
        let stream = super::fsevents::Stream::start(
            folder,
            self.latency,
            Box::new(move |paths, rescan| {
                if let Some(message) = filter.handed_from_delivery(paths, rescan) {
                    let _ = tx.send(message);
                }
            }),
        )?;
        Ok(Tree { _stream: stream })
    }

    /// Returns once notify's thread has handled every event it read before now, and added the
    /// watches of the folders those events made: notify answers a configure call on that thread,
    /// after the pass over its queue that handed on a folder's event and then watched it.
    #[cfg(not(target_os = "macos"))]
    fn settle(&self) {
        use notify::Watcher as _;
        let _ = self
            .watcher
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .configure(notify::Config::default());
    }

    /// `folder` itself when the index reads it (as it was handed on before), and the files under
    /// it (not through a symbolic link) the index reads.
    #[cfg(not(target_os = "macos"))]
    fn files_in(&self, folder: &Path, out: &mut Vec<PathBuf>) {
        if self.filter.reads(folder) && !out.iter().any(|p| p == folder) {
            out.push(folder.to_path_buf());
        }
        let mut pending = vec![folder.to_path_buf()];
        while let Some(dir) = pending.pop() {
            for entry in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
                let Ok(kind) = entry.file_type() else { continue };
                let path = entry.path();
                if kind.is_dir() {
                    pending.push(path);
                } else if self.filter.reads(&path) && !out.contains(&path) {
                    out.push(path);
                }
            }
        }
    }

    #[cfg(not(target_os = "macos"))]
    fn watch(&self, folder: &Path) -> Result<Tree, String> {
        use notify::Watcher as _;
        self.watcher
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .watch(folder, notify::RecursiveMode::Recursive)
            .map_err(|e| e.to_string())?;
        Ok(Tree { watcher: self.watcher.clone(), path: folder.to_path_buf() })
    }
}

/// A root watched as its session folders, its own entries and the root-level files the index
/// reads.
struct FolderWatch {
    at: usize,
    root: WatchedRoot,
    folders: &'static [&'static str],
    /// The session folders watched now, and the root-level files the kqueue watch holds.
    watched: HashMap<PathBuf, Tree>,
    files: Vec<PathBuf>,
    #[cfg(target_os = "macos")]
    entries: Option<crate::agent_host::record_watch::DirWatch>,
}

impl FolderWatch {
    fn new(at: usize, root: WatchedRoot, folders: &'static [&'static str]) -> Self {
        Self {
            at,
            root,
            folders,
            watched: HashMap::new(),
            files: Vec::new(),
            #[cfg(target_os = "macos")]
            entries: None,
        }
    }

    /// The root-level files the index reads, as the root holds them now.
    fn own_files(&self) -> Vec<PathBuf> {
        let mut files: Vec<PathBuf> = std::fs::read_dir(&self.root.path)
            .into_iter()
            .flatten()
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| classify_path(self.root.kind, &self.root.path, path) != PathRole::Ignore)
            .collect();
        files.sort();
        files
    }

    /// Watches what the root holds now: each session folder that exists, whole, and the
    /// root's entries and own files. Returns whether that changed (a folder or a file came or
    /// went), so the index scans the root again.
    fn arm(&mut self, trees: &Trees, errors: &mut Vec<String>) -> bool {
        let folders: Vec<PathBuf> = self
            .folders
            .iter()
            .map(|folder| self.root.path.join(folder))
            .filter(|folder| folder.is_dir())
            .collect();
        let files = self.own_files();
        let same_folders = folders.len() == self.watched.len()
            && folders.iter().all(|folder| self.watched.contains_key(folder));
        if same_folders && files == self.files && self.armed() {
            return false;
        }
        self.watched.retain(|folder, _| folders.contains(folder));
        for folder in folders {
            if self.watched.contains_key(&folder) {
                continue;
            }
            match trees.watch(&folder) {
                Ok(tree) => {
                    self.watched.insert(folder, tree);
                }
                Err(e) => errors.push(format!("{}: {e}", folder.display())),
            }
        }
        self.files = files;
        #[cfg(target_os = "macos")]
        {
            let mut paths = vec![self.root.path.clone()];
            paths.extend(self.files.iter().cloned());
            let (tx, at) = (trees.tx.clone(), self.at);
            // Dropping the old watch ends its thread at its next event; the new one is armed
            // before, so no change falls between them.
            let entries = crate::agent_host::record_watch::DirWatch::start(&paths, move || {
                tx.send(Message::RootEntries(at)).is_err()
            });
            if entries.is_none() {
                errors.push(format!(
                    "{}: the root's own files cannot be watched",
                    self.root.path.display()
                ));
            }
            self.entries = entries;
        }
        true
    }

    fn armed(&self) -> bool {
        #[cfg(target_os = "macos")]
        return self.entries.is_some();
        #[cfg(not(target_os = "macos"))]
        return true;
    }
}

/// What the chat watch thread gathered: one index pass.
#[derive(Default, Debug, PartialEq)]
struct Burst {
    paths: Vec<PathBuf>,
    rescan: bool,
    /// The roots watched by their folders whose entries changed.
    entries: Vec<usize>,
    /// Folders made in a tree notify watches whole, to be listed (`Message::Folder`).
    #[cfg_attr(target_os = "macos", allow(dead_code))]
    folders: Vec<PathBuf>,
}

impl Burst {
    fn add_path(&mut self, path: PathBuf) {
        if !self.paths.contains(&path) {
            self.paths.push(path);
        }
    }
}

/// Where the chat watch thread's messages come from, and its clock: the channel and the real
/// clock in the daemon, a script with no clock and no sleep in the tests.
trait Source {
    fn now(&self) -> Instant;
    /// The next message, waiting at most until `until` (None: as long as it takes).
    fn next(&mut self, until: Option<Instant>) -> Next;
}

#[derive(Debug)]
enum Next {
    Message(Message),
    Timeout,
    Closed,
}

struct Channel(Receiver<Message>);

impl Source for Channel {
    fn now(&self) -> Instant {
        Instant::now()
    }

    fn next(&mut self, until: Option<Instant>) -> Next {
        let Some(until) = until else {
            return self.0.recv().map_or(Next::Closed, Next::Message);
        };
        match self.0.recv_timeout(until.saturating_duration_since(Instant::now())) {
            Ok(message) => Next::Message(message),
            Err(RecvTimeoutError::Timeout) => Next::Timeout,
            Err(RecvTimeoutError::Disconnected) => Next::Closed,
        }
    }
}

/// Gathers what `source` sends into bursts: a burst ends after [`QUIET`] with no message, or
/// [`MAX_BURST`] after its first. `on_burst` gets each one (false: stop). Returns on a Stop
/// message or a closed source; a burst in progress then is dropped with the service.
fn coalesce(source: &mut impl Source, mut on_burst: impl FnMut(Burst) -> bool) {
    loop {
        let Next::Message(first) = source.next(None) else { return };
        let end = source.now() + MAX_BURST;
        let mut burst = Burst::default();
        let mut next = Some(first);
        loop {
            match next.take() {
                Some(Message::Paths { paths, rescan }) => {
                    burst.rescan |= rescan;
                    for path in paths {
                        burst.add_path(path);
                    }
                }
                #[cfg(target_os = "macos")]
                Some(Message::RootEntries(at)) if !burst.entries.contains(&at) => {
                    burst.entries.push(at)
                }
                #[cfg(target_os = "macos")]
                Some(Message::RootEntries(_)) => {}
                // Each folder once, and none below another: its listing lists them too.
                #[cfg(not(target_os = "macos"))]
                Some(Message::Folder(folder)) => {
                    if !burst.folders.iter().any(|seen| folder.starts_with(seen)) {
                        burst.folders.retain(|seen| !seen.starts_with(&folder));
                        burst.folders.push(folder);
                    }
                }
                None => {}
                Some(Message::Stop) => return,
            }
            let now = source.now();
            if now >= end {
                break;
            }
            match source.next(Some((now + QUIET).min(end))) {
                Next::Message(message) => next = Some(message),
                Next::Timeout => break,
                Next::Closed => return,
            }
        }
        if !on_burst(burst) {
            return;
        }
    }
}

/// Ends when the watch is dropped (its Stop message) or the service is gone.
fn run(
    source: &mut impl Source,
    service: &Weak<ChatService>,
    mut by_folders: Vec<FolderWatch>,
    trees: &Trees,
) {
    coalesce(source, |mut burst| {
        // A root watched by its folders: its own files as they are now, and, when what it
        // holds changed, the root again.
        let entries = std::mem::take(&mut burst.entries);
        for watch in by_folders.iter_mut().filter(|w| entries.contains(&w.at)) {
            let mut errors = Vec::new();
            if watch.arm(trees, &mut errors) {
                burst.rescan = true;
                burst.add_path(watch.root.path.clone());
            }
            for error in errors {
                tracing::warn!("chat watch: {error}");
            }
            for file in &watch.files {
                burst.add_path(file.clone());
            }
        }
        // Folders made in a tree watched whole: listed once notify watches them.
        #[cfg(not(target_os = "macos"))]
        if !burst.folders.is_empty() {
            trees.settle();
            for folder in std::mem::take(&mut burst.folders) {
                trees.files_in(&folder, &mut burst.paths);
            }
        }
        // Folders that held nothing the index reads: no pass.
        if burst.paths.is_empty() && !burst.rescan {
            return true;
        }
        let Some(service) = service.upgrade() else { return false };
        service.paths_changed(&burst.paths, burst.rescan);
        true
    });
}

#[cfg(test)]
#[path = "watch_tests.rs"]
mod tests;

#[cfg(all(test, target_os = "macos"))]
#[path = "watch_bench_tests.rs"]
mod bench;
