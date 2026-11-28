//! The acpmux wire ABI range the phone speaks to its Mac (hq RFD 0224 "One update system for every
//! place cmux runs", phase 2: a protocol range on every link). The phone talks to the Mac's acpmux
//! over the same `initialize` the acpmux socket clients send, so it uses the same fields as
//! acpmux's `protocol/range.rs`: `_meta.acpmux.{abi, abiMin}`, with the capabilities and features
//! the Mac lists in its reply gating the features themselves.
//!
//! Both sides check. The Mac refuses an `initialize` whose range shares no revision with its own,
//! answering the typed `version.incompatible` (its `details.update` is `peer` when the client is the
//! older side and `self` when the daemon is). The phone reads the Mac's reply the same way, so a
//! newer Mac that dropped what this app speaks gets a sentence naming the side to update instead
//! of a chat list that stops making sense. A Mac from before the fields names no `abi` and is
//! served as it was: no reply is refused for a field it never sent.

use serde_json::Value;

/// The newest acpmux wire ABI the phone reads: the newest revision in acpmux's
/// `spec/acpmux-abi.compat.json` that this app was checked against (`link_abi::tests`).
pub const PHONE_ABI: u32 = 2;

/// The oldest acpmux wire ABI the phone still reads. Revision 2 only took away the agent to-do
/// list, which the phone never read, so every revision back to the first is still read.
pub const PHONE_ABI_MIN: u32 = 0;

/// The `errorKind` acpmux's refusal carries (acpmux `recovery::kind::VERSION_INCOMPATIBLE`).
pub const VERSION_INCOMPATIBLE: &str = "version.incompatible";

/// An inclusive ABI range, as `initialize` `_meta.acpmux` names it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct PhoneAbiRange {
    pub min: u32,
    pub max: u32,
}

/// Which side the person updates when the phone and the Mac share no revision.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PhoneUpdateSide {
    /// This app is older than the Mac's acpmux still serves.
    Phone,
    /// The Mac's acpmux is older than this app still reads.
    Mac,
}

/// A link the phone and the Mac cannot share: which side to update and what the person reads.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PhoneLinkIncompatible {
    pub side: PhoneUpdateSide,
    /// One short sentence for the link's status line (under 80 characters).
    pub reason: String,
    /// The Mac's range, when its reply named one.
    pub mac: Option<PhoneAbiRange>,
}

/// The range the phone names in its `initialize` `_meta.acpmux` (`abi`, `abiMin`).
#[uniffi::export]
pub fn phone_abi_range() -> PhoneAbiRange {
    PhoneAbiRange { min: PHONE_ABI_MIN, max: PHONE_ABI }
}

/// Reads the Mac's `initialize` result (its JSON): `None` when the phone can read it, including a
/// Mac that names no `abi` (a build from before the field), or JSON that does not parse.
#[uniffi::export]
pub fn phone_abi_check(initialize_result_json: String) -> Option<PhoneLinkIncompatible> {
    let value: Value = serde_json::from_str(&initialize_result_json).ok()?;
    let mac = mac_range(&value)?;
    let ours = phone_abi_range();
    let top = ours.max.min(mac.max);
    if top >= ours.min.max(mac.min) {
        return None;
    }
    let side = if mac.max < ours.min { PhoneUpdateSide::Mac } else { PhoneUpdateSide::Phone };
    Some(PhoneLinkIncompatible { side, reason: reason(side), mac: Some(mac) })
}

/// Reads the Mac's refusal of the phone's `initialize` (the JSON-RPC error's `data`): the
/// incompatibility when it is acpmux's `version.incompatible`, else `None`. In the Mac's words
/// `details.update` is `peer` (the client, this phone, is older) or `self` (the Mac is older).
#[uniffi::export]
pub fn phone_abi_refusal(error_data_json: String) -> Option<PhoneLinkIncompatible> {
    let value: Value = serde_json::from_str(&error_data_json).ok()?;
    if value.get("errorKind").and_then(Value::as_str) != Some(VERSION_INCOMPATIBLE) {
        return None;
    }
    let side = match value.pointer("/details/update").and_then(Value::as_str) {
        Some("self") => PhoneUpdateSide::Mac,
        _ => PhoneUpdateSide::Phone,
    };
    let mac = value.pointer("/details/ours").and_then(range_of);
    Some(PhoneLinkIncompatible { side, reason: reason(side), mac })
}

fn reason(side: PhoneUpdateSide) -> String {
    match side {
        PhoneUpdateSide::Phone => "Update the cmux app: it is older than cmux on your Mac".into(),
        PhoneUpdateSide::Mac => "Update cmux on your Mac: it is older than this app".into(),
    }
}

/// The Mac's `_meta.acpmux.{abi, abiMin}`; `None` with no `abi`. No `abiMin`, or one above `abi`,
/// reads as `abi` alone, as acpmux's `AbiRange::of` does.
fn mac_range(result: &Value) -> Option<PhoneAbiRange> {
    let meta = result.pointer("/_meta/acpmux")?;
    let max = u32::try_from(meta.get("abi")?.as_u64()?).ok()?;
    let min = meta
        .get("abiMin")
        .and_then(Value::as_u64)
        .and_then(|m| u32::try_from(m).ok())
        .filter(|m| *m <= max)
        .unwrap_or(max);
    Some(PhoneAbiRange { min, max })
}

/// A `{min, max}` object, as acpmux's refusal details name a range.
fn range_of(value: &Value) -> Option<PhoneAbiRange> {
    let min = u32::try_from(value.get("min")?.as_u64()?).ok()?;
    let max = u32::try_from(value.get("max")?.as_u64()?).ok()?;
    (min <= max).then_some(PhoneAbiRange { min, max })
}

#[cfg(test)]
#[path = "link_abi_tests.rs"]
mod tests;
