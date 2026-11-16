//! Shutdown-aware wrappers for request-reachable blocking work.
//!
//! A blocking task cannot be aborted once its closure has started. The fence therefore
//! does three things: it refuses work that was queued after shutdown, gives a worker a
//! checkpoint for multi-step effects, and drops the result if shutdown wins while it runs.

use acpmux_core::life::StopFence;

/// A worker's cooperative checkpoint between effectful steps.
#[derive(Clone)]
pub(crate) struct Checkpoint {
    stop: StopFence,
}

impl Checkpoint {
    /// Whether the worker may begin or continue its next step.
    pub(crate) fn open(&self) -> bool {
        !self.stop.is_cancelled()
    }
}

/// Run blocking work behind the daemon stop fence.
///
/// The closure receives a checkpoint and may return early between effectful steps. A result is
/// returned only when the fence stayed open through the join; a result produced after shutdown is
/// dropped before it can be applied by the request task.
pub(crate) async fn spawn<T, F>(stop: StopFence, work: F) -> Option<T>
where
    T: Send + 'static,
    F: FnOnce(&Checkpoint) -> T + Send + 'static,
{
    if stop.is_cancelled() {
        return None;
    }
    let checkpoint = Checkpoint { stop: stop.clone() };
    let mut task = tokio::task::spawn_blocking(move || {
        if !checkpoint.open() {
            return None;
        }
        Some(work(&checkpoint))
    });
    tokio::select! {
        biased;
        result = &mut task => result.ok().flatten().filter(|_| !stop.is_cancelled()),
        _ = stop.cancelled() => {
            // Abort prevents a queued worker from starting. Once its closure has started,
            // Tokio cannot interrupt its syscall; dropping this handle still guarantees that
            // its result is never observed by the request.
            task.abort();
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;
    use std::fs;
    use std::path::{Path, PathBuf};

    #[tokio::test]
    async fn a_fired_fence_refuses_to_start_work() {
        let fence = StopFence::new();
        fence.cancel();
        assert!(spawn(fence, |_| panic!("the worker started")).await.is_none());
    }

    #[tokio::test]
    async fn a_result_finished_after_stop_is_dropped() {
        let fence = StopFence::new();
        let worker = fence.clone();
        let result = spawn(fence, move |_| {
            worker.cancel();
            String::from("late")
        })
        .await;
        assert!(result.is_none());
    }

    fn rust_files(root: &Path, out: &mut Vec<PathBuf>) {
        let Ok(entries) = fs::read_dir(root) else { return };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                rust_files(&path, out);
            } else if path.extension().is_some_and(|ext| ext == "rs") {
                out.push(path);
            }
        }
    }

    #[test]
    fn bare_request_blockers_are_in_the_migration_allowlist() {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src");
        let mut files = Vec::new();
        for dir in [root.join("server"), root.join("hub")] {
            rust_files(&dir, &mut files);
        }
        let allowlisted = include_str!("blocking_allowlist.txt")
            .lines()
            .filter(|line| !line.trim().is_empty() && !line.starts_with('#'))
            .filter_map(|line| line.split_once('#').map(|(site, _)| site.trim()))
            .map(str::to_owned)
            .collect::<BTreeSet<_>>();
        let mut found = BTreeSet::new();
        for file in files {
            let relative = file.strip_prefix(&root).unwrap_or(&file);
            let relative = relative.to_string_lossy();
            if relative.ends_with("_tests.rs") || relative.ends_with("/tests.rs") {
                continue;
            }
            let Ok(text) = fs::read_to_string(&file) else { continue };
            for (line, source) in text.lines().enumerate() {
                if source.contains("tokio::task::spawn_blocking") {
                    found.insert(format!("{relative}:{}", line + 1));
                }
            }
        }
        assert_eq!(found, allowlisted, "new bare blocking sites need a migration decision");
    }
}
