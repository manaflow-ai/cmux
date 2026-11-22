//! cmux-rd kept on the channel's build by `host self-update`, on a fake home and file server.

use super::*;
use futures::future::BoxFuture;
use std::collections::HashMap;
use std::sync::Mutex;

const KEY: &str = "0123456789abcdef0123456789abcdef01234567";
const COMMIT: &str = "89abcdef0123456789abcdef0123456789abcdef";
const TARGET: &str = "x86_64-unknown-linux-gnu";

#[derive(Default)]
struct Files {
    bodies: HashMap<String, Vec<u8>>,
    asked: Mutex<Vec<String>>,
}

impl Fetch for Files {
    fn get<'a>(&'a self, url: &'a str, _max: usize) -> BoxFuture<'a, Result<Vec<u8>, String>> {
        self.asked.lock().unwrap().push(url.to_owned());
        let body =
            self.bodies.get(url).cloned().ok_or_else(|| "the server answered 404".to_owned());
        Box::pin(async move { body })
    }
}

fn rd_url() -> String {
    format!("https://files.cmux.com/cmux-tui/tree/{KEY}/cmux-tui-rd-{TARGET}")
}

fn sha(bytes: &[u8]) -> String {
    crate::sha256::sha256_hex(bytes)
}

/// A channel offering `rd` (a fake cmux-rd) for the host's target, None for no cmux-rd build,
/// and a server that serves `served` at its URL.
fn serving(rd: Option<&[u8]>, served: &[u8]) -> (Channel, Files) {
    let mut binaries = serde_json::Map::new();
    binaries.insert("cmux-tui-acpmux-x86_64-unknown-linux-musl".into(), json!("a".repeat(64)));
    if let Some(rd) = rd {
        binaries.insert(format!("cmux-tui-rd-{TARGET}"), json!(sha(rd)));
    }
    let body = json!({"key": KEY, "commit": COMMIT, "binaries": binaries}).to_string();
    let mut files = Files::default();
    files.bodies.insert(rd_url(), served.to_vec());
    (Channel::parse(body.as_bytes()).unwrap(), files)
}

fn busy() -> bool {
    true
}
fn idle() -> bool {
    false
}

struct Home {
    dir: tempfile::TempDir,
}

impl Home {
    fn new() -> Self {
        Home { dir: tempfile::tempdir().unwrap() }
    }
    fn paths(&self, min_age: Duration, display_busy: fn() -> bool) -> RdPaths {
        RdPaths {
            rd: self.dir.path().join(CMUX_RD),
            install_failed: self.dir.path().join(".acpmux").join(INSTALL_FAILED),
            target: TARGET,
            min_age,
            display_busy,
        }
    }
    fn put_rd(&self, bytes: &[u8]) {
        let rd = self.dir.path().join(CMUX_RD);
        std::fs::create_dir_all(rd.parent().unwrap()).unwrap();
        std::fs::write(rd, bytes).unwrap();
    }
    fn rd(&self) -> Option<Vec<u8>> {
        std::fs::read(self.dir.path().join(CMUX_RD)).ok()
    }
    fn mark_install_failed(&self) {
        let mark = self.dir.path().join(".acpmux").join(INSTALL_FAILED);
        std::fs::create_dir_all(mark.parent().unwrap()).unwrap();
        std::fs::write(mark, "the feat-cmux-next channel has no cmux-rd build\n").unwrap();
    }
    fn install_failed(&self) -> bool {
        self.dir.path().join(".acpmux").join(INSTALL_FAILED).exists()
    }
}

/// A day and a minute after now: an installed cmux-rd old enough to replace.
fn tomorrow() -> SystemTime {
    SystemTime::now() + REPLACE_EVERY + Duration::from_secs(60)
}

#[test]
fn the_paths_are_the_join_lines_and_the_daemons() {
    // machine-join.sh installs `$bin_dir/cmux-rd` and writes the reason to
    // `$ACPMUX_HOME/share-host/cmux-rd-install`; the daemon reads both.
    #[cfg(unix)]
    {
        let user = Path::new("/home/u");
        assert_eq!(user.join(CMUX_RD), crate::share_host::linux::cmux_rd_path(user));
        assert_eq!(
            Path::new("/h").join(INSTALL_FAILED),
            crate::share_host::dir(Path::new("/h")).join(crate::share_host::linux::INSTALL_FAILED)
        );
    }
    assert_eq!(gnu_target("x86_64-unknown-linux-musl"), Some("x86_64-unknown-linux-gnu"));
    assert_eq!(gnu_target("aarch64-unknown-linux-musl"), Some("aarch64-unknown-linux-gnu"));
    assert_eq!(gnu_target("aarch64-apple-darwin"), None);
    assert!(
        RdPaths::here(Path::new("/u"), Path::new("/h"), "aarch64-apple-darwin", false).is_none()
    );
    let here = RdPaths::here(Path::new("/u"), Path::new("/h"), "x86_64-unknown-linux-musl", true);
    assert_eq!(here.map(|p| p.min_age), Some(Duration::ZERO), "--now replaces at once");
}

#[tokio::test]
async fn an_old_cmux_rd_is_replaced_with_the_channels_checked_build() {
    let home = Home::new();
    home.put_rd(b"old cmux-rd");
    let (feed, files) = serving(Some(b"new cmux-rd"), b"new cmux-rd");
    let got = refresh(&home.paths(REPLACE_EVERY, idle), &files, &feed, tomorrow()).await;
    assert_eq!(got, RdOutcome::Installed(sha(b"new cmux-rd")));
    assert_eq!(home.rd().as_deref(), Some(&b"new cmux-rd"[..]));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(home.dir.path().join(CMUX_RD)).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o755);
    }
    assert!(!home.dir.path().join(".local/bin/.cmux-rd.new").exists());
    // The next run finds it current and downloads nothing.
    let again = refresh(&home.paths(REPLACE_EVERY, idle), &files, &feed, tomorrow()).await;
    assert_eq!(again, RdOutcome::Current);
    assert_eq!(files.asked.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn a_download_that_does_not_match_the_channel_is_never_installed() {
    let home = Home::new();
    home.put_rd(b"old cmux-rd");
    let (feed, files) = serving(Some(b"new cmux-rd"), b"tampered");
    let got = refresh(&home.paths(REPLACE_EVERY, idle), &files, &feed, tomorrow()).await;
    assert!(matches!(&got, RdOutcome::Failed(why) if why.contains("not the channel's")), "{got:?}");
    assert_eq!(home.rd().as_deref(), Some(&b"old cmux-rd"[..]));
    assert!(!home.dir.path().join(".local/bin/.cmux-rd.new").exists());
}

#[tokio::test]
async fn a_machine_whose_join_never_wanted_cmux_rd_gets_none() {
    let home = Home::new();
    let (feed, files) = serving(Some(b"new cmux-rd"), b"new cmux-rd");
    let got = refresh(&home.paths(REPLACE_EVERY, idle), &files, &feed, tomorrow()).await;
    assert_eq!(got, RdOutcome::NotJoined);
    assert_eq!(home.rd(), None);
    assert!(files.asked.lock().unwrap().is_empty());
}

#[tokio::test]
async fn a_join_that_could_not_install_cmux_rd_gets_it_from_a_later_channel() {
    let home = Home::new();
    home.mark_install_failed();
    // The channel still has none: nothing changes, the reason stays.
    let (feed, files) = serving(None, b"");
    let got = refresh(&home.paths(REPLACE_EVERY, busy), &files, &feed, tomorrow()).await;
    assert_eq!(got, RdOutcome::NoBuild);
    assert!(home.install_failed());
    // Once it has one, it is installed at once (no host runs to cut), and the reason goes.
    let (feed, files) = serving(Some(b"new cmux-rd"), b"new cmux-rd");
    let got = refresh(&home.paths(REPLACE_EVERY, busy), &files, &feed, SystemTime::now()).await;
    assert_eq!(got, RdOutcome::Installed(sha(b"new cmux-rd")));
    assert_eq!(home.rd().as_deref(), Some(&b"new cmux-rd"[..]));
    assert!(!home.install_failed());
}

#[tokio::test]
async fn a_live_share_and_a_fresh_install_are_left_alone_until_a_later_run() {
    let home = Home::new();
    home.put_rd(b"old cmux-rd");
    let (feed, files) = serving(Some(b"new cmux-rd"), b"new cmux-rd");
    // Installed just now: at most one replacement a day.
    let got = refresh(&home.paths(REPLACE_EVERY, idle), &files, &feed, SystemTime::now()).await;
    assert!(matches!(&got, RdOutcome::Later(why) if why.contains("less than a day")), "{got:?}");
    // A day later, but the virtual display runs (a share may be live).
    let got = refresh(&home.paths(REPLACE_EVERY, busy), &files, &feed, tomorrow()).await;
    assert!(matches!(&got, RdOutcome::Later(why) if why.contains("in use")), "{got:?}");
    assert_eq!(home.rd().as_deref(), Some(&b"old cmux-rd"[..]));
    assert!(files.asked.lock().unwrap().is_empty());
    // --now (min age zero) with an idle display replaces it.
    let got = refresh(&home.paths(Duration::ZERO, idle), &files, &feed, SystemTime::now()).await;
    assert_eq!(got, RdOutcome::Installed(sha(b"new cmux-rd")));
}

#[cfg(unix)]
#[tokio::test]
async fn a_symlinked_cmux_rd_is_kept() {
    let home = Home::new();
    home.put_rd(b"test build");
    let bin = home.dir.path().join(".local/bin");
    std::fs::rename(bin.join("cmux-rd"), bin.join("mine")).unwrap();
    std::os::unix::fs::symlink(bin.join("mine"), bin.join("cmux-rd")).unwrap();
    let (feed, files) = serving(Some(b"new cmux-rd"), b"new cmux-rd");
    let got = refresh(&home.paths(Duration::ZERO, idle), &files, &feed, tomorrow()).await;
    assert_eq!(got, RdOutcome::Symlink);
    assert!(std::fs::symlink_metadata(bin.join("cmux-rd")).unwrap().file_type().is_symlink());
    assert_eq!(std::fs::read(bin.join("mine")).unwrap(), b"test build");
}

#[test]
fn the_outcome_reads_as_one_line_and_json() {
    assert_eq!(RdOutcome::Current.line(), None);
    assert_eq!(RdOutcome::NotJoined.json()["outcome"], "notJoined");
    let line = RdOutcome::Later("its virtual display is in use".into()).line().unwrap();
    assert_eq!(line, "cmux-rd: updated later (its virtual display is in use)");
    assert_eq!(
        RdOutcome::Installed("s".into()).json(),
        json!({"outcome": "installed", "message": "s"})
    );
}
