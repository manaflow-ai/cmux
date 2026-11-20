//! Every acpmux connection to the cmux-tui daemon goes through
//! `SocketDaemon::request`, so `daemon_skew::request` sees every refusal an
//! older daemon gives (cmux#48044). A second opener would skip the restart
//! again. This lint reads acpmux's own sources: a file that names the
//! daemon's socket and opens a socket must be on [`OPENERS`], with why.

use std::path::{Path, PathBuf};

/// Where the cmux-tui daemon's socket comes from.
const DAEMON_SOCKET_NAMES: &[&str] = &[
    "cmux::raw::env_socket_path",
    "cmux::raw::default_socket_path",
    "DAEMON_SOCKET_ENV",
    "SESSION_SOCKET_ENV",
    "\"CMUX_TUI_SOCKET\"",
    "app_daemon_socket",
];

/// Opening a local socket.
const CONNECTS: &[&str] = &["UnixStream::connect", "local_socket::connect", "connect_same_user"];

/// The files allowed to do both, relative to `src/`, and why.
const OPENERS: &[(&str, &str)] = &[
    (
        "computer_use/client.rs",
        "SocketDaemon::send_once, reached only through daemon_skew::request; its other \
         connect is the Computer Use worker's own socket",
    ),
    (
        "launch_credential.rs",
        "credential.mint in the cmux.protocol/2 envelope; an older daemon only means the \
         agent starts with no credential, as with no daemon",
    ),
];

/// The files under `src/` (relative, `/`-separated) that name the daemon's
/// socket and open a socket, outside test files.
fn openers(files: &[(String, String)]) -> Vec<String> {
    files
        .iter()
        .filter(|(path, _)| !path.ends_with("tests.rs") && !path.contains("/tests/"))
        .filter(|(_, text)| DAEMON_SOCKET_NAMES.iter().any(|name| text.contains(name)))
        .filter(|(_, text)| CONNECTS.iter().any(|connect| text.contains(connect)))
        .map(|(path, _)| path.clone())
        .collect()
}

/// Openers not on [`OPENERS`].
fn unlisted(files: &[(String, String)]) -> Vec<String> {
    openers(files).into_iter().filter(|path| !OPENERS.iter().any(|(ok, _)| ok == path)).collect()
}

fn sources(root: &Path) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let mut dirs = vec![PathBuf::from(root)];
    while let Some(dir) = dirs.pop() {
        for entry in std::fs::read_dir(&dir).expect("read src").flatten() {
            let path = entry.path();
            if path.is_dir() {
                dirs.push(path);
            } else if path.extension().is_some_and(|e| e == "rs") {
                let rel = path.strip_prefix(root).unwrap().to_string_lossy().replace('\\', "/");
                out.push((rel, std::fs::read_to_string(&path).unwrap_or_default()));
            }
        }
    }
    out
}

/// The detector for docs/handbook older-daemon-refuses-a-newer-command
/// (cmuxterm-hq): nothing in acpmux opens the cmux-tui daemon's socket
/// outside the shared path.
#[test]
fn only_the_shared_path_opens_the_cmux_daemon_socket() {
    let tree = sources(&Path::new(env!("CARGO_MANIFEST_DIR")).join("src"));
    assert!(tree.len() > 100, "read acpmux's sources ({} files)", tree.len());
    let stray = unlisted(&tree);
    assert!(
        stray.is_empty(),
        "these acpmux files open the cmux-tui daemon's socket outside SocketDaemon::request, \
         so an older daemon's \"unknown variant\" never reaches daemon_skew::request: {stray:?}. \
         Send the command through SocketDaemon::request instead."
    );
    // Every listed opener still opens it: a stale entry would hide a new one.
    let found = openers(&tree);
    for (path, _) in OPENERS {
        assert!(found.iter().any(|f| f == path), "{path} no longer opens the daemon socket");
    }
}

/// The lint catches a planted second caller.
#[test]
fn a_planted_second_caller_is_refused() {
    let planted = (
        "new_feature.rs".to_owned(),
        "fn ask() { let path = cmux::raw::env_socket_path().unwrap();\n\
         let s = std::os::unix::net::UnixStream::connect(path); }"
            .to_owned(),
    );
    let windows = (
        "win.rs".to_owned(),
        "fn ask(p: &Path) { let p = std::env::var_os(SESSION_SOCKET_ENV);\n\
         cmux::local_socket::connect_same_user(p) }"
            .to_owned(),
    );
    let unrelated = (
        "other.rs".to_owned(),
        "fn own() { std::os::unix::net::UnixStream::connect(acpmux_socket()); }".to_owned(),
    );
    let a_test = ("foo_tests.rs".to_owned(), planted.1.clone());
    assert_eq!(
        unlisted(&[planted, windows, unrelated, a_test]),
        ["new_feature.rs", "win.rs"],
        "a file naming the daemon socket and connecting is caught; acpmux's own socket and tests are not"
    );
}
