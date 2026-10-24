//! `acpmux peer status` (also `host status`): one line per machine from
//! `_acpmux/peer_status` (`server/peer_status.rs`).

use serde_json::Value;

/// The lines `peer status` prints for `reply`.
pub fn lines(reply: &Value) -> Vec<String> {
    let hosts = reply.get("hosts").and_then(Value::as_array).cloned().unwrap_or_default();
    hosts.iter().map(line).collect()
}

pub fn print(reply: &Value) {
    for l in lines(reply) {
        println!("{l}");
    }
}

fn line(h: &Value) -> String {
    let name = h.get("name").and_then(Value::as_str).unwrap_or("?");
    let me = h.get("self").and_then(Value::as_bool).unwrap_or(false);
    let label = if me { format!("{name} (this)") } else { name.to_owned() };
    if !h.get("reachable").and_then(Value::as_bool).unwrap_or(false) {
        let why = h.get("error").and_then(Value::as_str).unwrap_or("unreachable");
        return format!("{label:<20} unreachable  {why}");
    }
    let mut parts = Vec::new();
    if let Some(ms) = h.get("latencyMs").and_then(Value::as_u64) {
        parts.push(format!("{ms} ms"));
    }
    if let (Some(free), Some(total)) = (
        h.pointer("/disk/freeBytes").and_then(Value::as_u64),
        h.pointer("/disk/totalBytes").and_then(Value::as_u64),
    ) {
        parts.push(format!("disk {} free of {}", gb(free), gb(total)));
    }
    if let Some(load) = h.get("load").and_then(Value::as_array) {
        let cpus = h.get("cpus").and_then(Value::as_u64).unwrap_or(0);
        let one = load.first().and_then(Value::as_f64).unwrap_or(0.0);
        parts.push(format!("load {one:.1}/{cpus} cpus"));
    }
    if let Some(n) = h.get("liveSessions").and_then(Value::as_u64) {
        parts.push(format!("{n} live sessions"));
    }
    if let Some(b) = h.get("build").and_then(Value::as_str) {
        parts.push(format!("build {b}"));
    }
    let mut out = format!("{label:<20} ok  {}", parts.join("  "));
    if h.get("outdated").and_then(Value::as_bool).unwrap_or(false) {
        out.push_str(&format!("  (differs from this build: acpmux host update {name})"));
    }
    if let Some(e) = h.get("error").and_then(Value::as_str) {
        out.push_str(&format!("  ({e})"));
    }
    out
}

fn gb(bytes: u64) -> String {
    format!("{:.1} GB", bytes as f64 / 1e9)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_reachable_peer_reads_its_numbers_and_an_unreachable_one_its_next_step() {
        let reply = json!({"hosts": [
            {"name": "huge-blue", "self": true, "reachable": true, "cpus": 32, "load": [3.2, 2.0, 1.0],
             "disk": {"freeBytes": 25_000_000_000u64, "totalBytes": 252_000_000_000u64},
             "liveSessions": 9, "build": "abc"},
            {"name": "big-red", "self": false, "reachable": false,
             "error": "connection refused; `acpmux host doctor big-red` checks it step by step"},
            {"name": "cmux16", "self": false, "reachable": true, "latencyMs": 41, "outdated": true,
             "build": "old"},
        ]});
        let l = lines(&reply);
        assert_eq!(
            l[0],
            "huge-blue (this)     ok  disk 25.0 GB free of 252.0 GB  load 3.2/32 cpus  9 live sessions  build abc"
        );
        assert!(
            l[1].starts_with("big-red              unreachable  connection refused;"),
            "{}",
            l[1]
        );
        assert!(l[1].ends_with("`acpmux host doctor big-red` checks it step by step"), "{}", l[1]);
        assert!(l[2].contains("41 ms") && l[2].contains("acpmux host update cmux16"), "{}", l[2]);
    }
}
