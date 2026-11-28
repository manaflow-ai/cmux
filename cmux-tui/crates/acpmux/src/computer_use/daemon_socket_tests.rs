//! The bridge finds the running app's daemon outside a cmux terminal (seen on a desktop Mac and a CI Mac:
//! NIGHTLY's own `acpmux computer-use-mcp` asked `main.sock` and answered "the cmux daemon is
//! not reachable: No such file or directory (os error 2)" while the app's daemon ran).

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use super::*;

fn own(session: &str) -> PathBuf {
    PathBuf::from("/own-runtime").join(format!("{session}.sock"))
}

fn lookup(
    vars: &[(&str, &str)],
    exe: Option<&Path>,
    home: Option<&Path>,
    app_base: Option<&Path>,
) -> Vec<Candidate> {
    let vars: HashMap<String, String> =
        vars.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect();
    let env = move |key: &str| vars.get(key).cloned();
    candidates(&Inputs { env: &env, exe, home, app_base, own_socket: &own })
}

fn paths(found: &[Candidate]) -> Vec<String> {
    found.iter().map(|c| c.path.display().to_string()).collect()
}

/// A fake `cmux NIGHTLY.app` with `Contents/Resources/bin/acpmux` and its Info.plist.
fn fake_app(root: &Path, name: &str, bundle_id: &str, tag: Option<&str>) -> PathBuf {
    let app = root.join(name);
    let bin = app.join("Contents/Resources/bin");
    std::fs::create_dir_all(&bin).unwrap();
    let env = tag
        .map(|tag| {
            format!(
                "<key>LSEnvironment</key><dict><key>CMUX_TAG</key><string>{tag}</string></dict>"
            )
        })
        .unwrap_or_default();
    std::fs::write(
        app.join("Contents/Info.plist"),
        format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>{bundle_id}</string>{env}</dict></plist>"#
        ),
    )
    .unwrap();
    let exe = bin.join("acpmux");
    std::fs::write(&exe, b"").unwrap();
    exe
}

#[test]
fn a_named_socket_wins_alone() {
    let found = lookup(
        &[("CMUX_TUI_SOCKET", "/given.sock"), ("CMUX_BUNDLE_ID", "com.cmuxterm.app.nightly")],
        None,
        None,
        Some(Path::new("/darwin-tmp")),
    );
    assert_eq!(paths(&found), ["/given.sock"]);
}

/// The regression: outside a cmux terminal, NIGHTLY's bundled acpmux asks NIGHTLY's daemon
/// (`cmux-app-nightly`) in the Darwin temp folder the app starts it in, not `main`.
#[test]
fn nightlys_own_bridge_asks_nightlys_daemon_not_main() {
    let root = tempfile::tempdir().unwrap();
    let exe = fake_app(root.path(), "cmux NIGHTLY.app", "com.cmuxterm.app.nightly", None);
    let base = Path::new("/var/folders/xy/T");
    let found = lookup(&[], Some(&exe), Some(root.path()), Some(base));
    let runtime = cmux_tui_platform::platform::runtime_dir_for_base(base);
    assert_eq!(found[0].path, runtime.join("cmux-app-nightly.sock"), "{found:?}");
    assert_eq!(found[0].source, "the app bundle around acpmux");
    assert_eq!(found[1].path, own("cmux-app-nightly"));
    assert_eq!(found.last().unwrap().path, own("main"), "main stays the last resort");
}

#[test]
fn the_bundle_id_in_the_environment_names_the_app() {
    let found = lookup(
        &[("CMUX_BUNDLE_ID", "com.cmuxterm.app.debug.cu.preview2"), ("CMUX_TAG", "cu-preview2")],
        None,
        None,
        None,
    );
    assert_eq!(
        paths(&found),
        [own("cmux-app-cu-preview2"), own("main")].map(|p| p.display().to_string())
    );
    assert_eq!(found[0].source, "CMUX_BUNDLE_ID");
}

#[test]
fn a_bundles_shipped_tag_names_its_session() {
    let root = tempfile::tempdir().unwrap();
    let exe = fake_app(
        root.path(),
        "cmux DEV x.app",
        "com.cmuxterm.app.debug.cu.preview2",
        Some("cu-preview2"),
    );
    let found = lookup(&[], Some(&exe), None, None);
    assert_eq!(found[0].path, own("cmux-app-cu-preview2"));
}

/// An acpmux outside any cmux bundle, with no app named: only `main`, as before.
#[test]
fn outside_any_app_only_main() {
    let root = tempfile::tempdir().unwrap();
    let exe = root.path().join("bin/acpmux");
    let found = lookup(&[], Some(&exe), None, Some(Path::new("/darwin-tmp")));
    assert_eq!(paths(&found), [own("main").display().to_string()]);
    let other = fake_app(root.path(), "Other.app", "com.example.other", None);
    assert_eq!(lookup(&[], Some(&other), None, None).len(), 1);
}

#[test]
fn pick_takes_the_first_socket_that_exists_else_the_first() {
    let root = tempfile::tempdir().unwrap();
    let live = root.path().join("live.sock");
    std::fs::write(&live, b"").unwrap();
    let list = vec![
        Candidate { path: root.path().join("gone.sock"), source: "a" },
        Candidate { path: live.clone(), source: "b" },
    ];
    assert_eq!(pick(&list).unwrap().path, live);
    assert_eq!(pick(&list[..1]).unwrap().source, "a");
}

#[test]
fn the_bundle_name_is_the_app_around_the_binary() {
    let exe = Path::new("/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux");
    assert_eq!(bundle_name(exe).as_deref(), Some("cmux NIGHTLY"));
    assert_eq!(bundle_name(Path::new("/usr/local/bin/cmux")), None);
}
