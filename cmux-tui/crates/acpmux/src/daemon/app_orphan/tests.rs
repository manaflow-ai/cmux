use super::*;

const TIMING: Timing =
    Timing { delay: Duration::from_secs(3600), recheck: Duration::from_secs(600) };

#[test]
fn only_debug_bundles_are_dev() {
    assert!(is_dev_bundle("com.cmuxterm.app.debug"));
    assert!(is_dev_bundle("com.cmuxterm.app.debug.23046.global.search.parity"));
    assert!(!is_dev_bundle("com.cmuxterm.app.debugger"));
    assert!(!is_dev_bundle("com.cmuxterm.app.nightly"));
    assert!(!is_dev_bundle("com.cmuxterm.app.nightly.cmux-next"));
    assert!(!is_dev_bundle("com.cmuxterm.app"));
}

#[test]
fn every_channel_is_a_cmux_bundle() {
    for id in [
        "com.cmuxterm.app",
        "com.cmuxterm.app.nightly",
        "com.cmuxterm.app.nightly.cmux-next",
        "com.cmuxterm.app.debug.orphan",
    ] {
        assert!(is_cmux_bundle(id), "{id}");
    }
    assert!(!is_cmux_bundle("com.cmuxterm.appx"));
    assert!(!is_cmux_bundle("com.example.app"));
}

#[test]
fn only_a_dev_app_watches_its_socket() {
    let socket = Some(PathBuf::from("/tmp/app.sock"));
    let app = |id: &str| App::new(PathBuf::from("/A/x.app"), id.into(), socket.clone());
    assert_eq!(app("com.cmuxterm.app.debug.t").unwrap().socket, socket);
    assert_eq!(app("com.cmuxterm.app.nightly").unwrap().socket, None, "NIGHTLY outlives a quit");
    assert_eq!(app("com.cmuxterm.app").unwrap().socket, None, "Release outlives a quit");
    assert_eq!(app("com.example.app"), None, "not a cmux app: no watch");
}

#[test]
fn a_deleted_app_ends_its_agents_an_updated_one_keeps_them() {
    let app = |id: &str| App::new(PathBuf::from("/A/x.app"), id.into(), None).unwrap();
    let nightly = app("com.cmuxterm.app.nightly");
    assert!(nightly.ends_agents(true, None), "deleted");
    assert!(nightly.ends_agents(true, Some("com.cmuxterm.app")), "another app at its path");
    assert!(!nightly.ends_agents(true, Some("com.cmuxterm.app.nightly")), "updated in place");
    assert!(!nightly.ends_agents(false, None), "its executable is still there");
    let release = app("com.cmuxterm.app");
    assert!(release.ends_agents(true, None));
    assert!(!release.ends_agents(true, Some("com.cmuxterm.app")));
    // Deleted before its Info.plist was read: an unknown id.
    let unknown = App { bundle: PathBuf::from("/A/x.app"), bundle_id: String::new(), socket: None };
    assert!(unknown.ends_agents(true, None));
    assert!(!unknown.ends_agents(true, Some("com.cmuxterm.app")), "an app is installed there");
    assert!(!unknown.ends_agents(false, None));
    // A DEV rebuild ends them: no build of it is left to adopt them.
    let dev = app("com.cmuxterm.app.debug.t");
    assert!(dev.ends_agents(true, Some("com.cmuxterm.app.debug.t")));
    assert!(!dev.ends_agents(false, None));
}

#[test]
fn an_update_clone_watches_the_app_it_cloned() {
    let clone = Path::new(
        "/private/var/folders/a/b/T/com.cmuxterm.app.nightly.code_sign_clone/code_sign_clone.9gP34C/cmux NIGHTLY.app.bundle",
    );
    let exe = clone.join("Contents/Resources/bin/acpmux");
    assert_eq!(containing_app_bundle(&exe).as_deref(), Some(clone));
    assert_eq!(install_path(clone), Path::new("/Applications/cmux NIGHTLY.app"));
    let app = Path::new("/Applications/cmux NIGHTLY.app");
    assert_eq!(install_path(app), app);
    // A bundle named like a clone outside a clone folder is its own install.
    let lookalike = Path::new("/tmp/x/cmux NIGHTLY.app.bundle");
    assert_eq!(install_path(lookalike), lookalike);
    let own = App::new(app.to_path_buf(), "com.cmuxterm.app.nightly".into(), None).unwrap();
    assert!(!own.clone_orphaned(), "an installed app is never a clone");
    // The clone of an app no longer installed (none at this path on a test host).
    let cloned =
        App::new(clone.to_path_buf(), "com.cmuxterm.app.nightly.orphan-test-absent".into(), None)
            .unwrap();
    assert!(cloned.clone_orphaned(), "the app it cloned is gone");
}

#[test]
fn the_bundle_is_the_app_around_the_executable() {
    let exe = Path::new("/tmp/x/cmux DEV t.app/Contents/Resources/bin/acpmux");
    assert_eq!(containing_app_bundle(exe), Some(PathBuf::from("/tmp/x/cmux DEV t.app")));
    assert_eq!(containing_app_bundle(Path::new("/usr/local/bin/acpmux")), None);
    assert_eq!(containing_app_bundle(Path::new("/tmp/x.app")), None);
}

#[test]
fn an_answering_app_keeps_the_daemon() {
    assert_eq!(decide(None, Instant::now(), TIMING), Decision::Wait(TIMING.recheck));
}

#[test]
fn the_daemon_stops_once_the_app_was_gone_for_the_delay() {
    let since = Instant::now();
    assert_eq!(decide(Some(since), since, TIMING), Decision::Wait(TIMING.recheck));
    let late = since + TIMING.delay - Duration::from_secs(60);
    assert_eq!(decide(Some(since), late, TIMING), Decision::Wait(Duration::from_secs(60)));
    assert_eq!(decide(Some(since), since + TIMING.delay, TIMING), Decision::Exit);
}

#[test]
fn an_app_that_never_listened_is_gone_only_with_its_bundle() {
    assert!(!gone(true, true, false), "it answers");
    assert!(!gone(false, false, false), "it never listened: socket control off");
    assert!(gone(false, true, false), "it answered once, now refuses");
    assert!(gone(false, false, true), "its bundle was deleted");
}

#[test]
fn a_gone_executable_is_gone_even_while_the_socket_answers() {
    assert!(gone(true, true, true), "a same-tag DEV rebuilt elsewhere listens there");
    assert!(gone(true, false, true));
}

#[cfg(unix)]
#[test]
fn the_executable_is_gone_when_deleted_or_replaced_never_when_moved_or_touched() {
    let dir = std::env::temp_dir().join(format!("amx-orph-id-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let exe = dir.join("acpmux");
    std::fs::write(&exe, b"one").unwrap();
    let executable = Executable::open(&exe);
    assert!(!executable.gone());
    // Written in place (touched, re-signed, or its bytes rewritten): by design the same
    // file, not a new build. No build writes a binary in place (see `Executable`); a
    // size or mtime check would stop a live app's daemon on a touch or a re-sign.
    std::fs::write(&exe, b"one, signed").unwrap();
    assert!(!executable.gone(), "written in place");
    // The app moved: its file keeps a name elsewhere.
    let moved = dir.join("moved");
    std::fs::rename(&exe, &moved).unwrap();
    assert!(!executable.gone(), "moved");
    // A rebuild writes a new binary over that name.
    let next = dir.join("acpmux.next");
    std::fs::write(&next, b"build two").unwrap();
    std::fs::rename(&next, &moved).unwrap();
    assert!(executable.gone(), "replaced");
    // Deleted.
    std::fs::write(&exe, b"three").unwrap();
    let third = Executable::open(&exe);
    std::fs::remove_file(&exe).unwrap();
    assert!(third.gone(), "deleted");
    // Not opened at the start: never gone, unless marked gone then (a binary unlinked).
    assert!(!Executable::open(&dir.join("missing")).gone());
    assert!(Executable::open(&dir.join("missing")).gone_at_start().gone());
    let _ = std::fs::remove_dir_all(&dir);
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
#[test]
fn a_moved_then_updated_app_keeps_its_agents_a_deleted_one_ends_them() {
    let dir = std::env::temp_dir().join(format!("amx-orph-move-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let plist = br#"<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.cmuxterm.app.nightly</string></dict></plist>"#;
    let make = |bundle: &Path| {
        std::fs::create_dir_all(bundle.join("Contents/MacOS")).unwrap();
        std::fs::write(bundle.join("Contents/Info.plist"), plist).unwrap();
        std::fs::write(bundle.join("Contents/MacOS/acpmux"), b"build one").unwrap();
    };
    let old = dir.join("Downloads/cmux NIGHTLY.app");
    make(&old);
    let executable = Executable::open(&old.join("Contents/MacOS/acpmux"));
    let mut app = App::in_bundle(old.clone(), || executable.gone()).unwrap();
    // Moved: the same file under a new name, so not gone, and the watch follows it.
    let moved = dir.join("Applications/cmux NIGHTLY.app");
    std::fs::create_dir_all(moved.parent().unwrap()).unwrap();
    std::fs::rename(&old, &moved).unwrap();
    assert!(!executable.gone(), "moved");
    app.follow(&executable);
    assert_eq!(app.bundle, std::fs::canonicalize(&moved).unwrap());
    // Updated there: a new binary over its name. Gone, but the same app is installed where
    // it moved to, so its agents stay for the next launch to adopt.
    let next = moved.join("Contents/MacOS/acpmux.next");
    std::fs::write(&next, b"build two").unwrap();
    std::fs::rename(&next, moved.join("Contents/MacOS/acpmux")).unwrap();
    assert!(executable.gone(), "updated");
    app.follow(&executable);
    assert_eq!(app.bundle, std::fs::canonicalize(&moved).unwrap(), "kept once gone");
    let installed = bundle_id(&install_path(&app.bundle));
    assert_eq!(installed.as_deref(), Some("com.cmuxterm.app.nightly"));
    assert!(!app.ends_agents(true, installed.as_deref()), "moved, then updated");
    // The path it started from holds nothing: read there, it would look deleted.
    assert_eq!(bundle_id(&install_path(&old)), None);
    // Deleted where it moved to: its agents end.
    std::fs::remove_dir_all(&moved).unwrap();
    assert!(app.ends_agents(true, bundle_id(&install_path(&app.bundle)).as_deref()), "deleted");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A NIGHTLY app in `<dir>/Downloads`, its executable held open as the daemon holds it.
#[cfg(unix)]
fn downloaded_nightly(dir: &Path) -> (PathBuf, Executable, App) {
    let _ = std::fs::remove_dir_all(dir);
    let bundle = dir.join("Downloads/cmux NIGHTLY.app");
    std::fs::create_dir_all(bundle.join("Contents/MacOS")).unwrap();
    std::fs::write(
            bundle.join("Contents/Info.plist"),
            br#"<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.cmuxterm.app.nightly</string></dict></plist>"#,
        )
        .unwrap();
    std::fs::write(bundle.join("Contents/MacOS/acpmux"), b"build one").unwrap();
    std::fs::create_dir_all(dir.join("Applications")).unwrap();
    let executable = Executable::open(&bundle.join("Contents/MacOS/acpmux"));
    let app = App::in_bundle(bundle.clone(), || executable.gone()).unwrap();
    (bundle, executable, app)
}

#[cfg(unix)]
fn replace_binary(bundle: &Path) {
    let next = bundle.join("Contents/MacOS/acpmux.next");
    std::fs::write(&next, b"build two").unwrap();
    std::fs::rename(&next, bundle.join("Contents/MacOS/acpmux")).unwrap();
}

#[cfg(unix)]
#[test]
fn an_app_moved_and_updated_between_two_reads_keeps_its_agents() {
    let dir = std::env::temp_dir().join(format!("amx-orph-mvup-{}", std::process::id()));
    let (old, executable, app) = downloaded_nightly(&dir);
    let moved = dir.join("Applications/cmux NIGHTLY.app");
    let search = [dir.join("Applications")];
    // Moved, then updated where it moved, with no read of its path in between.
    std::fs::rename(&old, &moved).unwrap();
    replace_binary(&moved);
    assert!(executable.gone());
    assert_eq!(executable.current_path(), None, "unlinked: its new place can't be read");
    assert_eq!(app.bundle, old, "never followed");
    let installed = app.installed(&search);
    assert_eq!(installed.as_deref(), Some("com.cmuxterm.app.nightly"));
    assert!(!app.ends_agents(true, installed.as_deref()), "moved, then updated");
    // Without the folder it moved to, it reads as deleted (the bug this guards).
    assert!(app.ends_agents(true, app.installed(&[]).as_deref()));
    // Deleted where it moved to: its agents end.
    std::fs::remove_dir_all(&moved).unwrap();
    assert!(app.ends_agents(true, app.installed(&search).as_deref()), "deleted");
    let _ = std::fs::remove_dir_all(&dir);
}

#[cfg(unix)]
#[test]
fn an_app_updated_then_moved_keeps_its_agents() {
    let dir = std::env::temp_dir().join(format!("amx-orph-upmv-{}", std::process::id()));
    let (old, executable, app) = downloaded_nightly(&dir);
    replace_binary(&old);
    assert!(executable.gone());
    let moved = dir.join("Applications/cmux NIGHTLY.app");
    std::fs::rename(&old, &moved).unwrap();
    let installed = app.installed(&[dir.join("Applications")]);
    assert!(!app.ends_agents(true, installed.as_deref()), "updated, then moved");
    // Another channel's app there is not this one.
    let other = App::new(old.clone(), "com.cmuxterm.app".into(), None).unwrap();
    assert!(other.ends_agents(true, other.installed(&[dir.join("Applications")]).as_deref()));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_memory_store_without_agent_hosts_never_stops_a_nightly_or_release_daemon() {
    let at = |id: &str| App::new(PathBuf::from("/Applications/cmux.app"), id.into(), None).unwrap();
    for id in ["com.cmuxterm.app", "com.cmuxterm.app.nightly"] {
        assert!(!at(id).watched(false), "{id}: its in-memory chats would be lost");
        assert!(at(id).watched(true), "{id}: agent hosts or a store on disk keep them");
    }
    // A DEV build is throwaway: its daemon stops either way.
    assert!(at("com.cmuxterm.app.debug.t").watched(false));
}

#[cfg(unix)]
#[test]
fn a_bundle_deleted_between_the_open_and_the_plist_read_is_still_watched() {
    let dir = std::env::temp_dir().join(format!("amx-orph-plist-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let bundle = dir.join("cmux.app");
    let macos = bundle.join("Contents/MacOS");
    std::fs::create_dir_all(&macos).unwrap();
    let exe = macos.join("acpmux");
    std::fs::write(&exe, b"one").unwrap();
    let executable = Executable::open(&exe);
    // No Info.plist yet and the executable still there: not a cmux app it can tell.
    assert_eq!(App::in_bundle(bundle.clone(), || executable.gone()), None);
    std::fs::write(
            bundle.join("Contents/Info.plist"),
            br#"<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.cmuxterm.app.nightly</string></dict></plist>"#,
        )
        .unwrap();
    let app = App::in_bundle(bundle.clone(), || executable.gone()).unwrap();
    assert_eq!(app.bundle_id, "com.cmuxterm.app.nightly");
    // Opened, then the bundle deleted before its Info.plist was read: gone is asked after
    // the failed read, so the app is watched with an unknown id and stops.
    std::fs::remove_dir_all(&bundle).unwrap();
    let app = App::in_bundle(bundle.clone(), || executable.gone()).expect("watched");
    assert_eq!(app.bundle_id, "");
    assert!(app.ends_agents(executable.gone(), None));
    let _ = std::fs::remove_dir_all(&dir);
}

#[cfg(unix)]
#[test]
fn the_app_is_reachable_only_while_it_listens() {
    let dir = std::env::temp_dir().join(format!("amx-orph-unit-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("app.sock");
    assert!(!app_reachable(&socket), "no socket file");
    let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
    assert!(app_reachable(&socket));
    drop(listener);
    assert!(!app_reachable(&socket), "a socket file nobody listens on");
    let _ = std::fs::remove_dir_all(&dir);
}
