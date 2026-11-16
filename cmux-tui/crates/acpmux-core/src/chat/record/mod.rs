//! Shared event bytes and pure v1 log filters. No daemon or Session state lives here.
use serde::{Deserialize, Serialize};
use serde_json::Value;

mod display;
pub mod logged_bodies;
pub mod logged_init;
pub mod model_copy;
mod table;
pub mod update_repeats;
pub use display::drop_display_lines;
pub use table::{Context, Direction, Entry, Record, record_of};

pub const SESSION_PROMPT: &str = "session/prompt";

/// One line in the session event log.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct EventRecord {
    pub seq: u64,
    /// Unix milliseconds.
    pub at: u64,
    /// `in` = agent to acpmux, `out` = acpmux to agent, `mux` = acpmux internal.
    pub dir: String,
    /// JSON-RPC method, `sessionUpdate` value, or an acpmux kind such as `status`.
    pub kind: String,
    /// Raw JSON-RPC message, or the acpmux payload.
    pub msg: Value,
    /// The agent host entry this record logs (`hostSeq`), so a controller
    /// that adopts the host resumes after it (agent hosts, durable sessions).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host_seq: Option<u64>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn event_record_retains_the_v1_field_order() {
        let mut record = EventRecord {
            seq: 3,
            at: 8,
            dir: "mux".into(),
            kind: "stopped".into(),
            msg: serde_json::json!({"code": 0}),
            host_seq: None,
        };
        assert_eq!(
            serde_json::to_vec(&record).unwrap(),
            br#"{"seq":3,"at":8,"dir":"mux","kind":"stopped","msg":{"code":0}}"#
        );
        record.host_seq = Some(9);
        assert_eq!(
            serde_json::to_vec(&record).unwrap(),
            br#"{"seq":3,"at":8,"dir":"mux","kind":"stopped","msg":{"code":0},"hostSeq":9}"#
        );
    }
}
