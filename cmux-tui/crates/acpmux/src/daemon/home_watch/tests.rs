use super::*;

#[test]
fn a_removed_or_replaced_path_is_lost_and_an_unchanged_one_is_not() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    std::fs::create_dir(&home).unwrap();
    let lock = home.join("daemon.lock");
    std::fs::write(&lock, "").unwrap();
    let owned = Owned::now(&[&home, &lock]).unwrap();
    assert_eq!(owned.lost(), None);
    // Replaced: another file renamed over it (made while the first one exists, so its
    // inode cannot be the first one's reused).
    std::fs::write(dir.path().join("other"), "").unwrap();
    std::fs::rename(dir.path().join("other"), &lock).unwrap();
    assert!(owned.lost().unwrap().ends_with("was replaced"), "{:?}", owned.lost());
    std::fs::remove_dir_all(&home).unwrap();
    assert!(owned.lost().unwrap().ends_with("was removed"), "{:?}", owned.lost());
}

#[test]
fn an_ancestor_rename_is_lost_even_when_the_home_is_unchanged() {
    let dir = tempfile::tempdir().unwrap();
    let parent = dir.path().join("parent");
    let home = parent.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let owned = Owned::now(&[home.as_path()]).unwrap();
    std::fs::rename(&parent, dir.path().join("moved")).unwrap();
    assert!(owned.lost().is_some(), "ancestor rename was not detected");
}

#[cfg(unix)]
#[test]
fn a_symlink_ancestor_retarget_is_lost() {
    let dir = tempfile::tempdir().unwrap();
    let one = dir.path().join("one");
    let two = dir.path().join("two");
    std::fs::create_dir_all(one.join("home")).unwrap();
    std::fs::create_dir_all(two.join("home")).unwrap();
    let link = dir.path().join("link");
    std::os::unix::fs::symlink(&one, &link).unwrap();
    let home = link.join("home");
    let owned = Owned::now(&[home.as_path()]).unwrap();
    std::fs::remove_file(&link).unwrap();
    std::os::unix::fs::symlink(&two, &link).unwrap();
    assert!(owned.lost().is_some(), "symlink retarget was not detected");
}

#[test]
fn a_socket_ancestor_loss_is_not_a_home_loss() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    let first = dir.path().join("first");
    let second = dir.path().join("second");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(&first).unwrap();
    std::fs::create_dir_all(&second).unwrap();
    let link = dir.path().join("socket-link");
    std::os::unix::fs::symlink(&first, &link).unwrap();
    let socket = link.join("s.sock");
    std::fs::write(&socket, "").unwrap();
    let held = Owned::now(&[home.as_path()]).unwrap();
    let bound = Owned::now(&[socket.as_path()]).unwrap();
    std::fs::rename(dir.path().join("second"), dir.path().join("replacement")).unwrap();
    std::fs::remove_file(&link).unwrap();
    std::os::unix::fs::symlink(dir.path().join("replacement"), &link).unwrap();
    assert!(held.lost().is_none(), "socket ancestor changed the home identity");
    assert!(bound.lost().is_some(), "socket ancestor replacement was not detected");
}

#[test]
fn a_path_the_daemon_removes_itself_is_left_out() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    std::fs::create_dir(&home).unwrap();
    let socket = home.join("acpmux.sock");
    std::fs::write(&socket, "").unwrap();
    let owned = Owned::now(&[&home, &socket]).unwrap();
    std::fs::remove_file(&socket).unwrap();
    assert!(owned.lost().is_some(), "a removed socket is a loss");
    assert_eq!(owned.lost_except(Some(&socket)), None, "unless the daemon removed it");
    std::fs::remove_dir_all(&home).unwrap();
    assert!(owned.lost_except(Some(&socket)).is_some(), "the home still counts");
}

#[test]
fn a_socket_lost_alone_is_bound_again_but_one_in_a_replaced_folder_is_not() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    std::fs::create_dir(&home).unwrap();
    let lock = home.join("daemon.lock");
    let socket = home.join("acpmux.sock");
    std::fs::write(&lock, "").unwrap();
    std::fs::write(&socket, "").unwrap();
    let owned = Owned::now(&[&home, &lock]).unwrap().with(Owned::now(&[socket.as_path()]).unwrap());
    assert!(!owned.only_leaf_lost(&socket), "nothing was lost");
    // Replaced: made while the first one exists, so its inode cannot be the first one's reused.
    std::fs::write(dir.path().join("other"), "").unwrap();
    std::fs::rename(dir.path().join("other"), &socket).unwrap();
    assert!(owned.only_leaf_lost(&socket), "the socket alone was replaced");
    std::fs::remove_file(&socket).unwrap();
    assert!(owned.only_leaf_lost(&socket), "the socket alone was removed");
    std::fs::rename(&home, dir.path().join("moved")).unwrap();
    std::fs::create_dir(&home).unwrap();
    assert!(!owned.only_leaf_lost(&socket), "its folder is another one");
}

#[test]
fn a_path_that_cannot_be_read_at_start_is_never_watched() {
    let dir = tempfile::tempdir().unwrap();
    assert!(Owned::now(&[&dir.path().join("missing")]).is_none());
}
