//! Signed Chief question answers (cmux-next-ios `verify/phone-approvals.md`,
//! #13742 draft gap 1). A question part in a Chief conversation can ask the
//! person to choose, and its answer may grant something, so a phone's
//! `conversation-op` `question.answer` counts only with the paired phone's
//! approval-key signature (Face ID), as an agent answer does in acpmux
//! (`hub/approvers.rs`):
//!
//! - The command carries `approval: {approver, nonce, expiresAt, signature}`.
//!   `approver` is the link's phone (its backend-stamped device id), which the
//!   Mac paired with that approval key (the app's `devices` line).
//! - `signature` is ECDSA P-256 / SHA-256, raw `r || s` as lowercase hex, over
//!   [`message`]: the domain, this Mac's device id, the approver, the
//!   conversation, the question's message and part, the nonce, the expiry and
//!   the digest of the answer ([`answer_digest`], acpmux's canonical JSON).
//! - It counts once (a spent-nonce store for this hostd) and only until
//!   `expiresAt`, at most [`MAX_LIFETIME`] ahead.
//!
//! hostd strips `approval` before the line reaches the Chief owner. Without
//! pairing (unsupervised hostd: tests, `run-host.sh`) there is no key to check
//! against and answers pass as before.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};

use serde_json::Value;
use tokio::sync::watch;

use crate::pairing::DeviceTrust;

/// The domain of a Chief answer signature.
pub const DOMAIN: &str = "cmux-mobile-chief-answer-v1";
/// The furthest ahead `expiresAt` may be, in seconds.
pub const MAX_LIFETIME: u64 = 300;

/// What a phone signs for one answer.
pub struct Parts<'a> {
    pub mac: &'a str,
    pub approver: &'a str,
    pub conversation: &'a str,
    pub message_id: &'a str,
    pub part_index: u64,
    pub nonce: &'a str,
    pub expires_at: u64,
    /// [`answer_digest`] of the answer.
    pub answer: &'a str,
}

/// The signed bytes: the domain, then each part after one NUL.
pub fn message(p: &Parts<'_>) -> Vec<u8> {
    let (part, expires) = (p.part_index.to_string(), p.expires_at.to_string());
    let mut out = DOMAIN.as_bytes().to_vec();
    for field in [p.mac, p.approver, p.conversation, p.message_id, &part, p.nonce, &expires, p.answer] {
        out.push(0);
        out.extend_from_slice(field.as_bytes());
    }
    out
}

/// Lowercase hex SHA-256 of the answer's canonical JSON.
pub fn answer_digest(answer: &Value) -> String {
    let mut text = String::new();
    canonical_json(answer, &mut text);
    hex(ring::digest::digest(&ring::digest::SHA256, text.as_bytes()).as_ref())
}

/// acpmux's `canonical_json` (and the phone's `ApprovalPayload.canonicalJSON`):
/// object keys in byte order, no whitespace, only `"`, `\` and control
/// characters escaped.
pub fn canonical_json(v: &Value, out: &mut String) {
    match v {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(n) => out.push_str(&n.to_string()),
        Value::String(s) => canonical_string(s, out),
        Value::Array(a) => {
            out.push('[');
            for (i, x) in a.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                canonical_json(x, out);
            }
            out.push(']');
        }
        Value::Object(o) => {
            let mut keys: Vec<&String> = o.keys().collect();
            keys.sort_by(|a, b| a.as_bytes().cmp(b.as_bytes()));
            out.push('{');
            for (i, k) in keys.into_iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                canonical_string(k, out);
                out.push(':');
                if let Some(value) = o.get(k) {
                    canonical_json(value, out);
                }
            }
            out.push('}');
        }
    }
}

fn canonical_string(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Spent nonces with their expiry, shared by every link of one hostd.
#[derive(Debug, Default)]
pub struct SpentNonces(Mutex<HashMap<String, u64>>);

impl SpentNonces {
    /// Records `key` until `expires`; false when it was spent already.
    fn spend(&self, key: String, expires: u64, now: u64) -> bool {
        let mut spent = self.0.lock().unwrap_or_else(PoisonError::into_inner);
        spent.retain(|_, until| *until >= now);
        spent.insert(key, expires).is_none()
    }
}

/// Checks one link's signed answers.
#[derive(Clone)]
pub struct AnswerCheck {
    /// This Mac's device id (bound into every signature).
    pub mac: String,
    /// The link's phone: the only approver it may name.
    pub phone: String,
    pub trust: watch::Receiver<Option<DeviceTrust>>,
    pub spent: Arc<SpentNonces>,
}

impl std::fmt::Debug for AnswerCheck {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AnswerCheck")
            .field("mac", &self.mac)
            .field("phone", &self.phone)
            .finish_non_exhaustive()
    }
}

fn now() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs())
}

impl AnswerCheck {
    /// Whether `approval` is this phone's valid, unexpired, unspent signature
    /// over `op` (a `question.answer`) in `conversation`. Spends the nonce.
    pub fn verify(&self, conversation: &str, op: &Value, approval: Option<&Value>) -> Result<(), String> {
        self.verify_at(conversation, op, approval, now())
    }

    pub fn verify_at(
        &self,
        conversation: &str,
        op: &Value,
        approval: Option<&Value>,
        now: u64,
    ) -> Result<(), String> {
        let Some(Value::Object(approval)) = approval else {
            return Err("a question answer needs the iPhone's Face ID approval (approval)".into());
        };
        if approval.keys().any(|k| !["approver", "nonce", "expiresAt", "signature"].contains(&k.as_str())) {
            return Err("approval takes approver, nonce, expiresAt and signature".into());
        }
        let text = |k: &str| approval.get(k).and_then(Value::as_str);
        let (Some(approver), Some(nonce), Some(signature)) =
            (text("approver"), text("nonce"), text("signature"))
        else {
            return Err("approval needs approver, nonce and signature".into());
        };
        let Some(expires) = approval.get("expiresAt").and_then(Value::as_u64) else {
            return Err("approval needs expiresAt (Unix seconds)".into());
        };
        if approver != self.phone {
            return Err("the approver is not this iPhone".into());
        }
        if !(16..=128).contains(&nonce.len())
            || !nonce.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
        {
            return Err("nonce is 16 to 128 letters, digits or dashes".into());
        }
        if expires < now || expires > now.saturating_add(MAX_LIFETIME) {
            return Err("the approval expired or lives too long".into());
        }
        let key = self
            .trust
            .borrow()
            .as_ref()
            .and_then(|t| t.devices.iter().find(|d| d.id == self.phone).map(|d| d.approval_key.clone()))
            .filter(|k| !k.is_empty())
            .ok_or_else(|| "this iPhone has no approval key paired with the Mac".to_owned())?;
        let field = |k: &str| op.get(k).and_then(Value::as_str).unwrap_or_default();
        let part_index = op.get("part_index").and_then(Value::as_u64).ok_or("part_index is a number")?;
        let digest = answer_digest(op.get("answer").unwrap_or(&Value::Null));
        let signed = message(&Parts {
            mac: &self.mac,
            approver,
            conversation,
            message_id: field("message_id"),
            part_index,
            nonce,
            expires_at: expires,
            answer: &digest,
        });
        if !crate::pairing::verify(&key, &signed, signature) {
            return Err("the approval signature does not match this answer".into());
        }
        if !self.spent.spend(format!("{approver}\0{nonce}"), expires, now) {
            return Err("this approval was used already".into());
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ring::rand::SystemRandom;
    use ring::signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair, KeyPair};
    use serde_json::json;

    fn key() -> (EcdsaKeyPair, String) {
        let rng = SystemRandom::new();
        let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
        let pair = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8.as_ref(), &rng).unwrap();
        let public = hex(pair.public_key().as_ref());
        (pair, public)
    }

    fn check(approval_key: &str) -> AnswerCheck {
        let trust = DeviceTrust {
            devices: vec![crate::pairing::TrustedDevice {
                id: "phone-1".into(),
                identity_key: "04".into(),
                approval_key: approval_key.into(),
            }],
            denied: Vec::new(),
        };
        AnswerCheck {
            mac: "mac-1".into(),
            phone: "phone-1".into(),
            trust: watch::channel(Some(trust)).1,
            spent: Arc::default(),
        }
    }

    fn signed(pair: &EcdsaKeyPair, op: &Value, nonce: &str, expires: u64) -> Value {
        let digest = answer_digest(&op["answer"]);
        let bytes = message(&Parts {
            mac: "mac-1",
            approver: "phone-1",
            conversation: "conv_CHIEF",
            message_id: op["message_id"].as_str().unwrap(),
            part_index: op["part_index"].as_u64().unwrap(),
            nonce,
            expires_at: expires,
            answer: &digest,
        });
        let signature = pair.sign(&SystemRandom::new(), &bytes).unwrap();
        json!({"approver": "phone-1", "nonce": nonce, "expiresAt": expires, "signature": hex(signature.as_ref())})
    }

    #[test]
    fn the_message_is_fixed() {
        // The same vector is in the phone's ChiefAnswerPayloadTests.
        let digest = answer_digest(&json!({"selections": {"q1": ["b", "a"]}, "note": "ok"}));
        assert_eq!(digest, "cb8e07eaf77edb7c15c3ceb327ec738655893099180928f4d3ce7d8958716d3e");
        let m = message(&Parts {
            mac: "mac-1",
            approver: "phone-1",
            conversation: "conv_A",
            message_id: "msg_B",
            part_index: 2,
            nonce: "n0n0n0n0n0n0n0n0",
            expires_at: 1_800_000_000,
            answer: &digest,
        });
        assert_eq!(&m[..28], b"cmux-mobile-chief-answer-v1\0");
        assert_eq!(
            hex(ring::digest::digest(&ring::digest::SHA256, &m).as_ref()),
            "efdb94cfaf0c3176d7286d56d9f43b3bc0320bfec0fa026689e51f3a3074b6fb"
        );
    }

    #[test]
    fn only_this_phones_fresh_signature_over_this_answer_counts_once() {
        let (pair, public) = key();
        let check = check(&public);
        let op = json!({"kind": "question.answer", "message_id": "msg_Q", "part_index": 0,
                        "answer": {"selections": {"q": ["yes"]}}});
        let now = 1_800_000_000;
        let approval = signed(&pair, &op, "nonce-0123456789ab", now + 60);
        assert_eq!(
            check.verify_at("conv_CHIEF", &op, None, now).unwrap_err(),
            "a question answer needs the iPhone's Face ID approval (approval)"
        );
        assert!(check.verify_at("conv_CHIEF", &op, Some(&approval), now).is_ok());
        // Once.
        assert!(check.verify_at("conv_CHIEF", &op, Some(&approval), now).is_err());
        // Another answer, conversation or part is not what was signed.
        let fresh = signed(&pair, &op, "nonce-1123456789ab", now + 60);
        let mut other = op.clone();
        other["answer"] = json!({"selections": {"q": ["no"]}});
        assert!(check.verify_at("conv_CHIEF", &other, Some(&fresh), now).is_err());
        assert!(check.verify_at("conv_OTHER", &op, Some(&fresh), now).is_err());
        // Expired, or too long-lived.
        let late = signed(&pair, &op, "nonce-2123456789ab", now - 1);
        assert!(check.verify_at("conv_CHIEF", &op, Some(&late), now).is_err());
        let long = signed(&pair, &op, "nonce-3123456789ab", now + MAX_LIFETIME + 1);
        assert!(check.verify_at("conv_CHIEF", &op, Some(&long), now).is_err());
        // Another key, or another approver.
        let (stranger, _) = key();
        let forged = signed(&stranger, &op, "nonce-4123456789ab", now + 60);
        assert!(check.verify_at("conv_CHIEF", &op, Some(&forged), now).is_err());
        let mut named = signed(&pair, &op, "nonce-5123456789ab", now + 60);
        named["approver"] = json!("phone-2");
        assert!(check.verify_at("conv_CHIEF", &op, Some(&named), now).is_err());
        // The fresh one still counts.
        assert!(check.verify_at("conv_CHIEF", &op, Some(&fresh), now).is_ok());
    }
}
