//! `acpmux fetch URL -o FILE [--ranges 16] [--sha256 HEX]`: [`crate::range_fetch`] from the command
//! line, for tools and images that need one large file over a path where one stream is slow
//! (RFD 0067).

use anyhow::Result;
use clap::Args;
use serde_json::json;

use crate::cli::output::print_json;
use crate::range_fetch::{DEFAULT_RANGES, DEFAULT_THRESHOLD, Options, client, fetch_to_file};

#[derive(Args, Debug)]
pub struct FetchArgs {
    /// http(s) URL; redirects are followed.
    pub url: String,
    /// Where the file is written (renamed from FILE.part when whole and checked).
    #[arg(short, long, value_name = "FILE")]
    pub output: std::path::PathBuf,
    /// Parallel ranges for a file of --threshold bytes or more; 1 reads one stream.
    #[arg(long, default_value_t = DEFAULT_RANGES)]
    pub ranges: usize,
    /// Smaller files are read as one stream.
    #[arg(long, default_value_t = DEFAULT_THRESHOLD, value_name = "BYTES")]
    pub threshold: u64,
    /// The sha256 (hex) the file must have; a different file is not kept.
    #[arg(long, value_name = "HEX")]
    pub sha256: Option<String>,
}

pub async fn run(args: FetchArgs, json_out: bool) -> Result<()> {
    let opts = Options {
        ranges: args.ranges,
        threshold: args.threshold,
        sha256: args.sha256,
        adaptive: None,
    };
    let report = fetch_to_file(&client()?, &args.url, &args.output, &opts).await?;
    let secs = report.elapsed.as_secs_f64();
    let mbps = if secs > 0.0 { report.bytes as f64 / 1e6 / secs } else { 0.0 };
    if json_out {
        print_json(&json!({
            "path": args.output, "bytes": report.bytes, "ranges": report.ranges,
            "seconds": secs, "mbPerSecond": mbps,
        }));
    } else {
        println!(
            "{}: {} bytes in {secs:.1}s ({mbps:.1} MB/s, {} range{})",
            args.output.display(),
            report.bytes,
            report.ranges,
            if report.ranges == 1 { "" } else { "s" },
        );
    }
    Ok(())
}
