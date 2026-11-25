//! `acpmux machine deps warm|key|wait` (`crate::deps`), and the hidden
//! `upload` that `warm` starts detached after a cold install.
//!
//! `warm --json` prints `{dir, projects: [Report]}`; each report says what
//! the restore and upload did and how long each step took, never a credential.
//! It exits 1 only when an install failed.

use std::path::PathBuf;

use anyhow::Result;
use serde_json::json;

use crate::cli::command_host::DepsCmd;
use crate::cli::errors::{AppError, Code};
use crate::cli::output::print_json;
use crate::deps::archive::Codec;
use crate::deps::warm::{self, Options};

fn folder(dir: Option<PathBuf>) -> Result<PathBuf> {
    Ok(match dir {
        Some(dir) => dir,
        None => std::env::current_dir()?,
    })
}

pub async fn run(cmd: DepsCmd, json_out: bool) -> Result<()> {
    match cmd {
        DepsCmd::Warm { dir, no_upload, no_install, if_joined, if_missing, upload_now } => {
            let dir = folder(dir)?;
            if if_joined && !matches!(crate::deps::remote::Remote::joined(), Ok(Some(_))) {
                if json_out {
                    print_json(&json!({"dir": dir, "projects": [], "skipped": "not_joined"}));
                }
                return Ok(());
            }
            let reports = warm::warm(
                &dir,
                Options { install: !no_install, upload: !no_upload, if_missing, upload_now },
            )
            .await;
            if json_out {
                print_json(&json!({"dir": dir, "projects": reports}));
            } else if reports.is_empty() {
                println!("deps: no lockfile in {}", dir.display());
            } else {
                for r in &reports {
                    let secs = |ms: u64| ms as f64 / 1000.0;
                    println!(
                        "deps {}: {}{} (fetch {:.1}s, unpack {:.1}s, install {:.1}s{}){}",
                        r.ecosystem,
                        r.restore,
                        r.upload.map(|u| format!(", upload {u}")).unwrap_or_default(),
                        secs(r.fetch_ms),
                        secs(r.unpack_ms),
                        secs(r.install_ms),
                        if r.upload.is_some() {
                            format!(
                                ", pack {:.1}s, upload {:.1}s",
                                secs(r.pack_ms),
                                secs(r.upload_ms)
                            )
                        } else {
                            String::new()
                        },
                        r.error.as_deref().map(|e| format!(": {e}")).unwrap_or_default(),
                    );
                }
            }
            if reports.iter().any(|r| r.install_ok == Some(false)) {
                return Err(AppError::new(
                    Code::Runtime,
                    "deps.install_failed",
                    "an install failed",
                )
                .into());
            }
            Ok(())
        }
        DepsCmd::Upload { key, root, include, codec, cold_ms } => {
            let codec = match codec.as_str() {
                "zstd" => Codec::Zstd,
                "gzip" => Codec::Gzip,
                _ => {
                    return Err(
                        AppError::new(Code::Usage, "deps.codec", "codec is zstd or gzip").into()
                    );
                }
            };
            let outcome = warm::upload(&key, &root, &include, codec, cold_ms).await?;
            if json_out {
                print_json(&json!({"key": key, "upload": outcome}));
            }
            Ok(())
        }
        DepsCmd::Wait => {
            let waited = warm::wait_uploads()?;
            if json_out {
                print_json(&json!({"waited": waited}));
            }
            Ok(())
        }
        DepsCmd::Key { dir } => {
            let dir = folder(dir)?;
            let rows: Vec<_> = warm::keys(&dir)
                .into_iter()
                .map(|(project, plan, key)| {
                    json!({
                        "ecosystem": project.ecosystem.name(),
                        "lockfile": project.lockfile,
                        "key": key.as_ref().ok(),
                        "error": key.as_ref().err().map(|e| e.to_string()),
                        "root": plan.as_ref().map(|p| &p.root),
                        "include": plan.as_ref().map(|p| &p.include),
                        "install": plan.as_ref().map(|p| &p.install),
                    })
                })
                .collect();
            if json_out {
                print_json(&json!({"dir": dir, "projects": rows}));
            } else {
                for row in &rows {
                    println!(
                        "{} {}",
                        row["ecosystem"].as_str().unwrap_or_default(),
                        row["key"].as_str().unwrap_or("(no key)")
                    );
                }
            }
            Ok(())
        }
    }
}
