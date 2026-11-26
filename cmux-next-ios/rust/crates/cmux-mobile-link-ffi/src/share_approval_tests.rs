//! The phone's approval: it builds the shared vectors' canonical bytes, takes only a signature
//! by its own hub key, and answers the JSON the target admits.

use base64::Engine as _;
use ring::rand::SystemRandom;
use ring::signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair, KeyPair as _};
use serde_json::Value;

use super::*;

const VECTORS: &str = include_str!("../../../../../cmux-tui/crates/acpmux/src/share_approval_vectors.json");

/// The phone's hub key, as a software key (the app's is in the Secure Enclave).
struct PhoneKey {
    pair: EcdsaKeyPair,
    rng: SystemRandom,
}

impl PhoneKey {
    fn new() -> Self {
        let rng = SystemRandom::new();
        let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
        let pair = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8.as_ref(), &rng).unwrap();
        Self { pair, rng }
    }

    /// base64 X9.63: the hub's `signingKey` for this phone.
    fn public(&self) -> String {
        base64::engine::general_purpose::STANDARD.encode(self.pair.public_key().as_ref())
    }

    /// What Swift does after the tap: `DeviceIdentity.sign(canonical:)`.
    fn sign(&self, canonical: &str) -> String {
        let signature = self.pair.sign(&self.rng, canonical.as_bytes()).unwrap();
        base64::engine::general_purpose::STANDARD.encode(signature.as_ref())
    }
}

fn vector() -> Value {
    let vectors: Vec<Value> = serde_json::from_str(VECTORS).unwrap();
    vectors.into_iter().next().unwrap()
}

fn vector_ask(vector: &Value) -> (ShareAsk, u64, String) {
    let field = |name: &str| vector["approval"][name].as_str().unwrap().to_owned();
    let ask = ShareAsk {
        target_id: field("target"),
        target_name: field("target_name"),
        asker_id: field("asker"),
        asker_name: field("asker_name"),
        account: field("confirmed_by"),
    };
    (ask, field("confirmed_at").parse().unwrap(), field("nonce"))
}

#[test]
fn draft_is_the_shared_vectors_canonical() {
    let vector = vector();
    let (ask, at, nonce) = vector_ask(&vector);
    let draft = draft_at(&ask, at, &nonce).unwrap();
    assert_eq!(draft.canonical, vector["canonical"].as_str().unwrap());
    assert_eq!(draft.approval().wire(), vector["approval"]);
}

#[test]
fn signed_answers_the_wire_the_target_reads() {
    let vector = vector();
    let (ask, at, nonce) = vector_ask(&vector);
    let phone = PhoneKey::new();
    let draft = draft_at(&ask, at, &nonce).unwrap();
    let signature = phone.sign(&draft.canonical);
    let wire: Value =
        serde_json::from_str(&share_approval_signed(draft, signature.clone(), phone.public()).unwrap())
            .unwrap();
    let mut expected = vector["approval"].clone();
    expected["signature"] = Value::String(signature);
    assert_eq!(wire, expected);
    let read: ShareApproval = serde_json::from_value(wire).unwrap();
    assert_eq!(read.canonical(), vector["canonical"].as_str().unwrap());
}

/// No tap, no approval: an empty or foreign signature, or a draft changed after it was made,
/// never comes back as something to send.
#[test]
fn signed_refuses_anything_but_this_phones_signature_of_the_draft() {
    let (ask, at, nonce) = vector_ask(&vector());
    let phone = PhoneKey::new();
    let other = PhoneKey::new();
    let draft = draft_at(&ask, at, &nonce).unwrap();
    let code = |draft: ShareApprovalDraft, signature: String| match share_approval_signed(
        draft,
        signature,
        phone.public(),
    ) {
        Err(CmuxMobileError::Refused { code, .. }) => code,
        other => panic!("not refused: {other:?}"),
    };
    assert_eq!(code(draft.clone(), String::new()), "share.bad_signature");
    assert_eq!(code(draft.clone(), "not base64!".into()), "share.bad_signature");
    assert_eq!(code(draft.clone(), other.sign(&draft.canonical)), "share.bad_signature");
    let signature = phone.sign(&draft.canonical);
    let moved = ShareApprovalDraft { target: "another-mac".into(), ..draft.clone() };
    assert_eq!(code(moved, signature.clone()), "share.draft_changed");
    let resigned = ShareApprovalDraft {
        target: "another-mac".into(),
        canonical: draft.canonical.replace(&draft.target, "another-mac"),
        ..draft
    };
    assert_eq!(code(resigned, signature), "share.bad_signature");
}

#[test]
fn draft_takes_a_fresh_nonce_and_refuses_an_unregistered_phone() {
    let (ask, _, _) = vector_ask(&vector());
    let first = share_approval_draft(ask.clone()).unwrap();
    let second = share_approval_draft(ask.clone()).unwrap();
    assert_ne!(first.nonce, second.nonce);
    assert!(first.confirmed_at > 1_700_000_000);
    let unregistered = ShareAsk { asker_id: String::new(), ..ask };
    assert!(matches!(
        share_approval_draft(unregistered),
        Err(CmuxMobileError::Refused { code, .. }) if code == "share.no_device"
    ));
}

/// A control tap signs the control format's own bytes and comes back as that format, and a
/// share tap's signature never finishes a control draft.
#[test]
fn a_control_draft_signs_and_answers_the_control_format() {
    let (ask, at, nonce) = vector_ask(&vector());
    let phone = PhoneKey::new();
    let share = draft_at(&ask, at, &nonce).unwrap();
    let control = draft_for(cmux_share_approval::CONTROL_VERSION, &ask, at, &nonce).unwrap();
    assert!(control.canonical.starts_with("cmux.control-approval.v1\n"));
    assert_ne!(control.canonical, share.canonical);
    let signature = phone.sign(&control.canonical);
    let wire: Value =
        serde_json::from_str(&share_approval_signed(control.clone(), signature, phone.public()).unwrap())
            .unwrap();
    assert_eq!(wire["v"], "cmux.control-approval.v1");
    let read: ShareApproval = serde_json::from_value(wire).unwrap();
    assert_eq!(read.canonical(), control.canonical);
    let crossed = share_approval_signed(control, phone.sign(&share.canonical), phone.public());
    assert!(matches!(crossed, Err(CmuxMobileError::Refused { code, .. }) if code == "share.bad_signature"));
}
