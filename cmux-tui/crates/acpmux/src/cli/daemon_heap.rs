//! `acpmux daemon heap-dump`: the running daemon's sampled heap profile (`heap_sample.rs`), from
//! `_acpmux/heap_profile` with `sample`: the stacks holding the most bytes now, and the biggest
//! resident mappings beside, so a growing daemon's heap is named by allocation site without
//! ptrace or a profiler build.

use anyhow::Result;
use serde_json::{Map, Value, json};
use std::fmt::Write as _;

use crate::rpc::method;

/// `acpmux daemon heap-dump`.
pub async fn run(start: Option<usize>, stop: bool, top: usize, json_out: bool) -> Result<()> {
    let client = crate::daemon::connect(false).await?;
    let v = client.request(method::MUX_HEAP_PROFILE, params(start, stop, top)).await?;
    if json_out {
        crate::cli::output::print_json(&v);
    } else {
        print!("{}", render(&v));
    }
    Ok(())
}

fn params(start: Option<usize>, stop: bool, top: usize) -> Value {
    let mut sample = Map::new();
    if let Some(rate) = start {
        sample.insert("start".into(), rate.into());
    }
    if stop {
        sample.insert("stop".into(), true.into());
    }
    sample.insert("top".into(), top.into());
    json!({ "sample": sample })
}

fn human(bytes: u64) -> String {
    const UNITS: [&str; 4] = ["B", "KB", "MB", "GB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit + 1 < UNITS.len() {
        value /= 1024.0;
        unit += 1;
    }
    if unit == 0 { format!("{bytes} B") } else { format!("{value:.1} {}", UNITS[unit]) }
}

fn num(v: &Value, key: &str) -> u64 {
    v.get(key).and_then(Value::as_u64).unwrap_or(0)
}

/// The report as text: the state line, the top stacks by bytes held (each with its first acpmux
/// frames), and the biggest mappings.
fn render(v: &Value) -> String {
    let mut out = String::new();
    let Some(s) = v.get("sample") else {
        let _ = writeln!(out, "this daemon has no sampled heap profile (older build)");
        return out;
    };
    let on = s.get("on").and_then(Value::as_bool).unwrap_or(false);
    let _ = writeln!(
        out,
        "sampling {} at one per {}; {} held by {} sampled blocks over {} stacks (dropped: {} blocks, {} stacks)",
        if on { "on" } else { "off" },
        human(num(s, "rate")),
        human(num(s, "liveBytes")),
        num(s, "liveBlocks"),
        num(s, "stacks"),
        num(s, "droppedSlots"),
        num(s, "droppedStacks"),
    );
    if !on && num(s, "stacks") == 0 {
        let _ = writeln!(out, "start it with `acpmux daemon heap-dump --start`, then ask again");
    }
    if let Some(rows) = s.get("byLive").and_then(Value::as_array) {
        for (i, row) in rows.iter().enumerate() {
            let _ = writeln!(
                out,
                "\n#{} {} held in {} sampled blocks ({} allocated since start)",
                i + 1,
                human(num(row, "liveBytes")),
                num(row, "liveBlocks"),
                human(num(row, "totalBytes")),
            );
            let frames = row.get("frames").and_then(Value::as_array).cloned().unwrap_or_default();
            for frame in frames.iter().filter_map(Value::as_str).take(12) {
                let _ = writeln!(out, "    {frame}");
            }
        }
    }
    if let Some(maps) = s.get("mappings").filter(|m| !m.is_null()) {
        let _ = writeln!(
            out,
            "\nresident {} ({} anonymous) in {} mappings; the biggest:",
            human(num(maps, "rssKib") * 1024),
            human(num(maps, "anonKib") * 1024),
            num(maps, "count"),
        );
        for m in maps.get("top").and_then(Value::as_array).into_iter().flatten() {
            let _ = writeln!(
                out,
                "  {:>10}  {}",
                human(num(m, "rssKib") * 1024),
                m.get("mapping").and_then(Value::as_str).unwrap_or("")
            );
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn params_carry_start_stop_and_top() {
        assert_eq!(params(None, false, 5), json!({"sample": {"top": 5}}));
        assert_eq!(
            params(Some(4096), true, 7),
            json!({"sample": {"start": 4096, "stop": true, "top": 7}})
        );
    }

    #[test]
    fn render_names_the_top_stack_and_mappings() {
        let v = json!({"available": true, "sample": {
            "on": true, "rate": 524288, "liveBytes": 3u64 << 30, "liveBlocks": 6000,
            "stacks": 2, "droppedSlots": 0, "droppedStacks": 0,
            "byLive": [{"liveBytes": 3u64 << 30, "liveBlocks": 6000, "totalBytes": 4u64 << 30,
                        "frames": ["acpmux::hub::book::push (src/hub/book.rs:10)"]}],
            "mappings": {"count": 3, "rssKib": 4 << 20, "anonKib": 3 << 20,
                         "top": [{"rssKib": 3 << 20, "mapping": "7f00-7f80 rw-p 3072 MiB [anon]"}]},
        }});
        let text = render(&v);
        assert!(text.starts_with("sampling on at one per 512.0 KB; 3.0 GB held"), "{text}");
        assert!(text.contains("#1 3.0 GB held in 6000 sampled blocks"), "{text}");
        assert!(text.contains("acpmux::hub::book::push"), "{text}");
        assert!(text.contains("resident 4.0 GB (3.0 GB anonymous)"), "{text}");
    }

    #[test]
    fn render_says_an_older_daemon_has_none() {
        assert!(render(&json!({"available": false})).contains("older build"));
    }
}
