use p256::ecdsa::signature::Signer as _;
use p256::ecdsa::{Signature, SigningKey};
use p256::elliptic_curve::sec1::ToEncodedPoint;
use p256::{PublicKey, SecretKey};
use serde_json::{Value, json};

use super::seal::{self, ack_message, hex, public_key_hex, unhex};
use super::*;

const MAC: &str = "6f1c2a7e-0b1d-4c55-9a43-2d8e5b7f3c10";
const PHONE: &str = "a2b4c6d8-1e3f-4a5b-8c7d-9e0f1a2b3c4d";
const ID: &str = "0d9f5e2c-7b3a-4e61-8f20-5c4b3a291807";
const NOW: u64 = 1_792_540_800;

fn vectors() -> Value {
    serde_json::from_str(include_str!("../../../cmux-mobile-host/tests/fixtures/seal-vectors.json")).unwrap()
}

fn text<'a>(v: &'a Value, pointer: &str) -> &'a str {
    v.pointer(pointer).and_then(Value::as_str).unwrap_or_else(|| panic!("{pointer}"))
}

struct Identity(SigningKey);

impl Identity {
    fn from_scalar(hex_scalar: &str) -> Self {
        Self(SigningKey::from_slice(&unhex(hex_scalar).unwrap()).unwrap())
    }
    fn random() -> Self {
        Self(SigningKey::random(&mut p256::elliptic_curve::rand_core::OsRng))
    }
    fn key_hex(&self) -> String {
        hex(self.0.verifying_key().to_encoded_point(false).as_bytes())
    }
    fn sign_hex(&self, message: &[u8]) -> String {
        let signature: Signature = self.0.sign(message);
        hex(&signature.to_bytes())
    }
}

impl Signer for Identity {
    fn sign(&self, message: &[u8]) -> Result<Vec<u8>, String> {
        let signature: Signature = self.0.sign(message);
        Ok(signature.to_bytes().to_vec())
    }
}

fn spec(kind: &str, action: Action) -> ItemSpec {
    ItemSpec {
        id: ID.into(),
        mac: MAC.into(),
        phone: PHONE.into(),
        kind: kind.into(),
        target: Target { session_id: Some("s1".into()), ..Default::default() },
        action,
        approval: None,
        nonce: Some("n0nce0123456789abcdef".into()),
        issued_at: NOW,
        lifetime_secs: None,
    }
}

fn say(text: &str) -> Action {
    Action::Text { text: text.into(), steer: None }
}

/// Opens as the Mac does (the host's `seal::open`, written out: this crate does not depend on it).
fn open(key: &SecretKey, sealed: &str) -> Value {
    use aes_gcm::aead::{Aead, Payload};
    use aes_gcm::{Aes256Gcm, KeyInit, Nonce};
    use base64::Engine as _;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(sealed).unwrap();
    assert_eq!(bytes[0], 1);
    let ephemeral = PublicKey::from_sec1_bytes(&bytes[1..66]).unwrap();
    let context = seal::reply_context(MAC, PHONE, ID);
    let shared = p256::ecdh::diffie_hellman(key.to_nonzero_scalar(), ephemeral.as_affine());
    let mut salt = bytes[1..66].to_vec();
    salt.extend_from_slice(key.public_key().to_encoded_point(false).as_bytes());
    let mut k = [0u8; 32];
    hkdf::Hkdf::<sha2::Sha256>::new(Some(&salt), shared.raw_secret_bytes().as_slice())
        .expand(&context, &mut k)
        .unwrap();
    let plain = Aes256Gcm::new(&k.into())
        .decrypt(Nonce::from_slice(&bytes[66..78]), Payload { msg: &bytes[78..], aad: &context })
        .unwrap();
    serde_json::from_slice(&plain).unwrap()
}

#[test]
fn the_shared_reply_vector_seals_and_signs_byte_for_byte() {
    let v = vectors();
    let reply = &v["reply"];
    let plaintext: Value = serde_json::from_str(text(reply, "/plaintext")).unwrap();
    let mut unsigned = plaintext.clone();
    unsigned.as_object_mut().unwrap().remove("sig");
    // The canonical text, its signature message and the phone's signature (made by Python).
    let canonical = canon::canonical(&unsigned).unwrap();
    assert_eq!(canonical, text(reply, "/canonical"));
    let message = seal::signed_message(MAC, PHONE, &canonical);
    assert_eq!(hex(&message), text(reply, "/signatureMessage"));
    assert!(seal::verify(text(&v, "/phoneIdentityKey"), &message, text(&plaintext, "/sig")));
    // The seal, with the vector's ephemeral key and nonce.
    let recipient = public_key_hex(text(&v, "/macBoxKey")).unwrap();
    let context = seal::reply_context(MAC, PHONE, text(reply, "/id"));
    assert_eq!(hex(&context), text(reply, "/context"));
    let ephemeral = SecretKey::from_slice(&unhex(text(reply, "/ephemeralScalar")).unwrap()).unwrap();
    let nonce: [u8; 12] = unhex(text(reply, "/nonce")).unwrap().try_into().unwrap();
    let boxed =
        seal::seal_with(&recipient, &context, text(reply, "/plaintext").as_bytes(), &ephemeral, &nonce)
            .unwrap();
    assert_eq!(boxed, text(reply, "/box"));
}

#[test]
fn a_send_builds_to_the_vector_shape_and_opens_with_the_mac_box_key() {
    let v = vectors();
    let phone = Identity::from_scalar(text(&v, "/phoneIdentityScalar"));
    assert_eq!(phone.key_hex(), text(&v, "/phoneIdentityKey"));
    let box_secret = SecretKey::from_slice(&unhex(text(&v, "/macBoxScalar")).unwrap()).unwrap();
    // The box key checks against the pinned identity through its signature.
    let key = trusted_box_key(
        MAC,
        Some(text(&v, "/macBoxKey")),
        Some(text(&v, "/macBoxSignature")),
        Some(text(&v, "/macIdentityKey")),
    )
    .unwrap();
    assert_eq!(key, box_secret.public_key());

    let mut s = spec("send", Action::Text { text: "ship it\n\"now\"".into(), steer: Some(false) });
    s.id = ID.to_uppercase();
    let item = build(&s, &key, &phone, NOW + 5).unwrap();
    assert_eq!((item.id.as_str(), item.expires_at), (ID, NOW + 86_400));
    let opened = open(&box_secret, &item.sealed);
    let mut unsigned = opened;
    let sig = unsigned.as_object_mut().unwrap().remove("sig").unwrap();
    assert_eq!(
        unsigned,
        json!({"v": 1, "id": ID, "mac": MAC, "phone": PHONE, "kind": "send", "target": {"sessionId": "s1"},
               "action": {"type": "text", "text": "ship it\n\"now\"", "steer": false},
               "nonce": "n0nce0123456789abcdef", "issuedAt": NOW, "expiresAt": NOW + 86_400})
    );
    let message = seal::signed_message(MAC, PHONE, &canon::canonical(&unsigned).unwrap());
    assert!(seal::verify(&phone.key_hex(), &message, sig.as_str().unwrap()));
    assert!(!seal::verify(text(&v, "/macIdentityKey"), &message, sig.as_str().unwrap()));
}

#[test]
fn lifetimes_by_kind_and_hold_is_the_time_left() {
    let mac = Identity::random();
    let box_key = SecretKey::random(&mut p256::elliptic_curve::rand_core::OsRng).public_key();
    let _ = mac;
    let phone = Identity::random();
    let long = build(&spec("send", say("hi")), &box_key, &phone, NOW).unwrap();
    let reply = build(&spec("completed", say("hi")), &box_key, &phone, NOW).unwrap();
    assert_eq!((long.expires_at - NOW, reply.expires_at - NOW), (86_400, 540));
    // A longer wish is capped; a shorter one kept; never under a second.
    let mut s = spec("compose", Action::Queue(QueueOp::Remove { prompt_id: "p1".into() }));
    s.lifetime_secs = Some(10 * 86_400);
    assert_eq!(build(&s, &box_key, &phone, NOW).unwrap().expires_at - NOW, 86_400);
    s.lifetime_secs = Some(3_600);
    assert_eq!(build(&s, &box_key, &phone, NOW).unwrap().expires_at - NOW, 3_600);
    let mut r = spec("completed", say("hi"));
    r.lifetime_secs = Some(10_000);
    assert_eq!(build(&r, &box_key, &phone, NOW).unwrap().expires_at - NOW, 540);
    // hold: the time left, at most a day, at most 600 for a hub known to be old.
    assert_eq!(long.hold(NOW + 100, false), Some(86_300));
    assert_eq!(long.hold(NOW + 100, true), Some(600));
    assert_eq!(reply.hold(NOW + 500, false), Some(40));
    assert_eq!(reply.hold(NOW + 540, false), None);
    let body: Value = serde_json::from_str(&long.post_body(NOW + 100, false).unwrap()).unwrap();
    assert_eq!(body, json!({"id": ID, "from": PHONE, "sealed": long.sealed, "hold": 86_300}));
    // Already over at build time.
    assert_eq!(
        build(&spec("completed", say("x")), &box_key, &phone, NOW + 540).unwrap_err(),
        ItemError::Expired
    );
}

#[test]
fn compose_actions_and_refusals() {
    let box_key = SecretKey::random(&mut p256::elliptic_curve::rand_core::OsRng).public_key();
    let phone = Identity::random();
    let built = |kind: &str, action: Action| build(&spec(kind, action), &box_key, &phone, NOW);
    let queue = |op| Action::Queue(op);
    assert!(built("compose", queue(QueueOp::Move { prompt_id: "p".into(), index: 0 })).is_ok());
    assert!(built("compose", queue(QueueOp::Update { prompt_id: "p".into(), text: "t".into() })).is_ok());
    assert!(matches!(
        built("send", queue(QueueOp::Remove { prompt_id: "p".into() })),
        Err(ItemError::Unsupported(_))
    ));
    assert!(matches!(built("compose", say("x")), Err(ItemError::Unsupported(_))));
    assert!(matches!(built("send", Action::Deny { option_id: None }), Err(ItemError::Unsupported(_))));
    assert_eq!(built("send", say(&"x".repeat(4097))).unwrap_err(), ItemError::TooLong);
    assert_eq!(built("completed", Action::Allow { option_id: "o".into() }).unwrap_err(), ItemError::Unsigned);
    assert!(built("permission", Action::Deny { option_id: None }).is_ok());
    let mut no_session = spec("send", say("x"));
    no_session.target.session_id = None;
    assert_eq!(build(&no_session, &box_key, &phone, NOW).unwrap_err(), ItemError::Invalid("sessionId"));
    let mut bad_nonce = spec("send", say("x"));
    bad_nonce.nonce = Some("short".into());
    assert_eq!(build(&bad_nonce, &box_key, &phone, NOW).unwrap_err(), ItemError::Invalid("nonce"));
    let mut bad_id = spec("send", say("x"));
    bad_id.id = "not-a-uuid".into();
    assert_eq!(build(&bad_id, &box_key, &phone, NOW).unwrap_err(), ItemError::Invalid("id"));
    // Over the service's limit once sealed: 4096 bytes of text that escapes to six times its size.
    assert_eq!(built("send", say(&"\u{1}".repeat(4096))).unwrap_err(), ItemError::TooLong);
}

#[test]
fn a_box_key_is_trusted_only_with_the_pinned_identitys_signature() {
    let v = vectors();
    let (key, sig, pin) = (text(&v, "/macBoxKey"), text(&v, "/macBoxSignature"), text(&v, "/macIdentityKey"));
    assert!(trusted_box_key(MAC, Some(key), Some(sig), Some(pin)).is_ok());
    assert!(trusted_box_key(&MAC.to_uppercase(), Some(key), Some(sig), Some(pin)).is_ok());
    assert_eq!(trusted_box_key(MAC, None, Some(sig), Some(pin)).unwrap_err(), ItemError::NoBoxKey);
    assert_eq!(trusted_box_key(MAC, Some(key), None, Some(pin)).unwrap_err(), ItemError::UntrustedBoxKey);
    assert_eq!(trusted_box_key(MAC, Some(key), Some(sig), None).unwrap_err(), ItemError::UntrustedBoxKey);
    let other = Identity::random().key_hex();
    assert_eq!(
        trusted_box_key(MAC, Some(key), Some(sig), Some(&other)).unwrap_err(),
        ItemError::UntrustedBoxKey
    );
    assert_eq!(
        trusted_box_key("other-mac", Some(key), Some(sig), Some(pin)).unwrap_err(),
        ItemError::UntrustedBoxKey
    );
    assert!(mailbox_available("send", true, true));
    assert!(!mailbox_available("send", false, true));
    assert!(mailbox_available("completed", false, true));
    assert!(!mailbox_available("completed", true, false));
}

// -- the tracker --

struct Hub {
    mac: Identity,
}

impl Hub {
    fn ack(&self, applied: bool, reason: Option<&str>) -> String {
        self.mac.sign_hex(&ack_message(MAC, ID, applied, reason))
    }
    fn outcome(&self, state: &str, reason: Option<&str>) -> String {
        let sig = match state {
            "applied" => Some(self.ack(true, None)),
            "rejected" => Some(self.ack(false, reason)),
            _ => None,
        };
        json!({"state": state, "reason": reason, "sig": sig, "seq": 3, "expiresAt": (NOW + 86_400) * 1000})
            .to_string()
    }
}

fn tracker(hub: &Hub, kind: &str) -> Tracker {
    let box_key = SecretKey::random(&mut p256::elliptic_curve::rand_core::OsRng).public_key();
    let item = build(&spec(kind, say("hi")), &box_key, &Identity::random(), NOW).unwrap();
    Tracker::new(item, Some(hub.mac.key_hex()), false, NOW * 1000)
}

fn posted(t: &mut Tracker, now: u64, status: u16, body: &str) {
    let Step::Send(Request::Post { path, body: sent }) = t.next(now) else { panic!("{:?}", t.state()) };
    assert_eq!(path, format!("/v1/devices/{MAC}/mailbox"));
    let sent: Value = serde_json::from_str(&sent).unwrap();
    assert_eq!(sent["id"], ID);
    t.on_post(status, body, now);
}

#[test]
fn a_new_hub_queues_polls_on_schedule_and_trusts_a_signed_applied() {
    let hub = Hub { mac: Identity::random() };
    let mut t = tracker(&hub, "send");
    let t0 = NOW * 1000;
    posted(
        &mut t,
        t0,
        200,
        &json!({"queued": true, "delivered": false, "seq": 3, "expiresAt": (NOW + 86_400) * 1000})
            .to_string(),
    );
    assert_eq!(
        (t.state(), t.seq(), t.old_hub(), t.expires_at_ms()),
        (&State::Queued, Some(3), false, (NOW + 86_400) * 1000)
    );
    // Polls at +1, +2, +4, +8 s, then every 30 s.
    let mut now = t0;
    for gap in [1_000, 2_000, 4_000, 8_000, 30_000, 30_000] {
        assert_eq!(t.next(now + gap - 1), Step::Wait { until_ms: now + gap });
        now += gap;
        let Step::Send(Request::Poll { path }) = t.next(now) else { panic!() };
        assert_eq!(path, format!("/v1/devices/{MAC}/mailbox/{ID}"));
        t.on_poll(200, &hub.outcome("queued", None), now);
    }
    assert_eq!(t.state(), &State::Queued);
    t.next(now + 30_000);
    t.on_poll(200, &hub.outcome("applied", None), now + 30_000);
    assert_eq!(t.state(), &State::Applied);
    assert_eq!(t.next(now + 40_000), Step::Done);
}

#[test]
fn a_signed_rejection_carries_its_reason_and_a_forged_outcome_is_not_confirmed() {
    let hub = Hub { mac: Identity::random() };
    let mut t = tracker(&hub, "send");
    posted(&mut t, NOW * 1000, 200, r#"{"queued":true,"seq":1}"#);
    t.next(NOW * 1000 + 1_000);
    t.on_poll(200, &hub.outcome("rejected", Some("not_pending")), NOW * 1000 + 1_000);
    assert_eq!(t.state(), &State::Rejected { reason: "not_pending".into() });

    // No signature, another key's, another reason's, the other verdict's: all "not confirmed".
    let stranger = Hub { mac: Identity::random() };
    let forged = [
        json!({"state": "applied"}).to_string(),
        stranger.outcome("applied", None),
        json!({"state": "rejected", "reason": "expired", "sig": hub.ack(false, Some("not_pending"))})
            .to_string(),
        json!({"state": "rejected", "reason": "not_pending", "sig": hub.ack(true, None)}).to_string(),
        json!({"state": "applied", "sig": hub.ack(false, Some("refused"))}).to_string(),
    ];
    for body in forged {
        let mut t = tracker(&hub, "send");
        posted(&mut t, NOW * 1000, 200, r#"{"queued":true,"seq":1}"#);
        t.next(NOW * 1000 + 1_000);
        t.on_poll(200, &body, NOW * 1000 + 1_000);
        assert_eq!(t.state(), &State::NotConfirmed, "{body}");
    }
    // Without a pinned key nothing counts.
    let box_key = SecretKey::random(&mut p256::elliptic_curve::rand_core::OsRng).public_key();
    let item = build(&spec("send", say("hi")), &box_key, &Identity::random(), NOW).unwrap();
    let mut t = Tracker::new(item, None, false, NOW * 1000);
    posted(&mut t, NOW * 1000, 200, r#"{"queued":true,"seq":1}"#);
    t.next(NOW * 1000 + 1_000);
    t.on_poll(200, &hub.outcome("applied", None), NOW * 1000 + 1_000);
    assert_eq!(t.state(), &State::NotConfirmed);
}

#[test]
fn an_old_hub_gives_no_seq_and_holds_ten_minutes() {
    let hub = Hub { mac: Identity::random() };
    let mut t = tracker(&hub, "send");
    let t0 = NOW * 1000;
    posted(&mut t, t0, 200, r#"{"queued":true,"delivered":true}"#);
    assert_eq!((t.state(), t.seq(), t.old_hub(), t.delivered()), (&State::Queued, None, true, true));
    assert_eq!(t.expires_at_ms(), t0 + 600_000);
    // The next post of the same hub caps its hold at 600 s.
    let box_key = SecretKey::random(&mut p256::elliptic_curve::rand_core::OsRng).public_key();
    let item = build(&spec("send", say("hi")), &box_key, &Identity::random(), NOW).unwrap();
    let mut known_old = Tracker::new(item, None, true, t0);
    let Step::Send(Request::Post { body, .. }) = known_old.next(t0) else { panic!() };
    assert_eq!(serde_json::from_str::<Value>(&body).unwrap()["hold"], 600);
    // Unsettled well past the hold and its 10 minute outcome grace: expired.
    assert_eq!(t.next(t0 + 600_000 + 600_000), Step::Done);
    assert_eq!(t.state(), &State::Expired);
}

#[test]
fn conflict_is_queued_full_is_full_and_refusals_are_final() {
    let hub = Hub { mac: Identity::random() };
    let mut t = tracker(&hub, "send");
    posted(&mut t, NOW * 1000, 409, r#"{"error":"conflict"}"#);
    assert_eq!(t.state(), &State::Queued);
    // The poll then learns the seq and expiry.
    t.next(NOW * 1000 + 1_000);
    t.on_poll(200, &hub.outcome("queued", None), NOW * 1000 + 1_000);
    assert_eq!((t.seq(), t.expires_at_ms()), (Some(3), (NOW + 86_400) * 1000));

    let mut t = tracker(&hub, "send");
    posted(&mut t, NOW * 1000, 429, r#"{"error":"rate_limited"}"#);
    assert_eq!(t.next(NOW * 1000), Step::Done);
    assert_eq!(t.state(), &State::Full);
    t.retry(NOW * 1000 + 5_000);
    assert_eq!(t.state(), &State::Posting);
    posted(&mut t, NOW * 1000 + 5_000, 200, r#"{"queued":true,"seq":9}"#);
    assert_eq!(t.state(), &State::Queued);

    let mut t = tracker(&hub, "send");
    posted(&mut t, NOW * 1000, 403, r#"{"error":"not_owner"}"#);
    assert_eq!(t.state(), &State::Failed { code: "not_owner".into() });
    t.retry(NOW * 1000);
    assert_eq!(t.state(), &State::Failed { code: "not_owner".into() });
}

#[test]
fn a_flaky_network_retries_the_same_bytes_with_backoff() {
    let hub = Hub { mac: Identity::random() };
    let mut t = tracker(&hub, "send");
    let t0 = NOW * 1000;
    let Step::Send(Request::Post { body: first, .. }) = t.next(t0) else { panic!() };
    t.on_transport_error(t0);
    assert_eq!(t.next(t0), Step::Wait { until_ms: t0 + 2_000 });
    let Step::Send(Request::Post { body: again, .. }) = t.next(t0 + 2_000) else { panic!() };
    let (a, b): (Value, Value) =
        (serde_json::from_str(&first).unwrap(), serde_json::from_str(&again).unwrap());
    assert_eq!((a["sealed"].clone(), a["id"].clone()), (b["sealed"].clone(), b["id"].clone()));
    t.on_post(503, "", t0 + 2_000);
    assert_eq!(t.next(t0 + 2_000), Step::Wait { until_ms: t0 + 6_000 });
    // 401: the caller refreshes its token and goes on.
    t.on_post(401, "", t0 + 6_000);
    assert!(t.auth_refused());
    // Never posted before the item's own end.
    assert_eq!(t.next(t0 + 86_400_000), Step::Done);
    assert_eq!(t.state(), &State::Expired);
}

#[test]
fn the_hub_reports_expiry_and_forgetting() {
    let hub = Hub { mac: Identity::random() };
    let mut t = tracker(&hub, "completed");
    posted(&mut t, NOW * 1000, 200, r#"{"queued":true,"seq":2}"#);
    t.next(NOW * 1000 + 1_000);
    t.on_poll(200, r#"{"state":"expired"}"#, NOW * 1000 + 1_000);
    assert_eq!(t.state(), &State::Expired);

    let mut t = tracker(&hub, "completed");
    posted(&mut t, NOW * 1000, 200, r#"{"queued":true,"seq":2}"#);
    t.next(NOW * 1000 + 1_000);
    t.on_poll(404, "", NOW * 1000 + 1_000);
    assert_eq!(t.state(), &State::NotConfirmed);

    // 5xx and junk on a poll change nothing but the pace.
    let mut t = tracker(&hub, "completed");
    posted(&mut t, NOW * 1000, 200, r#"{"queued":true,"seq":2}"#);
    t.next(NOW * 1000 + 1_000);
    t.on_poll(502, "", NOW * 1000 + 1_000);
    t.on_poll(200, "not json", NOW * 1000 + 1_000);
    assert_eq!(t.state(), &State::Queued);
}
