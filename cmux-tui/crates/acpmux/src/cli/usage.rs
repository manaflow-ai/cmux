//! `acpmux usage insights`: why this machine's Claude Code sessions paid for each cache-write
//! token over the last hours, and the fix for each cause (`usage_insights.rs`). Local and on
//! demand: it reads transcripts only when run and sends nothing anywhere.

use anyhow::Result;
use clap::Subcommand;
use std::path::PathBuf;

use crate::usage_insights::{self, Transcript};

#[derive(Subcommand, Debug, Clone, PartialEq)]
pub enum UsageCmd {
    /// Cache writes by cause (session start, idle wake, compaction, model switch, shape change,
    /// lost under ttl, prefix edit), the gap over what the work needed, and each cause's fix.
    Insights {
        /// How many hours back.
        #[arg(long, default_value_t = 24.0)]
        hours: f64,
        /// Read these transcripts instead of ~/.claude*/projects.
        #[arg(long = "file", value_name = "PATH")]
        files: Vec<PathBuf>,
    },
}

/// `acpmux usage ...`.
pub fn run(cmd: UsageCmd, json_out: bool) -> Result<()> {
    match cmd {
        UsageCmd::Insights { hours, files } => insights(hours, files, json_out),
    }
}

fn insights(hours: f64, files: Vec<PathBuf>, json_out: bool) -> Result<()> {
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_secs_f64();
    let since = now - hours.max(0.0) * 3600.0;
    let paths = if files.is_empty() {
        let home = dirs::home_dir().ok_or_else(|| anyhow::anyhow!("no home folder"))?;
        usage_insights::transcripts_since(&usage_insights::default_roots(&home), since)
    } else {
        files
    };
    let texts: Vec<(String, bool)> = paths
        .iter()
        .filter_map(|p| Some((std::fs::read_to_string(p).ok()?, usage_insights::is_helper(p))))
        .collect();
    let transcripts: Vec<Transcript<'_>> =
        texts.iter().map(|(text, helper)| Transcript { text, helper: *helper }).collect();
    let report = usage_insights::analyze(&transcripts, since, &usage_insights::fallback_rates);
    if json_out {
        crate::cli::output::print_json(&serde_json::to_value(&report)?);
    } else {
        print!("{}", usage_insights::render(&report, hours));
    }
    Ok(())
}
