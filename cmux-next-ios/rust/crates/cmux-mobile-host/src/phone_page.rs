//! The `phone-page` service (`phone-page-v1`): an agent on this Mac drives a
//! browser tab the phone shows in its own web view (RFD 0089, "Agents drive
//! the phone's tab"). The wire, the verbs and the refusals are
//! `cmux_phone_page`'s, shared with the `cmux` CLI.
//!
//! The phone opens `phone-page` (args `{"name": "<device name>"}`) on its link
//! and holds it while it is linked. Each open channel is one [`Phone`] in
//! [`PHONES`]. The CLI asks on the link socket
//! (`{"op":"phone-page","device":D,"method":M,"params":P}`, `link_socket.rs`);
//! [`Phones::call`] picks the phone, writes the request line and waits for the
//! answer with the same id, bounded by the verb's timeout. A call to a phone
//! that holds no channel is refused `phone_not_linked` at once, never queued,
//! and a phone that leaves fails its waiting calls `phone_gone`.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, Mutex, PoisonError};
use std::time::Duration;

use bytes::Bytes;
use cmux_mobile_link::ChannelEvent;
use cmux_mobile_link::link::{ChannelReceiver, ChannelSender};
use cmux_phone_page::{Linked, Refusal as PageRefusal};
use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot};

use crate::services::Refusal;

/// Calls a phone may have outstanding at once (a further call waits for
/// room in the channel's queue).
const QUEUE: usize = 16;
/// The longest device name kept.
const MAX_NAME: usize = 80;

type Answer = Result<Value, Value>;
type Pending = Arc<Mutex<HashMap<u64, oneshot::Sender<Answer>>>>;

/// One open `phone-page` channel.
struct Phone {
    device_id: String,
    name: String,
    out: mpsc::Sender<Vec<u8>>,
    pending: Pending,
}

/// Every phone holding `phone-page` open on this host.
#[derive(Default)]
pub struct Phones {
    open: Mutex<HashMap<u64, Phone>>,
    next_channel: AtomicU64,
    next_call: AtomicU64,
}

/// This host process's phones.
pub static PHONES: LazyLock<Phones> = LazyLock::new(Phones::default);

/// A channel's registration: its key, the request lines to write and the
/// answers it owes.
pub struct Attached {
    pub key: u64,
    pub requests: mpsc::Receiver<Vec<u8>>,
    pending: Pending,
}

impl Phones {
    /// Registers a phone's channel. A phone that opens a second one (a new
    /// link after a network change) is reached on the newest.
    pub fn attach(&self, device_id: &str, name: &str) -> Attached {
        let key = self.next_channel.fetch_add(1, Ordering::Relaxed);
        let (out, requests) = mpsc::channel(QUEUE);
        let pending: Pending = Arc::default();
        let name: String = name.chars().filter(|c| !c.is_control()).take(MAX_NAME).collect();
        let phone = Phone { device_id: device_id.to_owned(), name, out, pending: Arc::clone(&pending) };
        self.lock().insert(key, phone);
        Attached { key, requests, pending }
    }

    /// Drops a channel; its waiting calls fail `phone_gone` (their senders drop).
    pub fn detach(&self, key: u64) {
        if let Some(phone) = self.lock().remove(&key) {
            phone.pending.lock().unwrap_or_else(PoisonError::into_inner).clear();
        }
    }

    /// The phones reachable now, one per device (its newest channel).
    pub fn linked(&self) -> Vec<Linked> {
        let open = self.lock();
        let mut newest: HashMap<&str, (u64, &Phone)> = HashMap::new();
        for (key, phone) in open.iter() {
            let entry = newest.entry(&phone.device_id).or_insert((*key, phone));
            if *key > entry.0 {
                *entry = (*key, phone);
            }
        }
        let mut list: Vec<Linked> = newest
            .values()
            .map(|(_, phone)| Linked { device_id: phone.device_id.clone(), name: phone.name.clone() })
            .collect();
        list.sort_by(|a, b| a.device_id.cmp(&b.device_id));
        list
    }

    /// Runs `method` on the phone `device` names (`None`: the one linked) and
    /// answers as the link socket does: `{"ok":true,"device_id":D,"value":V}`,
    /// the phone's refusal `{"error":CODE,"message":M}`, or this host's.
    pub async fn call(&self, device: Option<&str>, method: &str, params: &Value) -> Value {
        self.call_within(device, method, params, cmux_phone_page::timeout(method)).await
    }

    /// [`Self::call`] with its own bound on the phone's answer.
    pub async fn call_within(
        &self,
        device: Option<&str>,
        method: &str,
        params: &Value,
        wait: Duration,
    ) -> Value {
        match self.try_call(device, method, params, wait).await {
            Ok((device_id, value)) => json!({"ok": true, "device_id": device_id, "value": value}),
            Err(refusal) => refusal,
        }
    }

    async fn try_call(
        &self,
        device: Option<&str>,
        method: &str,
        params: &Value,
        wait: Duration,
    ) -> Result<(String, Value), Value> {
        let params = cmux_phone_page::check(method, params).map_err(|refusal| refusal.to_json())?;
        let linked = self.linked();
        let device_id = cmux_phone_page::pick(&linked, device).map_err(|r| r.to_json())?.device_id.clone();
        let id = self.next_call.fetch_add(1, Ordering::Relaxed) + 1;
        let (answer, answered) = oneshot::channel();
        let (out, pending) = {
            let open = self.lock();
            // The device's newest channel: the highest key among its entries.
            let newest =
                open.iter().filter(|(_, phone)| phone.device_id == device_id).max_by_key(|(key, _)| **key);
            let Some((_, phone)) = newest else {
                return Err(gone().to_json());
            };
            phone.pending.lock().unwrap_or_else(PoisonError::into_inner).insert(id, answer);
            (phone.out.clone(), Arc::clone(&phone.pending))
        };
        let forget = || {
            pending.lock().unwrap_or_else(PoisonError::into_inner).remove(&id);
        };
        // Queue backpressure is part of the call's budget, not an unbounded
        // wait before the reply deadline starts.
        let outcome = tokio::time::timeout(wait, async {
            if out.send(cmux_phone_page::request_line(id, method, &params)).await.is_err() {
                return Err(gone().to_json());
            }
            match answered.await {
                Ok(Ok(value)) => Ok(value),
                Ok(Err(refusal)) => Err(json!({
                    "error": refusal.get("code").cloned().unwrap_or_else(|| json!("operation.failed")),
                    "message": refusal.get("message").cloned().unwrap_or_else(|| json!("")),
                })),
                Err(_) => Err(gone().to_json()),
            }
        })
        .await;
        forget();
        match outcome {
            Ok(result) => result.map(|value| (device_id, value)),
            Err(_) => Err(PageRefusal::new(
                cmux_phone_page::TIMEOUT,
                format!("the iPhone did not answer {method} in time"),
            )
            .to_json()),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<u64, Phone>> {
        self.open.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl Attached {
    /// Hands one answer line from the phone to the call waiting on its id.
    /// An unknown or late id (the call timed out) is dropped.
    pub fn answered(&self, line: &[u8]) {
        let Some((id, answer)) = cmux_phone_page::parse_answer(line) else {
            tracing::info!("phone-page: unreadable answer line");
            return;
        };
        if let Some(waiting) = self.pending.lock().unwrap_or_else(PoisonError::into_inner).remove(&id) {
            let _ = waiting.send(answer);
        }
    }
}

fn gone() -> PageRefusal {
    PageRefusal::new(cmux_phone_page::GONE, "the iPhone left before it answered")
}

/// Splits a byte stream into `\n`-ended lines, at most `max` bytes each.
#[derive(Default)]
pub struct Lines {
    buffer: Vec<u8>,
}

impl Lines {
    /// The complete lines in `bytes`, or `Err` when a line outgrows `max`.
    #[allow(clippy::result_unit_err)] // the one failure is "too long"; the caller names it.
    pub fn push(&mut self, bytes: &[u8], max: usize) -> Result<Vec<Vec<u8>>, ()> {
        let mut lines = Vec::new();
        for &byte in bytes {
            if byte == b'\n' {
                if !self.buffer.is_empty() {
                    lines.push(std::mem::take(&mut self.buffer));
                }
            } else {
                // Check before appending so a newline-terminated line cannot
                // bypass the limit after it is drained from the buffer.
                if self.buffer.len() >= max {
                    return Err(());
                }
                self.buffer.push(byte);
            }
        }
        Ok(lines)
    }
}

/// Serves one phone's `phone-page` channel until it closes.
pub async fn serve(
    device_id: &str,
    args: &Value,
    sender: &ChannelSender,
    mut receiver: ChannelReceiver,
) -> Result<(), Refusal> {
    let name = args.get("name").and_then(Value::as_str).unwrap_or_default();
    let mut attached = PHONES.attach(device_id, name);
    let key = attached.key;
    let mut lines = Lines::default();
    let outcome = loop {
        tokio::select! {
            request = attached.requests.recv() => match request {
                Some(line) => {
                    if sender.send(Bytes::from(line)).await.is_err() {
                        break Ok(());
                    }
                }
                None => break Ok(()),
            },
            event = receiver.recv() => match event {
                Some(ChannelEvent::Data(bytes)) => match lines.push(&bytes, cmux_phone_page::MAX_LINE) {
                    Ok(answers) => answers.iter().for_each(|line| attached.answered(line)),
                    Err(()) => break Err(Refusal::new("too_large", "a phone-page line is too long")),
                },
                Some(ChannelEvent::Closed(_)) | None => break Ok(()),
            },
        }
    };
    PHONES.detach(key);
    outcome
}

#[cfg(test)]
#[path = "phone_page_tests.rs"]
mod tests;
