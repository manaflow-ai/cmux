//! One recursive watcher over every chat root real path (FSEvents on
//! macOS, inotify on Linux). No timers and no polling: the event thread
//! blocks until an event arrives, then gathers a short burst (debounce) and
//! hands the changed paths to the index.

use std::path::PathBuf;
use std::sync::Weak;
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::time::{Duration, Instant};

use notify::Watcher as _;

use super::ChatService;

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
    if let Err(e) = std::thread::Builder::new()
        .name("acpmux-chat-watch".into())
        .spawn(move || run(&rx, &service))
    {
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

/// Ends when the watcher is dropped (the channel closes) or the service is gone.
fn run(rx: &Events, service: &Weak<ChatService>) {
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
        let Some(service) = service.upgrade() else { return };
        service.paths_changed(&burst.paths, burst.rescan);
        if closed {
            return;
        }
    }
}
