//! Model keys and Claude tokens (`cmux-model-key`) through the Security framework, in acpmux itself.
//!
//! An item `/usr/bin/security` creates trusts `security`, so any process of the user could run
//! `security find-generic-password -w -s cmux-model-key …` and read it with no prompt. An item
//! acpmux adds here trusts acpmux's own signature instead: `security` (or any other program) gets
//! the Keychain's prompt. The app and `cmux cloud connect` hand a pasted key to the daemon
//! (`connections/key.store`) for that reason, rather than writing it themselves.
//!
//! Items `security` created before this stay as they are and are read the way they always were
//! (`profiles::keychain_lookup`'s `security` call), and so is one this process does not find: they are told apart by [`KIND`], which only an
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
    /// `security` wrote it, or the framework does not see it: the caller reads it with `security`,
    /// as before.
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
        Err(error) => read_refused(error.code(), || kind(account)),
    }
}

/// A refused framework read. Not found here is not proof it is gone: this process's Keychain
/// search list is read once and can lag a `security list-keychains -s` made after it started (a
/// job's own Keychain, a Keychain added since), while a `security` item there is what `security`
/// reads. So `security` decides, as it did before acpmux read model keys itself.
fn read_refused(code: i32, kind: impl FnOnce() -> Option<Option<String>>) -> Result<Read, String> {
    if code == ITEM_NOT_FOUND {
        return Ok(Read::Legacy);
    }
    match kind() {
        Some(Some(kind)) if kind == KIND => Err(OTHER_BUILD.to_owned()),
        Some(_) => Ok(Read::Legacy),
        None => Err(LOCKED.to_owned()),
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
        Ok(Err(error)) => delete_refused(error.code(), || kind(account)),
        Err(_) => Deleted::Kept(LOCKED),
    }
}

/// A refused framework delete. One this process cannot find still goes to `security`, which sees
/// the current search list ([`read_refused`]) and answers an item already gone as gone.
fn delete_refused(code: i32, kind: impl FnOnce() -> Option<Option<String>>) -> Deleted {
    if code == ITEM_NOT_FOUND {
        return Deleted::Legacy;
    }
    match kind() {
        Some(Some(kind)) if kind == KIND => Deleted::Kept(OTHER_BUILD),
        _ => Deleted::Legacy,
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
mod tests {
    use super::*;

    /// A real login-Keychain round trip: written here with acpmux's kind, read back, deleted. Run by
    /// hand on a Mac with an unlocked login Keychain
    /// (`cargo test -p acpmux model_key_keychain -- --ignored`).
    #[test]
    #[ignore = "uses the login Keychain"]
    fn model_key_keychain_round_trip_is_acpmux_only() {
        let account = super::super::new_account("test");
        store(&account, "cmux test key", "sk-test-value").unwrap();
        assert!(matches!(read(&account), Ok(Read::Value(v)) if v.as_str() == "sk-test-value"));
        assert_eq!(kind(&account), Some(Some(KIND.to_owned())));
        assert!(matches!(delete(&account), Deleted::Gone));
        assert!(matches!(read(&account), Ok(Read::Legacy)));
    }

    /// The probe's FIRE (11-28): the token item `security` wrote in a Keychain this process's
    /// search list did not have yet read as not found, and the Cloud start refused the connection.
    #[test]
    fn not_found_here_goes_to_security() {
        let never = || -> Option<Option<String>> { panic!("not found needs no attribute search") };
        assert!(matches!(read_refused(ITEM_NOT_FOUND, never), Ok(Read::Legacy)));
        assert!(matches!(delete_refused(ITEM_NOT_FOUND, never), Deleted::Legacy));
    }

    #[test]
    fn a_refusal_still_tells_security_items_from_another_build() {
        let ours = || Some(Some(KIND.to_owned()));
        let securitys = || Some(None);
        assert!(matches!(read_refused(INTERACTION_NOT_ALLOWED, ours), Err(e) if e == OTHER_BUILD));
        assert!(matches!(read_refused(INTERACTION_NOT_ALLOWED, securitys), Ok(Read::Legacy)));
        assert!(matches!(read_refused(AUTH_FAILED, || None), Err(e) if e == LOCKED));
        assert!(matches!(delete_refused(AUTH_FAILED, ours), Deleted::Kept(OTHER_BUILD)));
        assert!(matches!(delete_refused(AUTH_FAILED, securitys), Deleted::Legacy));
    }
}
