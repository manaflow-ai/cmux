//! The CLI's lines for the host's CPU and RAM budget (`host_pressure.rs`): the
//! `daemon status` host line and the warning a send prints. Warns only.

use serde_json::Value;

/// `daemon status`'s host line from its `host_pressure` (`host_pressure.rs`): the
/// warning when over budget, else the load against its limit. `None` from a daemon
/// that predates it.
pub(crate) fn host_pressure_line(p: &Value) -> Option<String> {
    if let Some(warning) = p.get("warning").and_then(Value::as_str) {
        return Some(warning.to_owned());
    }
    let limit = p.get("load_limit").and_then(Value::as_f64)?;
    let load = p.get("load1").and_then(Value::as_f64).map_or("?".into(), |l| format!("{l:.1}"));
    Some(format!(
        "within budget: load1 {load} < {limit} ({} {} cores), memory pressure {}",
        p.get("cores").and_then(Value::as_u64).unwrap_or(0),
        p.get("cores_kind").and_then(Value::as_str).unwrap_or(""),
        p.get("pressure").and_then(Value::as_str).unwrap_or("unknown"),
    ))
}

/// Prints an acceptance's host warning (`host_pressure.warning`) to stderr: the
/// sender learns the target host is over its CPU/RAM budget. Nothing is held.
pub(crate) fn warn_host_pressure(accepted: &Value) {
    if let Some(line) = accepted.pointer("/host_pressure/warning").and_then(Value::as_str) {
        eprintln!("{line}");
    }
}
