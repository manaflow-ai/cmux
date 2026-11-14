use super::*;

#[test]
fn post_launch_enrollment_replaces_and_clears_the_spawn_fallback() {
    let slot = RwLock::new(None);
    let fallback = || Some(Socket { path: "/spawn.sock".into(), token: "spawn-token".into() });
    assert_eq!(current_with(&slot, fallback).unwrap().path, PathBuf::from("/spawn.sock"));

    *slot.write().unwrap() = Some(select(Some("/enrolled.sock".into()), Some("new-token".into())));
    let enrolled = current_with(&slot, fallback).unwrap();
    assert_eq!(enrolled.path, PathBuf::from("/enrolled.sock"));
    assert_eq!(enrolled.token, "new-token");

    *slot.write().unwrap() = Some(select(Some(String::new()), Some("ignored".into())));
    assert!(current_with(&slot, fallback).is_none());
}
