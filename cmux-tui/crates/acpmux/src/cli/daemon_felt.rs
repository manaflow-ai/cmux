//! `acpmux daemon felt`: the running daemon's felt-latency histograms (`cmux-felt`, the net graph),
//! from `_acpmux/felt_snapshot`: p50, p90 and p99 of what a person feels, over the last minute and
//! since start. Names and numbers only.

use anyhow::Result;
use serde_json::{Value, json};
use std::fmt::Write as _;

use crate::rpc::method;

/// `acpmux daemon felt`.
pub async fn run(json_out: bool) -> Result<()> {
    let client = crate::daemon::connect(false).await?;
    let v = client.request(method::MUX_FELT_SNAPSHOT, json!({})).await?;
    if json_out {
        crate::cli::output::print_json(&v);
    } else {
        print!("{}", render(&v));
    }
    Ok(())
}

/// A percentile in microseconds as milliseconds, or a dash with no samples.
fn ms(v: &Value, key: &str) -> String {
    match v.get(key).and_then(Value::as_u64) {
        Some(us) => format!("{:.1}", us as f64 / 1000.0),
        None => "-".to_owned(),
    }
}

/// The `_acpmux/felt_snapshot` answer `v` as a table (milliseconds), one row per metric and window.
pub(crate) fn render(v: &Value) -> String {
    let mut out = String::from(
        "metric                       window       count    p50    p90    p99    max (ms)\n",
    );
    let Some(metrics) = v.get("metrics").and_then(Value::as_object) else {
        return out;
    };
    for (name, windows) in metrics {
        for window in ["last_60s", "since_start"] {
            let Some(w) = windows.get(window) else { continue };
            let count = w.get("count").and_then(Value::as_u64).unwrap_or(0);
            if count == 0 {
                continue;
            }
            let _ = writeln!(
                out,
                "{name:<28} {window:<11} {count:>6} {:>6} {:>6} {:>6} {:>6}",
                ms(w, "p50_us"),
                ms(w, "p90_us"),
                ms(w, "p99_us"),
                ms(w, "max_us"),
            );
        }
    }
    out
}

#[cfg(test)]
#[path = "daemon_felt_tests.rs"]
mod tests;
