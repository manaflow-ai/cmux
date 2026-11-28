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
    assert!(matches!(read(&account), Ok(Read::Missing)));
}
