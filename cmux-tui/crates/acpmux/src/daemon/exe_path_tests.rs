//! Tests of `exe_path.rs`.
use super::*;
use std::path::PathBuf;

const TMP: &str = "/var/folders/xc/abc/T";

fn v(exe: &str, home: &str, allow: bool) -> Verdict {
    verdict(
        Path::new(exe),
        Path::new(home),
        Path::new("/Users/cmux/.acpmux"),
        Path::new(TMP),
        allow,
        false,
    )
}

#[test]
fn the_runner_checkout_daemon_of_2026_10_23_is_refused_in_the_default_home() {
    let exe = "/Users/cmux/actions-runner-glaeda-2/_work/cmux/cmux/cmux-tui/target/hosted/tree/1e704e95/acpmux";
    assert_eq!(classify(Path::new(exe), Path::new(TMP)), Some(Unstable::RunnerWork));
    assert!(matches!(v(exe, "/Users/cmux/.acpmux", false), Verdict::Refuse(_)));
    assert!(matches!(v(exe, "/Users/cmux/.acpmux", true), Verdict::Warn(_)));
    // Its own home (a CI step's): quiet.
    assert_eq!(v(exe, "/Users/cmux/ci-home/.acpmux", false), Verdict::Stable);
}

#[test]
fn temp_folders_are_refused_in_the_default_home() {
    for exe in [
        "/tmp/abr-1/app/bin/acpmux",
        "/private/tmp/x/acpmux",
        "/var/folders/xc/abc/T/a/acpmux",
        "/private/var/folders/xc/abc/T/a/acpmux",
    ] {
        assert_eq!(classify(Path::new(exe), Path::new(TMP)), Some(Unstable::Temp), "{exe}");
        assert!(matches!(v(exe, "/Users/cmux/.acpmux", false), Verdict::Refuse(_)), "{exe}");
    }
    let linux_tmp = verdict(
        Path::new("/run/user/1000/tmp/acpmux"),
        Path::new("/home/l/.acpmux"),
        Path::new("/home/l/.acpmux"),
        Path::new("/run/user/1000/tmp"),
        false,
        false,
    );
    assert!(matches!(linux_tmp, Verdict::Refuse(_)));
}

#[test]
fn build_trees_only_warn_even_in_the_default_home() {
    for exe in [
        "/Users/leo/cmux/cmux-tui/target/release/acpmux",
        "/Users/cmux/Library/Developer/Xcode/DerivedData/cmux-x/Build/Products/Debug/cmux DEV x.app/Contents/Resources/bin/acpmux",
    ] {
        assert_eq!(classify(Path::new(exe), Path::new(TMP)), Some(Unstable::BuildTree), "{exe}");
        assert!(matches!(v(exe, "/Users/cmux/.acpmux", false), Verdict::Warn(_)), "{exe}");
    }
}

#[test]
fn an_app_bundle_is_never_refused_even_translocated() {
    // A quarantined cmux.app opened from ~/Downloads: its first launch must start the daemon.
    let translocated = "/private/var/folders/xc/abc/T/AppTranslocation/0F1E2D3C/d/cmux.app/Contents/Resources/bin/acpmux";
    assert!(matches!(v(translocated, "/Users/cmux/.acpmux", false), Verdict::Warn(_)));
    let dev_app_in_tmp = "/tmp/abr-1/app/cmux DEV x.app/Contents/Resources/bin/acpmux";
    assert!(matches!(v(dev_app_in_tmp, "/Users/cmux/.acpmux", false), Verdict::Warn(_)));
    // Not a bundle: a folder that only ends in .app, with no Contents under it.
    assert!(matches!(v("/tmp/x.app/acpmux", "/Users/cmux/.acpmux", false), Verdict::Refuse(_)));
}

#[test]
fn only_a_runner_work_folder_counts_not_any_folder_named_work() {
    assert_eq!(classify(Path::new("/Users/leo/clients/_work/bin/acpmux"), Path::new(TMP)), None);
    assert_eq!(
        v("/Users/leo/clients/_work/bin/acpmux", "/Users/cmux/.acpmux", false),
        Verdict::Stable
    );
    // An `_work` with the runner's `_diag` beside it, whatever the runner folder is called.
    let root = std::env::temp_dir().join(format!("acpmux-exe-path-{}", std::process::id()));
    std::fs::create_dir_all(root.join("runner/_diag")).unwrap();
    let exe = root.join("runner/_work/cmux/target/release/acpmux");
    assert_eq!(classify(&exe, Path::new(TMP)), Some(Unstable::RunnerWork));
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn a_home_spelled_with_dot_dot_or_through_a_link_is_resolved() {
    let root = std::env::temp_dir().join(format!("acpmux-exe-resolve-{}", std::process::id()));
    std::fs::create_dir_all(root.join("home/x")).unwrap();
    let real = resolved(&root.join("home"));
    // A home not created yet, spelled with `..`, is the default home.
    assert_eq!(resolved(&root.join("home/x/../.acpmux")), real.join(".acpmux"));
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(root.join("home"), root.join("link")).unwrap();
        assert_eq!(resolved(&root.join("link/.acpmux")), real.join(".acpmux"));
    }
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn stable_installs_pass() {
    for exe in [
        "/Users/cmux/.local/bin/acpmux",
        "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux",
        "/home/leo/.local/share/acpmux-supervised/acpmux",
        "/opt/cmux/bin/cmux-tui",
    ] {
        assert_eq!(classify(Path::new(exe), Path::new(TMP)), None, "{exe}");
        assert_eq!(v(exe, "/Users/cmux/.acpmux", false), Verdict::Stable, "{exe}");
    }
    // A word that only contains `target` or `_work` is not one of those folders.
    assert_eq!(classify(Path::new("/opt/targets/my_work/acpmux"), Path::new(TMP)), None);
}

#[test]
fn a_test_home_under_a_temp_folder_is_not_the_persons() {
    // cargo tests on a runner: the binary under _work, HOME and the home in a temp folder.
    let home = PathBuf::from(TMP).join("t1/.acpmux");
    let exe = "/Users/cmux/actions-runner-glaeda-2/_work/cmux/cmux/cmux-tui/target/debug/acpmux";
    let got = verdict(Path::new(exe), &home, &home, Path::new(TMP), false, false);
    assert_eq!(got, Verdict::Stable);
}

fn stop(peer: &str, home: &str, allow: bool) -> Option<String> {
    shutdown_refusal(
        Path::new(peer),
        Path::new(home),
        Path::new("/Users/cmux/.acpmux"),
        Path::new(TMP),
        allow,
        false,
    )
}

/// cmux12s, 2026-10-26: `cmux-next swift test` (no `ACPMUX_HOME`) handed the mini's own
/// `~/.acpmux` daemon off from Xcode's `swiftpm-testing-helper`.
#[test]
fn a_test_runner_never_stops_the_persons_daemon() {
    let helper = "/Applications/Xcode_26.6.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper";
    let refused = stop(helper, "/Users/cmux/.acpmux", false).expect("refused");
    assert!(refused.contains("a test runner"), "{refused}");
    assert!(stop(helper, "/Users/cmux/.acpmux", true).is_some());
    assert!(
        stop(
            "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest",
            "/Users/cmux/.acpmux",
            false
        )
        .is_some()
    );
    // Its own home (a CI job's): stopped as asked.
    assert_eq!(
        stop(helper, "/Users/cmux/actions-runner-glaeda-11/_work/_temp/acpmux-home", false),
        None
    );
    assert_eq!(stop(helper, "/Users/cmux/.acpmux/builds/com.cmuxterm.app.debug.x", false), None);
}

#[test]
fn a_client_from_a_runner_checkout_or_temp_does_not_stop_the_persons_daemon_unless_allowed() {
    for peer in [
        "/Users/cmux/actions-runner-glaeda-2/_work/cmux/cmux/cmux-tui/target/hosted/tree/1e704e95/acpmux",
        "/tmp/abr-1/app/bin/acpmux",
        "/var/folders/xc/abc/T/a/acpmux",
    ] {
        assert!(stop(peer, "/Users/cmux/.acpmux", false).is_some(), "{peer}");
        assert_eq!(stop(peer, "/Users/cmux/.acpmux", true), None, "{peer}");
    }
}

#[test]
fn installed_clients_and_apps_stop_the_persons_daemon() {
    for peer in [
        "/Users/cmux/.local/bin/acpmux",
        "/Applications/cmux NEXT.app/Contents/MacOS/cmux NEXT",
        "/private/var/folders/xc/abc/T/AppTranslocation/1234/d/cmux.app/Contents/Resources/bin/acpmux",
        // A build tree only warns when it starts a daemon; stopping one is a developer's own call.
        "/Users/me/src/cmux/cmux-tui/target/debug/acpmux",
    ] {
        assert_eq!(stop(peer, "/Users/cmux/.acpmux", false), None, "{peer}");
    }
}

#[test]
fn sign_clone_start_and_handoff_require_signature_proof() {
    let exe = Path::new(
        "/private/var/folders/a/b/T/com.cmuxterm.app.nightly.code_sign_clone/code_sign_clone.9gP34C/cmux NIGHTLY.app.bundle/Contents/Resources/bin/acpmux",
    );
    let home = Path::new("/Users/cmux/.acpmux");
    for verified in [false, true] {
        let result = verdict(exe, home, home, Path::new(TMP), false, verified);
        assert_eq!(matches!(result, Verdict::Warn(_)), verified);
        assert_eq!(
            shutdown_refusal(exe, home, home, Path::new(TMP), false, verified).is_none(),
            verified
        );
    }
    // A proof cannot override the runner cleanup protection.
    let runner = Path::new(
        "/Users/cmux/actions-runner-1/_work/com.cmuxterm.app.nightly.code_sign_clone/code_sign_clone.a/cmux NIGHTLY.app.bundle/Contents/Resources/bin/acpmux",
    );
    assert!(matches!(verdict(runner, home, home, Path::new(TMP), false, true), Verdict::Refuse(_)));
    assert!(shutdown_refusal(runner, home, home, Path::new(TMP), false, true).is_some());
}
