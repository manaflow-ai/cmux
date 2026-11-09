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
/// sender learns the target host is over its CPU/RAM budget. Nothing is held. One caller (the
/// session its shell runs in, else the person) hears it once per host per
/// [`WARNING_EVERY_MS`] (W5-S, bench round 4 friction 9, 2026-11-08: the line came on every
/// send, in agents' tool output too, where it costs context). `--json` prints none.
pub(crate) fn warn_host_pressure(accepted: &Value) {
    let Some(line) = accepted.pointer("/host_pressure/warning").and_then(Value::as_str) else {
        return;
    };
    let caller = std::env::var("ACPMUX_SESSION_ID").ok().filter(|id| !id.trim().is_empty());
    let dir = crate::config::home().join("host-warnings");
    if warning_due(&dir, caller.as_deref().unwrap_or("person"), line, crate::store::now_ms()) {
        eprintln!("{line}");
    }
}

/// How long one caller hears no second over-budget line for the same host.
pub(crate) const WARNING_EVERY_MS: u64 = 10 * 60 * 1000;

/// Whether `caller` is due `warning` (a `host-budget: HOST over ...` line) at `now_ms`: not when
/// it heard one for the same host less than [`WARNING_EVERY_MS`] ago. The time it is due is kept
/// in `dir`, one small file per caller and host; a file that cannot be read or written makes
/// the line due (a warning lost is worse than one repeated).
pub(crate) fn warning_due(dir: &std::path::Path, caller: &str, warning: &str, now_ms: u64) -> bool {
    use std::hash::{Hash, Hasher};
    let host = warning
        .strip_prefix("host-budget: ")
        .and_then(|rest| rest.split_whitespace().next())
        .unwrap_or(warning);
    // A stable name: the std hasher with no random keys (`DefaultHasher::new`).
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    (caller, host).hash(&mut hasher);
    let file = dir.join(format!("{:016x}", hasher.finish()));
    let last = std::fs::read_to_string(&file).ok().and_then(|t| t.trim().parse::<u64>().ok());
    if last.is_some_and(|at| now_ms.saturating_sub(at) <= WARNING_EVERY_MS) {
        return false;
    }
    let _ = std::fs::create_dir_all(dir).and_then(|()| std::fs::write(&file, now_ms.to_string()));
    true
}

/// The most stdin `machine verdict` reads: a fleet's readings fit many times over.
const MAX_VERDICT_INPUT: u64 = 4 << 20;

/// `acpmux machine verdict`: the shadow admission verdict for each set of host
/// readings on stdin (`cmux_host_budget::shadow_verdict`), printed as JSON. One
/// object in gives one verdict; an array gives an array, in order. A reading
/// without `now_ms` is judged at this machine's clock.
pub(crate) fn verdict_stdin() -> anyhow::Result<()> {
    use std::io::Read as _;
    let mut text = String::new();
    std::io::stdin().take(MAX_VERDICT_INPUT + 1).read_to_string(&mut text)?;
    if text.len() as u64 > MAX_VERDICT_INPUT {
        anyhow::bail!("machine verdict: stdin is over {} MiB", MAX_VERDICT_INPUT >> 20);
    }
    let out = verdicts_for(&text, crate::store::now_ms())?;
    crate::cli::output::print_json(&out);
    Ok(())
}

/// The verdicts for `text` (one inputs object or an array), with `now_ms`
/// filled in from `now` where it is left out.
pub(crate) fn verdicts_for(text: &str, now: u64) -> anyhow::Result<Value> {
    use crate::host_pressure::{ShadowInputs, shadow_verdict};
    let judge = |v: Value| -> anyhow::Result<Value> {
        let mut inputs: ShadowInputs = serde_json::from_value(v)
            .map_err(|e| anyhow::anyhow!("machine verdict: not a host's readings: {e}"))?;
        inputs.now_ms = inputs.now_ms.or(Some(now));
        Ok(serde_json::to_value(shadow_verdict(&inputs))?)
    };
    let input: Value = serde_json::from_str(text)
        .map_err(|e| anyhow::anyhow!("machine verdict: stdin is not JSON: {e}"))?;
    match input {
        Value::Array(items) => {
            Ok(Value::Array(items.into_iter().map(judge).collect::<anyhow::Result<_>>()?))
        }
        one => judge(one),
    }
}

#[cfg(test)]
mod tests {
    use super::{verdicts_for, warning_due};

    #[test]
    fn machine_verdict_judges_one_object_or_an_array() {
        let one = r#"{"host":"h","health_at_ms":100000,"cores":32,"load1":205.0,
            "previous":{"sample_at_ms":40000,"cpu":{"state":"pressured","hot":1}}}"#;
        let v = verdicts_for(one, 101_000).expect("judged");
        assert_eq!(v["reason"], "saturated:cpu");
        assert_eq!(v["would_defer"], true);
        assert_eq!(v["health_age_s"], 1);
        let many = format!("[{one}, {{\"host\":\"g\"}}]");
        let v = verdicts_for(&many, 101_000).expect("judged");
        assert_eq!(v[0]["host"], "h");
        assert_eq!(v[1]["reason"], "unknown:stale");
        assert!(verdicts_for("{\"lod1\": 1}", 0).is_err());
        assert!(verdicts_for("not json", 0).is_err());
    }

    /// W5-S, bench round 4 friction 9 (2026-11-08): the over-budget line came on every send, in
    /// agents' tool output too. One caller hears it once per host per 10 minutes.
    #[test]
    fn w5s_a_host_warning_comes_once_per_caller_and_host_per_ten_minutes() {
        let dir = std::env::temp_dir().join(format!("w5s-host-warning-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let over =
            |host: &str| format!("host-budget: {host} over its CPU/RAM budget: load1 190 >= 18");
        let t0 = 1_800_000_000_000;
        assert!(warning_due(&dir, "person", &over("gray"), t0));
        // The numbers change from send to send; the host is what counts.
        let again = "host-budget: gray over its CPU/RAM budget: load1 191 >= 18";
        assert!(!warning_due(&dir, "person", again, t0 + 60_000));
        assert!(warning_due(&dir, "session-a", &over("gray"), t0 + 60_000), "another caller");
        assert!(warning_due(&dir, "person", &over("cmux16"), t0 + 60_000), "another host");
        assert!(!warning_due(&dir, "person", &over("gray"), t0 + 9 * 60_000));
        assert!(warning_due(&dir, "person", &over("gray"), t0 + 10 * 60_000 + 1));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Review of #39057: the warning never creates a missing acpmux home (`ACPMUX_HOME` named
    /// but not made yet, or a typo); it makes only its own folder inside an existing one. The
    /// line is still due.
    #[test]
    fn w5s_a_host_warning_does_not_create_a_missing_acpmux_home() {
        let base = std::env::temp_dir().join(format!("w5s-host-home-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).unwrap();
        let home = base.join("not-made");
        let line = "host-budget: gray over its CPU/RAM budget: load1 190 >= 18";
        assert!(warning_due(&home.join("host-warnings"), "person", line, 1));
        assert!(!home.exists(), "the warning made the missing home {}", home.display());
        let _ = std::fs::remove_dir_all(&base);
    }
}
