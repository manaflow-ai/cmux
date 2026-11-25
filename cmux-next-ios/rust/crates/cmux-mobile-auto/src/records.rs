//! A stored event as the record the phone's chat view already draws.
//!
//! The store keeps a chat's log records as its holder wrote them: acpmux's
//! `{sessionId, seq, at, dir, kind, msg}`, the records a chat on a paired Mac sends the phone.
//! The phone's chat view maps those to its transcript (`AcpmuxRecords` in the app), so an Auto
//! chat goes through the same mapping: this module only makes each stored event one of those
//! records, and writes the two records the phone adds itself for a message it sent.

use cmux_auto_session::wire::SeqRecord;
use serde_json::{Value, json};

/// The stored event as a transcript record, or None for one that is no log record (no `dir`
/// or `kind`). The chat's id and the store's seq are written over the record's own, so a
/// record a former holder numbered differently still sorts where the store has it.
pub fn transcript_record(chat: &str, event: &SeqRecord) -> Option<Value> {
    let fields = event.record.as_object()?;
    fields.get("dir")?.as_str()?;
    fields.get("kind")?.as_str()?;
    let mut record = fields.clone();
    record.insert("sessionId".to_owned(), Value::from(chat));
    record.insert("seq".to_owned(), Value::from(event.seq));
    Some(Value::Object(record))
}

/// The prompt a record shows: its id and its text. A `user_message` (the prompt ran) or a
/// `queued` (it waits); anything else is None. A `user_message` with no prompt id is named by
/// its turn, as the chat view names it.
pub fn prompt_of(record: &Value) -> Option<(&str, &str)> {
    if record.get("dir")?.as_str()? != "mux" {
        return None;
    }
    let msg = record.get("msg")?;
    let id = match record.get("kind")?.as_str()? {
        "user_message" => msg.get("promptId").or_else(|| msg.get("turnId"))?.as_str()?,
        "queued" => msg.get("promptId")?.as_str()?,
        _ => return None,
    };
    Some((id, msg.get("text").and_then(Value::as_str).unwrap_or_default()))
}

/// The record the phone adds for a message it sent and the chat has not shown yet: it waits,
/// as a queued prompt does. It has no seq of the store's.
pub fn waiting(chat: &str, id: &str, text: &str, position: usize) -> Value {
    json!({
        "sessionId": chat, "seq": 0, "dir": "mux", "kind": "queued",
        "msg": { "promptId": id, "text": text, "position": position },
    })
}

/// The record that takes [`waiting`] away again, once the chat's own records show the message.
pub fn shown(chat: &str, id: &str) -> Value {
    json!({ "sessionId": chat, "seq": 0, "dir": "mux", "kind": "dequeued", "msg": { "promptId": id } })
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn a_stored_event_keeps_its_fields_under_the_stores_seq() {
        let stored = json!({ "sessionId": "old", "seq": 3, "at": 7, "dir": "mux", "kind": "turn_started",
                             "msg": { "turnId": "t1" } });
        let record = transcript_record("chat_1", &SeqRecord { seq: 9, record: stored }).expect("a record");
        assert_eq!(
            record,
            json!({ "sessionId": "chat_1", "seq": 9, "at": 7, "dir": "mux", "kind": "turn_started",
                    "msg": { "turnId": "t1" } })
        );
    }

    #[test]
    fn an_event_that_is_no_log_record_is_not_drawn() {
        for record in
            [json!({ "n": 1 }), json!("text"), json!({ "dir": "mux" }), json!({ "kind": 3, "dir": "in" })]
        {
            assert_eq!(transcript_record("chat_1", &SeqRecord { seq: 1, record }), None);
        }
    }

    #[test]
    fn a_prompt_is_read_from_the_records_that_show_one() {
        let ran = json!({ "dir": "mux", "kind": "user_message", "msg": { "promptId": "p1", "turnId": "t1", "text": "go" } });
        assert_eq!(prompt_of(&ran), Some(("p1", "go")));
        let unnamed =
            json!({ "dir": "mux", "kind": "user_message", "msg": { "turnId": "t1", "text": "go" } });
        assert_eq!(prompt_of(&unnamed), Some(("t1", "go")));
        let waits = json!({ "dir": "mux", "kind": "queued", "msg": { "promptId": "p2", "text": "next" } });
        assert_eq!(prompt_of(&waits), Some(("p2", "next")));
        let other = json!({ "dir": "mux", "kind": "turn_result", "msg": { "turnId": "t1" } });
        assert_eq!(prompt_of(&other), None);
        let agent = json!({ "dir": "in", "kind": "user_message", "msg": { "promptId": "p1" } });
        assert_eq!(prompt_of(&agent), None);
    }
}
