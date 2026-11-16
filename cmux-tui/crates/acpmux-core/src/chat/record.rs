//! Build the v1-shaped record for one retained harness entry.
//!
//! The raw writer does not know policy or `Session`; it appends the [`Record`] this pure
//! function hands it. `RecordContext` is the small actor-owned state that can be reconstructed
//! from the raw file and the claim line after a restart. The v1 tap's other effects stay in the
//! actor/cutover path (row 9c):
//!
//! - `hub/tap.rs::session_tap` updates liveness (`heard_now`, `heard_after_silence`), clears
//!   stuck state (`unstick_on_work`), and counts full-access reports.
//! - It toggles `Session::harness_turn`, records background-task lines, and applies the
//!   `logged_init`/`update_repeats` suppression state.
//! - The `HOST_EXIT` arm clears `harness_turn`, ends the background turn, and ends the workflow
//!   index for the process (`hub/tap.rs` lines 176-179 at the base).
//!
//! None of those effects are performed by this builder or the raw writer; 9c wires them after
//! the record has been accepted.

use serde_json::{Value, json};

/// The direction used by v1's event record.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TapDirection {
    In,
    Out,
}

/// The host entry shape needed by the record builder. The acpmux crate converts its transport
/// `agent_host::Entry` into this value at the row-9 seam; this core type deliberately carries no
/// `Session` or hub handle.
#[derive(Debug, Clone, PartialEq)]
pub enum RecordEntry {
    Tap { dir: TapDirection, msg: Value },
    In { msg: Value },
    Err { line: String },
    Exit { code: Option<i32> },
}

/// State the actor folds from raw lines and the claim line for a host exit.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct RecordContext {
    /// Whether the translator has an open user turn.
    pub turn_open: bool,
    /// Whether the chat was closed before the harness ended.
    pub closed: bool,
    /// Whether the idle hibernation mark was written before the harness ended.
    pub hibernate: bool,
}

/// A v1-shaped record before its seq, timestamp, and host sequence are assigned by the writer.
#[derive(Debug, Clone, PartialEq)]
pub struct Record {
    pub dir: String,
    pub kind: String,
    pub msg: Value,
}

/// Convert a host entry to the v1 record form. `None` is reserved for v1's "kept nowhere"
/// entries; the actor applies any method-specific suppression before calling this function.
pub fn record_of(entry: RecordEntry, context: RecordContext) -> Option<Record> {
    match entry {
        RecordEntry::Tap { dir, msg } => message_record(direction(dir), msg),
        RecordEntry::In { msg } => message_record("in", msg),
        RecordEntry::Err { line } => {
            Some(Record { dir: "mux".into(), kind: "stderr".into(), msg: json!({"text": line}) })
        }
        RecordEntry::Exit { code } => {
            let hibernating = context.hibernate && !context.closed;
            let intentional = hibernating || !context.turn_open || context.closed;
            let mut msg = json!({"code": code});
            if hibernating {
                msg["hibernated"] = Value::Bool(true);
            }
            Some(Record {
                dir: "mux".into(),
                kind: if intentional { "stopped" } else { "exited" }.into(),
                msg,
            })
        }
    }
}

fn direction(dir: TapDirection) -> &'static str {
    match dir {
        TapDirection::In => "in",
        TapDirection::Out => "out",
    }
}

fn message_record(dir: &str, msg: Value) -> Option<Record> {
    let kind = msg
        .get("method")
        .and_then(Value::as_str)
        .map(|method| {
            if method == "session/update" {
                msg.pointer("/params/update/sessionUpdate")
                    .and_then(Value::as_str)
                    .unwrap_or(method)
                    .to_owned()
            } else {
                method.to_owned()
            }
        })
        .unwrap_or_else(|| "response".into());
    Some(Record { dir: dir.into(), kind, msg })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn exit(context: RecordContext) -> Record {
        record_of(RecordEntry::Exit { code: Some(7) }, context).unwrap()
    }

    #[test]
    fn exit_table_matches_v1_for_turn_open_idle_and_closed() {
        assert_eq!(
            exit(RecordContext { turn_open: true, ..RecordContext::default() }),
            Record { dir: "mux".into(), kind: "exited".into(), msg: json!({"code": 7}) }
        );
        assert_eq!(
            exit(RecordContext { turn_open: false, ..RecordContext::default() }),
            Record { dir: "mux".into(), kind: "stopped".into(), msg: json!({"code": 7}) }
        );
        assert_eq!(
            exit(RecordContext { turn_open: true, hibernate: true, ..RecordContext::default() }),
            Record {
                dir: "mux".into(),
                kind: "stopped".into(),
                msg: json!({"code": 7, "hibernated": true}),
            }
        );
        assert_eq!(
            exit(RecordContext { closed: true, ..RecordContext::default() }),
            Record { dir: "mux".into(), kind: "stopped".into(), msg: json!({"code": 7}) }
        );
    }

    #[test]
    fn hibernate_mark_changes_only_the_intentional_exit_body() {
        let hibernated = exit(RecordContext { hibernate: true, ..RecordContext::default() });
        assert_eq!(hibernated.kind, "stopped");
        assert_eq!(hibernated.msg, json!({"code": 7, "hibernated": true}));

        let closed =
            exit(RecordContext { hibernate: true, closed: true, ..RecordContext::default() });
        assert_eq!(closed.kind, "stopped");
        assert_eq!(closed.msg, json!({"code": 7}));
    }

    #[test]
    fn restart_after_hibernate_mark_still_stops() {
        let after_restart = exit(RecordContext { hibernate: true, ..RecordContext::default() });
        assert_eq!(after_restart.kind, "stopped");
        assert_eq!(after_restart.msg["hibernated"], true);
    }

    #[test]
    fn host_entry_kinds_use_v1_record_shape() {
        let input = RecordEntry::In {
            msg: json!({"jsonrpc":"2.0", "method":"session/update", "params":{"update":{"sessionUpdate":"tool_call"}}}),
        };
        assert_eq!(record_of(input, RecordContext::default()).unwrap().kind, "tool_call");
        assert_eq!(
            record_of(RecordEntry::Err { line: "warn".into() }, RecordContext::default()).unwrap(),
            Record { dir: "mux".into(), kind: "stderr".into(), msg: json!({"text":"warn"}) }
        );
    }
}
