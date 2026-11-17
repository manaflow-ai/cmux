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
    use std::collections::BTreeMap;
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

    fn count_bare_sites(text: &str) -> usize {
        let lines = text.lines().collect::<Vec<_>>();
        let mut depth = 0i32;
        let mut test_depth = None;
        let mut pending_test = false;
        let mut found = 0;
        for (line, source) in lines.iter().enumerate() {
            let delta = source.matches('{').count() as i32 - source.matches('}').count() as i32;
            if source.contains("#[cfg(test)]") {
                pending_test = true;
            }
            if pending_test && source.contains(';') && !source.contains('{') {
                pending_test = false;
            }
            if pending_test && source.contains('{') {
                test_depth = Some(depth + delta);
                pending_test = false;
            }
            let in_test = test_depth.is_some_and(|start| depth >= start);
            let trimmed = source.trim_start();
            let is_site = source.contains("spawn_blocking") || source.contains("block_in_place");
            let exempt = line > 0
                && (lines[line - 1].trim_start().starts_with("// bare blocking (shutdown):")
                    || lines[line - 1].trim_start().starts_with("// bare blocking (daemon):"));
            if !in_test && !trimmed.starts_with("//") && is_site && !exempt {
                found += 1;
            }
            depth += delta;
            if test_depth.is_some_and(|start| depth < start) {
                test_depth = None;
            }
        }
        found
    }

    #[test]
    fn bare_request_blockers_are_in_the_migration_allowlist() {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src");
        let mut files = Vec::new();
        rust_files(&root, &mut files);
        let allowlisted = include_str!("blocking_allowlist.txt")
            .lines()
            .filter(|line| !line.trim().is_empty() && !line.starts_with('#'))
            .filter_map(|line| line.split_once('='))
            .filter_map(|(path, count)| {
                Some((path.trim().to_owned(), count.trim().parse::<usize>().ok()?))
            })
            .collect::<BTreeMap<_, _>>();
        let mut found = BTreeMap::<String, usize>::new();
        for file in files {
            let relative = file.strip_prefix(&root).unwrap_or(&file);
            let relative = relative.to_string_lossy().into_owned();
            if relative == "blocking.rs"
                || relative.ends_with("_tests.rs")
                || relative.ends_with("/tests.rs")
            {
                continue;
            }
            let Ok(text) = fs::read_to_string(&file) else { continue };
            let count = count_bare_sites(&text);
            if count > 0 {
                found.insert(relative, count);
            }
        }
        let mut mismatches = Vec::new();
        for (path, count) in &found {
            if !allowlisted.get(path).is_some_and(|expected| count <= expected) {
                mismatches.push(format!("a new bare site needs a decision: {path} = {count}"));
            }
        }
        for (path, count) in &allowlisted {
            if !found.get(path).is_some_and(|actual| actual >= count) {
                mismatches.push(format!("lower the number: {path} = {count}"));
            }
        }
        assert!(mismatches.is_empty(), "{}", mismatches.join("\n"));
    }

    #[test]
    fn cfg_test_module_declaration_does_not_hide_following_production_code() {
        let source = r#"
#[cfg(test)]
mod tests;
use crate::{one, two};

fn production() {
    let _ = tokio::task::spawn_blocking(|| 1);
}
"#;
        assert_eq!(count_bare_sites(source), 1);
    }
}
