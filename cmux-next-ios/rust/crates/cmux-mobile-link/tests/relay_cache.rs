//! The relay cache client (src/relay_cache.rs) against the fake backend's relay cache
//! (`FakeOptions::relay_cache`, testing/relay_cache.rs): cold open, resume, ack, and the refusals.

use cmux_mobile_link::api::ApiClient;
use cmux_mobile_link::relay_cache::{DEFAULT_BUDGET_BYTES, RelayCache, RelayCacheConfig, RelayCacheError};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use cmux_relay_snapshot::delta::{ApplyError, delta_stream};
use cmux_relay_snapshot::{Floor, Position, seal};
use p256::ecdsa::SigningKey;
use p256::{PublicKey, SecretKey};

const MAC: &str = "00000000-0000-4000-8000-0000000000aa";
const PHONE: &str = "00000000-0000-4000-8000-0000000000bb";
const STREAM: &str = "chat/one";

struct Rig {
    _server: FakeSignaling,
    mac: RelayCache,
    phone: RelayCache,
    mac_key: SigningKey,
    phone_key: SecretKey,
}

impl Rig {
    async fn start(relay_cache: bool) -> Self {
        let server = FakeSignaling::start(FakeOptions { relay_cache, ..FakeOptions::default() }).await;
        let on = RelayCacheConfig { enabled: true };
        let mac = RelayCache::new(ApiClient::new(&server.base_url, "user:me"), MAC, on);
        let phone = RelayCache::new(ApiClient::new(&server.base_url, "user:me"), PHONE, on);
        let mac_key = SigningKey::random(&mut p256::elliptic_curve::rand_core::OsRng);
        let phone_key = SecretKey::random(&mut p256::elliptic_curve::rand_core::OsRng);
        Self { _server: server, mac, phone, mac_key, phone_key }
    }

    fn source(&self) -> PublicKey {
        PublicKey::from(self.mac_key.verifying_key())
    }

    fn seal(&self, stream: &str, seq: u64, text: &str) -> Vec<u8> {
        seal(&self.mac_key, &self.phone_key.public_key(), stream, Position { epoch: 7, seq }, text.as_bytes())
            .unwrap()
    }

    async fn delta(&self, seq: u64, text: &str) {
        let env = self.seal(&delta_stream(STREAM), seq, text);
        self.phone_slot_put_delta(env).await;
    }

    async fn phone_slot_put_delta(&self, env: Vec<u8>) {
        self.mac.append_delta(PHONE, STREAM, env).await.unwrap();
    }
}

#[tokio::test]
async fn cold_open_reads_the_newest_snapshot_and_raises_the_floor() {
    let rig = Rig::start(true).await;
    let mut floor = Floor::default();
    let none = rig.phone.cold_open(MAC, &rig.source(), &rig.phone_key, STREAM, &mut floor).await.unwrap();
    assert!(none.is_none(), "no snapshot yet");
    rig.mac.put_snapshot(PHONE, STREAM, rig.seal(STREAM, 4, "four")).await.unwrap();
    rig.mac.put_snapshot(PHONE, STREAM, rig.seal(STREAM, 2, "older")).await.unwrap();
    let opened =
        rig.phone.cold_open(MAC, &rig.source(), &rig.phone_key, STREAM, &mut floor).await.unwrap().unwrap();
    assert_eq!(opened.opened.plaintext, b"four");
    assert!(opened.cached_at_ms.is_some());
    assert_eq!(floor.position(), Some(Position { epoch: 7, seq: 4 }));
}

#[tokio::test]
async fn cold_open_refuses_a_snapshot_from_another_key() {
    let rig = Rig::start(true).await;
    let other = SigningKey::random(&mut p256::elliptic_curve::rand_core::OsRng);
    let forged =
        seal(&other, &rig.phone_key.public_key(), STREAM, Position { epoch: 9, seq: 9 }, b"x").unwrap();
    rig.mac.put_snapshot(PHONE, STREAM, forged).await.unwrap();
    let mut floor = Floor::default();
    let refused = rig.phone.cold_open(MAC, &rig.source(), &rig.phone_key, STREAM, &mut floor).await;
    assert!(matches!(refused, Err(RelayCacheError::Seal(cmux_relay_snapshot::Error::WrongSource))));
    assert_eq!(floor.position(), None);
}

#[tokio::test]
async fn resume_applies_deltas_in_order_then_acks() {
    let rig = Rig::start(true).await;
    rig.mac.put_snapshot(PHONE, STREAM, rig.seal(STREAM, 1, "base")).await.unwrap();
    for seq in 2..=5 {
        rig.delta(seq, &format!("d{seq}")).await;
    }
    let mut floor = Floor::default();
    rig.phone.cold_open(MAC, &rig.source(), &rig.phone_key, STREAM, &mut floor).await.unwrap().unwrap();
    let mut floors =
        vec![(STREAM.to_owned(), floor), ("chat/none".to_owned(), Floor::at(Position { epoch: 7, seq: 0 }))];
    let resume = rig
        .phone
        .resume(MAC, &rig.source(), &rig.phone_key, &mut floors, DEFAULT_BUDGET_BYTES)
        .await
        .unwrap();
    assert_eq!(resume.cut, vec!["chat/none".to_owned()], "nothing held for it: ask the Mac");
    let got = &resume.surfaces[0];
    let texts: Vec<_> = got.applied.iter().map(|o| String::from_utf8(o.plaintext.clone()).unwrap()).collect();
    assert_eq!(texts, ["d2", "d3", "d4", "d5"]);
    assert!(got.stopped.is_none());
    assert_eq!(floors[0].1.position(), Some(Position { epoch: 7, seq: 5 }));
    assert_eq!(rig.phone.ack(MAC, STREAM, Position { epoch: 7, seq: 5 }).await.unwrap(), 4);
    let again = rig
        .phone
        .resume(MAC, &rig.source(), &rig.phone_key, &mut floors[..1], DEFAULT_BUDGET_BYTES)
        .await
        .unwrap();
    assert!(again.surfaces[0].applied.is_empty(), "current after the ack");
}

#[tokio::test]
async fn resume_stops_at_the_first_delta_that_does_not_open() {
    let rig = Rig::start(true).await;
    rig.delta(1, "d1").await;
    // Sealed on the snapshot stream, not `<stream>/delta`: the stream is signed, so it does not verify as a delta.
    rig.phone_slot_put_delta(rig.seal(STREAM, 2, "wrong stream")).await;
    rig.delta(3, "d3").await;
    let mut floors = vec![(STREAM.to_owned(), Floor::at(Position { epoch: 7, seq: 0 }))];
    let resume = rig
        .phone
        .resume(MAC, &rig.source(), &rig.phone_key, &mut floors, DEFAULT_BUDGET_BYTES)
        .await
        .unwrap();
    let got = &resume.surfaces[0];
    assert_eq!(got.applied.len(), 1);
    assert!(matches!(got.stopped, Some(ApplyError::Seal(cmux_relay_snapshot::Error::BadSignature))));
    assert_eq!(floors[0].1.position(), Some(Position { epoch: 7, seq: 1 }));
}

#[tokio::test]
async fn a_catch_up_over_the_budget_is_cut() {
    let rig = Rig::start(true).await;
    let big = "x".repeat(40 * 1024);
    rig.delta(1, &big).await;
    rig.delta(2, &big).await;
    let mut floors = vec![(STREAM.to_owned(), Floor::at(Position { epoch: 7, seq: 0 }))];
    let resume = rig
        .phone
        .resume(MAC, &rig.source(), &rig.phone_key, &mut floors, DEFAULT_BUDGET_BYTES)
        .await
        .unwrap();
    assert!(resume.surfaces.is_empty());
    assert_eq!(resume.cut, vec![STREAM.to_owned()]);
    let bigger = rig.phone.resume(MAC, &rig.source(), &rig.phone_key, &mut floors, 256 * 1024).await.unwrap();
    assert_eq!(bigger.surfaces[0].applied.len(), 2);
}

#[tokio::test]
async fn a_cut_surface_resumes_from_the_newest_snapshot() {
    let rig = Rig::start(true).await;
    let big = "x".repeat(40 * 1024);
    rig.delta(1, &big).await;
    rig.delta(2, &big).await;
    rig.mac.put_snapshot(PHONE, STREAM, rig.seal(STREAM, 2, "state at two")).await.unwrap();
    let mut floors = vec![(STREAM.to_owned(), Floor::at(Position { epoch: 7, seq: 0 }))];
    let resume = rig
        .phone
        .resume_or_snapshot(MAC, &rig.source(), &rig.phone_key, &mut floors, DEFAULT_BUDGET_BYTES)
        .await
        .unwrap();
    assert_eq!(resume.cut, vec![STREAM.to_owned()]);
    assert_eq!(resume.snapshots.len(), 1);
    assert_eq!(resume.snapshots[0].plaintext, b"state at two");
    assert_eq!(floors[0].1.position(), Some(Position { epoch: 7, seq: 2 }));
}

#[tokio::test]
async fn the_relay_switch_off_answers_relay_cache_off() {
    let rig = Rig::start(false).await;
    let refused = rig.phone.snapshot(MAC, STREAM).await;
    assert!(matches!(refused, Err(RelayCacheError::RelayOff(code)) if code == "relay_cache_off"));
}

#[tokio::test]
async fn only_the_source_writes() {
    let rig = Rig::start(true).await;
    let refused = rig.phone.put_snapshot(PHONE, STREAM, rig.seal(STREAM, 1, "x")).await;
    // The phone writes to its own id as the source: the fake sees deviceId == source, so it is the
    // viewer naming a slot under itself. A write to the Mac's cache must come from the Mac.
    assert!(refused.is_ok());
    let mut floor = Floor::default();
    let none = rig.phone.cold_open(MAC, &rig.source(), &rig.phone_key, STREAM, &mut floor).await.unwrap();
    assert!(none.is_none(), "the phone's put landed under the phone, not the Mac");
}
