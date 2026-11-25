//! The Mac's relay publisher (src/relay_publish.rs) into the fake backend's relay cache, read back
//! by the phone's client (cmux_mobile_link::relay_cache): every paired phone with a push key gets
//! its own sealed copy, the deltas follow the snapshot's position, and off publishes nothing.

use cmux_mobile_host::pairing::{DeviceTrust, TrustedDevice};
use cmux_mobile_host::push_keys::PushKeys;
use cmux_mobile_host::relay_publish::{RelayPublishConfig, RelayPublisher, viewers};
use cmux_mobile_host::seal::hex;
use cmux_mobile_link::api::ApiClient;
use cmux_mobile_link::relay_cache::{DEFAULT_BUDGET_BYTES, FIRST_SCREEN_BYTES, RelayCache, RelayCacheConfig};
use cmux_mobile_link::testing::{FakeOptions, FakeSignaling};
use cmux_relay_snapshot::Floor;
use p256::SecretKey;
use p256::ecdsa::SigningKey;
use p256::elliptic_curve::rand_core::OsRng;
use p256::elliptic_curve::sec1::ToEncodedPoint as _;

const MAC: &str = "00000000-0000-4000-8000-0000000000aa";
const PHONES: [&str; 2] = ["00000000-0000-4000-8000-0000000000b1", "00000000-0000-4000-8000-0000000000b2"];
const STREAM: &str = "chat/one";

fn on() -> RelayCacheConfig {
    RelayCacheConfig { enabled: true }
}

#[tokio::test]
async fn each_paired_phone_cold_opens_and_resumes_from_its_own_copy() {
    let server = FakeSignaling::start(FakeOptions { relay_cache: true, ..FakeOptions::default() }).await;
    let keys: Vec<SecretKey> = PHONES.iter().map(|_| SecretKey::random(&mut OsRng)).collect();
    let push_keys = PushKeys::memory();
    let mut trust = DeviceTrust::default();
    for (phone, key) in PHONES.iter().zip(&keys) {
        let point = hex(key.public_key().to_encoded_point(false).as_bytes());
        push_keys.set(phone, "identity", &point);
        trust.devices.push(TrustedDevice {
            id: (*phone).to_owned(),
            identity_key: "identity".into(),
            ..TrustedDevice::default()
        });
    }
    // A phone the Mac no longer pairs gets nothing.
    push_keys.set(
        "00000000-0000-4000-8000-0000000000b3",
        "gone",
        &hex(keys[0].public_key().to_encoded_point(false).as_bytes()),
    );
    let viewers = viewers(&push_keys, &trust);
    assert_eq!(viewers.len(), 2);

    let mac = RelayCache::new(ApiClient::new(&server.base_url, "user:me"), MAC, on());
    let publisher =
        RelayPublisher::new(mac, SigningKey::random(&mut OsRng), 5, RelayPublishConfig { enabled: true });
    publisher.publish_delta(&viewers, STREAM, b"one").await;
    let snap = publisher.publish_snapshot(&viewers, STREAM, b"state after one").await;
    assert_eq!((snap.sent, snap.failed), (2, 0), "{:?}", snap.first_error);
    for change in [&b"two"[..], b"three"] {
        assert_eq!(publisher.publish_delta(&viewers, STREAM, change).await.sent, 2);
    }

    for (phone, key) in PHONES.iter().zip(&keys) {
        let client = RelayCache::new(ApiClient::new(&server.base_url, "user:me"), phone, on());
        let mut floor = Floor::default();
        let opened =
            client.cold_open(MAC, &publisher.source_key(), key, STREAM, &mut floor).await.unwrap().unwrap();
        assert_eq!(opened.opened.plaintext, b"state after one");
        let mut floors = vec![(STREAM.to_owned(), floor)];
        let resume = client
            .resume(MAC, &publisher.source_key(), key, &mut floors, DEFAULT_BUDGET_BYTES)
            .await
            .unwrap();
        let texts: Vec<_> = resume.surfaces[0].applied.iter().map(|o| o.plaintext.clone()).collect();
        assert_eq!(texts, [b"two".to_vec(), b"three".to_vec()]);
        assert!(resume.surfaces[0].stopped.is_none());
    }
    // Phone 1's copy does not open with phone 2's key.
    let client = RelayCache::new(ApiClient::new(&server.base_url, "user:me"), PHONES[0], on());
    let mut floor = Floor::default();
    assert!(client.cold_open(MAC, &publisher.source_key(), &keys[1], STREAM, &mut floor).await.is_err());
}

#[tokio::test]
async fn off_publishes_nothing() {
    let server = FakeSignaling::start(FakeOptions { relay_cache: true, ..FakeOptions::default() }).await;
    let mac = RelayCache::new(ApiClient::new(&server.base_url, "user:me"), MAC, on());
    let publisher =
        RelayPublisher::new(mac, SigningKey::random(&mut OsRng), 1, RelayPublishConfig::default());
    let phone = SecretKey::random(&mut OsRng);
    let viewers =
        vec![cmux_mobile_host::relay_publish::Viewer { device: PHONES[0].into(), key: phone.public_key() }];
    assert_eq!(publisher.publish_snapshot(&viewers, STREAM, b"x").await.sent, 0);
    assert_eq!(publisher.publish_delta(&viewers, STREAM, b"y").await.sent, 0);
    assert_eq!(server.relay_cache_hits("snapshot PUT") + server.relay_cache_hits("delta POST"), 0);
}

#[tokio::test]
async fn the_first_screen_opens_at_the_snapshots_position_and_stays_in_its_bound() {
    let server = FakeSignaling::start(FakeOptions { relay_cache: true, ..FakeOptions::default() }).await;
    let mac = RelayCache::new(ApiClient::new(&server.base_url, "user:me"), MAC, on());
    let publisher =
        RelayPublisher::new(mac, SigningKey::random(&mut OsRng), 3, RelayPublishConfig { enabled: true });
    let phone = SecretKey::random(&mut OsRng);
    let viewers =
        vec![cmux_mobile_host::relay_publish::Viewer { device: PHONES[0].into(), key: phone.public_key() }];
    publisher.publish_delta(&viewers, STREAM, b"one").await;
    publisher.publish_snapshot(&viewers, STREAM, b"whole state").await;
    assert_eq!(publisher.publish_first_screen(&viewers, STREAM, b"newest lines").await.sent, 1);
    let over = publisher.publish_first_screen(&viewers, STREAM, &vec![b'x'; FIRST_SCREEN_BYTES + 1]).await;
    assert_eq!((over.sent, over.failed), (0, 1));

    let client = RelayCache::new(ApiClient::new(&server.base_url, "user:me"), PHONES[0], on());
    let (mut first, mut whole) = (Floor::default(), Floor::default());
    let screen = client
        .cold_open_first_screen(MAC, &publisher.source_key(), &phone, STREAM, &mut first)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(screen.opened.plaintext, b"newest lines");
    let all =
        client.cold_open(MAC, &publisher.source_key(), &phone, STREAM, &mut whole).await.unwrap().unwrap();
    assert_eq!(all.opened.plaintext, b"whole state");
    assert_eq!(screen.opened.position, all.opened.position);
}
