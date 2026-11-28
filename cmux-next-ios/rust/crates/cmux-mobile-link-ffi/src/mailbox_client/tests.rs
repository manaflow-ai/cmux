//! The phone's items against the Mac's real opener and checks (`cmux-mobile-host`), on the
//! vectors both sides share (`cmux-mobile-host/tests/fixtures/seal-vectors.json`).

use std::sync::Arc;

use cmux_mobile_host::mailbox::{self, SpentReplies};
use cmux_mobile_host::pairing::{DeviceTrust, MacIdentity, TrustedDevice};
use cmux_mobile_host::seal as host_seal;
use cmux_mobile_link::signaling::MailboxItem;
use serde_json::Value;

use super::*;

const MAC: &str = "6f1c2a7e-0b1d-4c55-9a43-2d8e5b7f3c10";
const PHONE: &str = "a2b4c6d8-1e3f-4a5b-8c7d-9e0f1a2b3c4d";
const ID: &str = "7c1e9a52-3b44-4d0e-9d6a-1f2e3d4c5b6a";
const NOW: u64 = 1_792_540_900;

fn vectors() -> Value {
    serde_json::from_str(include_str!("../../../cmux-mobile-host/tests/fixtures/seal-vectors.json")).unwrap()
}

fn field(v: &Value, key: &str) -> String {
    v[key].as_str().unwrap().to_owned()
}

fn mac_identity() -> MacIdentity {
    let v = vectors();
    MacIdentity::from_raw(&field(&v, "macIdentityScalar"), &field(&v, "macIdentityKey")).unwrap()
}

/// The phone's identity key, as the Secure Enclave would sign with it.
struct PhoneKey(MacIdentity);

impl MailboxSigner for PhoneKey {
    fn sign(&self, message: Vec<u8>) -> Result<Vec<u8>, MailboxSignError> {
        let hex = self.0.sign(&message).ok_or(MailboxSignError::Failed { message: "no".into() })?;
        Ok(host_seal::unhex(&hex).unwrap())
    }
}

fn phone_key() -> Arc<dyn MailboxSigner> {
    let v = vectors();
    Arc::new(PhoneKey(
        MacIdentity::from_raw(&field(&v, "phoneIdentityScalar"), &field(&v, "phoneIdentityKey")).unwrap(),
    ))
}

fn trust() -> DeviceTrust {
    DeviceTrust {
        devices: vec![TrustedDevice {
            id: PHONE.into(),
            identity_key: field(&vectors(), "phoneIdentityKey"),
            approval_key: String::new(),
            ..Default::default()
        }],
        denied: vec![],
    }
}

fn box_key() -> String {
    let v = vectors();
    mailbox_trusted_box_key(
        MAC.into(),
        Some(field(&v, "macBoxKey")),
        Some(field(&v, "macBoxSignature")),
        Some(field(&v, "macIdentityKey")),
    )
    .unwrap()
}

fn spec(kind: &str, action: MailboxAction) -> MailboxItemSpec {
    MailboxItemSpec {
        id: ID.into(),
        mac: MAC.into(),
        phone: PHONE.into(),
        kind: kind.into(),
        target: MailboxTarget { session_id: Some("s1".into()), ..Default::default() },
        action,
        approval_json: None,
        nonce: None,
        issued_at: NOW - 10,
        lifetime_secs: None,
    }
}

fn as_item(sealed: &MailboxSealedItem) -> MailboxItem {
    MailboxItem {
        id: sealed.id.clone(),
        from: sealed.phone.clone(),
        sealed: sealed.sealed.clone(),
        at: None,
        seq: None,
    }
}

#[test]
fn a_reply_item_passes_the_hosts_every_check() {
    let sealed = mailbox_build(
        spec("completed", MailboxAction::Text { text: "ship it".into(), steer: None }),
        box_key(),
        phone_key(),
        NOW,
    )
    .unwrap();
    assert_eq!(sealed.expires_at, NOW - 10 + 540);
    let spent = SpentReplies::memory();
    let reply = mailbox::check(&as_item(&sealed), MAC, &mac_identity(), &trust(), &spent, NOW)
        .expect("the Mac applies it");
    assert_eq!((reply.id.as_str(), reply.text.as_deref()), (ID, Some("ship it")));
    // The same item again is the replay the Mac already settled.
    assert!(mailbox::check(&as_item(&sealed), MAC, &mac_identity(), &trust(), &spent, NOW).is_err());
}

#[test]
fn send_and_compose_open_with_the_macs_box_key_and_verify_against_the_phone_identity() {
    let v = vectors();
    let mac = mac_identity();
    let cases = [
        ("send", MailboxAction::Text { text: "hi there".into(), steer: Some(true) }),
        ("compose", MailboxAction::QueueMove { prompt_id: "p1".into(), index: 2 }),
    ];
    for (kind, action) in cases {
        let sealed = mailbox_build(spec(kind, action), box_key(), phone_key(), NOW).unwrap();
        assert_eq!(sealed.expires_at, NOW - 10 + 86_400);
        let context = host_seal::reply_context(MAC, PHONE, ID);
        let plain = host_seal::open(mac.box_secret(), &context, &sealed.sealed).expect("the Mac opens it");
        let mut object: Value = serde_json::from_slice(&plain).unwrap();
        assert_eq!(object["kind"], kind);
        let sig = object.as_object_mut().unwrap().remove("sig").unwrap();
        let message = mailbox::signed_message(MAC, PHONE, &object);
        assert!(cmux_mobile_host::pairing::verify(
            &field(&v, "phoneIdentityKey"),
            &message,
            sig.as_str().unwrap()
        ));
        // Another id's context does not open it: the item can't be moved to another id.
        let other = host_seal::reply_context(MAC, PHONE, "other");
        assert!(host_seal::open(mac.box_secret(), &other, &sealed.sealed).is_err());
    }
}

#[test]
fn the_tracker_trusts_the_hosts_ack_signature_and_nothing_else() {
    let v = vectors();
    let sealed = mailbox_build(
        spec("send", MailboxAction::Text { text: "x".into(), steer: None }),
        box_key(),
        phone_key(),
        NOW,
    )
    .unwrap();
    let ack = |applied: bool, reason: Option<&str>| {
        mac_identity().sign(&mailbox::ack_message(MAC, ID, applied, reason)).unwrap()
    };
    let t = MailboxTracker::new(sealed.clone(), Some(field(&v, "macIdentityKey")), false, NOW * 1000);
    let MailboxStep::Post { path, body } = t.next(NOW * 1000) else { panic!() };
    assert_eq!(path, format!("/v1/devices/{MAC}/mailbox"));
    assert_eq!(serde_json::from_str::<Value>(&body).unwrap()["hold"], 86_390);
    t.on_post(200, r#"{"queued":true,"delivered":false,"seq":1}"#.into(), NOW * 1000);
    assert_eq!((t.state(), t.seq(), t.old_hub()), (MailboxState::Queued, Some(1), false));
    t.on_poll(
        200,
        serde_json::json!({"state": "applied", "sig": ack(true, None)}).to_string(),
        NOW * 1000 + 1_000,
    );
    assert_eq!(t.state(), MailboxState::Applied);

    let t = MailboxTracker::new(sealed, Some(field(&v, "macIdentityKey")), false, NOW * 1000);
    t.next(NOW * 1000);
    t.on_post(200, r#"{"queued":true,"seq":1}"#.into(), NOW * 1000);
    // The Mac's signature of "applied" does not back a "rejected".
    t.on_poll(
        200,
        serde_json::json!({"state": "rejected", "reason": "refused", "sig": ack(true, None)}).to_string(),
        NOW * 1000 + 1_000,
    );
    assert_eq!(t.state(), MailboxState::NotConfirmed);
}

#[test]
fn the_exported_router_and_availability() {
    let input = |link_up, presence, mailbox_available| MailboxRouteInput {
        link_up,
        presence,
        mailbox_available,
        cloud_holder: false,
    };
    assert_eq!(mailbox_route(input(true, MailboxPresence::Online, true)), MailboxRoute::Link);
    assert_eq!(mailbox_route(input(true, MailboxPresence::Offline, true)), MailboxRoute::Mailbox);
    assert_eq!(mailbox_route(input(false, MailboxPresence::Online, true)), MailboxRoute::Mailbox);
    assert_eq!(mailbox_route(input(false, MailboxPresence::Offline, false)), MailboxRoute::Fail);
    assert!(!mailbox_available("send".into(), false, true));
    assert_eq!(mailbox_lifetime_cap("compose".into()), 86_400);
    assert_eq!(mailbox_lifetime_cap("question".into()), 540);
    assert_eq!(
        mailbox_trusted_box_key(MAC.into(), Some(field(&vectors(), "macBoxKey")), None, None),
        Err(MailboxError::UntrustedBoxKey)
    );
}

#[test]
fn a_cloud_held_chat_routes_to_its_inbox_with_the_same_id() {
    let held = MailboxRouteInput {
        link_up: true,
        presence: MailboxPresence::Online,
        mailbox_available: true,
        cloud_holder: true,
    };
    assert_eq!(mailbox_route(held), MailboxRoute::CloudInbox);
    assert_eq!(
        mailbox_route_for("0D9F5E2C-7B3A-4E61-8F20-5C4B3A291807".into(), held),
        MailboxRoute::CloudInbox
    );
    assert_eq!(mailbox_route_for("not ok".into(), held), MailboxRoute::Fail);
    let post =
        mailbox_inbox_post("c1".into(), "0D9F5E2C-7B3A-4E61-8F20-5C4B3A291807".into(), "hi".into()).unwrap();
    assert_eq!(post[0], "/v1/auto-sessions/c1/inbox");
    assert!(post[1].contains("\"id\":\"0d9f5e2c-7b3a-4e61-8f20-5c4b3a291807\""));
}
