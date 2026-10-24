//! Sealed boxes for notification content and mailbox replies (PROTOCOL.md
//! "Sealed pushes and the reply mailbox"; `verify/notifications-trust.md`).
//!
//! ECIES on P-256, as CryptoKit does it on the phone:
//!
//! - an ephemeral key `E`; `z = ECDH(E, R)` (the shared point's x coordinate)
//!   for the recipient key `R`;
//! - `k = HKDF-SHA256(ikm: z, salt: E_pub || R_pub, info: context, 32 bytes)`;
//! - AES-256-GCM with a random 12-byte nonce, the context as associated data;
//! - wire: base64url without padding of
//!   `0x01 || E_pub (65, X9.63) || nonce (12) || ciphertext || tag (16)`.
//!
//! The context names the Mac, the phone and the object (`push_context`,
//! `reply_context`), so a box opens only for the one it was made for.
//!
//! The Mac's box key is derived from its identity key ([`box_key`]): no new
//! secret to store, and the app's identity key stays the one root.
//!
//! `tests/fixtures/seal-vectors.json` (made by `gen_seal_vectors.py` with
//! Python's `cryptography`) is shared with the phone's tests.

use aes_gcm::aead::{Aead, Payload};
use aes_gcm::{Aes256Gcm, KeyInit, Nonce};
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use hkdf::Hkdf;
use p256::elliptic_curve::sec1::ToEncodedPoint;
use p256::{PublicKey, SecretKey};
use sha2::Sha256;

/// The box format's version byte.
const VERSION: u8 = 1;
/// An X9.63 uncompressed P-256 point.
const POINT_LEN: usize = 65;
const NONCE_LEN: usize = 12;
const TAG_LEN: usize = 16;

/// The HKDF info (and signature domain) of the Mac's box key.
pub const BOX_KEY_DOMAIN: &str = "cmux-mobile-mac-box-v1";
/// The domain of the phone's statement of its push key.
pub const PUSH_KEY_DOMAIN: &str = "cmux-mobile-push-key-v1";
/// The domain of the Mac's signature over a sealed push.
pub const PUSH_SIGNATURE_DOMAIN: &str = "cmux-mobile-push-v1";

/// Why a box did not open.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SealError {
    Malformed,
    BadKey,
    Unopened,
    Random,
}

impl std::fmt::Display for SealError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Malformed => "not a sealed box",
            Self::BadKey => "not a P-256 key",
            Self::Unopened => "the box does not open with this key and context",
            Self::Random => "no randomness",
        })
    }
}

impl std::error::Error for SealError {}

/// The domain, then each part after one NUL byte.
pub fn joined(domain: &str, parts: &[&str]) -> Vec<u8> {
    let mut out = domain.as_bytes().to_vec();
    for part in parts {
        out.push(0);
        out.extend_from_slice(part.as_bytes());
    }
    out
}

/// `cmux-mobile-push-seal-v1 \0 mac \0 phone \0 eventId`.
pub fn push_context(mac: &str, phone: &str, event_id: &str) -> Vec<u8> {
    joined("cmux-mobile-push-seal-v1", &[mac, phone, event_id])
}

/// `cmux-mobile-reply-seal-v1 \0 mac \0 phone \0 replyId`.
pub fn reply_context(mac: &str, phone: &str, reply_id: &str) -> Vec<u8> {
    joined("cmux-mobile-reply-seal-v1", &[mac, phone, reply_id])
}

/// What the Mac signs with its identity key to vouch for its box key.
pub fn box_key_message(mac: &str, box_key_hex: &str) -> Vec<u8> {
    joined(BOX_KEY_DOMAIN, &[mac, box_key_hex])
}

/// What the phone signs with its identity key to vouch for its push key.
pub fn push_key_message(mac: &str, phone: &str, push_key_hex: &str) -> Vec<u8> {
    joined(PUSH_KEY_DOMAIN, &[mac, phone, push_key_hex])
}

/// What the Mac signs with its identity key over one sealed push.
pub fn push_signature_message(mac: &str, phone: &str, event_id: &str, sealed: &str) -> Vec<u8> {
    joined(PUSH_SIGNATURE_DOMAIN, &[mac, phone, event_id, sealed])
}

/// The Mac's box key from its identity scalar: `HKDF-SHA256(ikm: scalar,
/// salt: "", info: "cmux-mobile-mac-box-v1")`, taken again with a counter
/// byte (1, 2, ...) appended to the info while it is not a valid scalar
/// (zero or at least the group order, about 2^-32 likely).
pub fn box_key(identity_scalar: &[u8]) -> Option<SecretKey> {
    let hkdf = Hkdf::<Sha256>::new(Some(&[][..]), identity_scalar);
    let mut info = BOX_KEY_DOMAIN.as_bytes().to_vec();
    for counter in 0u8..=255 {
        if counter > 0 {
            info.truncate(BOX_KEY_DOMAIN.len());
            info.push(counter);
        }
        let mut okm = [0u8; 32];
        hkdf.expand(&info, &mut okm).ok()?;
        if let Ok(key) = SecretKey::from_slice(&okm) {
            return Some(key);
        }
    }
    None
}

/// A public key as its X9.63 uncompressed point.
pub fn point(key: &PublicKey) -> [u8; POINT_LEN] {
    let encoded = key.to_encoded_point(false);
    let mut out = [0u8; POINT_LEN];
    out.copy_from_slice(encoded.as_bytes());
    out
}

/// A public key as lowercase hex of its X9.63 point.
pub fn point_hex(key: &PublicKey) -> String {
    hex(&point(key))
}

/// Parses an X9.63 point given as hex.
pub fn public_key_hex(text: &str) -> Result<PublicKey, SealError> {
    let bytes = unhex(text).ok_or(SealError::BadKey)?;
    if bytes.len() != POINT_LEN || bytes[0] != 4 {
        return Err(SealError::BadKey);
    }
    PublicKey::from_sec1_bytes(&bytes).map_err(|_| SealError::BadKey)
}

/// Seals `plaintext` to `recipient` under `context`, with a fresh ephemeral
/// key and nonce.
pub fn seal(recipient: &PublicKey, context: &[u8], plaintext: &[u8]) -> Result<String, SealError> {
    let ephemeral = random_secret()?;
    let mut nonce = [0u8; NONCE_LEN];
    fill(&mut nonce)?;
    seal_with(recipient, context, plaintext, &ephemeral, &nonce)
}

/// [`seal`] with a given ephemeral key and nonce (test vectors).
pub fn seal_with(
    recipient: &PublicKey,
    context: &[u8],
    plaintext: &[u8],
    ephemeral: &SecretKey,
    nonce: &[u8; NONCE_LEN],
) -> Result<String, SealError> {
    let ephemeral_point = point(&ephemeral.public_key());
    let key = derive(ephemeral, recipient, &ephemeral_point, &point(recipient), context);
    let ciphertext = Aes256Gcm::new(&key.into())
        .encrypt(Nonce::from_slice(nonce), Payload { msg: plaintext, aad: context })
        .map_err(|_| SealError::Malformed)?;
    let mut out = Vec::with_capacity(1 + POINT_LEN + NONCE_LEN + ciphertext.len());
    out.push(VERSION);
    out.extend_from_slice(&ephemeral_point);
    out.extend_from_slice(nonce);
    out.extend_from_slice(&ciphertext);
    Ok(URL_SAFE_NO_PAD.encode(out))
}

/// Opens a box sealed to `recipient` under `context`.
pub fn open(recipient: &SecretKey, context: &[u8], sealed: &str) -> Result<Vec<u8>, SealError> {
    let bytes = URL_SAFE_NO_PAD.decode(sealed.trim_end_matches('=')).map_err(|_| SealError::Malformed)?;
    if bytes.len() < 1 + POINT_LEN + NONCE_LEN + TAG_LEN || bytes[0] != VERSION {
        return Err(SealError::Malformed);
    }
    let ephemeral_point = &bytes[1..1 + POINT_LEN];
    let nonce = &bytes[1 + POINT_LEN..1 + POINT_LEN + NONCE_LEN];
    let ciphertext = &bytes[1 + POINT_LEN + NONCE_LEN..];
    if ephemeral_point[0] != 4 {
        return Err(SealError::Malformed);
    }
    let ephemeral = PublicKey::from_sec1_bytes(ephemeral_point).map_err(|_| SealError::Malformed)?;
    let key = derive(recipient, &ephemeral, ephemeral_point, &point(&recipient.public_key()), context);
    Aes256Gcm::new(&key.into())
        .decrypt(Nonce::from_slice(nonce), Payload { msg: ciphertext, aad: context })
        .map_err(|_| SealError::Unopened)
}

/// The AES key: HKDF over the ECDH x coordinate, salted with both points.
fn derive(
    secret: &SecretKey,
    peer: &PublicKey,
    ephemeral_point: &[u8],
    recipient_point: &[u8],
    context: &[u8],
) -> [u8; 32] {
    let shared = p256::ecdh::diffie_hellman(secret.to_nonzero_scalar(), peer.as_affine());
    let mut salt = Vec::with_capacity(2 * POINT_LEN);
    salt.extend_from_slice(ephemeral_point);
    salt.extend_from_slice(recipient_point);
    let mut key = [0u8; 32];
    Hkdf::<Sha256>::new(Some(&salt), shared.raw_secret_bytes().as_slice())
        .expand(context, &mut key)
        .expect("32 bytes is a valid HKDF-SHA256 length");
    key
}

/// A fresh random P-256 key.
pub fn random_secret() -> Result<SecretKey, SealError> {
    loop {
        let mut bytes = [0u8; 32];
        fill(&mut bytes)?;
        if let Ok(key) = SecretKey::from_slice(&bytes) {
            return Ok(key);
        }
    }
}

fn fill(bytes: &mut [u8]) -> Result<(), SealError> {
    use ring::rand::SecureRandom;
    ring::rand::SystemRandom::new().fill(bytes).map_err(|_| SealError::Random)
}

/// Lowercase hex.
pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Bytes from hex (either case); `None` for anything else.
pub fn unhex(text: &str) -> Option<Vec<u8>> {
    if !text.len().is_multiple_of(2) {
        return None;
    }
    (0..text.len()).step_by(2).map(|i| u8::from_str_radix(text.get(i..i + 2)?, 16).ok()).collect()
}

/// Lowercase hex SHA-256.
pub fn sha256_hex(bytes: &[u8]) -> String {
    hex(ring::digest::digest(&ring::digest::SHA256, bytes).as_ref())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn vectors() -> Value {
        serde_json::from_str(include_str!("../tests/fixtures/seal-vectors.json")).unwrap()
    }

    fn text<'a>(v: &'a Value, pointer: &str) -> &'a str {
        v.pointer(pointer).and_then(Value::as_str).unwrap_or_else(|| panic!("{pointer}"))
    }

    fn secret(v: &Value, pointer: &str) -> SecretKey {
        SecretKey::from_slice(&unhex(text(v, pointer)).unwrap()).unwrap()
    }

    fn nonce(v: &Value, pointer: &str) -> [u8; 12] {
        unhex(text(v, pointer)).unwrap().try_into().unwrap()
    }

    #[test]
    fn the_box_key_matches_the_vector() {
        let v = vectors();
        let key = box_key(&unhex(text(&v, "/macIdentityScalar")).unwrap()).unwrap();
        assert_eq!(hex(&key.to_bytes()), text(&v, "/macBoxScalar"));
        assert_eq!(point_hex(&key.public_key()), text(&v, "/macBoxKey"));
        let message = box_key_message(text(&v, "/mac"), text(&v, "/macBoxKey"));
        assert_eq!(hex(&message), text(&v, "/macBoxMessage"));
        assert!(crate::pairing::verify(text(&v, "/macIdentityKey"), &message, text(&v, "/macBoxSignature")));
    }

    #[test]
    fn a_push_seals_to_the_vector_and_opens() {
        let v = vectors();
        let (mac, phone) = (text(&v, "/mac"), text(&v, "/phone"));
        let context = push_context(mac, phone, text(&v, "/push/eventId"));
        assert_eq!(hex(&context), text(&v, "/push/context"));
        let push = secret(&v, "/phonePushScalar");
        assert_eq!(point_hex(&push.public_key()), text(&v, "/phonePushKey"));
        let sealed = seal_with(
            &push.public_key(),
            &context,
            text(&v, "/push/plaintext").as_bytes(),
            &secret(&v, "/push/ephemeralScalar"),
            &nonce(&v, "/push/nonce"),
        )
        .unwrap();
        assert_eq!(sealed, text(&v, "/push/box"));
        assert_eq!(open(&push, &context, &sealed).unwrap(), text(&v, "/push/plaintext").as_bytes());
        let message = push_signature_message(mac, phone, text(&v, "/push/eventId"), &sealed);
        assert_eq!(hex(&message), text(&v, "/push/signatureMessage"));
        assert!(crate::pairing::verify(text(&v, "/macIdentityKey"), &message, text(&v, "/push/signature")));
        let statement = push_key_message(mac, phone, text(&v, "/phonePushKey"));
        assert_eq!(hex(&statement), text(&v, "/pushKeyMessage"));
        assert!(crate::pairing::verify(
            text(&v, "/phoneIdentityKey"),
            &statement,
            text(&v, "/pushKeySignature")
        ));
    }

    #[test]
    fn a_reply_opens_with_the_box_key_only_in_its_context() {
        let v = vectors();
        let (mac, phone) = (text(&v, "/mac"), text(&v, "/phone"));
        let key = box_key(&unhex(text(&v, "/macIdentityScalar")).unwrap()).unwrap();
        let context = reply_context(mac, phone, text(&v, "/reply/id"));
        assert_eq!(hex(&context), text(&v, "/reply/context"));
        let sealed = text(&v, "/reply/box");
        assert_eq!(open(&key, &context, sealed).unwrap(), text(&v, "/reply/plaintext").as_bytes());
        // Another reply id, phone or Mac: it does not open.
        for wrong in [
            reply_context(mac, phone, "other"),
            reply_context(mac, "other-phone", text(&v, "/reply/id")),
            reply_context("other-mac", phone, text(&v, "/reply/id")),
        ] {
            assert_eq!(open(&key, &wrong, sealed), Err(SealError::Unopened));
        }
        // Another key: it does not open.
        assert_eq!(open(&random_secret().unwrap(), &context, sealed), Err(SealError::Unopened));
        // One flipped byte anywhere: it does not open.
        let mut bytes = URL_SAFE_NO_PAD.decode(sealed).unwrap();
        let last = bytes.len() - 1;
        bytes[last] ^= 1;
        assert!(open(&key, &context, &URL_SAFE_NO_PAD.encode(&bytes)).is_err());
        assert_eq!(open(&key, &context, "not base64!"), Err(SealError::Malformed));
        assert_eq!(open(&key, &context, "AQ"), Err(SealError::Malformed));
    }

    #[test]
    fn fresh_seals_round_trip_and_differ() {
        let key = random_secret().unwrap();
        let context = reply_context("m", "p", "r");
        let a = seal(&key.public_key(), &context, b"hello").unwrap();
        let b = seal(&key.public_key(), &context, b"hello").unwrap();
        assert_ne!(a, b);
        assert_eq!(open(&key, &context, &a).unwrap(), b"hello");
        assert_eq!(open(&key, &context, &b).unwrap(), b"hello");
    }

    #[test]
    fn public_keys_parse_only_as_uncompressed_points() {
        let v = vectors();
        assert!(public_key_hex(text(&v, "/phonePushKey")).is_ok());
        assert_eq!(public_key_hex("04"), Err(SealError::BadKey));
        assert_eq!(public_key_hex(&format!("05{}", &text(&v, "/phonePushKey")[2..])), Err(SealError::BadKey));
    }
}
