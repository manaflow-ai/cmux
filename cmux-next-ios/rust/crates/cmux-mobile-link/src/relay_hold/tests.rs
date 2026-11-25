use std::collections::{BTreeMap, HashMap, HashSet};

use super::*;

/// The LinkRelay's queue (backend/src/relay-hold.ts) as a model: hold (idempotent by id, tombstone after the
/// ack), drain on join, ack. Only what the relay sees: ids, the sender, sealed bytes, times.
#[derive(Default)]
struct ModelRelay {
    seq: u64,
    items: BTreeMap<u64, (String, String, u64)>,
    by_id: HashMap<String, u64>,
    done: HashSet<String>,
}

impl ModelRelay {
    fn on_text(&mut self, text: &str, now: u64) -> Option<Incoming> {
        match serde_json::from_str::<Outgoing>(text).ok()? {
            Outgoing::Hold { id, sealed } => {
                if self.done.contains(&id) {
                    return Some(Incoming::Held {
                        id,
                        depth: self.items.len() as u32,
                        expires_at: now,
                        delivered: true,
                    });
                }
                if let Some(seq) = self.by_id.get(&id) {
                    let exp = self.items[seq].2;
                    return Some(Incoming::Held {
                        id,
                        depth: self.items.len() as u32,
                        expires_at: exp,
                        delivered: false,
                    });
                }
                self.seq += 1;
                self.items.insert(self.seq, (id.clone(), sealed, now + HOLD_TTL_MS));
                self.by_id.insert(id.clone(), self.seq);
                Some(Incoming::Held {
                    id,
                    depth: self.items.len() as u32,
                    expires_at: now + HOLD_TTL_MS,
                    delivered: false,
                })
            }
            Outgoing::HeldAck { id } => {
                let seq = self.by_id.remove(&id)?;
                self.items.remove(&seq);
                self.done.insert(id.clone());
                Some(Incoming::Delivered { id })
            }
        }
    }

    fn drain(&self, now: u64) -> Vec<Incoming> {
        self.items
            .values()
            .map(|(id, sealed, exp)| Incoming::HeldItem {
                id: id.clone(),
                from: "phone".into(),
                sealed: sealed.clone(),
                at: now,
                expires_at: *exp,
            })
            .collect()
    }
}

/// A tiny deterministic generator, so a failing run replays.
struct Lcg(u64);
impl Lcg {
    fn next(&mut self, n: u64) -> u64 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        (self.0 >> 33) % n
    }
}

#[test]
fn frames_match_the_relay_wire() {
    let hold = Outgoing::Hold { id: "a".into(), sealed: "AQ".into() }.to_text();
    assert_eq!(hold, r#"{"type":"hold","id":"a","sealed":"AQ"}"#);
    assert_eq!(HeldInbox::ack("ABC"), r#"{"type":"held_ack","id":"abc"}"#);
    let held = Incoming::parse(r#"{"type":"held","id":"a","depth":2,"expiresAt":9}"#).unwrap();
    assert_eq!(held, Incoming::Held { id: "a".into(), depth: 2, expires_at: 9, delivered: false });
    let item =
        Incoming::parse(r#"{"type":"held_item","id":"a","from":"p","sealed":"AQ","at":1,"expiresAt":9}"#);
    assert!(matches!(item, Some(Incoming::HeldItem { .. })));
    assert_eq!(
        Incoming::parse(r#"{"type":"hold_refused","code":"bad"}"#),
        Some(Incoming::HoldRefused { id: None, code: RefusedCode::Bad })
    );
    assert_eq!(Incoming::parse(r#"{"type":"joined","peer":false}"#), None);
}

#[test]
fn the_sender_counts_acceptance_from_the_first_write_and_resends_only_unanswered() {
    let mut s = HoldSender::new();
    s.send("ID1", "AQ", 100);
    s.send("id2", "Ag", 110);
    // A second write of the same id keeps the first write's time and the first sealed bytes.
    assert_eq!(s.send("id1", "zz", 150), r#"{"type":"hold","id":"id1","sealed":"AQ"}"#);
    let ev = s.on_frame(&Incoming::Held { id: "id1".into(), depth: 1, expires_at: 0, delivered: false }, 160);
    assert_eq!(ev, Some(SenderEvent::Accepted { id: "id1".into(), ms: 60 }));
    assert_eq!(s.resend(), vec![r#"{"type":"hold","id":"id2","sealed":"Ag"}"#.to_string()]);
    let refused = s.on_frame(&Incoming::HoldRefused { id: Some("id2".into()), code: RefusedCode::Off }, 170);
    assert_eq!(refused, Some(SenderEvent::Refused { id: "id2".into(), code: RefusedCode::Off }));
    assert_eq!(
        s.on_frame(&Incoming::Delivered { id: "id1".into() }, 180),
        Some(SenderEvent::Delivered { id: "id1".into() })
    );
    s.prune_delivered();
    assert_eq!(s.state("id1"), None);
}

#[test]
fn the_inbox_applies_once_survives_a_restart_and_forgets_after_expiry() {
    let mut inbox = HeldInbox::new();
    assert_eq!(inbox.check("A"), Verdict::Apply);
    inbox.settle("A", 1_000, 10);
    let restored = HeldInbox::restore(&inbox.snapshot()).unwrap();
    assert_eq!(restored.check("a"), Verdict::AckOnly);
    assert!(HeldInbox::restore(b"not json").is_err());
    inbox.settle("b", 2_000, 1_500);
    assert_eq!(
        inbox.check("a"),
        Verdict::Apply,
        "expired ids are dropped: the relay can no longer redeliver them"
    );
    assert_eq!(inbox.len(), 1);
}

/// RFD 0142 R8's stop: 100 kill-and-wake runs, the Mac unreachable at send, then waking, with a kill at a random
/// point on each side: 0 duplicate and 0 lost sends.
#[test]
fn kill_and_wake_100_runs_zero_duplicates_zero_lost() {
    let mut rng = Lcg(0x5eed_0142);
    let mut relay = ModelRelay::default();
    // The phone's outbox is durable (the composer's queued send); the Mac's durable state is its last snapshot.
    let mut phone = HoldSender::new();
    let mut mac_disk: Vec<u8> = HeldInbox::new().snapshot();
    let mut applied: HashMap<String, u32> = HashMap::new();
    let mut accepted_ms = Vec::new();
    let mut now = 1_000u64;
    let (mut phone_kills, mut mac_kills) = (0, 0);
    for run in 0..100 {
        let id = format!("00000000-0000-4000-8000-{run:012}");
        now += 50;
        // The Mac is asleep. The phone sends; on some runs the relay's answer is lost with the phone's socket.
        let frame = phone.send(&id, "c2VhbGVk", now);
        let answer = relay.on_text(&frame, now + 20);
        if rng.next(3) == 0 {
            phone_kills += 1;
            now += 200;
            for again in phone.resend() {
                if let Some(a) = relay.on_text(&again, now + 20) {
                    if let Some(SenderEvent::Accepted { ms, .. }) = phone.on_frame(&a, now + 40) {
                        accepted_ms.push(ms);
                    }
                }
            }
        } else if let Some(SenderEvent::Accepted { ms, .. }) = phone.on_frame(&answer.unwrap(), now + 40) {
            accepted_ms.push(ms);
        }
        assert_eq!(phone.state(&id), Some(SendState::Accepted), "run {run}");
        // The Mac wakes, perhaps several times: killed before applying, after applying and before its ack, or not.
        loop {
            now += 100;
            let mut inbox = HeldInbox::restore(&mac_disk).unwrap();
            let kill_at = rng.next(4); // 0: before apply, 1: after settle before ack, 2..: no kill
            let mut killed = false;
            for item in relay.drain(now) {
                let Incoming::HeldItem { id, expires_at, .. } = item else { unreachable!() };
                if kill_at == 0 {
                    killed = true;
                    break;
                }
                if inbox.check(&id) == Verdict::Apply {
                    // The send's effect and the settle go to disk in one write.
                    *applied.entry(id.clone()).or_default() += 1;
                    inbox.settle(&id, expires_at, now);
                    mac_disk = inbox.snapshot();
                }
                if kill_at == 1 {
                    killed = true;
                    break;
                }
                if let Some(ev) = relay.on_text(&HeldInbox::ack(&id), now) {
                    phone.on_frame(&ev, now);
                }
            }
            if !killed {
                break;
            }
            mac_kills += 1;
        }
        assert_eq!(phone.state(&id), Some(SendState::Delivered), "run {run}");
        phone.prune_delivered();
    }
    let dups = applied.values().filter(|n| **n > 1).count();
    let lost = 100 - applied.len();
    accepted_ms.sort_unstable();
    eprintln!(
        "{}",
        serde_json::json!({"row": "relay-hold kill-and-wake (model)", "runs": 100, "duplicates": dups, "lost": lost,
            "phoneKills": phone_kills, "macKills": mac_kills, "acceptedP50Ms": accepted_ms[accepted_ms.len() / 2]})
    );
    assert_eq!(dups, 0);
    assert_eq!(lost, 0);
    assert!(relay.items.is_empty());
    assert!(phone_kills > 10 && mac_kills > 10, "the runs exercised both kill sides");
}
