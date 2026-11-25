//! The read-first store as Swift calls it: open, put, get after a reopen, bounds, sign-out.

use cmux_mobile_link_ffi::{PhoneReadKey, PhoneReadStore, PhoneReadStoreError};

fn key(account: &str, mac: &str) -> PhoneReadKey {
    PhoneReadKey { scope: account.into(), device: mac.into(), kind: "agent_chats".into() }
}

#[test]
fn a_cold_launch_reads_what_the_last_run_kept_and_sign_out_clears_it() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("read-first").to_string_lossy().into_owned();
    let store = PhoneReadStore::open(path.clone(), 8, 1024).unwrap();
    assert_eq!(store.get(key("user_1", "mac-1")), None);
    store.put(key("user_1", "mac-1"), b"{\"chats\":[]}".to_vec()).unwrap();
    drop(store);

    let again = PhoneReadStore::open(path, 8, 1024).unwrap();
    assert_eq!(again.get(key("user_1", "mac-1")).as_deref(), Some(&b"{\"chats\":[]}"[..]));
    assert_eq!(again.get(key("user_2", "mac-1")), None, "another account reads nothing");
    assert_eq!(again.count(), 1);

    again.remove_all().unwrap();
    assert_eq!(again.get(key("user_1", "mac-1")), None);
    assert_eq!(again.count(), 0);
}

#[test]
fn bounds_hold() {
    let dir = tempfile::tempdir().unwrap();
    let store = PhoneReadStore::open(dir.path().to_string_lossy().into_owned(), 2, 4).unwrap();
    assert_eq!(
        store.put(key("u", "m"), b"12345".to_vec()),
        Err(PhoneReadStoreError::TooLarge { size: 5, limit: 4 })
    );
    for mac in ["a", "b", "c", "d"] {
        store.put(key("u", mac), b"v".to_vec()).unwrap();
    }
    assert_eq!(store.count(), 2);
    store.remove(key("u", "d")).unwrap();
    assert_eq!(store.get(key("u", "d")), None);
}
