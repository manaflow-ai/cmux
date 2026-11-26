//! Share a Mac from the iPhone with no action on the Mac (cmuxterm-hq#18912 cut 1). Leo,
//! 2026-11-22: "well im not at the computer right now unless screen sharing between ios and
//! mac works then i can click". The design: "Share works from your computer with zero actions
//! on that machine: no app open there, no switch, no approval".
//!
//! A Mac's Screen Sharing row that says it isn't shared offers "Share <Mac>". After the
//! person taps it, the phone asks for a [`ShareApprovalDraft`] here ([`share_approval_draft`]:
//! the approval `cmux.share-approval.v1` with a fresh nonce and the tap's time), signs its
//! `canonical` bytes with the device key the device hub knows this phone by (its Secure
//! Enclave key: that one call is Swift's), and hands the signature back
//! ([`share_approval_signed`]), which checks it against the phone's own hub key and answers the
//! JSON the target Mac admits (`acpmux::share_approval::admit` under `OwnerPairedDevice`).
//!
//! Nothing here signs: Rust has no key. The only signature comes from the tap.

use std::time::{SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use cmux_share_approval::{Device, ShareApproval};

use crate::CmuxMobileError;

/// Who asks to share what: the Mac (its device hub id and name), this phone (its device hub
/// id and name) and the signed-in account (device hub user id).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ShareAsk {
    pub target_id: String,
    pub target_name: String,
    pub asker_id: String,
    pub asker_name: String,
    pub account: String,
}

/// One tap's approval before it is signed: what the target reads, plus the bytes to sign.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ShareApprovalDraft {
    pub target: String,
    pub target_name: String,
    pub asker: String,
    pub asker_name: String,
    pub confirmed_by: String,
    /// The tap, Unix seconds.
    pub confirmed_at: u64,
    pub nonce: String,
    /// What the device key signs (UTF-8): `ShareApproval::canonical`.
    pub canonical: String,
}

impl ShareApprovalDraft {
    /// The approval this draft was made for. Its format is the first line of the bytes the tap
    /// signs ([`Self::canonical`]): a share approval, or a control approval
    /// ([`draft_for`]). Any other first line reads as a share approval, whose
    /// canonical then differs from the draft's, so [`share_approval_signed`] refuses it.
    fn approval(&self) -> ShareApproval {
        let version = match self.canonical.lines().next() {
            Some(cmux_share_approval::CONTROL_VERSION) => cmux_share_approval::CONTROL_VERSION,
            _ => cmux_share_approval::VERSION,
        };
        ShareApproval {
            v: version.into(),
            target: self.target.clone(),
            target_name: self.target_name.clone(),
            asker: self.asker.clone(),
            asker_name: self.asker_name.clone(),
            confirmed_by: self.confirmed_by.clone(),
            confirmed_at: self.confirmed_at,
            nonce: self.nonce.clone(),
            signature: String::new(),
        }
    }
}

/// The approval for the tap happening now, unsigned: call it only from the tap.
#[uniffi::export]
pub fn share_approval_draft(ask: ShareAsk) -> Result<ShareApprovalDraft, CmuxMobileError> {
    let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|since| since.as_secs()).unwrap_or(0);
    draft_at(&ask, now, &uuid::Uuid::new_v4().to_string())
}

/// [`share_approval_draft`] at a given time and nonce (tests).
pub fn draft_at(ask: &ShareAsk, now: u64, nonce: &str) -> Result<ShareApprovalDraft, CmuxMobileError> {
    draft_for(cmux_share_approval::VERSION, ask, now, nonce)
}

/// A draft of the approval format `version` at a given time and nonce. With
/// `cmux_share_approval::CONTROL_VERSION` it is the control approval: the person, on this phone,
/// allows control of `ask.target_id` (a Mac of theirs) from their other signed-in machines, so
/// nobody has to click Allow at that Mac. Leo, 2026-11-22: "who's gonna walk over and click
/// allow on a headless mac mini, or a remote macbook???". It is signed and finished like a
/// share approval ([`share_approval_signed`]) and goes to the hub's `control-approval` path.
pub fn draft_for(
    version: &str,
    ask: &ShareAsk,
    now: u64,
    nonce: &str,
) -> Result<ShareApprovalDraft, CmuxMobileError> {
    let approval = ShareApproval::asked_for(
        version,
        Device { id: &ask.target_id, name: &ask.target_name },
        Device { id: &ask.asker_id, name: &ask.asker_name },
        &ask.account,
        now,
        nonce,
    )
    .map_err(|refused| CmuxMobileError::Refused { code: refused.code.into(), message: refused.message })?;
    Ok(ShareApprovalDraft {
        canonical: approval.canonical(),
        target: approval.target,
        target_name: approval.target_name,
        asker: approval.asker,
        asker_name: approval.asker_name,
        confirmed_by: approval.confirmed_by,
        confirmed_at: approval.confirmed_at,
        nonce: approval.nonce,
    })
}

/// The signed approval as the JSON the target Mac admits, once `signature` (base64 raw r||s
/// ECDSA P-256 SHA-256 of `draft.canonical`) checks against `signing_key` (base64 X9.63, this
/// phone's key as the device hub lists it). A signature by any other key would be refused on
/// the Mac (`share.bad_signature`), so it is refused here first.
#[uniffi::export]
pub fn share_approval_signed(
    draft: ShareApprovalDraft,
    signature: String,
    signing_key: String,
) -> Result<String, CmuxMobileError> {
    let approval = draft.approval();
    let refused =
        |code: &str, message: &str| CmuxMobileError::Refused { code: code.into(), message: message.into() };
    if approval.canonical() != draft.canonical {
        return Err(refused("share.draft_changed", "the approval changed after it was made"));
    }
    let engine = base64::engine::general_purpose::STANDARD;
    let (Ok(key), Ok(raw)) = (engine.decode(signing_key.trim()), engine.decode(signature.trim())) else {
        return Err(refused("share.bad_signature", "the signature or this iPhone's key is not base64"));
    };
    let valid = ring::signature::UnparsedPublicKey::new(&ring::signature::ECDSA_P256_SHA256_FIXED, key)
        .verify(draft.canonical.as_bytes(), &raw)
        .is_ok();
    if !valid {
        return Err(refused(
            "share.bad_signature",
            "the approval is not signed by the key your devices know this iPhone by",
        ));
    }
    Ok(approval.signed(signature.trim()).wire().to_string())
}

#[cfg(test)]
#[path = "share_approval_tests.rs"]
mod tests;
