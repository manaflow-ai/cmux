//! The brain's conversation port over the daemon's cloud commands. The proxy
//! pages are smaller than the local owner's (snapshot tail 50, history 200);
//! the brain's catch-up pages back until it has every message, so clamping
//! loses nothing. Typing has no cloud frame yet (proxy part 1).

use cmux_conversation::{Change, Message, Op, Summary};
use serde_json::{Value, json};

use super::events::{decode_message, decode_summary};
use super::idmap::{to_brain, to_cloud};
use super::wire::Rpc;
use crate::daemon::{ConversationPort, OpError};

pub const SNAPSHOT_TAIL: u32 = 50;
pub const HISTORY_LIMIT: u32 = 200;

pub struct CloudPort<R: Rpc> {
    rpc: R,
    chief: String,
}

impl<R: Rpc> CloudPort<R> {
    pub fn new(rpc: R, chief: String) -> CloudPort<R> {
        CloudPort { rpc, chief }
    }

    fn messages(&self, data: &Value) -> Vec<Message> {
        data.get("messages")
            .and_then(Value::as_array)
            .map(|list| {
                list.iter()
                    .filter_map(|m| decode_message(m.clone(), &self.chief))
                    .collect()
            })
            .unwrap_or_default()
    }
}

impl<R: Rpc> ConversationPort for CloudPort<R> {
    fn snapshot(
        &mut self,
        conversation: &str,
        tail: u32,
    ) -> Result<(Summary, Vec<Message>), OpError> {
        let data = self.rpc.call(
            "cloud-conversation-snapshot",
            json!({"conversation": conversation, "tail": tail.clamp(1, SNAPSHOT_TAIL)}),
        )?;
        let mut summary = data
            .get("conversation")
            .cloned()
            .ok_or_else(|| OpError::Transport("snapshot without a conversation".into()))?;
        to_brain(&mut summary, &self.chief);
        let summary = decode_summary(summary)
            .ok_or_else(|| OpError::Transport("snapshot: unreadable conversation".into()))?;
        Ok((summary, self.messages(&data)))
    }

    fn history(
        &mut self,
        conversation: &str,
        before_seq: u64,
        limit: u32,
    ) -> Result<Vec<Message>, OpError> {
        let data = self.rpc.call(
            "cloud-conversation-history",
            json!({"conversation": conversation, "before_seq": before_seq, "limit": limit.clamp(1, HISTORY_LIMIT)}),
        )?;
        Ok(self.messages(&data))
    }

    fn op(&mut self, conversation: &str, key: &str, op: &Op) -> Result<Option<Change>, OpError> {
        let mut op = serde_json::to_value(op).map_err(|e| OpError::Transport(e.to_string()))?;
        to_cloud(&mut op, &self.chief);
        let data = self.rpc.call(
            "cloud-conversation-op",
            json!({"conversation": conversation, "idempotency_key": key, "op": op}),
        )?;
        Ok(data.get("change").cloned().and_then(|mut change| {
            to_brain(&mut change, &self.chief);
            serde_json::from_value(change).ok()
        }))
    }

    fn typing(&mut self, _conversation: &str, _on: bool) -> Result<(), OpError> {
        Ok(())
    }

    fn mux_ack(&mut self, conversation: &str, seq: u64) -> Result<(), OpError> {
        self.rpc
            .call(
                "cloud-mux-ack",
                json!({"conversation": conversation, "seq": seq}),
            )
            .map(|_| ())
    }
}
