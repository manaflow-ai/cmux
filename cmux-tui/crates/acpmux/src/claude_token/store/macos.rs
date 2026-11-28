//! Model keys and Claude tokens (`cmux-model-key`) through the Security framework, in acpmux itself.
//!
//! An item `/usr/bin/security` creates trusts `security`, so any process of the user could run
//! `security find-generic-password -w -s cmux-model-key …` and read it with no prompt. An item
//! acpmux adds here trusts acpmux's own signature instead: `security` (or any other program) gets
//! the Keychain's prompt. The app and `cmux cloud connect` hand a pasted key to the daemon
//! (`connections/key.store`) for that reason, rather than writing it themselves.
//!
//! Items `security` created before this stay as they are and are read the way they always were
//! (`profiles::keychain_lookup`'s `security` call): they are told apart by [`KIND`], which only an
//! item written here carries. They are not rewritten: a differently signed acpmux (a tagged or dev
//! build) that rewrote one would lock the release build out of it. Adding the key again moves it.
//!
//! Every call runs with Keychain interaction off, so none shows a dialog; one refused that way
//! answers an error that names the other build.

use security_framework::item::{ItemClass, ItemSearchOptions, Limit};
use security_framework::passwords::{
    PasswordOptions, delete_generic_password, generic_password, set_generic_password_options,
};
use zeroize::Zeroizing;

use super::SERVICE;
use crate::vault::store::macos::without_ui;

/// The item kind (`kSecAttrDescription`) of an item acpmux wrote; `security` sets none.
pub const KIND: &str = "cmux model key";

const AUTH_FAILED: i32 = -25293;
const ITEM_NOT_FOUND: i32 = -25300;
const INTERACTION_NOT_ALLOWED: i32 = -25308;

/// The answer for an item another acpmux signature wrote (a tagged, dev or older build).
pub const OTHER_BUILD: &str = "this key was saved by another cmux build, which only it can read: \
                               add it again in Settings > Models";
const LOCKED: &str = "the login Keychain is locked or unavailable";

/// What a read found.
pub enum Read {
    Value(Zeroizing<String>),
    Missing,
    /// `security` wrote it: the caller reads it as before.
    Legacy,
}

/// `value` as a new `SERVICE`/`account` item, trusted by this acpmux only. Never an update: any
/// process of the user reaches `secret.store`, so an account that is already taken is refused
/// rather than overwritten (each key gets a fresh account, `new_account`).
pub fn store(account: &str, label: &str, value: &str) -> Result<(), String> {
    if value.is_empty() {
        return Err("the value is empty".into());
    }
    if kind(account).is_some() {
        return Err("that Keychain item already exists; nothing was stored".into());
    }
    let mut options = PasswordOptions::new_generic_password(SERVICE, account);
    options.set_label(label);
    options.set_description(KIND);
    without_ui(|| set_generic_password_options(value.as_bytes(), options))
        .map_err(|_| LOCKED.to_owned())?
        .map_err(|error| match error.code() {
            AUTH_FAILED | INTERACTION_NOT_ALLOWED if kind(account).is_some() => {
                OTHER_BUILD.to_owned()
            }
            _ => format!("cannot store it in the Keychain ({})", error.code()),
        })
}

/// `SERVICE`/`account`'s value.
pub fn read(account: &str) -> Result<Read, String> {
    let found =
        without_ui(|| generic_password(PasswordOptions::new_generic_password(SERVICE, account)))
            .map_err(|_| LOCKED.to_owned())?;
    match found {
        Ok(bytes) => {
            let bytes = Zeroizing::new(bytes);
            std::str::from_utf8(&bytes)
                .map(|text| Read::Value(Zeroizing::new(text.to_owned())))
                .map_err(|_| "the Keychain item is not UTF-8 text".to_owned())
        }
        Err(error) if error.code() == ITEM_NOT_FOUND => Ok(Read::Missing),
        Err(_) => match kind(account) {
            Some(Some(kind)) if kind == KIND => Err(OTHER_BUILD.to_owned()),
            Some(_) => Ok(Read::Legacy),
            None => Err(LOCKED.to_owned()),
        },
    }
}

/// How a delete ended.
pub enum Deleted {
    /// Gone, or never there.
    Gone,
    /// `security` wrote it: the caller deletes it with `security`.
    Legacy,
    /// Still there (a locked Keychain, another build's item): the reason, never a value.
    Kept(&'static str),
}

/// Removes `SERVICE`/`account`. An item already gone is fine; one still there after a refusal says why.
pub fn delete(account: &str) -> Deleted {
    match without_ui(|| delete_generic_password(SERVICE, account)) {
        Ok(Ok(())) => Deleted::Gone,
        Ok(Err(error)) if error.code() == ITEM_NOT_FOUND => Deleted::Gone,
        Ok(Err(_)) => match kind(account) {
            None => Deleted::Gone,
            Some(Some(kind)) if kind == KIND => Deleted::Kept(OTHER_BUILD),
            Some(_) => Deleted::Legacy,
        },
        Err(_) => Deleted::Kept(LOCKED),
    }
}

/// The item's kind when it exists (`Some(None)`: no kind, as `security` writes it); `None` when
/// there is no such item (or the Keychain cannot be searched). Reads attributes only, never the value.
fn kind(account: &str) -> Option<Option<String>> {
    let items = without_ui(|| {
        ItemSearchOptions::new()
            .class(ItemClass::generic_password())
            .service(SERVICE)
            .account(account)
            .limit(Limit::Max(1))
            .load_attributes(true)
            .search()
    })
    .ok()?
    .ok()?;
    let attributes = items.first()?.simplify_dict()?;
    Some(attributes.get("desc").cloned())
}

#[cfg(test)]
#[path = "macos_tests.rs"]
mod tests;
