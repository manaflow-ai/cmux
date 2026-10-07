//! The env that pins every `cmux` call of the Chief (its turns, its agents
//! and the acpmux daemon it starts) to this app's own daemon session.
//!
//! The `cmux` CLI picks its session from `--socket`, then `--session`, then
//! `CMUX_TUI_SOCKET` (`CMUX_MUX_SOCKET`), then the app it thinks it belongs
//! to. That last guess reads `CMUX_SOCKET_PATH` without a tag as the
//! untagged app: hmchief7's Chief created its workspace in the user's
//! release app (session `cmux-app`), and the tagged sidebar stayed empty.
//! So the host names the exact socket of the app's daemon and puts the
//! bundled CLI, the one built with this app, first on PATH. That socket is
//! `CMUX_APP_DAEMON_SOCKET` when the app sets it (a host shared by builds,
//! whose `--daemon-socket` is the Chief's own conversation owner), else
//! `--daemon-socket` (on a remote brain host, that host's own daemon).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// The socket variables the `cmux` CLI reads, first wins.
pub const SOCKET_KEYS: [&str; 2] = ["CMUX_TUI_SOCKET", "CMUX_MUX_SOCKET"];

/// The app's daemon when the host's `--daemon-socket` is not it.
pub const APP_DAEMON_KEY: &str = "CMUX_APP_DAEMON_SOCKET";

/// The socket `cmux` calls must reach: `CMUX_APP_DAEMON_SOCKET`, else the
/// host's `--daemon-socket`.
pub fn app_daemon_socket(
    daemon_socket: &str,
    inherited: &dyn Fn(&str) -> Option<String>,
) -> String {
    inherited(APP_DAEMON_KEY)
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| daemon_socket.to_owned())
}

/// The env keys a pinned env sets (the socket keys and PATH).
pub const PINNED_KEYS: [&str; 3] = ["CMUX_TUI_SOCKET", "CMUX_MUX_SOCKET", "PATH"];

/// The directory of the `cmux` CLI bundled next to `exe` (the app's
/// Contents/Resources/bin), when there is one.
pub fn bundled_bin(exe: &Path) -> Option<PathBuf> {
    let dir = exe.parent()?;
    dir.join("cmux").is_file().then(|| dir.to_path_buf())
}

/// Pins `env` to the daemon at `daemon_socket`: both socket keys name it, and
/// `bundled_bin` (when known) leads PATH, once.
pub fn pin(env: &mut BTreeMap<String, String>, daemon_socket: &str, bundled_bin: Option<&Path>) {
    for key in SOCKET_KEYS {
        env.insert(key.to_owned(), daemon_socket.to_owned());
    }
    let path = env
        .get("PATH")
        .cloned()
        .unwrap_or_else(|| "/usr/bin:/bin".into());
    env.insert("PATH".to_owned(), path_with_first(&path, bundled_bin));
}

/// `path` with `first` in front and every other copy of it removed.
pub fn path_with_first(path: &str, first: Option<&Path>) -> String {
    let Some(first) = first.map(|p| p.display().to_string()) else {
        return path.to_owned();
    };
    let rest = path
        .split(':')
        .filter(|dir| !dir.is_empty() && *dir != first);
    std::iter::once(first.as_str())
        .chain(rest)
        .collect::<Vec<_>>()
        .join(":")
}

/// The pinned subset of `env` (the keys a child session must carry).
pub fn pinned_subset(env: &BTreeMap<String, String>) -> BTreeMap<String, String> {
    PINNED_KEYS
        .iter()
        .chain(["CMUX_SOCKET_PATH"].iter())
        .filter_map(|key| env.get(*key).map(|v| ((*key).to_owned(), v.clone())))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pin_names_the_daemon_socket_and_puts_the_bundled_cli_first() {
        let mut env = BTreeMap::new();
        env.insert("PATH".to_owned(), "/u/bin:/app/bin:/usr/bin".to_owned());
        env.insert(
            "CMUX_SOCKET_PATH".to_owned(),
            "/tmp/cmux-debug-t.sock".to_owned(),
        );
        pin(&mut env, "/T/cmux-app-t.sock", Some(Path::new("/app/bin")));
        assert_eq!(env["CMUX_TUI_SOCKET"], "/T/cmux-app-t.sock");
        assert_eq!(env["CMUX_MUX_SOCKET"], "/T/cmux-app-t.sock");
        assert_eq!(env["PATH"], "/app/bin:/u/bin:/usr/bin");
    }

    #[test]
    fn pin_without_a_bundled_cli_keeps_path() {
        let mut env = BTreeMap::new();
        env.insert("PATH".to_owned(), "/u/bin:/usr/bin".to_owned());
        pin(&mut env, "/s", None);
        assert_eq!(env["PATH"], "/u/bin:/usr/bin");
        assert_eq!(env["CMUX_TUI_SOCKET"], "/s");
    }

    #[test]
    fn bundled_bin_needs_a_cmux_next_to_the_exe() {
        let dir = std::env::temp_dir().join(format!("cmux-env-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let exe = dir.join("optchat-chief");
        assert_eq!(bundled_bin(&exe), None);
        std::fs::write(dir.join("cmux"), b"").unwrap();
        assert_eq!(bundled_bin(&exe), Some(dir.clone()));
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
