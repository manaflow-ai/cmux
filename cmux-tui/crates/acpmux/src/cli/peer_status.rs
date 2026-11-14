//! `acpmux peer status` (also `host status`): one line per machine from
//! `_acpmux/peer_status` (`server/peer_status.rs`).

use serde_json::Value;

/// The target names used by `host update --binary-dir` release bundles.
pub fn target_triple(os: &str, arch: &str) -> Option<&'static str> {
    match (os, arch) {
        ("Linux" | "linux", "x86_64" | "amd64") => Some("x86_64-unknown-linux-musl"),
        ("Linux" | "linux", "aarch64" | "arm64") => Some("aarch64-unknown-linux-musl"),
        ("Darwin" | "macos", "arm64" | "aarch64") => Some("aarch64-apple-darwin"),
        ("Darwin" | "macos", "x86_64" | "amd64") => Some("x86_64-apple-darwin"),
        _ => None,
    }
}

pub fn target_from_uname(uname: &str) -> Option<&'static str> {
    let mut words = uname.split_whitespace();
    target_triple(words.next()?, words.next()?)
}

fn local_target() -> Option<&'static str> {
    target_triple(std::env::consts::OS, std::env::consts::ARCH)
}

/// The actionable hint for an outdated peer, including the release target
/// needed by `host update --binary-dir` when platforms differ.
pub fn outdated_hint(name: &str, peer: &Value) -> Option<String> {
    if peer.get("outdated").and_then(Value::as_bool) != Some(true) {
        return None;
    }
    let platform = peer.get("health").filter(|health| health.is_object()).unwrap_or(peer);
    let os = platform.get("os").and_then(Value::as_str);
    let arch = platform.get("arch").and_then(Value::as_str);
    let target = os.zip(arch).and_then(|(os, arch)| target_triple(os, arch));
    if let Some(target) = target.filter(|target| Some(*target) != local_target()) {
        return Some(format!(
            "  (differs from this build: acpmux machine update {name} --binary-dir DIR (DIR/acpmux-{target}), or rebuild acpmux on {name} for its OS and architecture (see docs/remote-agents-and-cloud.md))"
        ));
    }
    if target.is_none() {
        return Some(format!(
            "  (peer target unknown: acpmux machine update {name} only with a matching build, or rebuild acpmux on {name} for its OS and architecture (see docs/remote-agents-and-cloud.md))"
        ));
    }
    Some(format!("  (differs from this build: acpmux machine update {name})"))
}

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
    if let Some(hint) = outdated_hint(name, h) {
        out.push_str(&hint);
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

/// `acpmux host vm-host`'s line for an `_acpmux/vm_host` reply:
/// `this machine: vmHost on (unsandboxed only for its owner's own sessions, …)`.
pub fn vm_host_line(name: Option<&str>, v: &Value) -> String {
    let who = name.unwrap_or("this machine");
    let on = v["vmHost"] == true;
    let state = if on { "on" } else { "off" };
    let why = match (on, v["configured"].as_bool()) {
        (_, Some(false)) => "turned off in its config",
        (true, _) => "unsandboxed only for its owner's own sessions, when the Cloud API says so",
        (false, _) => "always sandboxed here",
    };
    format!("{who}: vmHost {state} ({why})")
}

#[cfg(test)]
mod tests;
