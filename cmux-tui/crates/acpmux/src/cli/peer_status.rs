//! `acpmux peer status` (also `host status`): one line per machine from
//! `_acpmux/peer_status` (`server/peer_status.rs`).

use serde_json::Value;

/// The lines `peer status` prints for `reply`: one per machine, then one
/// indented line per problem its health loop reports.
pub fn lines(reply: &Value) -> Vec<String> {
    let hosts = reply.get("hosts").and_then(Value::as_array).cloned().unwrap_or_default();
    hosts.iter().flat_map(|h| std::iter::once(line(h)).chain(problem_lines(h))).collect()
}

/// `  problem DNS: DNS: github.com does not resolve (since 2026-10-25T11:40:00.000Z)`;
/// a disk problem with a severity says it: `  problem disk (warning): ...`.
fn problem_lines(h: &Value) -> Vec<String> {
    h.get("problems")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|p| {
            let check = p.get("check")?.as_str()?;
            let detail = p.get("detail")?.as_str()?;
            let since = p.get("since").and_then(Value::as_str);
            let since = since.map(|s| format!(" (since {s})")).unwrap_or_default();
            let level = match p.get("severity").and_then(Value::as_str) {
                Some(level @ ("warning" | "critical")) => format!(" ({level})"),
                _ => String::new(),
            };
            Some(format!("  problem {}{level}: {detail}{since}", check_label(check)))
        })
        .collect()
}

/// The well-formed `{check, detail, since?}` entries of a health reading's `problems`.
fn problems(h: &Value) -> impl Iterator<Item = (&str, &str, Option<&str>)> {
    h.get("problems").and_then(Value::as_array).into_iter().flatten().filter_map(|p| {
        let check = p.get("check")?.as_str()?;
        let detail = p.get("detail")?.as_str()?;
        Some((check, detail, p.get("since").and_then(Value::as_str)))
    })
}

/// A check's short name, as `host ls` and the app's machine row show it.
fn check_label(check: &str) -> &str {
    match check {
        "dns" => "DNS",
        "disk" => "disk",
        "ram" => "RAM",
        "acpmux" => "acpmux",
        "cmux" => "cmux-tui",
        "peer" => "peer link",
        "loop" => "health check",
        other => other,
    }
}

/// `problems: DNS, peer link`: each check once, in the loop's order.
fn problem_summary(h: &Value) -> Option<String> {
    let mut labels: Vec<&str> = Vec::new();
    for (check, _, _) in problems(h) {
        let label = check_label(check);
        if !labels.contains(&label) {
            labels.push(label);
        }
    }
    (!labels.is_empty()).then(|| format!("problems: {}", labels.join(", ")))
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
    if let (Some(free), Some(total)) = (
        h.pointer("/ram/freeBytes").and_then(Value::as_u64),
        h.pointer("/ram/totalBytes").and_then(Value::as_u64),
    ) {
        parts.push(format!("ram {} free of {}", gb(free), gb(total)));
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

/// A `host ls` row's resources, from the peer's last health reading
/// (`peer_health.rs`): `ram 40.0 GB free  load 3.2/32  disk 25.0 GB free  9 live`,
/// `over budget` when its verdict says so, `problems: DNS, peer link` when its
/// health loop reports some (`host status NAME` prints the details),
/// `resources unknown` for a build
/// that does not report them or before the first reading.
pub fn resources(p: &Value) -> String {
    let Some(h) = p.get("health").filter(|h| h.is_object() && h.get("unsupported").is_none())
    else {
        return "resources unknown".to_owned();
    };
    let mut parts = Vec::new();
    if let Some(free) = h.pointer("/ram/freeBytes").and_then(Value::as_u64) {
        parts.push(format!("ram {} free", gb(free)));
    }
    if let Some(one) = h.pointer("/load/0").and_then(Value::as_f64) {
        let cpus = h.get("cpus").and_then(Value::as_u64).unwrap_or(0);
        parts.push(format!("load {one:.1}/{cpus}"));
    }
    if let Some(free) = h.pointer("/disk/freeBytes").and_then(Value::as_u64) {
        parts.push(format!("disk {} free", gb(free)));
    }
    if let Some(n) = h.get("liveSessions").and_then(Value::as_u64) {
        parts.push(format!("{n} live"));
    }
    if h.pointer("/pressure/ok").and_then(Value::as_bool) == Some(false) {
        parts.push("over budget".to_owned());
    }
    parts.extend(problem_summary(h));
    if parts.is_empty() { "resources unknown".to_owned() } else { parts.join("  ") }
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
             "ram": {"freeBytes": 40_000_000_000u64, "totalBytes": 128_000_000_000u64},
             "liveSessions": 9, "build": "abc"},
            {"name": "big-red", "self": false, "reachable": false,
             "error": "connection refused; `acpmux host doctor big-red` checks it step by step"},
            {"name": "cmux16", "self": false, "reachable": true, "latencyMs": 41, "outdated": true,
             "build": "old"},
        ]});
        let l = lines(&reply);
        assert_eq!(
            l[0],
            "huge-blue (this)     ok  disk 25.0 GB free of 252.0 GB  ram 40.0 GB free of 128.0 GB  load 3.2/32 cpus  9 live sessions  build abc"
        );
        assert!(
            l[1].starts_with("big-red              unreachable  connection refused;"),
            "{}",
            l[1]
        );
        assert!(l[1].ends_with("`acpmux host doctor big-red` checks it step by step"), "{}", l[1]);
        assert!(l[2].contains("41 ms") && l[2].contains("acpmux host update cmux16"), "{}", l[2]);
        assert_eq!(l.len(), 3, "no problems, no extra lines: {l:?}");
    }

    #[test]
    fn host_status_prints_each_problem_under_its_machine() {
        let reply = json!({"hosts": [
            {"name": "huge-blue", "self": false, "reachable": true, "latencyMs": 12,
             "problems": [
                {"check": "dns", "detail": "DNS: github.com does not resolve",
                 "since": "2026-10-25T11:40:00.000Z"},
                {"check": "loop", "detail": "machine health check has not run since 2026-10-25T11:50:00.000Z"},
                {"check": 7, "detail": "a bad entry"}]},
            {"name": "cmux16", "self": false, "reachable": true, "latencyMs": 41, "problems": []},
        ]});
        let l = lines(&reply);
        assert_eq!(l.len(), 4, "{l:?}");
        assert!(l[0].starts_with("huge-blue"), "{}", l[0]);
        assert_eq!(
            l[1],
            "  problem DNS: DNS: github.com does not resolve (since 2026-10-25T11:40:00.000Z)"
        );
        assert_eq!(
            l[2],
            "  problem health check: machine health check has not run since 2026-10-25T11:50:00.000Z"
        );
        assert!(l[3].starts_with("cmux16"), "{}", l[3]);
    }

    #[test]
    fn a_disk_problem_says_its_severity_and_a_cmux_tui_one_its_name() {
        let reply = json!({"hosts": [{"name": "devbox", "self": true, "reachable": true, "problems": [
            {"check": "disk", "detail": "disk: CRITICAL: 1.0 GB free on /", "severity": "critical"},
            {"check": "disk", "detail": "disk: 9.0 GB free on /", "severity": "loud"},
            {"check": "cmux", "detail": "cmux: cmux-tui-daemon.service failed"}]}]});
        let l = lines(&reply);
        assert_eq!(l[1], "  problem disk (critical): disk: CRITICAL: 1.0 GB free on /");
        assert_eq!(l[2], "  problem disk: disk: 9.0 GB free on /");
        assert_eq!(l[3], "  problem cmux-tui: cmux: cmux-tui-daemon.service failed");
    }

    #[test]
    fn a_host_ls_row_reads_the_last_health_and_an_old_peer_reads_unknown() {
        let p = json!({"health": {"cpus": 16, "load": [9.5, 4.0, 2.0],
            "ram": {"freeBytes": 12_000_000_000u64, "totalBytes": 64_000_000_000u64},
            "disk": {"freeBytes": 80_000_000_000u64}, "liveSessions": 4,
            "pressure": {"ok": false}}});
        assert_eq!(
            resources(&p),
            "ram 12.0 GB free  load 9.5/16  disk 80.0 GB free  4 live  over budget"
        );
        let p = json!({"health": {"disk": {"freeBytes": 31_000_000_000u64}, "problems": [
            {"check": "dns", "detail": "DNS: github.com does not resolve"},
            {"check": "peer", "detail": "peer cosmic-gray: handshake not finished"},
            {"check": "dns", "detail": "DNS: api.github.com does not resolve"},
            {"detail": "no check"}]}});
        assert_eq!(resources(&p), "disk 31.0 GB free  problems: DNS, peer link");
        let healthy = json!({"health": {"disk": {"freeBytes": 31_000_000_000u64}, "problems": []}});
        assert_eq!(resources(&healthy), "disk 31.0 GB free");
        assert_eq!(resources(&json!({"health": {"unsupported": true}})), "resources unknown");
        assert_eq!(resources(&json!({"health": null})), "resources unknown");
    }
}
