//! One recursive watcher over every chat root real path (FSEvents on
//! macOS, inotify on Linux). No timers and no polling: the event thread
//! blocks until an event arrives, then gathers a short burst (debounce) and
//! hands the changed paths to the index.

use crate::daemon::hang_watch::{BLOCKING_ITEM, SyncThread};
use std::path::PathBuf;
use std::sync::Weak;
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::time::{Duration, Instant};

use notify::Watcher as _;

use super::ChatService;
use crate::supervised::{Fatal, ShutdownBehavior, Supervisor};

/// A burst ends after this much quiet...
const QUIET: Duration = Duration::from_millis(300);
/// ...or after this long, so a harness that writes without pause still
/// shows its progress.
const MAX_BURST: Duration = Duration::from_secs(2);

/// Keeps the watcher alive; dropping it stops the events and its thread.
pub(super) struct RootWatcher {
    _watcher: notify::RecommendedWatcher,
}

type Events = Receiver<notify::Result<notify::Event>>;

/// Watches `roots`. Returns the watcher (None when there is nothing to
/// watch or it cannot start) and one message per root it cannot watch.
pub(super) fn start(
    roots: &[PathBuf],
    service: Weak<ChatService>,
    supervisor: &Supervisor,
) -> (Option<RootWatcher>, Vec<String>) {
    if roots.is_empty() {
        return (None, Vec::new());
    }
    let (tx, rx) = std::sync::mpsc::channel();
    let mut watcher = match notify::recommended_watcher(move |event| {
        let _ = tx.send(event);
    }) {
        Ok(watcher) => watcher,
        Err(e) => return (None, vec![format!("the chat watcher cannot start: {e}")]),
    };
    let mut errors = Vec::new();
    for root in roots {
        if let Err(e) = watcher.watch(root, notify::RecursiveMode::Recursive) {
            errors.push(format!("{}: {e}", root.display()));
        }
    }
    // The thread updates the shared chat index: a panic in it is fatal. It ends when the
    // watcher drops (its channel closes), so shutdown does not wait for it.
    let thread = crate::supervised::thread(
        supervisor,
        THREAD,
        cmux_threads::ThreadQos::Utility,
        Fatal,
        ShutdownBehavior::Continue,
        move |_stop| run(&rx, &service),
    );
    if let Err(e) = thread {
        errors.push(format!("the chat watcher thread cannot start: {e}"));
        return (None, errors);
    }
    (Some(RootWatcher { _watcher: watcher }), errors)
}

#[derive(Default)]
struct Burst {
    paths: Vec<PathBuf>,
    rescan: bool,
}

impl Burst {
    fn add(&mut self, event: notify::Result<notify::Event>) {
        match event {
            Ok(event) => {
                // Access events (inotify's open and close) change no data:
                // the index's own reads of a store made them, so taking them
                // as changes made every scan trigger the next one. A close
                // after write is dropped too: SQLite opens a WAL read-write
                // even for a read-only connection, so it closes "for write"
                // with no write. Every real write also reports a Modify.
                if matches!(event.kind, notify::EventKind::Access(_)) {
                    return;
                }
                self.rescan |= event.need_rescan();
                for path in event.paths {
                    if !self.paths.contains(&path) {
                        self.paths.push(path);
                    }
                }
            }
            // A watcher error may have dropped events: scan again.
            Err(_) => self.rescan = true,
        }
    }
}

/// The watch thread's name, also its name in a hang record.
const THREAD: &str = "acpmux-chat-watch";

/// Ends when the watcher is dropped (the channel closes) or the service is gone.
/// Each burst's index update, not its wait, is one hang-watch item; a rescan
/// walks whole roots, as the index's start does, and is not watched.
fn run(rx: &Events, service: &Weak<ChatService>) {
    let watched = SyncThread::register(THREAD, BLOCKING_ITEM);
    while let Ok(first) = rx.recv() {
        let started = Instant::now();
        let mut burst = Burst::default();
        burst.add(first);
        let mut closed = false;
        loop {
            let left = MAX_BURST.saturating_sub(started.elapsed());
            if left.is_zero() {
                break;
            }
            match rx.recv_timeout(QUIET.min(left)) {
                Ok(event) => burst.add(event),
                Err(RecvTimeoutError::Timeout) => break,
                Err(RecvTimeoutError::Disconnected) => {
                    closed = true;
                    break;
                }
            }
        }
        let _item = (!burst.rescan).then(|| watched.item());
        let Some(service) = service.upgrade() else { return };
        service.paths_changed(&burst.paths, burst.rescan);
        if closed {
            return;
        }
    }
}
