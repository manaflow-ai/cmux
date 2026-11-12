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
//!   is watched as those folders, whole (notify: FSEvents on macOS, inotify on Linux), plus the
//!   root's own entries and the root-level files the index reads (`classify_path`), each by a
//!   kqueue vnode watch (`record_watch::DirWatch`, macOS): a write to another file of the root
//!   never reaches the daemon. A change of the root's entries (a store file or a session folder
//!   created, renamed or removed) arms the watch again for what the root holds now.
//! - Every other root, and every root on Linux, is watched whole: it may hold thousands of
//!   transcripts, too many for a watch per file. The notify callback drops each event whose
//!   paths the index does not read before anything is handed on: those events cost the
//!   callback, never the chat watch thread or the index.

use std::path::{Path, PathBuf};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};

use cmux_chat_index::{AdapterKind, PathRole, classify_path};
use notify::Watcher as _;

use super::ChatService;

/// A burst ends after this much quiet...
const QUIET: Duration = Duration::from_millis(300);
/// ...or after this long, so a harness that writes without pause still
/// shows its progress.
const MAX_BURST: Duration = Duration::from_secs(2);

/// One root to watch: its real path and its adapter.
#[derive(Clone, Debug)]
pub(super) struct WatchedRoot {
    pub path: PathBuf,
    pub kind: AdapterKind,
}

/// Keeps the watch alive; dropping it stops the events, and its thread ends.
pub(super) struct RootWatcher {
    _watcher: Arc<Mutex<notify::RecommendedWatcher>>,
    /// Ends the chat watch thread's loop even while a kqueue watch still holds a sender.
    _stop: Sender<Message>,
}

impl Drop for RootWatcher {
    fn drop(&mut self) {
        let _ = self._stop.send(Message::Stop);
    }
}

enum Message {
    Event(notify::Result<notify::Event>),
    /// A root watched by its folders: its entries or one of its own store files changed.
    /// Only the macOS folder watch sends it.
    #[cfg(target_os = "macos")]
    RootEntries(usize),
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
    let filter = Filter { roots: roots.to_vec() };
    let events = tx.clone();
    let watcher = match notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
        if filter.needed(&event) {
            let _ = events.send(Message::Event(event));
        }
    }) {
        Ok(watcher) => Arc::new(Mutex::new(watcher)),
        Err(e) => return (None, vec![format!("the chat watcher cannot start: {e}")]),
    };
    let mut errors = Vec::new();
    let mut by_folders = Vec::new();
    for (at, root) in roots.iter().enumerate() {
        match folders_of(root) {
            Some(folders) => {
                let mut watch = FolderWatch::new(at, root.clone(), folders);
                watch.arm(&watcher, &tx, &mut errors);
                by_folders.push(watch);
            }
            None => {
                if let Err(e) = lock(&watcher).watch(&root.path, notify::RecursiveMode::Recursive) {
                    errors.push(format!("{}: {e}", root.path.display()));
                }
            }
        }
    }
    let thread_watcher = watcher.clone();
    let thread_tx = tx.clone();
    // task-owner: the chat service's RootWatcher; ends when it is dropped (its Stop message) or
    // the service is gone.
    if let Err(e) = std::thread::Builder::new()
        .name("acpmux-chat-watch".into())
        .spawn(move || run(&rx, &service, by_folders, &thread_watcher, &thread_tx))
    {
        errors.push(format!("the chat watcher thread cannot start: {e}"));
        return (None, errors);
    }
    (Some(RootWatcher { _watcher: watcher, _stop: tx }), errors)
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// The session folders `root` is watched by, on a platform with a watch per file (macOS).
fn folders_of(root: &WatchedRoot) -> Option<&'static [&'static str]> {
    if cfg!(target_os = "macos") { cmux_chat_index::session_folders(root.kind) } else { None }
}

/// Which events the index reads: run in notify's callback, before any hand-off.
struct Filter {
    roots: Vec<WatchedRoot>,
}

impl Filter {
    fn needed(&self, event: &notify::Result<notify::Event>) -> bool {
        let Ok(event) = event else {
            // A watcher error may have dropped events: the index scans again.
            return true;
        };
        // Access events (inotify's open and close) change no data: the index's own reads of
        // a store made them, so taking them as changes made every scan trigger the next one.
        // A close after write is dropped too: SQLite opens a WAL read-write even for a
        // read-only connection, so it closes "for write" with no write. Every real write also
        // reports a Modify.
        if matches!(event.kind, notify::EventKind::Access(_)) {
            return false;
        }
        event.need_rescan() || event.paths.is_empty() || event.paths.iter().any(|p| self.reads(p))
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

/// A root watched as its session folders, its own entries and the root-level files the index
/// reads.
struct FolderWatch {
    at: usize,
    root: WatchedRoot,
    folders: &'static [&'static str],
    /// The session folders watched now, and the root-level files the kqueue watch holds.
    watched: Vec<PathBuf>,
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
            watched: Vec::new(),
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
    fn arm(
        &mut self,
        watcher: &Mutex<notify::RecommendedWatcher>,
        tx: &Sender<Message>,
        errors: &mut Vec<String>,
    ) -> bool {
        let folders: Vec<PathBuf> = self
            .folders
            .iter()
            .map(|folder| self.root.path.join(folder))
            .filter(|folder| folder.is_dir())
            .collect();
        let files = self.own_files();
        if folders == self.watched && files == self.files && self.armed() {
            return false;
        }
        {
            let mut watcher = lock(watcher);
            for gone in self.watched.iter().filter(|w| !folders.contains(w)) {
                let _ = watcher.unwatch(gone);
            }
            for folder in folders.iter().filter(|f| !self.watched.contains(f)) {
                if let Err(e) = watcher.watch(folder, notify::RecursiveMode::Recursive) {
                    errors.push(format!("{}: {e}", folder.display()));
                }
            }
        }
        self.watched = folders;
        self.files = files;
        #[cfg(target_os = "macos")]
        {
            let mut paths = vec![self.root.path.clone()];
            paths.extend(self.files.iter().cloned());
            let (tx, at) = (tx.clone(), self.at);
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
        #[cfg(not(target_os = "macos"))]
        let _ = tx;
        true
    }

    fn armed(&self) -> bool {
        #[cfg(target_os = "macos")]
        return self.entries.is_some();
        #[cfg(not(target_os = "macos"))]
        return true;
    }
}

#[derive(Default)]
struct Burst {
    paths: Vec<PathBuf>,
    rescan: bool,
}

impl Burst {
    fn add_path(&mut self, path: PathBuf) {
        if !self.paths.contains(&path) {
            self.paths.push(path);
        }
    }

    fn add(&mut self, event: notify::Result<notify::Event>) {
        match event {
            Ok(event) => {
                self.rescan |= event.need_rescan();
                for path in event.paths {
                    self.add_path(path);
                }
            }
            // A watcher error may have dropped events: scan again.
            Err(_) => self.rescan = true,
        }
    }
}

/// Ends when the watch is dropped (its Stop message) or the service is gone.
fn run(
    rx: &Receiver<Message>,
    service: &Weak<ChatService>,
    mut by_folders: Vec<FolderWatch>,
    watcher: &Mutex<notify::RecommendedWatcher>,
    tx: &Sender<Message>,
) {
    while let Ok(first) = rx.recv() {
        let started = Instant::now();
        let mut burst = Burst::default();
        // Roots whose folder watch reported a change; only macOS has folder watches.
        #[cfg(target_os = "macos")]
        let mut entries = Vec::new();
        #[cfg(not(target_os = "macos"))]
        let entries: Vec<usize> = Vec::new();
        let mut closed = false;
        let mut next = Some(first);
        loop {
            match next.take() {
                Some(Message::Event(event)) => burst.add(event),
                #[cfg(target_os = "macos")]
                Some(Message::RootEntries(at)) if !entries.contains(&at) => entries.push(at),
                #[cfg(target_os = "macos")]
                Some(Message::RootEntries(_)) => {}
                Some(Message::Stop) => {
                    closed = true;
                    break;
                }
                None => {}
            }
            let left = MAX_BURST.saturating_sub(started.elapsed());
            if left.is_zero() {
                break;
            }
            match rx.recv_timeout(QUIET.min(left)) {
                Ok(message) => next = Some(message),
                Err(RecvTimeoutError::Timeout) => break,
                Err(RecvTimeoutError::Disconnected) => {
                    closed = true;
                    break;
                }
            }
        }
        if closed {
            return;
        }
        // A root watched by its folders: its own files as they are now, and, when what it
        // holds changed, the root again.
        for watch in by_folders.iter_mut().filter(|w| entries.contains(&w.at)) {
            let mut errors = Vec::new();
            if watch.arm(watcher, tx, &mut errors) {
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
        let Some(service) = service.upgrade() else { return };
        service.paths_changed(&burst.paths, burst.rescan);
    }
}

#[cfg(test)]
#[path = "watch_tests.rs"]
mod tests;
