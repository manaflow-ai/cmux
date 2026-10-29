//! One ordered request in flight per splice. Completion means a daemon reply,
//! not merely that the input task accepted or wrote the command.

use std::sync::Mutex;

use serde_json::Value;
use tokio::sync::oneshot;

#[derive(Default)]
pub(crate) struct SideCompletion(Mutex<Option<Pending>>);

struct Pending {
    id: Value,
    added_id: bool,
    done: oneshot::Sender<()>,
}

impl SideCompletion {
    pub(crate) fn prepare(&self, line: Vec<u8>) -> (Vec<u8>, oneshot::Receiver<()>) {
        let mut request: Value = serde_json::from_slice(&line).expect("policy checked request JSON");
        let added_id = request.get("id").is_none();
        if added_id {
            request["id"] = Value::String(format!("mobile-side-{}", uuid::Uuid::new_v4()));
        }
        let (done, wait) = oneshot::channel();
        *self.0.lock().unwrap() = Some(Pending { id: request["id"].clone(), added_id, done });
        let line = if added_id { serde_json::to_vec(&request).unwrap() } else { line };
        (line, wait)
    }

    pub(crate) fn answer(&self, line: Vec<u8>) -> Vec<u8> {
        let Ok(mut reply) = serde_json::from_slice::<Value>(&line) else { return line };
        if reply.get("event").is_some() || reply.get("ok").is_none() {
            return line;
        }
        let pending = {
            let mut pending = self.0.lock().unwrap();
            if pending.as_ref().is_none_or(|pending| reply.get("id") != Some(&pending.id)) {
                return line;
            }
            pending.take().unwrap()
        };
        let _ = pending.done.send(());
        if !pending.added_id {
            return line;
        }
        reply.as_object_mut().unwrap().remove("id");
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
        let (line, mut wait) = completion.prepare(br#"{"id":12,"cmd":"select-tab","surface":5}"#.to_vec());
        assert_eq!(serde_json::from_slice::<Value>(&line).unwrap()["id"], 12);
        completion.answer(br#"{"id":12,"event":"tree-changed"}"#.to_vec());
        completion.answer(br#"{"id":13,"ok":true}"#.to_vec());
        assert!(matches!(wait.try_recv(), Err(oneshot::error::TryRecvError::Empty)));
        let reply = br#"{"id":12,"ok":true}"#.to_vec();
        assert_eq!(completion.answer(reply.clone()), reply);
        assert!(wait.try_recv().is_ok());
    }

    #[test]
    fn an_internal_id_does_not_escape_to_the_phone() {
        let completion = SideCompletion::default();
        let (line, mut wait) = completion.prepare(br#"{"cmd":"identify"}"#.to_vec());
        let request: Value = serde_json::from_slice(&line).unwrap();
        let reply = serde_json::json!({"id":request["id"],"ok":true});
        let reply = completion.answer(reply.to_string().into_bytes());
        assert!(serde_json::from_slice::<Value>(&reply).unwrap().get("id").is_none());
        assert!(wait.try_recv().is_ok());
    }
}
