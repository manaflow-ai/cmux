use super::*;
use std::os::unix::fs::PermissionsExt as _;

const A: &str = "01a15d7d-b692-76b3-b8de-a9a71809de2a";
const B: &str = "01a15db7-20cd-7e10-8535-158031297e5c";

struct Scratch(PathBuf);
impl Scratch {
    fn new(tag: &str) -> Self {
        let dir = std::env::temp_dir().join(format!(
            "acpmux-session-tmp-{tag}-{}-{}",
            std::process::id(),
            uuid::Uuid::now_v7().simple()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        Scratch(dir)
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn two_sessions_never_share_a_temporary_folder() {
    let s = Scratch::new("two");
    let base = s.0.join("acpmux-501");
    let home = Path::new("/home/someone/state");
    let a = make(&base, home, A).unwrap();
    let b = make(&base, home, B).unwrap();
    assert_ne!(a, b);
    assert_eq!(a, daemon_root(&base, home).join(A));
    assert_eq!(a.parent(), b.parent());
    assert!(a.is_dir() && b.is_dir());
    for dir in [&base, &base.join("t"), &daemon_root(&base, home), &a] {
        assert_eq!(std::fs::metadata(dir).unwrap().permissions().mode() & 0o777, 0o700);
    }
    // The same session again (a restart) gets the same folder.
    assert_eq!(make(&base, home, A), Some(a));
    for bad in ["", ".", "..", "a/b", "../x"] {
        assert!(make(&base, home, bad).is_none(), "{bad:?}");
    }
}

#[test]
fn the_real_path_fits_a_macos_socket_beside_it() {
    // /tmp/acpmux-<uid>/t/<8 hex>/<UUIDv7>/ + a tool's socket name.
    let dir = daemon_root(Path::new("/tmp/acpmux-4294967294"), Path::new("/x")).join(A);
    assert!(dir.as_os_str().len() <= 72, "{}", dir.display());
    assert!(dir.join("tmux-12345/default.sock").as_os_str().len() < 104);
}

#[test]
fn a_base_that_is_not_private_to_this_user_is_refused() {
    let s = Scratch::new("refuse");
    let home = Path::new("/h");
    // Writable by others (and not sticky).
    let open = s.0.join("open");
    std::fs::create_dir(&open).unwrap();
    std::fs::set_permissions(&open, std::fs::Permissions::from_mode(0o777)).unwrap();
    assert!(make(&open, home, A).is_none());
    assert!(!open.join("t").exists());
    // A symlink to a private directory.
    let real = s.0.join("real");
    std::fs::create_dir(&real).unwrap();
    std::fs::set_permissions(&real, std::fs::Permissions::from_mode(0o700)).unwrap();
    let link = s.0.join("link");
    std::os::unix::fs::symlink(&real, &link).unwrap();
    assert!(make(&link, home, A).is_none());
    assert!(!real.join("t").exists());
    // A planted symlink below a private base is not followed.
    let base = s.0.join("base");
    let elsewhere = s.0.join("elsewhere");
    std::fs::create_dir(&elsewhere).unwrap();
    std::fs::create_dir(&base).unwrap();
    std::fs::set_permissions(&base, std::fs::Permissions::from_mode(0o700)).unwrap();
    std::os::unix::fs::symlink(&elsewhere, base.join("t")).unwrap();
    assert!(make(&base, home, A).is_none());
    assert_eq!(std::fs::read_dir(&elsewhere).unwrap().count(), 0);
}

#[test]
fn with_a_runtime_dir_only_tmpdir_changes() {
    let dir = Path::new("/tmp/acpmux-1/t/0/s");
    let agent = |k: &str| (k == "XDG_RUNTIME_DIR").then(|| "/run/user/1".to_owned());
    for pin in [true, false] {
        let env = env_for(dir, agent, |_| false, pin, 1);
        assert_eq!(
            env,
            vec![(SESSION_TMPDIR_ENV, dir.into()), ("TMPDIR", dir.into())],
            "pin={pin}"
        );
    }
}

/// The socket bases every client resolves: cmux-tui's runtime base and
/// the browser host socket (cmux-browser-host `default_socket_path`).
fn resolved(env: &dyn Fn(&str) -> Option<String>, uid: u32) -> (PathBuf, PathBuf) {
    let set = |k: &str| env(k).filter(|v| !v.is_empty());
    let runtime = set("XDG_RUNTIME_DIR")
        .or_else(|| set("TMPDIR"))
        .map(PathBuf::from)
        .unwrap_or_else(|| "/tmp".into());
    let browser = match set("CMUX_BROWSER_HOST_SOCKET") {
        Some(path) => PathBuf::from(path),
        None => match set("XDG_RUNTIME_DIR") {
            Some(dir) => PathBuf::from(dir).join("cmux"),
            None => set("TMPDIR")
                .map(PathBuf::from)
                .unwrap_or_else(|| "/platform-temp".into())
                .join(format!("cmux-{uid}")),
        }
        .join("browser-host.sock"),
    };
    (runtime, browser)
}

#[test]
fn a_mac_without_a_runtime_dir_resolves_every_socket_as_before() {
    let dir = Path::new("/tmp/acpmux-501/t/0/s");
    let cases: [&[(&str, &str)]; 4] = [
        &[("TMPDIR", "/var/folders/ab/T/")],
        &[],
        &[("TMPDIR", "")],
        &[("TMPDIR", "/var/folders/ab/T/"), ("CMUX_BROWSER_HOST_SOCKET", "/x/b.sock")],
    ];
    for case in cases {
        let before = |k: &str| case.iter().find(|(n, _)| *n == k).map(|(_, v)| v.to_string());
        let changes = env_for(dir, before, |_| false, true, 501);
        let after = |k: &str| {
            changes
                .iter()
                .find(|(n, _)| *n == k)
                .map(|(_, v)| v.to_string_lossy().into_owned())
                .or_else(|| before(k))
        };
        assert_eq!(after(SESSION_TMPDIR_ENV).as_deref(), dir.to_str());
        if before("TMPDIR").is_some_and(|v| !v.is_empty()) {
            assert_eq!(after("TMPDIR").as_deref(), dir.to_str(), "{case:?}");
        } else {
            // No TMPDIR to pin: nothing but the session's own folder.
            assert_eq!(changes, vec![(SESSION_TMPDIR_ENV, dir.into())], "{case:?}");
        }
        assert_eq!(resolved(&after, 501), resolved(&before, 501), "{case:?}");
    }
    // The base it pins is the agent's own TMPDIR, verbatim.
    let env = env_for(
        dir,
        |k| (k == "TMPDIR").then(|| "/var/folders/ab/T/".into()),
        |_| false,
        true,
        501,
    );
    assert!(env.contains(&("XDG_RUNTIME_DIR", "/var/folders/ab/T/".into())));
}

#[test]
fn under_a_cmux_daemon_the_browser_host_socket_is_not_named() {
    // cmux-browser-host takes a named socket next to CMUX_TUI_SOCKET for
    // the daemon's own host and never starts one; unnamed, the agent
    // resolves a socket of its own and starts its host there.
    let dir = Path::new("/tmp/acpmux-501/t/0/s");
    let before = |k: &str| match k {
        "TMPDIR" => Some("/var/folders/ab/T/".to_owned()),
        "CMUX_TUI_SOCKET" => Some("/var/folders/ab/T/cmux-501/tui.sock".to_owned()),
        _ => None,
    };
    let changes = env_for(dir, before, |_| false, true, 501);
    assert!(!changes.iter().any(|(k, _)| *k == "CMUX_BROWSER_HOST_SOCKET"), "{changes:?}");
    assert!(changes.contains(&("XDG_RUNTIME_DIR", "/var/folders/ab/T/".into())));
    let after = |k: &str| {
        changes
            .iter()
            .find(|(n, _)| *n == k)
            .map(|(_, v)| v.to_string_lossy().into_owned())
            .or_else(|| before(k))
    };
    assert_eq!(resolved(&after, 501).1, Path::new("/var/folders/ab/T/cmux/browser-host.sock"));
}

#[test]
fn linux_without_a_runtime_dir_keeps_the_shared_tmpdir() {
    let dir = Path::new("/tmp/acpmux-1/t/0/s");
    let env = env_for(dir, |k| (k == "TMPDIR").then(|| "/tmp".into()), |_| false, false, 1);
    assert_eq!(env, vec![(SESSION_TMPDIR_ENV, dir.into())]);
    // A profile that blanks XDG_RUNTIME_DIR would undo the pin on a Mac too.
    let env = env_for(dir, |_| None, |k| k == "XDG_RUNTIME_DIR", true, 1);
    assert_eq!(env, vec![(SESSION_TMPDIR_ENV, dir.into())]);
}

#[test]
fn a_daemon_sweeps_only_its_own_unknown_sessions() {
    let s = Scratch::new("sweep");
    let base = s.0.join("acpmux-1");
    let (mine, theirs) = (s.0.join("home/state"), s.0.join("home/chief/acpmux"));
    std::fs::create_dir_all(&mine).unwrap();
    std::fs::create_dir_all(&theirs).unwrap();
    let (mine, theirs) = (mine.as_path(), theirs.as_path());
    assert_ne!(daemon_root(&base, mine), daemon_root(&base, theirs));
    let kept = make(&base, mine, A).unwrap();
    let gone = make(&base, mine, B).unwrap();
    std::fs::write(gone.join("scratch"), b"x").unwrap();
    let other = make(&base, theirs, B).unwrap();
    let root = daemon_root(&base, mine);
    // Not a session name, a file, and a symlink to a folder elsewhere.
    std::fs::create_dir(root.join("notes")).unwrap();
    let file_id = "01a15db7-20cd-7e10-8535-158031297e5d";
    std::fs::write(root.join(file_id), b"x").unwrap();
    let target = s.0.join("target");
    std::fs::create_dir(&target).unwrap();
    std::fs::write(target.join("keep"), b"x").unwrap();
    let link_id = "01a15db7-20cd-7e10-8535-158031297e5e";
    std::os::unix::fs::symlink(&target, root.join(link_id)).unwrap();

    let stale = stale(&base, mine, None, &|id| id == A, &|_| false);
    assert_eq!(stale, vec![gone.clone()]);
    remove_all(&stale);
    assert!(kept.is_dir() && !gone.exists());
    assert!(other.is_dir(), "another daemon's live session folder was swept");
    assert!(root.join("notes").is_dir() && root.join(file_id).is_file());
    assert!(root.join(link_id).symlink_metadata().unwrap().file_type().is_symlink());
    assert!(target.join("keep").is_file());
}

#[test]
fn a_purge_removes_the_folder_and_the_first_builds_one() {
    let s = Scratch::new("purge");
    let base = s.0.join("acpmux-1");
    let home = Path::new("/home/u/state");
    let user = s.0.join("user");
    let dir = make(&base, home, A).unwrap();
    std::fs::write(dir.join("f"), b"x").unwrap();
    let legacy = legacy_root(&user).join(A).join("tmp");
    std::fs::create_dir_all(&legacy).unwrap();
    let legacy_b = legacy_root(&user).join(B).join("tmp");
    std::fs::create_dir_all(&legacy_b).unwrap();
    remove(&base, home, Some(&user), A);
    assert!(!dir.exists() && !legacy_root(&user).join(A).exists());
    assert!(legacy_b.is_dir(), "another session's folder went with this one");
    // A symlink in the session's place is left, and what it names too.
    let target = s.0.join("target");
    std::fs::create_dir(&target).unwrap();
    std::os::unix::fs::symlink(&target, daemon_root(&base, home).join(A)).unwrap();
    remove(&base, home, Some(&user), A);
    assert!(target.is_dir());
    assert!(daemon_root(&base, home).join(A).symlink_metadata().is_ok());
}

#[test]
fn a_daemon_whose_home_is_gone_has_its_root_removed() {
    let s = Scratch::new("orphan");
    let base = s.0.join("acpmux-1");
    let (mine, live, gone) = (s.0.join("mine"), s.0.join("live"), s.0.join("gone"));
    for home in [&mine, &live, &gone] {
        std::fs::create_dir(home).unwrap();
    }
    make(&base, &mine, A).unwrap();
    let live_dir = make(&base, &live, A).unwrap();
    let gone_dir = make(&base, &gone, B).unwrap();
    // A root without a record (an older build's, a stranger's) stays.
    let bare = base.join("t").join("0badc0de");
    std::fs::create_dir(&bare).unwrap();
    std::fs::remove_dir(&gone).unwrap();
    let stale = stale(&base, &mine, None, &|id| id == A, &|_| false);
    assert_eq!(stale, vec![daemon_root(&base, &gone)]);
    remove_all(&stale);
    assert!(!gone_dir.exists() && live_dir.is_dir() && bare.is_dir());
    // Its own root is never taken for a gone one, even with a stale record.
    std::fs::remove_dir(&mine).unwrap();
    assert!(super::stale(&base, &mine, None, &|_| true, &|_| false).is_empty());
}

#[test]
fn nothing_is_swept_or_purged_below_a_base_others_can_change() {
    let s = Scratch::new("unsafe-base");
    let base = s.0.join("acpmux-1");
    let (mine, gone) = (s.0.join("mine"), s.0.join("gone"));
    std::fs::create_dir(&mine).unwrap();
    std::fs::create_dir(&gone).unwrap();
    let a = make(&base, &mine, A).unwrap();
    let b = make(&base, &mine, B).unwrap();
    let theirs = make(&base, &gone, A).unwrap();
    std::fs::remove_dir(&gone).unwrap();
    let own = daemon_root(&base, &mine);
    for widen in [base.clone(), base.join("t"), own.clone()] {
        std::fs::set_permissions(&widen, std::fs::Permissions::from_mode(0o777)).unwrap();
        let listed = stale(&base, &mine, None, &|_| false, &|_| false);
        if widen == own {
            // Only the gone daemon's root, in a base still private.
            assert_eq!(listed, vec![daemon_root(&base, &gone)]);
        } else {
            assert!(listed.is_empty(), "{widen:?}: {listed:?}");
        }
        remove(&base, &mine, None, A);
        assert!(a.is_dir() && b.is_dir() && theirs.is_dir(), "{widen:?}");
        std::fs::set_permissions(&widen, std::fs::Permissions::from_mode(0o700)).unwrap();
    }
    // A symlink for `t` (a private base, as a stranger could not make
    // one, but checked the same): nothing it names is listed.
    let s2 = Scratch::new("link-t");
    let base2 = s2.0.join("acpmux-1");
    std::fs::create_dir(&base2).unwrap();
    std::fs::set_permissions(&base2, std::fs::Permissions::from_mode(0o700)).unwrap();
    std::os::unix::fs::symlink(base.join("t"), base2.join("t")).unwrap();
    assert!(stale(&base2, &mine, None, &|_| false, &|_| false).is_empty());
    remove(&base2, &mine, None, A);
    assert!(a.is_dir());
}

#[test]
fn two_homes_with_one_hash_never_share_a_root() {
    let s = Scratch::new("collide");
    let base = s.0.join("acpmux-1");
    let (first, second) = (Path::new("/home/first/state"), Path::new("/home/second/state"));
    let dir = make(&base, first, A).unwrap();
    // The first's root moved to the second home's name: what a hash
    // collision would make.
    let root = daemon_root(&base, first);
    let collided = |home: &Path| {
        let theirs = daemon_root(&base, home);
        if theirs != root {
            std::fs::rename(&root, &theirs).unwrap();
        }
        theirs
    };
    let shared = collided(second);
    assert!(make(&base, second, B).is_none(), "a second home took the first's root");
    // The second daemon neither sweeps nor purges the first's sessions.
    assert!(stale(&base, second, None, &|_| false, &|_| false).is_empty());
    remove(&base, second, None, A);
    assert!(shared.join(A).is_dir() && !dir.exists());
}

#[test]
fn the_home_record_is_written_once() {
    let s = Scratch::new("record");
    let root = s.0.join("root");
    std::fs::create_dir(&root).unwrap();
    record_home(&root, Path::new("/first"));
    record_home(&root, Path::new("/second"));
    assert_eq!(recorded_home(&root).as_deref(), Some(Path::new("/first")));
    // Only the record is left, no part file beside it.
    let names: Vec<_> =
        std::fs::read_dir(&root).unwrap().flatten().map(|e| e.file_name()).collect();
    assert_eq!(names, vec![std::ffi::OsString::from(HOME_RECORD)]);
}

#[test]
fn the_first_builds_shared_folders_go_only_for_closed_sessions_this_daemon_knows() {
    let s = Scratch::new("legacy");
    let base = s.0.join("acpmux-1");
    let user = s.0.join("user");
    let id_c = "01a15db7-20cd-7e10-8535-158031297e5f";
    for id in [A, B, id_c] {
        std::fs::create_dir_all(legacy_root(&user).join(id).join("tmp")).unwrap();
    }
    // A: closed here. B: known and live here. C: another daemon's.
    let known = |id: &str| id == A || id == B;
    let closed = |id: &str| id == A;
    let home = Path::new("/h");
    remove_all(&stale(&base, home, Some(&user), &known, &closed));
    assert!(!legacy_root(&user).join(A).exists());
    assert!(legacy_root(&user).join(B).is_dir());
    assert!(legacy_root(&user).join(id_c).is_dir());
}
