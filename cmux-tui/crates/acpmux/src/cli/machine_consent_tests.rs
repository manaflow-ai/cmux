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
    let first = a.enroll_with_sync(false, |_| anyhow::bail!("injected interrupted flush"));
    assert!(first.is_err());
    assert!(a.root.join("enrolled.json").exists());
    let seen = RefCell::new(Vec::new());
    a.enroll_with_sync(false, |path| {
        seen.borrow_mut().push(path.to_owned());
        Ok(())
    })
    .unwrap();
    let mut expected = vec![a.root.join("enrolled.json")];
    expected.extend(a.root.ancestors().take(3).map(Path::to_owned));
    assert_eq!(*seen.borrow(), expected);
}

#[test]
fn a_sign_in_join_requires_consent_from_elsewhere_and_keeps_the_macs_own_computer_use() {
    let (_dir, a, b) = fixture();
    a.enroll_as(true).unwrap();
    // What reaches this Mac from elsewhere still needs the consent.
    assert_eq!(b.status()["consentRequired"], true);
    assert_eq!(b.status()["consent"]["control"], "none");
    // The Mac's own sessions keep computer use, on every tag.
    assert!(a.required_only_by_sign_in() && b.required_only_by_sign_in());
    // Signing in again changes nothing.
    b.enroll_as(true).unwrap();
    assert!(a.required_only_by_sign_in());
    // A consent the person set (granted or taken back) is theirs: the gate is as it always was.
    a.set("control", false).unwrap();
    assert!(!a.required_only_by_sign_in());
}
#[test]
fn any_other_join_makes_the_requirement_the_one_it_always_was() {
    let (_dir, a, b) = fixture();
    a.enroll_as(true).unwrap();
    b.enroll().unwrap();
    assert!(!a.required_only_by_sign_in());
    // A later sign-in never turns it back.
    a.enroll_as(true).unwrap();
    assert!(!b.required_only_by_sign_in());
    // Never enrolled: nothing is required, so nothing is kept by sign-in either.
    let (_dir, fresh, _) = fixture();
    assert!(!fresh.required_only_by_sign_in());
    assert_eq!(fresh.status()["consentRequired"], false);
}

#[test]
fn after_a_sign_in_join_a_local_computer_use_call_passes_and_one_from_elsewhere_does_not() {
    let (_dir, a, b) = fixture();
    a.enroll_as(true).unwrap();
    // The Mac's own Computer Use (the app's helper): a screenshot and a click pass the bridge's
    // check and the helper's, on every tag.
    for authority in [&a, &b] {
        let local = authority.status_for(true);
        assert_eq!(local["consentRequired"], false, "{local}");
        assert_eq!(local["localComputerUse"], "keptBySignIn");
        assert!(crate::cua_v2::require_tool_consent(true, &local).is_ok());
        assert!(crate::cua_v2::require_tool_consent(false, &local).is_ok());
    }
    // What reaches this Mac from elsewhere (a hand, the hub) still needs the consent.
    let elsewhere = a.status_for(false);
    assert_eq!(elsewhere, a.status());
    assert_eq!(elsewhere["consentRequired"], true);
    let refused = crate::cua_v2::require_tool_consent(true, &elsewhere).unwrap_err();
    assert_eq!(refused.to_string(), crate::machine_record::CONSENT_REQUIRED);
    // A consent the person set is theirs: the local use is gated by it, as it always was.
    a.set("screen", true).unwrap();
    let local = a.status_for(true);
    assert_eq!(local["consentRequired"], true);
    assert!(crate::cua_v2::require_tool_consent(true, &local).is_ok());
    assert!(crate::cua_v2::require_tool_consent(false, &local).is_err());
}

#[test]
fn a_join_the_person_made_gates_the_macs_own_computer_use_as_before() {
    let (_dir, a, _b) = fixture();
    a.enroll().unwrap();
    let local = a.status_for(true);
    assert_eq!(local["consentRequired"], true);
    assert!(local.get("localComputerUse").is_none());
    assert!(crate::cua_v2::require_tool_consent(true, &local).is_err());
    // Never joined: nothing is required either way.
    let (_dir, fresh, _) = fixture();
    assert_eq!(fresh.status_for(true), fresh.status());
}
/// "Control for my other machines signed in to this account": off after a sign-in join, granted
/// and revoked only by a set, and any answer is recorded so the machine is asked once.
#[test]
fn signed_in_machines_is_off_by_default_and_answered_once() {
    let (_dir, a, b) = fixture();
    a.enroll_as(true).unwrap();
    let status = b.status();
    assert_eq!(status["consent"]["signedInMachines"], "none", "signing in grants nothing");
    assert!(status["consent"]["signedInMachinesAnsweredAt"].is_null(), "not asked yet");
    a.refused_from(crate::machine_record::SIGNED_IN_MACHINES, Some("studio")).unwrap();
    let status = b.status();
    assert_eq!(status["lastRefusal"]["surface"], "signedInMachines");
    assert_eq!(status["lastRefusal"]["from"], "studio");
    assert_eq!(status["consent"]["signedInMachines"], "none", "a refusal grants nothing");
    // Not now: still off, and answered.
    b.set_as("signedInMachines", false, Some("user-1".into())).unwrap();
    let status = a.status();
    assert_eq!(status["consent"]["signedInMachines"], "none");
    assert!(status["consent"]["signedInMachinesAnsweredAt"].is_string());
    // Allow, then Off again: revocable on this machine.
    a.set_as("signedInMachines", true, Some("user-1".into())).unwrap();
    assert_eq!(b.status()["consent"]["signedInMachines"], "granted");
    assert_eq!(b.status()["consent"]["control"], "none", "it is not control from elsewhere");
    b.set_as("signedInMachines", false, Some("user-1".into())).unwrap();
    assert_eq!(a.status()["consent"]["signedInMachines"], "none");
}
/// A consent file an older build wrote (no signedInMachines) reads as off, and its other grants
/// keep.
#[test]
fn an_older_consent_file_reads_signed_in_machines_as_off() {
    let (_dir, a, _b) = fixture();
    a.enroll().unwrap();
    crate::config::write_atomic(
        &a.root.join("consent.json"),
        b"{\"screen\":\"granted\",\"control\":\"none\"}",
    )
    .unwrap();
    let status = a.status();
    assert_eq!(status["consent"]["screen"], "granted");
    assert_eq!(status["consent"]["signedInMachines"], "none");
}
/// The grant names the account it was given for, and no grant goes without one.
#[test]
fn a_signed_in_machines_grant_names_its_account() {
    let (_dir, a, b) = fixture();
    a.enroll_as(true).unwrap();
    assert!(a.set_as("signedInMachines", true, None).is_err(), "no account, nothing to allow");
    assert_eq!(b.status()["consent"]["signedInMachines"], "none");
    a.set_as("signedInMachines", true, Some("user-1".into())).unwrap();
    assert_eq!(b.status()["consent"]["signedInMachinesUser"], "user-1");
}
/// After a switch to another account, an earlier account's grant, answer and pending ask read as
/// never given: nothing is granted, the app shows no old ask, and the next request asks again.
#[test]
fn a_switch_to_another_account_reads_signed_in_machines_as_unasked() {
    let (_dir, a, b) = fixture();
    a.enroll_as(true).unwrap();
    a.refused_by("signedInMachines", Some("studio"), Some("user-1")).unwrap();
    a.set_as("signedInMachines", true, Some("user-1".into())).unwrap();
    let mine = for_account(b.status(), Some("user-1"));
    assert_eq!(mine["consent"]["signedInMachines"], "granted");
    assert_eq!(mine["lastRefusal"]["user"], "user-1");
    let other = for_account(b.status(), Some("user-2"));
    assert_eq!(other["consent"]["signedInMachines"], "none", "another account's grant");
    assert!(
        other["consent"]["signedInMachinesAnsweredAt"].is_null(),
        "and answer, are not this one's"
    );
    assert!(other["lastRefusal"].is_null(), "another account's ask is not shown");
    let none = for_account(b.status(), None);
    assert_eq!(none["consent"]["signedInMachines"], "none", "no account, nothing granted");
    // Screen and control, and asks for them, are not the account's.
    a.set("screen", true).unwrap();
    a.refused("control").unwrap();
    let other = for_account(b.status(), Some("user-2"));
    assert_eq!(other["consent"]["screen"], "granted");
    assert_eq!(other["lastRefusal"]["surface"], "control");
}
