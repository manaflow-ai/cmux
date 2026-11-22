//! An original-file upload holds its conversation's order, not every conversation.

mod common;

use std::io::Write;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_conversation::{Op, Part};
use common::*;
use optchat_chief::brain::Input;
use optchat_chief::state::{HostState, StateFile};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

const SIDE: &str = "conv_other";
const PENDING: &str = "test:pending";
const FOLLOWING: &str = "test:following";
const READY: &str = "test:ready";
const FILE_BYTES: u64 = 8 * 1024 * 1024 + 17;

struct Release(Sender<()>);

impl Drop for Release {
    fn drop(&mut self) {
        // A failing assertion must release the worker too.
        let _ = self.0.send(());
    }
}

struct PendingUpload {
    release: Release,
    entered: Receiver<()>,
    hash: String,
    h: Harness,
}

fn entry(conversation: &str, key: &str, text: &str) -> Value {
    json!({
        "conversation": conversation,
        "idempotency_key": key,
        "op": {"kind": "message.send", "client_msg_id": key,
            "parts": [{"type": "text", "text": text}]},
    })
}

fn pending_upload() -> PendingUpload {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("report.bin");
    let mut file = std::fs::File::create(&path).unwrap();
    let page = [0x5a; 64 * 1024];
    let mut remaining = FILE_BYTES;
    let mut hash = Sha256::new();
    while remaining > 0 {
        let count = remaining.min(page.len() as u64) as usize;
        file.write_all(&page[..count]).unwrap();
        hash.update(&page[..count]);
        remaining -= count as u64;
    }
    drop(file);
    let mut pending = entry(CONV, PENDING, "The full report.");
    pending["pending_media"] = json!([{
        "path": path, "mime_type": "application/octet-stream", "image_syntax": null,
    }]);
    let entries = serde_json::from_value(json!([
        pending,
        entry(CONV, FOLLOWING, "After the report."),
        entry(SIDE, READY, "Ready in another conversation."),
    ]))
    .unwrap();
    StateFile::new(&dir.path().join("host.json"))
        .save(&HostState {
            conversation: Some(CONV.into()),
            outbox: entries,
            ..Default::default()
        })
        .unwrap();
    let (entered_tx, entered) = channel();
    let (release_tx, release_rx) = channel();
    let release_rx = Mutex::new(release_rx);
    let owner = Arc::new(Mutex::new(Owner {
        summary: Some(summary()),
        before_attachment_upload: Some(Arc::new(move || {
            entered_tx.send(()).unwrap();
            release_rx.lock().unwrap().recv_timeout(WAIT).unwrap();
        })),
        ..Default::default()
    }));
    let mut config = settings(dir.path());
    config.agent_gap = Duration::ZERO;
    let h = Harness::configured(dir, default_script(), owner, config, Arc::new(|_| {}));
    h.add_side(SIDE, "user_other");
    PendingUpload {
        release: Release(release_tx),
        entered,
        hash: format!("{:x}", hash.finalize()),
        h,
    }
}

fn finish_upload(h: &mut Harness) {
    let completed = h.rx.recv_timeout(WAIT).expect("upload completion event");
    assert!(matches!(&completed, Input::Previews { key, parts: Some(_) } if key == PENDING));
    h.brain.step(completed);
}

fn assert_full_delivery(h: &Harness, hash: &str) {
    assert!(h.brain.state().outbox.is_empty());
    let owner = h.owner.lock().unwrap();
    let keys: Vec<_> = owner
        .ops
        .iter()
        .filter(|(_, op)| matches!(op, Op::MessageSend { .. }))
        .map(|(key, _)| key.as_str())
        .collect();
    assert_eq!(keys, vec![PENDING, FOLLOWING]);
    assert_eq!(owner.uploads.len(), 1);
    let (conversation, uploaded, name, ..) = &owner.uploads[0];
    assert_eq!(conversation, CONV);
    assert_eq!(uploaded.hash, hash);
    assert_eq!(uploaded.byte_count, FILE_BYTES);
    assert_eq!(name, "report.bin");
    let (_, sent) = owner.ops.iter().find(|(key, _)| key == PENDING).unwrap();
    let Op::MessageSend { parts, .. } = sent else {
        panic!("the report was not sent");
    };
    assert!(parts.iter().any(|part| matches!(part,
        Part::Attachment { hash: actual, byte_count, name, .. }
            if actual == hash && *byte_count == FILE_BYTES && name == "report.bin"
    )));
    assert_eq!(owner.stores[SIDE].messages.len(), 1);
}

#[test]
fn a_pending_original_holds_only_its_conversation_and_remains_durable() {
    let PendingUpload {
        release,
        entered,
        hash,
        mut h,
    } = pending_upload();
    h.connect();
    entered.recv_timeout(WAIT).unwrap();
    assert_eq!(
        h.side_sends(SIDE),
        vec![(READY.into(), "Ready in another conversation.".into())]
    );
    assert!(h.owner.lock().unwrap().sends().is_empty());
    let saved = StateFile::new(&h.dir.path().join("host.json"))
        .attach(h.chat.clone())
        .load();
    assert_eq!(saved.outbox, h.brain.state().outbox);
    assert_eq!(saved.outbox.len(), 2);
    assert_eq!(saved.outbox[0].idempotency_key, PENDING);
    assert_eq!(saved.outbox[0].pending_media.len(), 1);
    assert_eq!(saved.outbox[1].idempotency_key, FOLLOWING);
    assert!(saved.outbox.iter().all(|entry| !entry.attempted));
    drop(release);
    finish_upload(&mut h);
    assert_full_delivery(&h, &hash);
}

#[test]
fn a_rate_rejection_updates_and_retries_the_selected_entry() {
    let PendingUpload {
        release,
        entered,
        hash,
        mut h,
    } = pending_upload();
    h.owner
        .lock()
        .unwrap()
        .stores
        .get_mut(SIDE)
        .unwrap()
        .rejects
        .push_back(Some("agent_rate".into()));
    h.connect();
    entered.recv_timeout(WAIT).unwrap();
    let entries = &h.brain.state().outbox;
    assert_eq!(entries.len(), 3);
    assert!(!entries[0].attempted);
    assert_eq!(entries[0].rate_attempts, 0);
    assert_eq!(entries[2].idempotency_key, READY);
    assert!(entries[2].attempted);
    assert_eq!(entries[2].rate_attempts, 1);
    assert!(entries[2].rate_retried);
    let at = h.brain.next_timer().expect("rate retry timer");
    std::thread::sleep(at.saturating_duration_since(Instant::now()));
    h.brain.on_timer();
    assert_eq!(
        h.side_sends(SIDE)
            .iter()
            .map(|(key, _)| key.as_str())
            .collect::<Vec<_>>(),
        vec![READY, READY]
    );
    assert_eq!(h.brain.state().outbox.len(), 2);
    drop(release);
    finish_upload(&mut h);
    assert_full_delivery(&h, &hash);
}

#[test]
#[ignore = "same-harness before/after attachment head-of-line latency measurement"]
fn pending_attachment_latency() {
    let mut samples = Vec::new();
    for _ in 0..7 {
        let PendingUpload {
            release,
            entered,
            hash,
            mut h,
        } = pending_upload();
        let start = Instant::now();
        h.connect();
        entered.recv_timeout(WAIT).unwrap();
        let release_worker = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(100));
            drop(release);
        });
        let posted_before_completion = !h.side_sends(SIDE).is_empty();
        let fast = start.elapsed();
        finish_upload(&mut h);
        let latency = if posted_before_completion {
            fast
        } else {
            start.elapsed()
        };
        release_worker.join().unwrap();
        assert_full_delivery(&h, &hash);
        samples.push(latency.as_secs_f64() * 1000.0);
    }
    samples.sort_by(f64::total_cmp);
    println!(
        "outbox_fairness_perf payload_bytes={FILE_BYTES} samples={} upload_hold_ms=100 ready_latency_p50_ms={:.3} ready_latency_max_ms={:.3}",
        samples.len(),
        samples[samples.len() / 2],
        samples[samples.len() - 1]
    );
}
