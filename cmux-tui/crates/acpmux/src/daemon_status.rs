//! `daemon status`'s `memory` section: the process footprint, the pressure
//! level, each memory consumer's bytes (`memory.rs`,
//! `hub/memory_consumers.rs`) and the sessions that hold the most. Chrome's
//! `chrome://memory-internals` and the task manager's per-tab memory, for the
//! daemon.

use crate::hub::Hub;
use cmux_memory::{ConsumerReport, PressureLevel, Retention};
use serde_json::{Value, json};

/// How many sessions `memory.top` names.
pub const TOP_SESSIONS: usize = 20;

/// The `memory` section of `daemon status`.
pub fn memory_status(hub: &Hub) -> Value {
    let registry = hub.memory().registry();
    let consumers = registry.report();
    let mut sessions: Vec<(u64, String, String)> =
        hub.sessions().iter().map(|s| (s.approx_bytes(), s.id.clone(), s.meta().name)).collect();
    let session_bytes: u64 = sessions.iter().map(|(bytes, ..)| bytes).sum();
    sessions.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
    sessions.truncate(TOP_SESSIONS);
    json!({
        "footprint_bytes": crate::memory::footprint_bytes(),
        "level": level_word(registry.level()),
        "pressure_source": hub.memory().watching(),
        "consumers": consumers.iter().map(consumer_value).collect::<Vec<_>>(),
        "session_bytes": session_bytes,
        "top": sessions
            .into_iter()
            .map(|(bytes, id, name)| json!({"session_id": id, "name": name, "bytes": bytes}))
            .collect::<Vec<_>>(),
    })
}

fn consumer_value(c: &ConsumerReport) -> Value {
    let retention = match c.retention {
        Retention::Lossless => "lossless",
        Retention::Lossy => "lossy",
    };
    json!({"name": c.name, "retention": retention, "bytes": c.bytes})
}

pub fn level_word(level: PressureLevel) -> &'static str {
    match level {
        PressureLevel::Normal => "normal",
        PressureLevel::Warning => "warning",
        PressureLevel::Critical => "critical",
    }
}

/// `daemon status`'s memory lines for people, from its `memory` section.
pub fn memory_lines(m: &Value) -> Vec<String> {
    let Some(obj) = m.as_object() else { return Vec::new() };
    let mb = |b: Option<u64>| b.map_or("-".to_owned(), |b| format!("{:.1} MB", b as f64 / 1e6));
    let mut lines = vec![format!(
        "{} footprint, pressure {}",
        mb(obj.get("footprint_bytes").and_then(Value::as_u64)),
        obj.get("level").and_then(Value::as_str).unwrap_or("-"),
    )];
    for c in obj.get("consumers").and_then(Value::as_array).into_iter().flatten() {
        lines.push(format!(
            "  {} ({}): {}",
            c.get("name").and_then(Value::as_str).unwrap_or(""),
            c.get("retention").and_then(Value::as_str).unwrap_or(""),
            mb(c.get("bytes").and_then(Value::as_u64)),
        ));
    }
    lines
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn memory_lines_name_each_consumer() {
        let m = json!({
            "footprint_bytes": 24_000_000u64,
            "level": "warning",
            "consumers": [
                {"name": "pool.auth_cache", "retention": "lossless", "bytes": 0},
                {"name": "chats.index", "retention": "lossy", "bytes": null},
            ],
        });
        assert_eq!(
            memory_lines(&m),
            [
                "24.0 MB footprint, pressure warning",
                "  pool.auth_cache (lossless): 0.0 MB",
                "  chats.index (lossy): -",
            ]
        );
    }
}
