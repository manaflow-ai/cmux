//! One ordered request in flight per splice. Completion means a daemon reply,
//! not merely that the input task accepted or wrote the command.

use std::sync::{Arc, Mutex};

use serde_json::Value;
use tokio::sync::oneshot;

#[derive(Default)]
pub(crate) struct SideCompletion(Mutex<State>);

#[derive(Default)]
struct State {
    closed: bool,
    pending: Option<Pending>,
}

pub(crate) struct CompletionScope(Arc<SideCompletion>);

impl Drop for CompletionScope {
    fn drop(&mut self) {
        let mut state = self.0.0.lock().unwrap();
        state.closed = true;
        // Drop while holding the registration lock: closure cannot finish
        // before invalidation, and a racing prepare cannot install new work.
        drop(state.pending.take());
    }
}

struct Pending {
    id: Value,
    added_id: bool,
    original_id: Option<Value>,
    invalidates: Option<crate::workspace_cache::WorkspaceCache>,
    done: Option<oneshot::Sender<()>>,
}

impl Drop for Pending {
    fn drop(&mut self) {
        // The daemon may have applied this mutation even if its reply never
        // reached the splice. Dropping an unanswered request must not leave
        // its old snapshot available to another channel.
        if let Some(cache) = self.invalidates.take() {
            cache.invalidate();
        }
    }
}

impl SideCompletion {
    pub(crate) fn scope(self: &Arc<Self>) -> CompletionScope {
        CompletionScope(Arc::clone(self))
    }

    pub(crate) fn prepare(
        &self,
        line: Vec<u8>,
        invalidates: Option<crate::workspace_cache::WorkspaceCache>,
    ) -> Option<(Vec<u8>, oneshot::Receiver<()>)> {
        let mut state = self.0.lock().unwrap();
        if state.closed {
            return None;
        }
        let mut request: Value = serde_json::from_slice(&line).expect("policy checked request JSON");
        let original_id = request.get("id").cloned();
        // The daemon treats an explicit null exactly like an omitted id. Both
        // need a concrete correlation id so the ordered worker can complete.
        let added_id = original_id.as_ref().is_none_or(Value::is_null);
        if added_id {
            request["id"] = Value::String(format!("mobile-side-{}", uuid::Uuid::new_v4()));
        }
        let (done, wait) = oneshot::channel();
        state.pending =
            Some(Pending { id: request["id"].clone(), added_id, original_id, invalidates, done: Some(done) });
        let line = if added_id { serde_json::to_vec(&request).unwrap() } else { line };
        Some((line, wait))
    }

    pub(crate) fn answer(&self, line: Vec<u8>) -> Vec<u8> {
        let Ok(mut reply) = serde_json::from_slice::<Value>(&line) else { return line };
        if reply.get("event").is_some() || reply.get("ok").is_none() {
            return line;
        }
        let mut pending = {
            let mut state = self.0.lock().unwrap();
            if state.pending.as_ref().is_none_or(|pending| reply.get("id") != Some(&pending.id)) {
                return line;
            }
            // Serialize invalidation with scope teardown. Once pending is
            // removed, a racing scope drop may return; stale views must already
            // be cleared before that happens.
            if let Some(cache) = state.pending.as_mut().unwrap().invalidates.take() {
                cache.invalidate();
            }
            state.pending.take().unwrap()
        };
        // Invalidate synchronously before waking the worker or exposing this
        // reply to the phone. A request on any other channel after this ack
        // must wait for a snapshot newer than this completed mutation.
        if let Some(done) = pending.done.take() {
            let _ = done.send(());
        }
        if !pending.added_id {
            return line;
        }
        match pending.original_id.take() {
            Some(id) => {
                reply["id"] = id;
            }
            None => {
                reply.as_object_mut().unwrap().remove("id");
            }
        }
        let mut line = serde_json::to_vec(&reply).unwrap();
        line.push(b'\n');
        line
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_matching_reply_completes_a_request() {
        let completion = SideCompletion::default();
        let (line, mut wait) =
            completion.prepare(br#"{"id":12,"cmd":"select-tab","surface":5}"#.to_vec(), None).unwrap();
        assert_eq!(serde_json::from_slice::<Value>(&line).unwrap()["id"], 12);
        completion.answer(br#"{"id":12,"event":"tree-changed"}"#.to_vec());
        completion.answer(br#"{"id":13,"ok":true}"#.to_vec());
        assert!(matches!(wait.try_recv(), Err(oneshot::error::TryRecvError::Empty)));
        let reply = br#"{"id":12,"ok":true}"#.to_vec();
        assert_eq!(completion.answer(reply.clone()), reply);
        assert!(wait.try_recv().is_ok());
    }

    #[test]
    fn missing_and_null_ids_complete_without_exposing_the_internal_id() {
        let completion = SideCompletion::default();
        for request in
            [serde_json::json!({"cmd":"identify"}), serde_json::json!({"id":null,"cmd":"identify"})]
        {
            let original_id = request.get("id").cloned();
            let (line, mut wait) = completion.prepare(request.to_string().into_bytes(), None).unwrap();
            let forwarded: Value = serde_json::from_slice(&line).unwrap();
            assert!(forwarded["id"].as_str().is_some_and(|id| id.starts_with("mobile-side-")));

            // An uncorrelated daemon reply must not unblock this request.
            completion.answer(br#"{"ok":true}"#.to_vec());
            completion.answer(br#"{"id":null,"ok":true}"#.to_vec());
            assert!(matches!(wait.try_recv(), Err(oneshot::error::TryRecvError::Empty)));

            let reply = serde_json::json!({"id":forwarded["id"],"ok":true});
            let reply = completion.answer(reply.to_string().into_bytes());
            let restored: Value = serde_json::from_slice(&reply).unwrap();
            assert_eq!(restored.get("id"), original_id.as_ref());
            assert_eq!(restored["ok"], true);
            assert!(wait.try_recv().is_ok());
        }
    }

    #[test]
    fn closed_scope_drops_pending_and_rejects_late_registration() {
        let completion = Arc::new(SideCompletion::default());
        let scope = completion.scope();
        let task_handle = Arc::clone(&completion);
        let (_, mut waiting) = completion.prepare(br#"{"cmd":"identify"}"#.to_vec(), None).unwrap();
        drop(scope);
        assert!(matches!(waiting.try_recv(), Err(oneshot::error::TryRecvError::Closed)));
        // A child task can outlive the service's scope, but cannot add work.
        assert!(task_handle.prepare(br#"{"cmd":"identify"}"#.to_vec(), None).is_none());
    }
}
