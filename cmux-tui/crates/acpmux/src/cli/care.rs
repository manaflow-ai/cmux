//! `acpmux care status|clean|why|tick|install-timer` (also `cmux care ...`): keep this
//! machine's disk under budget (`cmux_worktree_care::care`).
//!
//! - `status`: the disk now (one `statvfs`), its budget and forecast, and what each family would
//!   free as the last whole pass found it (the timer's, a daemon's or a `clean`). No walk, no git,
//!   no write: it answers in milliseconds however big the tree. Changes nothing.
//! - `clean`: a pass now, under the budget; `--dry-run` measures everything afresh without acting
//!   (and records what it found for `status`); `--family F` limits it.
//! - `why PATH`: what the ledger recorded for it, whether the never-delete list holds it.
//! - `tick`: the cheap headless pass the timer runs every five minutes: samples the disk and runs a
//!   pass when one is due, under the machine's claim (a daemon's worker takes the same).
//! - `install-timer`: the systemd --user timer (Linux) or LaunchAgent (macOS) that runs `tick`.
//!
//! In-process, as `acpmux worktree` is: the machine's claim keeps it from running with a daemon's
//! pass, and the sessions come from every state folder on disk.

use std::path::PathBuf;

use anyhow::{Result, anyhow};
use clap::Subcommand;
use cmux_worktree_care::budget::{Forecast, Plan};
use cmux_worktree_care::care::{self, FamilySummary, Report};
use cmux_worktree_care::disk::Usage;
use cmux_worktree_care::inventory::now_ms;
use serde_json::json;

use crate::care_machine::{self, Ask, Tick};
use crate::cli::output::print_json;

#[derive(Subcommand, Debug, PartialEq, Eq)]
pub enum CareCmd {
    /// The disk, its budget and forecast, and what each family would free (as of the last pass).
    Status,
    /// A pass now, under the disk budget.
    Clean {
        /// Only report: a whole scan now, acting on nothing.
        #[arg(long)]
        dry_run: bool,
        /// Only this family (repeatable), e.g. worktrees, npm-cache, tmp-files.
        #[arg(long = "family")]
        families: Vec<String>,
    },
    /// Why a path was kept or removed: the ledger's rows and the never-delete list.
    Why { path: PathBuf },
    /// Sample the disk and run a pass if one is due (what the timer runs).
    Tick {
        /// Run the pass even if auto cleanup is off.
        #[arg(long)]
        force: bool,
    },
    /// Install the timer that runs `tick` every five minutes (idempotent).
    InstallTimer,
}

pub fn run(cmd: CareCmd, json_out: bool) -> Result<()> {
    match cmd {
        CareCmd::Status => status(json_out),
        CareCmd::Clean { dry_run, families } => pass(!dry_run, families, json_out),
        CareCmd::Why { path } => why(path, json_out),
        CareCmd::Tick { force } => match care_machine::tick(force).map_err(|e| anyhow!(e))? {
            Tick::Off => {
                emit(json_out, json!({"ran": false, "reason": "auto cleanup is off"}), || {
                    println!("care: auto cleanup is off (worktrees.autoCleanup)");
                })
            }
            Tick::NotDue { used, next_in_ms } => emit(
                json_out,
                json!({"ran": false, "reason": "not due", "used": used, "spacingMs": next_in_ms}),
                || {
                    println!(
                        "care: {:.0}% used, no pass due (spacing {} min)",
                        used * 100.0,
                        next_in_ms / 60_000
                    );
                },
            ),
            Tick::Ran(report) => {
                if json_out {
                    print_json(&json!({"ran": true, "report": &*report}));
                } else {
                    print_report(&report);
                }
                Ok(())
            }
        },
        CareCmd::InstallTimer => {
            let lines = care_machine::install_timer().map_err(|e| anyhow!(e))?;
            emit(json_out, json!({"installed": &lines}), || {
                for line in &lines {
                    println!("{line}");
                }
            })
        }
    }
}

fn emit(json_out: bool, value: serde_json::Value, human: impl FnOnce()) -> Result<()> {
    if json_out {
        print_json(&value);
    } else {
        human();
    }
    Ok(())
}

fn pass(apply: bool, families: Vec<String>, json_out: bool) -> Result<()> {
    let home = dirs::home_dir().ok_or_else(|| anyhow!("no home folder"))?;
    let store = care_machine::store().map_err(|e| anyhow!(e))?;
    let claim = if apply {
        Some(
            cmux_worktree_care::schedule::claim(&store.dir, now_ms(), None, families.is_empty())
                .map_err(|refused| match refused {
                    cmux_worktree_care::schedule::Refused::Unavailable(error) => anyhow!(error),
                    _ => anyhow!("a care pass is already running on this machine"),
                })?,
        )
    } else {
        None
    };
    let config = care_machine::config(
        &home,
        store,
        Vec::new(),
        None,
        Ask { apply, only: Vec::new(), only_families: families, roots: Vec::new(), pressure: None },
    );
    let report = care::run(&config, None);
    if let Some(claim) = claim
        && let Err(error) = claim.finish(now_ms())
    {
        eprintln!("acpmux: could not record the care pass: {error}");
    }
    let report = report.map_err(|e| anyhow!(e))?;
    if json_out {
        print_json(&json!(report));
    } else {
        print_report(&report);
    }
    Ok(())
}

/// The volume now and the last whole pass's report: no walk, no git.
fn status(json_out: bool) -> Result<()> {
    let home = dirs::home_dir().ok_or_else(|| anyhow!("no home folder"))?;
    let store = care_machine::store().map_err(|e| anyhow!(e))?;
    let status = care::status(&home, &store, &Default::default())
        .ok_or_else(|| anyhow!("cannot read the disk's size"))?;
    let look = &status.look;
    if json_out {
        // The last report's shape, with the volume, budget and forecast of now.
        let mut value = status
            .last
            .as_ref()
            .map(|last| last.report.clone())
            .filter(serde_json::Value::is_object)
            .unwrap_or_else(|| json!({"families": []}));
        if let Some(object) = value.as_object_mut() {
            object.insert("disk".into(), json!(look.usage));
            object.insert("budget".into(), json!(look.plan));
            object.insert("forecast".into(), json!(look.forecast));
            object.insert("lastPassAtMs".into(), json!(status.last.as_ref().map(|l| l.at_ms)));
            object.insert("lastPassTookMs".into(), json!(status.last.as_ref().map(|l| l.took_ms)));
        }
        print_json(&value);
        return Ok(());
    }
    print_disk(look.usage, &look.plan, &look.forecast);
    let Some(last) = &status.last else {
        println!(
            "no pass recorded yet: the timer's next one records it (`cmux care clean --dry-run` measures now)"
        );
        return Ok(());
    };
    let age_min = now_ms().saturating_sub(last.at_ms) / 60_000;
    println!(
        "last pass {age_min} min ago ({}, took {:.1} s):",
        if last.applied() { "cleaned" } else { "dry run" },
        last.took_ms as f64 / 1000.0
    );
    print_families(&last.families());
    for error in last.errors() {
        println!("error    {error}");
    }
    if last.applied() {
        println!("freed {}; would free {} more", gib(last.freed()), gib(last.reclaimable()));
    } else {
        println!("would free {}", gib(last.reclaimable()));
    }
    Ok(())
}

fn why(path: PathBuf, json_out: bool) -> Result<()> {
    let home = dirs::home_dir().ok_or_else(|| anyhow!("no home folder"))?;
    let store = care_machine::store().map_err(|e| anyhow!(e))?;
    let path = if path.is_absolute() { path } else { std::env::current_dir()?.join(path) };
    let config = care_machine::config(
        &home,
        store,
        Vec::new(),
        None,
        Ask {
            apply: false,
            only: Vec::new(),
            only_families: Vec::new(),
            roots: Vec::new(),
            pressure: None,
        },
    );
    let why = care::why(&config, &path);
    if json_out {
        print_json(&json!(why));
        return Ok(());
    }
    println!("{}", why.path.display());
    if let Some(glob) = &why.never_delete {
        println!("  never-delete: held by {glob}");
    }
    match &why.now {
        Some(item) => {
            println!("  now: {} ({:?}): {}", item.family, item.verdict.action, item.verdict.reason)
        }
        None => {
            println!("  now: not in a cache family (worktrees: `cmux worktree list --only PATH`)")
        }
    }
    if why.ledger.is_empty() {
        println!("  ledger: nothing recorded");
    }
    for row in &why.ledger {
        println!(
            "  ledger: {} {} {} {} MiB {}{}",
            row.at_ms,
            row.family,
            row.action,
            row.bytes >> 20,
            row.reason,
            row.archive.as_ref().map(|a| format!(" (archive {a})")).unwrap_or_default()
        );
    }
    Ok(())
}

fn gib(bytes: u64) -> String {
    format!("{:.1} GiB", bytes as f64 / f64::from(1u32 << 30))
}

fn hours(h: Option<f64>) -> String {
    h.map_or_else(|| "never at this rate".into(), |h| format!("{h:.1} h"))
}

fn print_disk(disk: Usage, budget: &Plan, forecast: &Forecast) {
    println!(
        "disk {:.0}% used, {} free; pressure {:?}, budget 75% (over: {}, predicted: {})",
        disk.used_fraction() * 100.0,
        gib(disk.available),
        budget.pressure,
        budget.over_budget,
        budget.predicted
    );
    println!(
        "fill {}/h over {} samples; 75% in {}, 90% in {}; next pass spaced {} min",
        gib(forecast.fill_bytes_per_hour.unwrap_or(0.0).max(0.0) as u64),
        forecast.samples,
        hours(forecast.hours_to_target),
        hours(forecast.hours_to_critical),
        budget.spacing_ms / 60_000
    );
}

fn print_families(families: &[FamilySummary]) {
    for f in families {
        let mut tag = String::new();
        if !f.enabled {
            tag.push_str(" [off]");
        }
        if f.report_only {
            tag.push_str(" [report only]");
        }
        println!(
            "{:20} {:5} entries, {:>10} held, {:>10} reclaimable, {:>10} freed{tag}",
            f.name,
            f.entries,
            gib(f.bytes),
            gib(f.reclaimable),
            gib(f.freed)
        );
    }
}

fn print_report(report: &Report) {
    if let Some(disk) = report.disk {
        print_disk(disk, &report.budget, &report.forecast);
    }
    print_families(&report.families);
    for error in &report.errors {
        println!("error    {error}");
    }
    for problem in &report.never_delete_problems {
        println!("never-delete: {problem}");
    }
    if report.applied {
        println!(
            "freed {}; projected {:.0}% used{}",
            gib(report.freed),
            report.projected_fraction * 100.0,
            if report.stopped_at_budget { " (stopped: under budget)" } else { "" }
        );
    } else {
        println!("would free {}", gib(report.reclaimable));
    }
}
