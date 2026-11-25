//! The mailbox's crypto, the phone's half (PROTOCOL.md "Sealed pushes and the reply mailbox"):
//! ECIES on P-256 as `cmux-mobile-host`'s `seal.rs` opens it and CryptoKit's `PushSeal` makes it.
//!
//! `k = HKDF-SHA256(ikm: ECDH(E, R) x, salt: E_pub || R_pub, info: context, 32)`; AES-256-GCM,
//! random 12-byte nonce, the context as associated data; wire: base64url (no padding) of
//! `0x01 || E_pub (65, X9.63) || nonce (12) || ciphertext || tag (16)`.

use aes_gcm::aead::{Aead, Payload};
use aes_gcm::{Aes256Gcm, KeyInit, Nonce};
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use hkdf::Hkdf;
use p256::ecdsa::signature::Verifier as _;
use p256::ecdsa::{Signature, VerifyingKey};
use p256::elliptic_curve::sec1::ToEncodedPoint;
use p256::{PublicKey, SecretKey};
use sha2::{Digest, Sha256};

const VERSION: u8 = 1;
const POINT_LEN: usize = 65;
const NONCE_LEN: usize = 12;

/// The signature domain of a reply (and every mailbox item).
pub const REPLY_DOMAIN: &str = "cmux-mobile-reply-v1";
/// The domain of the Mac's signature over its box key.
pub const BOX_KEY_DOMAIN: &str = "cmux-mobile-mac-box-v1";
/// The domain of the Mac's signature over a mailbox outcome.
pub const ACK_DOMAIN: &str = "cmux-mobile-mailbox-ack-v1";

/// Why a seal or a key check failed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum SealError {
    #[error("not a P-256 key")]
    BadKey,
    #[error("no randomness")]
    Random,
    #[error("the box could not be made")]
    Seal,
}

/// The domain, then each part after one NUL byte (as every cmux-mobile signature).
pub fn joined(domain: &str, parts: &[&str]) -> Vec<u8> {
    let mut out = domain.as_bytes().to_vec();
    for part in parts {
        out.push(0);
        out.extend_from_slice(part.as_bytes());
    }
    out
}

/// `cmux-mobile-reply-seal-v1 \0 mac \0 phone \0 id`.
pub fn reply_context(mac: &str, phone: &str, id: &str) -> Vec<u8> {
    joined("cmux-mobile-reply-seal-v1", &[mac, phone, id])
}

/// What the phone's identity key signs: the domain, the Mac, the phone and the
/// lowercase hex SHA-256 of the canonical plaintext without `sig`.
pub fn signed_message(mac: &str, phone: &str, canonical_unsigned: &str) -> Vec<u8> {
    joined(REPLY_DOMAIN, &[mac, phone, &sha256_hex(canonical_unsigned.as_bytes())])
}

/// What the Mac's ack signature covers.
pub fn ack_message(mac: &str, id: &str, applied: bool, reason: Option<&str>) -> Vec<u8> {
    joined(ACK_DOMAIN, &[mac, id, if applied { "1" } else { "0" }, reason.unwrap_or("")])
}

/// What the Mac signed to vouch for its box key.
pub fn box_key_message(mac: &str, box_key_hex: &str) -> Vec<u8> {
    joined(BOX_KEY_DOMAIN, &[mac, box_key_hex])
}

/// Parses an X9.63 uncompressed point given as hex.
pub fn public_key_hex(text: &str) -> Result<PublicKey, SealError> {
    let bytes = unhex(text).ok_or(SealError::BadKey)?;
    if bytes.len() != POINT_LEN || bytes[0] != 4 {
        return Err(SealError::BadKey);
    }
    PublicKey::from_sec1_bytes(&bytes).map_err(|_| SealError::BadKey)
}

/// ECDSA P-256 / SHA-256 over `message`: a raw `r || s` signature as hex, a key as X9.63 hex.
pub fn verify(key_hex: &str, message: &[u8], signature_hex: &str) -> bool {
    let (Some(key), Some(signature)) = (unhex(key_hex), unhex(signature_hex)) else { return false };
    let (Ok(key), Ok(signature)) = (VerifyingKey::from_sec1_bytes(&key), Signature::from_slice(&signature))
    else {
        return false;
    };
    key.verify(message, &signature).is_ok()
}

fn point(key: &PublicKey) -> [u8; POINT_LEN] {
    let mut out = [0u8; POINT_LEN];
    out.copy_from_slice(key.to_encoded_point(false).as_bytes());
    out
}

/// Seals `plaintext` to `recipient` under `context` with a fresh ephemeral key and nonce.
pub fn seal(recipient: &PublicKey, context: &[u8], plaintext: &[u8]) -> Result<String, SealError> {
    let ephemeral = loop {
        let mut bytes = [0u8; 32];
        getrandom::fill(&mut bytes).map_err(|_| SealError::Random)?;
        if let Ok(key) = SecretKey::from_slice(&bytes) {
            break key;
        }
    };
    let mut nonce = [0u8; NONCE_LEN];
    getrandom::fill(&mut nonce).map_err(|_| SealError::Random)?;
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
    let shared = p256::ecdh::diffie_hellman(ephemeral.to_nonzero_scalar(), recipient.as_affine());
    let mut salt = Vec::with_capacity(2 * POINT_LEN);
    salt.extend_from_slice(&ephemeral_point);
    salt.extend_from_slice(&point(recipient));
    let mut key = [0u8; 32];
    Hkdf::<Sha256>::new(Some(&salt), shared.raw_secret_bytes().as_slice())
        .expand(context, &mut key)
        .map_err(|_| SealError::Seal)?;
    let ciphertext = Aes256Gcm::new(&key.into())
        .encrypt(Nonce::from_slice(nonce), Payload { msg: plaintext, aad: context })
        .map_err(|_| SealError::Seal)?;
    let mut out = Vec::with_capacity(1 + POINT_LEN + NONCE_LEN + ciphertext.len());
    out.push(VERSION);
    out.extend_from_slice(&ephemeral_point);
    out.extend_from_slice(nonce);
    out.extend_from_slice(&ciphertext);
    Ok(URL_SAFE_NO_PAD.encode(out))
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
    hex(&Sha256::digest(bytes))
}
