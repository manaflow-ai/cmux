//! A harness binary that an update is replacing. `npm install --global`
//! removes the package and its bin link, then writes them again, so for
//! several seconds `/opt/homebrew/bin/claude` does not exist. Claude Code's
//! own auto-updater does this whenever any running copy finds a newer
//! version, so a chat started in that window failed with "spawn harness
//! process: No such file or directory". A start waits, within a budget, for
//! the program to come back, and starts once more when it vanished between
//! the check and the spawn.

use super::*;
use notify::Watcher as _;
use std::time::Duration;

/// How long a start waits for a missing harness binary to come back. An npm
/// reinstall of Claude Code takes about 10 to 30 seconds end to end.
pub const PROGRAM_BUDGET: Duration = Duration::from_secs(30);

/// [`link::spawn`], waiting up to [`PROGRAM_BUDGET`] for a harness binary
/// that is being replaced.
pub async fn spawn(launcher: &link::HostLauncher, spec: &SpawnSpec) -> Result<HostRecord> {
    spawn_within(launcher, spec, PROGRAM_BUDGET).await
}

/// [`spawn`] with the wait's budget given by the caller.
pub async fn spawn_within(
    launcher: &link::HostLauncher,
    spec: &SpawnSpec,
    budget: Duration,
) -> Result<HostRecord> {
    // A refused launch is refused now, not after the wait.
    crate::launch_policy::refuse_if_disabled()?;
    wait_for_program(&spec.program, budget).await?;
    match link::spawn(launcher, spec).await {
        // Gone again between the check and the host's spawn: the same
        // update is still writing it.
        Err(_) if missing(&spec.program) => {
            wait_for_program(&spec.program, budget).await?;
            link::spawn(launcher, spec).await
        }
        started => started,
    }
}

/// An absolute program path that does not resolve to a file now. A bare
/// name is looked up on the harness's PATH by the host, so it is never
/// waited for here.
fn missing(program: &str) -> bool {
    let path = Path::new(program);
    path.is_absolute()
        && matches!(std::fs::metadata(path), Err(e) if e.kind() == std::io::ErrorKind::NotFound)
}

/// Returns once `program` exists, or fails after `budget`. Watches the
/// nearest existing folder above it, so a removed package folder that
/// comes back is followed down to the program.
pub async fn wait_for_program(program: &str, budget: Duration) -> Result<()> {
    if !missing(program) {
        return Ok(());
    }
    tracing::info!(program, "harness program is missing; waiting for it to come back");
    let path = Path::new(program).to_path_buf();
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    let mut watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
        if !matches!(&event, Ok(e) if e.kind.is_access()) {
            let _ = tx.send(());
        }
    })
    .with_context(|| format!("watch for {program}"))?;
    let mut watched: Vec<PathBuf> = Vec::new();
    let came_back = within("program wait", budget, async {
        loop {
            // Watch before checking, so a program written in between is
            // seen by the check or wakes the next wait.
            let wanted = watch_dirs(&path);
            for old in watched.iter().filter(|d| !wanted.contains(d)) {
                let _ = watcher.unwatch(old);
            }
            watched.retain(|d| wanted.contains(d));
            let mut vanished = false;
            for dir in wanted {
                if watched.contains(&dir) {
                    continue;
                }
                match watcher.watch(&dir, notify::RecursiveMode::NonRecursive) {
                    Ok(()) => watched.push(dir),
                    // Removed since it was found: the update is still at
                    // work; look again for the folder above it.
                    Err(e) if not_found(&e) => vanished = true,
                    Err(e) => return Err(anyhow!(e).context(format!("watch {}", dir.display()))),
                }
            }
            if !missing(program) {
                return Ok::<_, anyhow::Error>(());
            }
            if vanished {
                continue;
            }
            if rx.recv().await.is_none() {
                bail!("the watch for {program} ended");
            }
        }
    })
    .await;
    match came_back {
        Ok(result) => result,
        Err(_) => {
            bail!("{program} was not found (waited {budget:?} in case an update was replacing it)")
        }
    }
}

/// The folders whose changes can bring `path` back: the nearest existing
/// folder above it and, when it is a link whose target is gone (npm keeps
/// the bin link and swaps the package folder), the nearest existing folder
/// above each target along the link chain.
fn watch_dirs(path: &Path) -> Vec<PathBuf> {
    let mut dirs: Vec<PathBuf> = nearest_existing_ancestor(path).into_iter().collect();
    let mut link = path.to_path_buf();
    // A bounded chain: a loop of links never resolves.
    for _ in 0..8 {
        let Ok(target) = std::fs::read_link(&link) else { break };
        let target = match link.parent() {
            Some(parent) if target.is_relative() => parent.join(target),
            _ => target,
        };
        if let Some(dir) = nearest_existing_ancestor(&target)
            && !dirs.contains(&dir)
        {
            dirs.push(dir);
        }
        link = target;
    }
    dirs
}

fn not_found(e: &notify::Error) -> bool {
    match &e.kind {
        notify::ErrorKind::PathNotFound => true,
        notify::ErrorKind::Io(io) => io.kind() == std::io::ErrorKind::NotFound,
        _ => false,
    }
}

fn nearest_existing_ancestor(path: &Path) -> Option<PathBuf> {
    path.ancestors().skip(1).find(|dir| dir.is_dir()).map(Path::to_path_buf)
}
