//! A standing pre-grant: a key this machine's user enrolled once, with which a local tool
//! (`acpmux allow SESSION --standing-grant`) signs a one-time allow the daemon counts.
//!
//! Leo, 2026-11-23 (ask-833d75c8b9): "you guys should simply decide on case by case and allow
//! permissions. i grant it beforehand". A local CLI is never the person (`hub/person.rs`), so its
//! plain allow is refused. The daemon already counts a one-time allow signed by a key in
//! `ACPMUX_HOME/mac-approvers.json` (`hub/mac_approvers.rs`), a file only this user writes and no
//! RPC changes. The grant is one more entry there, id [`ID`], whose private key stays in
//! [`KEY_FILE`] (0600) beside it:
//!
//! - `acpmux machine approvals grant` makes the key (or keeps the one there) and enrolls it.
//!   `acpmux machine approvals rm standing-grant` ends the grant at once, as for a Mac.
//! - `acpmux allow SESSION [OPTION] --standing-grant` signs [`mac_approvers::message`] for the
//!   pending prompt (its `decisionNonce`, the daemon run's `personInstance`), as an enrolled Mac's
//!   app does. Everything a Mac's signature is held to holds: it counts once, for at most
//!   [`MAX_LIFETIME`] seconds, and only as the one-time allow of a plain tool ask, an agent's
//!   question or a folder-trust card (`mac_approvers::may_allow`): never a lasting allow, a plan,
//!   a mode switch, a policy or a rule.
//!
//! Residual: the key is a file of this user, so any process of this user can sign with it while
//! the grant stands, as any such process could already write `mac-approvers.json` itself. Which
//! prompt to allow is the caller's judgment (leo-workspace `tools/permission_autoclear.py`), not
//! this module's. Test: `tests/peer_integration.rs`
//! `a_standing_grant_allows_a_local_tool_ask_once_and_never_a_lasting_allow`.

use crate::hub::approvers::{MAX_LIFETIME, answers_digest, hex, unhex};
use crate::hub::mac_approvers::{self, Parts};
use anyhow::{Context, Result, anyhow};
use ring::signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair, KeyPair};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

/// The grant's approver id in `mac-approvers.json`.
pub const ID: &str = "standing-grant";
/// The grant's private key (PKCS#8 as hex), in `ACPMUX_HOME`.
pub const KEY_FILE: &str = "standing-grant.key";
/// How long a signature lives: well inside [`MAX_LIFETIME`], long enough for one answer.
const LIFETIME: u64 = 120;

/// `ACPMUX_HOME/standing-grant.key`.
pub fn key_path() -> PathBuf {
    crate::config::home().join(KEY_FILE)
}

/// The key at `path`, made there first when there is none.
pub fn ensure_key(path: &Path) -> Result<EcdsaKeyPair> {
    if crate::home_fs::exists_nofollow(path) {
        return load(path);
    }
    let rng = ring::rand::SystemRandom::new();
    let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng)
        .map_err(|_| anyhow!("could not make a P-256 key"))?;
    crate::home_fs::write_json_private(path, hex(pkcs8.as_ref()).as_bytes())
        .with_context(|| format!("write {}", path.display()))?;
    load(path)
}

/// The key at `path`: a private file of this user, never a link.
pub fn load(path: &Path) -> Result<EcdsaKeyPair> {
    use std::io::Read as _;
    let mut text = String::new();
    crate::config::private_state_file(path)
        .context("no standing grant here (`acpmux machine approvals grant` makes one)")?
        .take(4096)
        .read_to_string(&mut text)?;
    let pkcs8 = unhex(text.trim()).ok_or_else(|| anyhow!("{} is not a key", path.display()))?;
    EcdsaKeyPair::from_pkcs8(
        &ECDSA_P256_SHA256_FIXED_SIGNING,
        &pkcs8,
        &ring::rand::SystemRandom::new(),
    )
    .map_err(|_| anyhow!("{} is not a P-256 key", path.display()))
}

/// The grant's entry for `mac-approvers.json`.
pub fn entry(key: &EcdsaKeyPair) -> Value {
    json!({"id": ID, "publicKey": hex(key.public_key().as_ref()), "name": "standing grant"})
}

/// `_meta.acpmux` of a `permission_respond` that allows `pending` (an `_acpmux/info` `pending`
/// entry: `permissionId`, `decisionNonce`, `personInstance`, `request`) with `option`, signed
/// with `key` for `session`, valid from `now` for [`LIFETIME`] seconds.
pub fn signed_meta(
    key: &EcdsaKeyPair,
    session: &str,
    pending: &Value,
    option: &str,
    now: u64,
) -> Result<Value> {
    let field = |f: &str| {
        pending
            .get(f)
            .and_then(Value::as_str)
            .ok_or_else(|| anyhow!("the pending prompt has no {f}"))
    };
    let (permission, nonce, instance) =
        (field("permissionId")?, field("decisionNonce")?, field("personInstance")?);
    let expires_at = now + LIFETIME.min(MAX_LIFETIME);
    let message = mac_approvers::message(&Parts {
        instance,
        mac: ID,
        session,
        permission,
        tool_call: pending
            .pointer("/request/toolCall/toolCallId")
            .and_then(Value::as_str)
            .unwrap_or_default(),
        option,
        nonce,
        expires_at,
        answers: &answers_digest(None),
    });
    let signature = key
        .sign(&ring::rand::SystemRandom::new(), &message)
        .map_err(|_| anyhow!("could not sign the allow"))?;
    Ok(json!({
        "decisionNonce": nonce,
        "approverDecision": {"approver": ID, "expiresAt": expires_at, "signature": hex(signature.as_ref())},
    }))
}
