//! `acpmux memory`: the memory mount shared by your machines (`memory_mount.rs`) from a shell.
//! `sync` runs a pass (or the daemon's loop with `--watch`), `put`/`get`/`ls`/`history` reach the
//! store, `status` says how far this machine is behind, and `link` points a harness's memory
//! folder into the mount.

use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use clap::Subcommand;
use serde_json::json;

use crate::memory_mount::client::Client;
use crate::memory_mount::engine::{Engine, State};
use crate::memory_mount::link::{self, Harness};
use crate::memory_mount::{self as mm, Scope};

#[derive(Subcommand)]
pub enum MemoryCmd {
    /// Sync the memory folders with the store: one pass, or keep syncing with --watch.
    Sync {
        /// One scope; both when left out.
        #[arg(long, value_enum)]
        scope: Option<Scope>,
        /// The mount's root (default ~/.cmux/memory).
        #[arg(long)]
        dir: Option<PathBuf>,
        /// Keep syncing (as the daemon does) until interrupted.
        #[arg(long)]
        watch: bool,
    },
    /// Write a memory file (from --file or stdin) into the mount and publish it.
    Put {
        /// The path inside the scope, e.g. notes/fleet.md.
        path: String,
        #[arg(long, value_enum, default_value = "private")]
        scope: Scope,
        /// Read the bytes from this file instead of stdin.
        #[arg(long)]
        file: Option<PathBuf>,
        #[arg(long)]
        dir: Option<PathBuf>,
    },
    /// Print a memory file as the store has it.
    Get {
        path: String,
        #[arg(long, value_enum, default_value = "private")]
        scope: Scope,
    },
    /// List the store's files.
    Ls {
        #[arg(long, value_enum, default_value = "private")]
        scope: Scope,
        /// Include deleted files.
        #[arg(long)]
        all: bool,
    },
    /// A memory file's versions.
    History {
        path: String,
        #[arg(long, value_enum, default_value = "private")]
        scope: Scope,
    },
    /// Last sequence number, lag behind the store, last error and pending changes per scope.
    Status {
        #[arg(long)]
        dir: Option<PathBuf>,
    },
    /// Point a harness's memory folder into the mount (dry run unless --apply).
    Link {
        #[arg(long, value_enum)]
        harness: Harness,
        /// Do it: merge the old folder in, move it aside, symlink.
        #[arg(long)]
        apply: bool,
        #[arg(long)]
        dir: Option<PathBuf>,
    },
}

fn root(dir: Option<PathBuf>) -> Result<PathBuf> {
    if let Some(dir) = dir {
        return Ok(dir);
    }
    let config = crate::config::Config::load().map(|c| c.memory).unwrap_or_default();
    mm::root(&config).context("no home folder for ~/.cmux/memory")
}

fn client() -> Result<Client> {
    Client::joined()?.context("this machine is not joined to cmux Cloud (acpmux cloud join)")
}

pub async fn run(cmd: MemoryCmd, json_out: bool) -> Result<()> {
    match cmd {
        MemoryCmd::Sync { scope, dir, watch } => {
            let root = root(dir)?;
            let client = client()?;
            let host = crate::hand::pair::hostname();
            let scopes: Vec<Scope> = scope.map(|s| vec![s]).unwrap_or_else(|| Scope::ALL.to_vec());
            if watch {
                let shutdown = tokio::sync::Notify::new();
                let mut runs = Vec::new();
                for scope in scopes {
                    runs.push(Engine::new(client.clone(), scope, &root, host.clone())?);
                }
                let stop = async {
                    let _ = tokio::signal::ctrl_c().await;
                    shutdown.notify_waiters();
                };
                let all = futures::future::join_all(runs.into_iter().map(|e| e.run(&shutdown)));
                tokio::select! { _ = all => {}, _ = stop => {} }
                return Ok(());
            }
            let mut reports = serde_json::Map::new();
            for scope in scopes {
                let mut engine = Engine::new(client.clone(), scope, &root, host.clone())?;
                let report = engine.pass().await?;
                if !json_out {
                    println!(
                        "{}: seq {}, pulled {}, pushed {}, deleted {}, merged {}, conflicts {}, refused {}",
                        scope.as_str(),
                        engine.state.last_seq,
                        report.pulled.len(),
                        report.pushed.len(),
                        report.deleted.len(),
                        report.merged.len(),
                        report.conflicts.len(),
                        report.refused.len()
                    );
                }
                reports.insert(scope.as_str().into(), serde_json::to_value(&report)?);
            }
            if json_out {
                println!("{}", serde_json::to_string_pretty(&reports)?);
            }
            Ok(())
        }
        MemoryCmd::Put { path, scope, file, dir } => {
            if !crate::memory_mount::engine::safe_rel(&path) || mm::skipped_name(&path) {
                bail!("{path}: not a path the memory sync carries");
            }
            let bytes = match file {
                Some(file) => {
                    std::fs::read(&file).with_context(|| format!("read {}", file.display()))?
                }
                None => {
                    use std::io::Read;
                    let mut buf = Vec::new();
                    std::io::stdin().read_to_end(&mut buf)?;
                    buf
                }
            };
            if bytes.len() as u64 > mm::MAX_FILE_BYTES {
                bail!("{path}: over the 256 KiB memory file limit");
            }
            let root = root(dir)?;
            let target = mm::scope_dir(&root, scope).join(&path);
            crate::memory_mount::engine::write_atomic(&target, &bytes)
                .with_context(|| format!("write {}", target.display()))?;
            // Publish now when no daemon holds the scope; else the daemon's watcher does.
            let published = match Engine::new(
                client()?,
                scope,
                &root,
                crate::hand::pair::hostname(),
            ) {
                Ok(mut engine) => {
                    let report = engine.pass().await?;
                    if report.refused.contains(&path) {
                        bail!(
                            "{path}: refused (a secret, or too large); it stays only on this machine"
                        );
                    }
                    true
                }
                Err(_) => false,
            };
            if json_out {
                println!("{}", json!({"path": target, "published": published}));
            } else if published {
                println!("{}: published", target.display());
            } else {
                println!("{}: written; the daemon's sync publishes it", target.display());
            }
            Ok(())
        }
        MemoryCmd::Get { path, scope } => {
            let bytes = client()?
                .get(scope, &path)
                .await?
                .with_context(|| format!("{path}: no such memory file"))?;
            use std::io::Write;
            std::io::stdout().write_all(&bytes)?;
            Ok(())
        }
        MemoryCmd::Ls { scope, all } => {
            let tree = client()?.tree(scope, 0).await?;
            let entries: Vec<_> = tree.entries.into_iter().filter(|e| all || !e.deleted).collect();
            if json_out {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&json!({"seq": tree.seq, "entries": entries}))?
                );
            } else {
                for e in entries {
                    let mark = if e.deleted { " (deleted)" } else { "" };
                    println!("{:>4}  {:>8}  {}{mark}", e.version, e.size, e.path);
                }
            }
            Ok(())
        }
        MemoryCmd::History { path, scope } => {
            let history = client()?.history(scope, &path).await?;
            println!("{}", serde_json::to_string_pretty(&history)?);
            Ok(())
        }
        MemoryCmd::Status { dir } => {
            let root = root(dir)?;
            let client = Client::joined().ok().flatten();
            let mut out = serde_json::Map::new();
            for scope in Scope::ALL {
                let state = State::load(&mm::state_dir(&root, scope));
                let pending =
                    crate::memory_mount::engine::pending(&mm::scope_dir(&root, scope), &state);
                let (remote, remote_error) = match &client {
                    Some(client) => match client.tree(scope, state.last_seq).await {
                        Ok(tree) => (Some(tree.seq), None),
                        Err(e) => (None, Some(format!("{e:#}"))),
                    },
                    None => (None, Some("not joined to cmux Cloud".to_owned())),
                };
                let lag = remote.map(|r| r.saturating_sub(state.last_seq));
                let row = json!({
                    "dir": mm::scope_dir(&root, scope),
                    "lastSeq": state.last_seq,
                    "remoteSeq": remote,
                    "lag": lag,
                    "lastOk": state.last_ok,
                    "lastError": state.last_error,
                    "remoteError": remote_error,
                    "files": state.files.values().filter(|b| !b.sha256.is_empty()).count(),
                    "pending": pending,
                    "refused": state.refused.keys().collect::<Vec<_>>(),
                });
                if !json_out {
                    println!(
                        "{}: last seq {}, store seq {}, lag {}, {} files, {} pending{}{}",
                        scope.as_str(),
                        state.last_seq,
                        remote.map_or("?".into(), |r| r.to_string()),
                        lag.map_or("?".into(), |l| l.to_string()),
                        row["files"],
                        pending.len(),
                        state
                            .last_error
                            .as_ref()
                            .map(|e| format!(", last error: {e}"))
                            .unwrap_or_default(),
                        remote_error.as_ref().map(|e| format!(", store: {e}")).unwrap_or_default(),
                    );
                }
                out.insert(scope.as_str().into(), row);
            }
            if json_out {
                println!("{}", serde_json::to_string_pretty(&out)?);
            }
            Ok(())
        }
        MemoryCmd::Link { harness, apply, dir } => {
            let root = root(dir)?;
            let home = dirs::home_dir().context("no home folder")?;
            let links = link::plan(harness, &home, &mm::scope_dir(&root, Scope::Private))?;
            if !apply {
                if json_out {
                    println!("{}", serde_json::to_string_pretty(&links)?);
                } else if links.is_empty() {
                    println!("Nothing to link.");
                } else {
                    for l in &links {
                        let what = if l.linked {
                            "linked already".to_owned()
                        } else {
                            format!("would link ({} files to merge)", l.files.len())
                        };
                        println!("{} -> {}: {what}", l.from.display(), l.to.display());
                    }
                    println!("Dry run: --apply links them.");
                }
                return Ok(());
            }
            let client = Client::joined().ok().flatten();
            let applied =
                link::apply(&links, client.as_ref(), &crate::hand::pair::hostname()).await?;
            if json_out {
                println!("{}", serde_json::to_string_pretty(&applied)?);
            } else {
                for a in &applied {
                    match &a.kept {
                        None => {
                            println!("{} -> {}: linked already", a.from.display(), a.to.display())
                        }
                        Some(kept) => println!(
                            "{} -> {}: linked ({} copied, {} replaced; old folder at {})",
                            a.from.display(),
                            a.to.display(),
                            a.copied.len(),
                            a.replaced.len(),
                            kept.display()
                        ),
                    }
                }
            }
            Ok(())
        }
    }
}
