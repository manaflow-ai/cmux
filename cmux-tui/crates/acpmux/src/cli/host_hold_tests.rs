use super::*;

const NOW: u64 = 1_793_000_000_000; // 2026-10-26

fn holds(entries: &[(&str, Option<&str>, Option<&str>)]) -> Holds {
    let holds = entries
        .iter()
        .map(|(k, reason, until)| {
            let hold = Hold { reason: reason.map(Into::into), until: until.map(Into::into) };
            ((*k).to_owned(), hold)
        })
        .collect();
    Holds { holds }
}

#[test]
fn a_hold_names_the_peer_its_host_or_the_hosts_first_label() {
    let h = holds(&[("mini-a", Some("reserved for a teammate"), None)]);
    assert!(h.why("mini-a", "elsewhere", NOW).is_some(), "the peer name");
    assert!(h.why("other", "cmux@Mini-A.tail0.ts.net", NOW).is_some(), "the first label");
    assert!(h.why("other", "mini-a", NOW).is_some(), "the host");
    assert_eq!(h.why("mini-b", "mini-b.tail0.ts.net", NOW), None);
    let why = h.why("mini-a", "mini-a", NOW).unwrap();
    assert!(why.contains("(reserved for a teammate)"), "{why}");
    assert!(why.contains("acpmux machine hold mini-a --release"), "{why}");
    let fqdn = holds(&[("mini-a.tail0.ts.net", None, None)]);
    assert!(fqdn.why("x", "cmux@mini-a.tail0.ts.net", NOW).is_some());
}

#[test]
fn an_expired_hold_under_one_name_never_hides_an_active_one_under_another() {
    let h = holds(&[
        ("mini-a", None, Some("2026-10-01T00:00:00Z")),
        ("mini-a.tail0.ts.net", Some("reserved"), Some("2026-10-28T23:59:59Z")),
    ]);
    let why = h.why("mini-a", "cmux@mini-a.tail0.ts.net", NOW).unwrap();
    assert!(why.starts_with("mini-a.tail0.ts.net is held (reserved)"), "{why}");
}

#[test]
fn a_hold_ends_at_its_until_and_an_unreadable_one_still_holds() {
    let h = holds(&[
        ("past", None, Some("2026-10-01T00:00:00Z")),
        ("future", None, Some("2026-10-28T23:59:59Z")),
        ("garbled", None, Some("next week")),
    ]);
    assert_eq!(h.why("past", "past", NOW), None);
    assert!(h.why("future", "future", NOW).unwrap().contains("until 2026-10-28T23:59:59Z"));
    assert!(h.why("garbled", "garbled", NOW).is_some());
}

fn scratch(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("acpmux-holds-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

#[test]
fn the_file_reads_back_and_a_missing_one_holds_nothing() {
    let dir = scratch("file");
    let path = dir.join("update-holds.json");
    assert_eq!(Holds::read(&path).unwrap(), Holds::default());
    let h = holds(&[("mini-a", Some("r"), Some("2026-10-28T23:59:59Z"))]);
    h.write(&path).unwrap();
    assert_eq!(Holds::read(&path).unwrap(), h);
    std::fs::write(&path, "not json").unwrap();
    assert!(Holds::read(&path).is_err(), "never dropped on a guess");
    std::fs::write(&path, vec![b' '; HOLDS_MAX_BYTES as usize + 1]).unwrap();
    assert!(Holds::read(&path).is_err(), "bounded");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
#[cfg(unix)]
fn a_holds_file_through_a_link_or_writable_by_others_is_refused() {
    use std::os::unix::fs::PermissionsExt;
    let dir = scratch("link");
    let path = dir.join("update-holds.json");
    holds(&[("mini-a", None, None)]).write(&path).unwrap();
    let link = dir.join("linked.json");
    std::os::unix::fs::symlink(&path, &link).unwrap();
    assert!(Holds::read(&link).is_err(), "a link is refused");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o666)).unwrap();
    assert!(Holds::read(&path).is_err(), "writable by others is refused");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn hold_and_release_change_one_name_and_keep_the_others() {
    let dir = scratch("change");
    let path = dir.join("update-holds.json");
    let until = Some("2026-10-28T23:59:59Z".to_owned());
    change(&path, Some("Mini-A".into()), Some("r".into()), until, false, true).unwrap();
    change(&path, Some("mini-b".into()), None, None, false, true).unwrap();
    let read = Holds::read(&path).unwrap();
    assert_eq!(read.holds.keys().collect::<Vec<_>>(), ["mini-a", "mini-b"]);
    change(&path, Some("MINI-A".into()), None, None, true, true).unwrap();
    let read = Holds::read(&path).unwrap();
    assert_eq!(read.holds.keys().collect::<Vec<_>>(), ["mini-b"]);
    let bad = Some("next week".to_owned());
    assert!(change(&path, Some("mini-c".into()), None, bad, false, true).is_err());
    assert!(change(&path, Some("--all".into()), None, None, false, true).is_err());
    assert_eq!(Holds::read(&path).unwrap().holds.len(), 1, "a refused change writes nothing");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A folder that is a dangling link hides nothing: the read fails, so
/// `host update` leaves the peer alone (`holdsUnreadable`).
#[test]
#[cfg(unix)]
fn a_holds_folder_that_is_a_dangling_link_is_an_error_not_no_holds() {
    let dir = scratch("dangling");
    std::fs::create_dir_all(&dir).unwrap();
    let home = dir.join("home");
    std::os::unix::fs::symlink(dir.join("gone"), &home).unwrap();
    assert!(Holds::read(&home.join("update-holds.json")).is_err());
    let file = dir.join("file");
    std::fs::write(&file, "").unwrap();
    assert!(Holds::read(&file.join("update-holds.json")).is_err(), "not a folder");
    let none = dir.join("no-home").join("update-holds.json");
    assert_eq!(Holds::read(&none).unwrap(), Holds::default(), "no home at all: nothing held");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Two commands at once never lose each other's hold.
#[test]
fn concurrent_holds_are_all_kept() {
    let dir = scratch("race");
    let path = dir.join("update-holds.json");
    std::thread::scope(|s| {
        for i in 0..8 {
            let path = &path;
            s.spawn(move || change(path, Some(format!("m{i}")), None, None, false, true));
        }
    });
    assert_eq!(Holds::read(&path).unwrap().holds.len(), 8);
    let _ = std::fs::remove_dir_all(&dir);
}
