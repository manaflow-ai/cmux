use super::*;
fn fixture() -> (tempfile::TempDir, Authority, Authority) {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("os-account/.acpmux/machine-consent");
    let a = Authority { root: root.clone(), legacy: dir.path().join("tag-a") };
    let b = Authority { root, legacy: dir.path().join("tag-b") };
    (dir, a, b)
}
#[test]
fn tags_share_enrollment_and_live_grants_and_revocation() {
    let (_dir, a, b) = fixture();
    assert_eq!(b.status()["consentRequired"], false);
    a.enroll().unwrap();
    assert_eq!(b.status()["consentRequired"], true);
    assert_eq!(b.status()["consent"]["screen"], "none");
    a.set("screen", true).unwrap();
    assert_eq!(b.status()["consent"]["screen"], "granted");
    b.set("screen", false).unwrap();
    assert_eq!(a.status()["consent"]["screen"], "none");
    assert_eq!(a.status()["consentRequired"], true);
}
/// A process the daemon spawns while a change holds the lock shares the lock's open file
/// description from its fork until its exec. The change must release the lock anyway.
#[cfg(unix)]
#[test]
fn a_change_releases_its_lock_while_a_spawned_child_holds_a_copy() {
    let (_dir, a, b) = fixture();
    a.enroll().unwrap();
    let held = a.lock().unwrap();
    let inherited = held.0.try_clone().unwrap();
    drop(held);
    b.set("screen", true).unwrap();
    assert_eq!(a.status()["consent"]["screen"], "granted");
    drop(inherited);
}
#[test]
fn own_branch_state_carries_requirement_never_grants() {
    let (_dir, a, b) = fixture();
    std::fs::create_dir_all(&a.legacy).unwrap();
    std::fs::write(
        a.legacy.join("consent.json"),
        b"{\"screen\":\"granted\",\"control\":\"granted\"}",
    )
    .unwrap();
    assert_eq!(a.status()["consentRequired"], true);
    assert_eq!(b.status()["consentRequired"], true);
    assert_eq!(b.status()["consent"]["screen"], "none");
}
#[test]
fn refusal_is_shared_but_does_not_grant_or_enroll() {
    let (_dir, a, b) = fixture();
    a.refused("screen").unwrap();
    let status = b.status();
    assert_eq!(status["consentRequired"], false);
    assert_eq!(status["lastRefusal"]["surface"], "screen");
    assert_eq!(status["consent"]["screen"], "none");
    assert!(a.refused("anything").is_err());
}
#[cfg(unix)]
#[test]
fn authority_files_are_private_and_symlink_authority_fails_closed() {
    use std::os::unix::fs::{MetadataExt, symlink};
    let (dir, a, b) = fixture();
    a.enroll().unwrap();
    a.set("control", true).unwrap();
    a.refused("control").unwrap();
    assert_eq!(std::fs::metadata(&a.root).unwrap().mode() & 0o777, 0o700);
    for name in ["enrolled.json", "consent.json", "refusal.json"] {
        assert_eq!(std::fs::metadata(a.root.join(name)).unwrap().mode() & 0o777, 0o600);
    }
    let linked = dir.path().join("link");
    symlink(&a.root, &linked).unwrap();
    let attacker = Authority { root: linked, legacy: b.legacy };
    assert_eq!(attacker.status()["consentRequired"], true);
    assert_eq!(attacker.status()["consent"]["control"], "none");
}
#[cfg(unix)]
#[test]
fn redirected_parent_is_refused_even_when_authority_does_not_exist() {
    use std::os::unix::fs::symlink;
    let dir = tempfile::tempdir().unwrap();
    let destination = dir.path().join("elsewhere");
    std::fs::create_dir(&destination).unwrap();
    let parent = dir.path().join(".acpmux");
    symlink(destination, &parent).unwrap();
    let authority =
        Authority { root: parent.join("machine-consent"), legacy: dir.path().join("tag") };
    assert!(authority.enroll().is_err());
    assert!(authority.set("screen", true).is_err());
    assert_eq!(authority.status()["consentRequired"], true);
    assert_eq!(authority.status()["consent"]["screen"], "none");
}
#[test]
fn existing_marker_retries_file_and_parent_durability() {
    use std::cell::RefCell;
    let (_dir, a, _) = fixture();
    let first = a.enroll_with_sync(|_| anyhow::bail!("injected interrupted flush"));
    assert!(first.is_err());
    assert!(a.root.join("enrolled.json").exists());
    let seen = RefCell::new(Vec::new());
    a.enroll_with_sync(|path| {
        seen.borrow_mut().push(path.to_owned());
        Ok(())
    })
    .unwrap();
    let mut expected = vec![a.root.join("enrolled.json")];
    expected.extend(a.root.ancestors().take(3).map(Path::to_owned));
    assert_eq!(*seen.borrow(), expected);
}
