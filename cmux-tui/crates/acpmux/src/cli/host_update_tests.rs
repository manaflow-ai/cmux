//! `host update` against fake peers: its scripts run under `sh` in a fake
//! home, with fake `acpmux`, `systemctl`, `loginctl`, `uname` and `sleep`.

use super::super::*;
use super::*;

#[test]
fn a_peer_gets_the_binary_for_its_os_and_architecture() {
    assert_eq!(uname_target("Linux x86_64"), Some("x86_64-unknown-linux-musl"));
    assert_eq!(uname_target("Linux aarch64"), Some("aarch64-unknown-linux-musl"));
    assert_eq!(uname_target("Linux arm64"), Some("aarch64-unknown-linux-musl"));
    assert_eq!(uname_target("Darwin arm64"), Some("aarch64-apple-darwin"));
    assert_eq!(uname_target("Darwin x86_64"), Some("x86_64-apple-darwin"));
    assert_eq!(uname_target("Linux riscv64"), None);
    assert_eq!(uname_target("FreeBSD amd64"), None);
    assert_eq!(uname_target(""), None);
    if cfg!(all(target_os = "linux", target_arch = "x86_64")) {
        assert_eq!(local_target(), Some("x86_64-unknown-linux-musl"));
    }
    if cfg!(all(target_os = "macos", target_arch = "aarch64")) {
        assert_eq!(local_target(), Some("aarch64-apple-darwin"));
    }
}

#[test]
fn builds_of_one_commit_are_current_whatever_their_date_or_edits() {
    assert!(same_commit("d5829ffea 2026-10-21", "d5829ffea 2026-10-14"));
    assert!(same_commit("d5829ffea+dirty.0badf00d 2026-10-21", "d5829ffea 2026-10-21"));
    assert!(same_commit("d5829ffea 2026-10-21", "d5829ffea1 2026-10-21"), "short hash lengths");
    assert!(!same_commit("d5829ffea 2026-10-21", "0b3a76d55 2026-10-21"));
    assert!(!same_commit("nogit 2026-10-21", "nogit 2026-10-21"), "no commit is no match");
    assert!(!same_commit("", "d5829ffea 2026-10-21"));
    assert_eq!(version_build("acpmux 1.0.0 (d5829ffea 2026-10-21)"), Some("d5829ffea 2026-10-21"));
    assert_eq!(version_build("acpmux 1.0.0"), None);
}

#[test]
fn a_binarys_build_is_read_from_its_bytes() {
    let mut bytes = b"\x00\x01clap (not a build) 2 (zz) Error (os 2)".to_vec();
    bytes.extend_from_slice(b"1.0.0 (d5829ffea+dirty.0badf00d 2026-10-21)\x00tail");
    assert_eq!(embedded_build(&bytes).as_deref(), Some("d5829ffea+dirty.0badf00d 2026-10-21"));
    assert_eq!(
        embedded_build(b"1.0.0 (d5829ffea 2026-10-21)").as_deref(),
        Some("d5829ffea 2026-10-21")
    );
    assert_eq!(embedded_build(b"1.0.0 (nogit 2026-10-21)"), None, "no commit to compare");
    assert_eq!(embedded_build(b"1.0.0 (d5829ffea+dirty 2026-10-21)"), None);
    assert_eq!(embedded_build(b"version (d5829ffea 2026-10-21)"), None, "not after a version");
    assert_eq!(embedded_build(b""), None);
}

#[test]
fn only_the_daemons_own_turns_and_permission_prompts_make_it_busy() {
    let ls = json!({"sessions": [
        {"name": "mid-turn", "status": "idle", "turn": {"startedAt": 1}, "pendingPermissions": 0},
        {"name": "asking", "status": "idle", "turn": null, "pendingPermissions": 1},
        {"name": "between-turns", "status": "idle", "turn": null, "pendingPermissions": 0},
        {"name": "closed", "status": "closed"},
        {"name": "other/lane", "peer": "other", "status": "running", "turn": {"startedAt": 1}},
    ]});
    assert_eq!(
        busy_sessions(&ls.to_string(), None),
        Some(vec!["mid-turn".into(), "asking".into()])
    );
    // A sub-session is a session of the same daemon: an idle parent
    // with a child mid-turn is busy.
    let family = json!({"sessions": [
        {"name": "parent", "status": "idle", "turn": null, "pendingPermissions": 0, "children": 1},
        {"name": "parent-sub", "status": "running", "turn": {"startedAt": 1}, "startedBy": "parent", "depth": 1},
    ]});
    assert_eq!(busy_sessions(&family.to_string(), None), Some(vec!["parent-sub".into()]));
    assert_eq!(busy_sessions(r#"{"sessions": []}"#, None), Some(vec![]));
    assert_eq!(busy_sessions("", None), None, "unreadable is not idle");
    assert_eq!(
        answering_build("{\n  \"build\": \"d5829ffea 2026-10-21\",\n  \"pid\": 7\n}").as_deref(),
        Some("d5829ffea 2026-10-21")
    );
    assert_eq!(answering_build(r#"{"running": false, "error": "daemon not running"}"#), None);
    assert_eq!(answering_build(""), None);
}

#[test]
fn each_peer_row_says_what_happened() {
    let mut up = PeerUpdate::new();
    up.outcome = Outcome::Updated;
    up.target = Some("x86_64-unknown-linux-musl");
    up.build = Some(NEW.into());
    up.version = Some(format!("acpmux 1.0.0 ({NEW})"));
    up.status = Some("{}".into());
    up.migrated_from = Some(FOREIGN.into());
    assert_eq!(
        up.to_json("hb", "huge-blue"),
        json!({"peer": "hb", "host": "huge-blue", "outcome": "updated", "ok": true,
                   "build": NEW, "target": "x86_64-unknown-linux-musl",
                   "version": format!("acpmux 1.0.0 ({NEW})"), "status": "{}",
                   "migratedFrom": FOREIGN})
    );
    let busy = PeerUpdate::new().end(Outcome::Busy, "busy", "mid-turn: lane");
    assert_eq!(
        busy.to_json("hb", "huge-blue"),
        json!({"peer": "hb", "host": "huge-blue", "outcome": "busy", "ok": true,
                   "build": null, "reason": "busy", "error": "mid-turn: lane"})
    );
    let back = PeerUpdate::new().end(Outcome::RolledBack, "noAnswer", "no answer");
    assert_eq!(back.to_json("a", "b")["outcome"], "rolledBack");
    assert_eq!(back.to_json("a", "b")["ok"], false);
    assert_eq!(
        [Outcome::Updated, Outcome::Current, Outcome::Busy, Outcome::NeedsBinary]
            .map(Outcome::failed),
        [false; 4]
    );
    assert!(Outcome::RolledBack.failed() && Outcome::Failed.failed());
    assert_eq!(Outcome::NeedsBinary.as_str(), "needsBinary");
}

/// The fake peers' daemon builds: before, after, and the stale binary
/// huge-blue keeps at the standard path while its daemon runs another.
const OLD: &str = "0b3a76d55 2026-10-20";
const NEW: &str = "a1b2c3d4e 2026-10-21";
#[cfg(unix)]
const STALE: &str = "d5829ffea 2026-10-14";
const FOREIGN: &str = "acpmux-agent-hb.service";
#[cfg(unix)]
const BACKSTOP: &str = "[Service]\nMemoryHigh=5G\nMemoryMax=6G\nRestart=always\n";
#[cfg(unix)]
const UNITS: &str = ".config/systemd/user";
#[cfg(unix)]
const TARGET: &str = "x86_64-unknown-linux-musl";

/// The `personInstance` the fake peer daemon reports.
#[cfg(unix)]
const PEER_DAEMON: &str = "peer-daemon-run";

/// A fake acpmux of `build` whose daemon, once started, reports `runs`
/// (None: it never answers). Like cmux-tui, it answers as acpmux only
/// under that file name. `$HOME/daemon` holds the build of the daemon
/// that runs (absent: none), `$HOME/started` every build started.
#[cfg(unix)]
fn fake_acpmux(build: &str, runs: Option<&str>) -> String {
    let start = match runs {
        Some(b) => format!("echo '{b}' > \"$HOME/daemon\"; echo '{b}' >> \"$HOME/started\""),
        None => ":".to_owned(),
    };
    format!(
        r#"#!/bin/sh
echo "acpmux $*" >> "$HOME/calls"
case "$*" in
--version) if [ "${{0##*/}}" = acpmux ]; then echo "acpmux 1.0.0 ({build})"; else echo "cmux 1.0.0"; fi;;
"--json daemon status") if [ -f "$HOME/daemon" ]; then printf '{{\n  "build": "%s",\n  "pid": 4242,\n  "personInstance": "{PEER_DAEMON}"\n}}\n' "$(cat "$HOME/daemon")"; else printf '{{\n  "running": false,\n  "error": "daemon not running"\n}}\n'; fi;;
"--json ls") cat "$HOME/sessions.json";;
"daemon shutdown"*) rm -f "$HOME/daemon";;
"--json daemon start"|__start) {start};;
esac
"#
    )
}

/// A user systemd manager: a unit with `$HOME/active-<unit>` runs the
/// daemon (acpmux.service the binary at the standard path, another unit
/// the build in `$HOME/old-build`), `$HOME/fails-<unit>` does not start,
/// and a stop without `KillMode=process` (the unit's, or the migration's
/// runtime drop-in) ends the agent host `$HOME/agents`. `$HOME/no-systemd`:
/// no manager answers. `show` (not logged: every update script reads it)
/// prints `acpmux.service`'s `Environment=` settings, its drop-ins'
/// included, or `$HOME/unit-environment` as it is (what systemd prints for
/// values it quotes). Like the daemon
/// (`config::private_state_dir`, which opens its home with `O_NOFOLLOW`),
/// acpmux.service never answers when `~/.acpmux` is a link and no drop-in
/// sets `ACPMUX_HOME`.
#[cfg(unix)]
const FAKE_SYSTEMCTL: &str = r#"#!/bin/sh
d="$HOME/.config/systemd/user"; r="$XDG_RUNTIME_DIR/systemd/user"
if [ "$2" = show ] && [ -f "$HOME/unit-environment" ]; then cat "$HOME/unit-environment"; exit 0; fi
if [ "$2" = show ]; then cat "$d/$3" "$d/$3.d/"*.conf 2>/dev/null | sed -n 's/^Environment=//p' | tr '\n' ' '; echo; exit 0; fi
echo "systemctl $*" >> "$HOME/calls"
under() { echo "0::/user.slice/user-1001.slice/user@1001.service/app.slice/$1" > "$HOME/proc/4242/cgroup"; }
# Type=simple: the start succeeds once the process forks; a daemon that then
# exits (a home through a link) is seen only as no answer.
starts() {
  cat "$d/$1.d/"*.conf > "$HOME/started-with" 2>/dev/null
  if [ "$1" = acpmux.service ] && [ -L "$HOME/.acpmux" ] && ! grep -q '^Environment=ACPMUX_HOME=' "$HOME/started-with"; then echo "open private state directory $HOME/.acpmux: Not a directory" >> "$HOME/calls"; else ~/.local/bin/acpmux __start; fi
}
case "$2" in
show-environment) test ! -f "$HOME/no-systemd";;
cat) test -f "$d/$3";;
is-active) test -f "$HOME/active-$4";;
restart) rm -f "$HOME/daemon"; under "$3"; starts "$3";;
enable)
  test -f "$d/$4" && test ! -f "$HOME/fails-$4" || exit 1
  touch "$HOME/active-$4"; under "$4"
  if [ "$4" = acpmux.service ]; then starts acpmux.service; else cp "$HOME/old-build" "$HOME/daemon"; fi;;
disable)
  if [ -f "$HOME/active-$4" ]; then
    rm -f "$HOME/active-$4" "$HOME/daemon"
    if cat "$d/$4" "$r/$4.d/zzz-acpmux-migrate.conf" 2>/dev/null | grep -q '^KillMode=process'; then echo "agents kept by $4" >> "$HOME/calls"; else rm -f "$HOME/agents"; fi
  fi;;
esac
"#;

/// A peer for [`update_peer`]: a fake home whose scripts run under `sh`
/// with fake `acpmux`, `systemctl`, `loginctl`, `uname` and `sleep` (the
/// waits pass at once), `/proc` under the home, and a copy for scp.
#[cfg(unix)]
struct FakePeer {
    home: PathBuf,
    /// A file (relative path, text) written right after the next copy: what
    /// changes on the peer while the binary is pushed.
    after_copy: std::cell::RefCell<Option<(&'static str, &'static str)>>,
    /// Right after the next copy, the process that keeps the host's update
    /// lease ends: the connection that held the lock dropped.
    lease_ends_after_copy: std::cell::Cell<bool>,
}

#[cfg(unix)]
impl Remote for FakePeer {
    fn host(&self) -> &str {
        "fake"
    }

    fn exec(&self, script: &str, stdin: Option<&[u8]>) -> Result<RemoteOut> {
        assert!(stdin.is_none(), "host update feeds no stdin");
        let out = self.sh(script).output()?;
        Ok(RemoteOut {
            ok: out.status.success(),
            stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
        })
    }

    fn spawn(&self, script: &str) -> Result<std::process::Child> {
        use std::process::Stdio;
        let mut child = self.sh(script);
        child.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
        Ok(child.spawn()?)
    }

    fn push(&self, local: &Path, remote: &str) -> Result<()> {
        // As scp: a `~/` path is under the remote home.
        std::fs::copy(local, self.home.join(remote.strip_prefix("~/").unwrap_or(remote)))?;
        if let Some((rel, text)) = self.after_copy.borrow_mut().take() {
            self.write(rel, text);
        }
        if self.lease_ends_after_copy.take() {
            self.end_lease();
        }
        Ok(())
    }
}

#[cfg(unix)]
impl Drop for FakePeer {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.home);
    }
}

#[cfg(unix)]
impl FakePeer {
    /// A Linux host `host setup` set up: the daemon runs build OLD under
    /// `acpmux.service` with one agent host, and no session is busy.
    fn new(tag: &str) -> FakePeer {
        let home = std::env::temp_dir().join(format!("acpmux-up-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        let peer = FakePeer {
            home,
            after_copy: Default::default(),
            lease_ends_after_copy: Default::default(),
        };
        for dir in ["fakebin", ".local/bin", UNITS, "proc/4242", "run", "binaries", ".acpmux"] {
            std::fs::create_dir_all(peer.home.join(dir)).unwrap();
        }
        peer.exe("fakebin/systemctl", FAKE_SYSTEMCTL);
        peer.exe("fakebin/loginctl", "#!/bin/sh\ncase \"$1\" in show-user) echo yes;; esac\n");
        peer.exe("fakebin/uname", "#!/bin/sh\ncat \"$HOME/uname\"\n");
        peer.exe("fakebin/sleep", "#!/bin/sh\nexit 0\n");
        peer.write("uname", "Linux x86_64\n");
        peer.exe(".local/bin/acpmux", &fake_acpmux(OLD, Some(OLD)));
        peer.write("daemon", OLD);
        peer.write("agents", "");
        peer.write("sessions.json", r#"{"sessions": []}"#);
        peer.write(&format!("{UNITS}/acpmux.service"), SYSTEMD_UNIT);
        peer.write("active-acpmux.service", "");
        peer.under("acpmux.service");
        peer
    }

    /// huge-blue's shape: the daemon (build OLD, from its own binary)
    /// runs under a hand-written unit with a memory drop-in and
    /// `--listen 127.0.0.1:47822`, as its home's config.json says, while
    /// the standard path holds a STALE binary. Its home
    /// `~/.acpmux-supervised/hb` is where `~/.acpmux` links to, unless
    /// `carried` (then `~/.acpmux` is another folder, and the unit's
    /// ACPMUX_HOME must be carried to acpmux.service).
    fn under_foreign_unit(&self, carried: bool) {
        let _ = std::fs::remove_file(self.home.join(format!("{UNITS}/acpmux.service")));
        let _ = std::fs::remove_file(self.home.join("active-acpmux.service"));
        let sup = self.home.join(".acpmux-supervised/hb");
        self.write(
                ".acpmux-supervised/hb/config.json",
                "{\n  \"websocket\": {\n    \"listen\": \"127.0.0.1:47822\",\n    \"token\": \"t\"\n  }\n}\n",
            );
        self.write(".acpmux-supervised/hb/acpmux.sock", "");
        if !carried {
            std::fs::remove_dir_all(self.home.join(".acpmux")).unwrap();
            std::os::unix::fs::symlink(&sup, self.home.join(".acpmux")).unwrap();
        }
        self.write(
                &format!("{UNITS}/{FOREIGN}"),
                "[Service]\nEnvironment=ACPMUX_HOME=%h/.acpmux-supervised/hb\nExecStart=%h/.local/share/acpmux-supervised/acpmux daemon run --listen 127.0.0.1:47822 --log info\nRestart=always\n",
            );
        self.write(&format!("{UNITS}/{FOREIGN}.d/memory-backstop.conf"), BACKSTOP);
        self.write(&format!("active-{FOREIGN}"), "");
        self.write("old-build", OLD);
        self.under(FOREIGN);
        let h = sup.display();
        self.write(
            "proc/4242/environ",
            &format!("PATH=/usr/bin\0ACPMUX_HOME={h}\0ACPMUX_SOCKET={h}/acpmux.sock\0"),
        );
        self.write(
                "proc/4242/cmdline",
                &format!(
                    "{}/.local/share/acpmux-supervised/acpmux\0daemon\0run\0--listen\0127.0.0.1:47822\0--log\0info\0",
                    self.home.display()
                ),
            );
        self.exe(".local/bin/acpmux", &fake_acpmux(STALE, Some(STALE)));
    }

    /// End the process that keeps the update lease (a holder this test
    /// spawned, `host_lock.rs`) and reap it, as sshd does when the
    /// connection that held the lock drops.
    fn end_lease(&self) {
        let owner = self.read(".acpmux/update.owner");
        let pid: i32 =
            owner.split_whitespace().nth(1).and_then(|p| p.parse().ok()).expect("a lease");
        let mut status = 0;
        // SAFETY: the holder is a child of this test process (`Self::spawn`).
        unsafe {
            libc::kill(pid, libc::SIGKILL);
            libc::waitpid(pid, &mut status, 0);
        }
    }

    /// `script` under `sh` in the fake home, as [`Remote::exec`] runs it;
    /// `$HOME/path`, when a test wrote one, is its PATH, and `$HOME/shell`
    /// its shell (ssh runs the login shell).
    fn sh(&self, script: &str) -> Command {
        let script = script
            .replace("/proc/", &format!("{}/", self.home.join("proc").display()))
            .replace("/etc/cmux/", &format!("{}/", self.home.join("etc/cmux").display()));
        let shell = std::fs::read_to_string(self.home.join("shell"));
        let mut command = Command::new(shell.as_deref().unwrap_or("sh").trim());
        command
            .args(["-c", &script])
            .current_dir(&self.home)
            .env("HOME", &self.home)
            .env("XDG_RUNTIME_DIR", self.home.join("run"))
            .env(
                "PATH",
                std::fs::read_to_string(self.home.join("path")).unwrap_or_else(|_| {
                    format!("{}:/usr/bin:/bin", self.home.join("fakebin").display())
                }),
            )
            .env_remove("ACPMUX_HOME")
            .env_remove("ACPMUX_SOCKET");
        command
    }

    fn write(&self, rel: &str, text: &str) {
        let path = self.home.join(rel);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }

    fn exe(&self, rel: &str, text: &str) {
        use std::os::unix::fs::PermissionsExt;
        self.write(rel, text);
        let mode = std::fs::Permissions::from_mode(0o755);
        std::fs::set_permissions(self.home.join(rel), mode).unwrap();
    }

    fn read(&self, rel: &str) -> String {
        std::fs::read_to_string(self.home.join(rel)).unwrap_or_default()
    }

    /// The build of the daemon that runs ("" for none).
    fn daemon(&self) -> String {
        self.read("daemon").trim().to_owned()
    }

    fn exists(&self, rel: &str) -> bool {
        self.home.join(rel).exists()
    }

    fn under(&self, unit: &str) {
        let slice = "/user.slice/user-1001.slice/user@1001.service/app.slice";
        self.write("proc/4242/cgroup", &format!("0::{slice}/{unit}\n"));
    }

    /// The binary `--binary-dir` offers for this peer.
    fn offer(&self, build: &str, runs: Option<&str>) {
        self.exe(&format!("binaries/acpmux-{TARGET}"), &fake_acpmux(build, runs));
    }

    fn update(&self, if_idle: bool) -> PeerUpdate {
        let opts =
            UpdateOptions { binary_dir: Some(self.home.join("binaries")), if_idle, caller: None };
        update_peer(self, &opts)
    }

    /// `update(true)` run from the session `session` of the daemon `daemon`.
    fn update_from(&self, session: &str, daemon: &str) -> PeerUpdate {
        let caller = Caller { session: session.to_owned(), daemon: daemon.to_owned() };
        let opts = UpdateOptions {
            binary_dir: Some(self.home.join("binaries")),
            if_idle: true,
            caller: Some(caller),
        };
        update_peer(self, &opts)
    }

    /// The commands the fakes got since the last call.
    fn take_calls(&self) -> Vec<String> {
        let calls = self.read("calls");
        let _ = std::fs::remove_file(self.home.join("calls"));
        calls.lines().map(str::to_owned).collect()
    }

    /// Nothing on the peer changed: its binary, units and daemon are as
    /// they were, and nothing but reads ran.
    fn assert_untouched(&self, binary: &str, daemon: &str) {
        assert!(!self.exists(".local/bin/acpmux.prev"));
        self.assert_only_read(binary, daemon);
    }

    /// The binary and daemon are as they were, and nothing but reads ran.
    fn assert_only_read(&self, binary: &str, daemon: &str) {
        assert_eq!(self.read(".local/bin/acpmux"), binary);
        assert!(!self.exists(".local/bin/.acpmux-new"));
        assert_eq!(self.daemon(), daemon);
        assert!(self.exists("agents"));
        let calls = self.take_calls();
        assert!(
            calls.iter().all(|c| c == "acpmux --json daemon status"
                || c == "acpmux --json ls"
                || c.starts_with("loginctl show-user")),
            "{calls:?}"
        );
    }
}

#[test]
#[cfg(unix)]
fn an_update_pushes_the_targets_binary_and_restarts_the_unit() {
    let peer = FakePeer::new("update");
    peer.offer(NEW, Some(NEW));
    let up = peer.update(true);
    assert_eq!(up.outcome, Outcome::Updated, "{up:?}");
    assert_eq!(up.build.as_deref(), Some(NEW));
    assert_eq!(up.target, Some(TARGET));
    assert_eq!(up.version, Some(format!("acpmux 1.0.0 ({NEW})")));
    assert_eq!(up.migrated_from, None);
    assert_eq!(peer.read(".local/bin/acpmux"), fake_acpmux(NEW, Some(NEW)));
    assert_eq!(peer.read(".local/bin/acpmux.prev"), fake_acpmux(OLD, Some(OLD)));
    assert!(peer.take_calls().contains(&"systemctl --user restart acpmux.service".to_owned()));
    assert!(peer.exists("agents"));
}

#[test]
#[cfg(unix)]
fn a_turn_that_starts_during_the_push_keeps_its_daemon() {
    let peer = FakePeer::new("turn-during-push");
    peer.offer(NEW, Some(NEW));
    *peer.after_copy.borrow_mut() = Some((
        "sessions.json",
        r#"{"sessions": [{"name": "late", "status": "running", "turn": {"startedAt": 1}}]}"#,
    ));
    let up = peer.update(true);
    assert_eq!(up.outcome, Outcome::Busy, "{up:?}");
    assert_eq!(up.reason.as_deref(), Some("busy"));
    assert!(up.error.as_deref().unwrap_or_default().contains("late"), "{up:?}");
    assert_eq!(up.version, None);
    // The old binary is back and its daemon was never restarted.
    assert_eq!(peer.read(".local/bin/acpmux"), fake_acpmux(OLD, Some(OLD)));
    assert_eq!(peer.daemon(), OLD);
    assert!(!peer.take_calls().iter().any(|c| c.contains("restart")));
}

#[test]
#[cfg(unix)]
fn a_login_banner_is_not_read_as_the_platform() {
    let stdout = format!(
        "Welcome to box\n{UNAME}Linux aarch64\n{CLOUD_VM}\n\n{PROBE_SPLIT}\n{{}}\n\n{PROBE_SPLIT}\n\n{PROBE_SPLIT}\n"
    );
    let out = RemoteOut { ok: true, stdout, stderr: String::new() };
    let probe = Probe::parse(&out, None).unwrap();
    assert_eq!(probe.uname, "Linux aarch64");
    assert!(probe.cloud_vm);
}

#[test]
#[cfg(unix)]
fn a_pushed_binary_that_does_not_run_is_never_installed() {
    let peer = FakePeer::new("no-run");
    peer.exe(
        &format!("binaries/acpmux-{TARGET}"),
        "#!/bin/sh\necho 'cannot execute binary file: Exec format error' >&2\nexit 126\n",
    );
    let up = peer.update(false);
    assert_eq!(up.outcome, Outcome::Failed, "{up:?}");
    assert_eq!(up.reason.as_deref(), Some("pushFailed"));
    assert!(up.error.as_deref().unwrap_or_default().contains("does not run"), "{up:?}");
    // The old binary stays installed, and no copy of the new one is left.
    peer.assert_untouched(&fake_acpmux(OLD, Some(OLD)), OLD);
}

#[test]
#[cfg(unix)]
fn a_cloud_vm_is_left_to_cmux_link_machine_update() {
    let peer = FakePeer::new("cloud-vm");
    peer.write("etc/cmux/vm-kind", "cloud\n");
    peer.offer(NEW, Some(NEW));
    for if_idle in [false, true] {
        let up = peer.update(if_idle);
        assert_eq!(up.outcome, Outcome::Failed, "{up:?}");
        assert_eq!(up.reason.as_deref(), Some("cloudMachine"));
        assert!(up.error.as_deref().unwrap_or_default().contains("--to-bundled"), "{up:?}");
        peer.assert_untouched(&fake_acpmux(OLD, Some(OLD)), OLD);
    }
}

#[test]
#[cfg(unix)]
fn a_current_peer_or_one_without_a_binary_is_left_alone() {
    let peer = FakePeer::new("current");
    // Another day's build of the same commit, with local edits: current.
    peer.write("daemon", "a1b2c3d4e+dirty.0badf00d 2026-10-19");
    peer.offer(NEW, Some(NEW));
    let up = peer.update(true);
    assert_eq!(up.outcome, Outcome::Current, "{up:?}");
    assert_eq!(up.build.as_deref(), Some("a1b2c3d4e+dirty.0badf00d 2026-10-19"));
    peer.assert_untouched(&fake_acpmux(OLD, Some(OLD)), "a1b2c3d4e+dirty.0badf00d 2026-10-19");

    let peer = FakePeer::new("needs-binary");
    let up = peer.update(true);
    assert_eq!(up.outcome, Outcome::NeedsBinary, "{up:?}");
    assert_eq!(up.to_json("p", "h")["target"], TARGET);
    assert!(up.error.as_deref().unwrap_or("").contains(&format!("acpmux-{TARGET}")));
    peer.assert_untouched(&fake_acpmux(OLD, Some(OLD)), OLD);

    // Without --binary-dir, this binary goes only to its own platform.
    let peer = FakePeer::new("wrong-platform");
    let other = if cfg!(target_os = "linux") { "Darwin arm64" } else { "Linux x86_64" };
    peer.write("uname", other);
    let up = update_peer(&peer, &UpdateOptions { binary_dir: None, if_idle: false, caller: None });
    assert_eq!((up.outcome, up.reason.as_deref()), (Outcome::NeedsBinary, Some("wrongPlatform")));
    let why = up.error.as_deref().unwrap_or("");
    assert!(why.contains("--binary-dir") && why.contains("fake is "), "{why}");
    peer.assert_untouched(&fake_acpmux(OLD, Some(OLD)), OLD);
}

#[test]
#[cfg(unix)]
fn if_idle_leaves_a_peer_mid_turn_untouched() {
    let peer = FakePeer::new("busy");
    peer.write(
        "sessions.json",
        &json!({"sessions": [
            {"name": "lane", "status": "idle", "turn": {"startedAt": 1}, "pendingPermissions": 0},
            {"name": "other/x", "peer": "other", "status": "running", "turn": {"startedAt": 1}},
        ]})
        .to_string(),
    );
    peer.offer(NEW, Some(NEW));
    let up = peer.update(true);
    assert_eq!((up.outcome, up.reason.as_deref()), (Outcome::Busy, Some("busy")), "{up:?}");
    assert!(up.error.as_deref().unwrap_or("").contains("lane"), "{up:?}");
    assert!(!up.outcome.failed());
    peer.assert_untouched(&fake_acpmux(OLD, Some(OLD)), OLD);
    // Without --if-idle it updates.
    assert_eq!(peer.update(false).outcome, Outcome::Updated);
}

#[test]
#[cfg(unix)]
fn if_idle_does_not_wait_on_the_session_that_runs_the_update() {
    // deputy-2, 2026-10-22: "`--if-idle` never succeeds on a busy host (a
    // probe or the calling lane is always mid-turn)". The caller's own turn
    // runs this command, so it never ends first.
    let peer = FakePeer::new("busy-caller");
    let sessions = |other_busy: bool, caller_asks: u64| {
        json!({"sessions": [
            {"name": "caller", "sessionId": "01a1-caller", "status": "running", "turn": {"startedAt": 1},
             "pendingPermissions": caller_asks},
            {"name": "probe", "sessionId": "01a1-probe", "status": "idle",
             "turn": if other_busy { json!({"startedAt": 1}) } else { Value::Null }, "pendingPermissions": 0},
        ]})
        .to_string()
    };
    peer.write("sessions.json", &sessions(true, 0));
    peer.offer(NEW, Some(NEW));
    // Another session mid-turn still holds the update, and the caller is not named.
    let up = peer.update_from("01a1-caller", PEER_DAEMON);
    assert_eq!((up.outcome, up.reason.as_deref()), (Outcome::Busy, Some("busy")), "{up:?}");
    assert_eq!(up.error.as_deref(), Some("mid-turn or waiting on a permission: probe"));
    peer.write("sessions.json", &sessions(false, 0));
    // From another session, the caller's turn holds it.
    let up = peer.update_from("01a1-elsewhere", PEER_DAEMON);
    assert_eq!(up.error.as_deref(), Some("mid-turn or waiting on a permission: caller"));
    // A session id is daemon-local: the same id on another daemon is not the caller.
    let up = peer.update_from("01a1-caller", "another-daemon-run");
    assert_eq!(up.error.as_deref(), Some("mid-turn or waiting on a permission: caller"));
    // A permission the caller waits on still holds it: a restart would cancel it.
    peer.write("sessions.json", &sessions(false, 1));
    let up = peer.update_from("01a1-caller", PEER_DAEMON);
    assert_eq!(up.error.as_deref(), Some("mid-turn or waiting on a permission: caller"));
    // Only the caller's turn runs: it updates, through both reads.
    peer.write("sessions.json", &sessions(false, 0));
    let up = peer.update_from("01a1-caller", PEER_DAEMON);
    assert_eq!(up.outcome, Outcome::Updated, "{up:?}");
    assert_eq!(peer.daemon(), NEW);
}

#[test]
#[cfg(unix)]
fn a_daemon_that_does_not_answer_with_the_pushed_build_is_rolled_back() {
    for (tag, runs, reason) in [
        ("mismatch", Some("fedcba987 2026-10-21"), "buildMismatch"),
        ("no-answer", None, "noAnswer"),
    ] {
        let peer = FakePeer::new(tag);
        peer.offer(NEW, runs);
        let up = peer.update(true);
        assert_eq!(
            (up.outcome, up.reason.as_deref()),
            (Outcome::RolledBack, Some(reason)),
            "{up:?}"
        );
        assert!(up.outcome.failed());
        assert_eq!(up.build.as_deref(), Some(OLD), "the previous build answers again");
        assert_eq!(peer.read(".local/bin/acpmux"), fake_acpmux(OLD, Some(OLD)));
        assert_eq!(peer.daemon(), OLD);
        let restarts = peer
            .take_calls()
            .iter()
            .filter(|c| *c == "systemctl --user restart acpmux.service")
            .count();
        assert_eq!(restarts, 2, "{tag}");
        assert!(peer.exists("agents"));
    }
}

#[test]
#[cfg(unix)]
fn without_systemd_the_detached_daemon_is_updated_checked_and_rolled_back() {
    // A cloud VM (root, no user manager): a daemon started detached.
    let peer = FakePeer::new("detached");
    peer.write("no-systemd", "");
    let _ = std::fs::remove_file(peer.home.join("active-acpmux.service"));
    peer.under("session-4.scope");
    peer.write(
            "sessions.json",
            r#"{"sessions": [{"name": "lane", "status": "idle", "turn": null, "pendingPermissions": 2}]}"#,
        );
    peer.offer(NEW, Some(NEW));
    assert_eq!(peer.update(true).outcome, Outcome::Busy);
    peer.assert_untouched(&fake_acpmux(OLD, Some(OLD)), OLD);
    peer.write("sessions.json", r#"{"sessions": []}"#);
    let up = peer.update(true);
    assert_eq!(up.outcome, Outcome::Updated, "{up:?}");
    assert_eq!(peer.daemon(), NEW);
    let calls = peer.take_calls();
    assert!(calls.contains(&"acpmux daemon shutdown --keep-agents".to_owned()), "{calls:?}");
    assert!(calls.contains(&"acpmux --json daemon start".to_owned()), "{calls:?}");
    // A newer binary whose daemon never answers: back to NEW, detached.
    peer.offer("b2c3d4e5f 2026-10-22", None);
    let up = peer.update(true);
    assert_eq!(
        (up.outcome, up.reason.as_deref()),
        (Outcome::RolledBack, Some("noAnswer")),
        "{up:?}"
    );
    assert_eq!(peer.daemon(), NEW);
    assert_eq!(peer.read(".local/bin/acpmux"), fake_acpmux(NEW, Some(NEW)));
    assert!(peer.exists("agents"));
}

#[test]
#[cfg(unix)]
fn a_daemon_under_a_hand_written_unit_moves_to_acpmux_service_with_its_agents() {
    let peer = FakePeer::new("migrate");
    peer.under_foreign_unit(true);
    peer.offer(NEW, Some(NEW));
    let up = peer.update(true);
    assert_eq!(up.outcome, Outcome::Updated, "{up:?}");
    assert_eq!(up.migrated_from.as_deref(), Some(FOREIGN));
    assert_eq!(up.to_json("hb", "hb")["migratedFrom"], FOREIGN);
    assert_eq!(up.build.as_deref(), Some(NEW));
    // The old unit is renamed, so nothing starts it by name again.
    assert!(!peer.exists(&format!("{UNITS}/{FOREIGN}")));
    assert!(peer.exists(&format!("{UNITS}/{FOREIGN}.migrated")));
    assert_eq!(peer.read(&format!("{UNITS}/acpmux.service")), SYSTEMD_UNIT);
    assert_eq!(peer.read(&format!("{UNITS}/acpmux.service.d/memory-backstop.conf")), BACKSTOP);
    let home = peer.home.join(".acpmux-supervised/hb");
    assert_eq!(
        peer.read(&format!("{UNITS}/acpmux.service.d/10-migrated.conf")),
        format!(
            "[Service]\nEnvironment=ACPMUX_HOME={h}\nEnvironment=ACPMUX_SOCKET={h}/acpmux.sock\n",
            h = home.display()
        )
    );
    let started_with = peer.read("started-with");
    assert!(started_with.contains("MemoryMax=6G") && started_with.contains("ACPMUX_HOME="));
    assert_eq!(
        peer.read(&format!("run/systemd/user/{FOREIGN}.d/zzz-acpmux-migrate.conf")),
        "[Service]\nKillMode=process\nRestart=no\n"
    );
    let calls = peer.take_calls();
    let at =
        |c: &str| calls.iter().position(|x| x == c).unwrap_or_else(|| panic!("no {c}: {calls:?}"));
    let stop = at(&format!("systemctl --user disable --now {FOREIGN}"));
    assert!(at("systemctl --user daemon-reload") < stop, "the drop-in applies before the stop");
    assert!(calls.contains(&format!("agents kept by {FOREIGN}")), "{calls:?}");
    assert!(stop < at("systemctl --user enable --now acpmux.service"));
    assert!(
        !calls
            .iter()
            .any(|c| c.contains("--end-agents") || c.contains(" stop ") || c.contains(" kill ")),
        "{calls:?}"
    );
    assert!(peer.exists("agents"));
    assert!(!peer.read("started").contains(STALE));

    // Again, with nothing new: current, and no second migration.
    let up = peer.update(true);
    assert_eq!(up.outcome, Outcome::Current, "{up:?}");
    peer.assert_only_read(&fake_acpmux(NEW, Some(NEW)), NEW);
    // A newer build restarts acpmux.service like any set-up host.
    let newer = "b2c3d4e5f 2026-10-22";
    peer.offer(newer, Some(newer));
    let up = peer.update(true);
    assert_eq!((up.outcome, up.migrated_from), (Outcome::Updated, None));
    assert!(peer.take_calls().contains(&"systemctl --user restart acpmux.service".to_owned()));
    assert!(peer.exists(&format!("{UNITS}/{FOREIGN}.migrated")));
}

/// `binary` (a fake acpmux) whose daemon answers only at `socket`: a daemon
/// whose home or socket a drop-in of `acpmux.service` moved.
#[cfg(unix)]
fn listening_at(socket: &str, binary: &str) -> String {
    let check = format!(
        "#!/bin/sh\nif [ \"$*\" = \"--json daemon status\" ] && [ \"$ACPMUX_SOCKET\" != '{socket}' ]; then printf '{{\"running\": false}}\\n'; exit 0; fi\n"
    );
    binary.replacen("#!/bin/sh\n", &check, 1)
}

#[test]
#[cfg(unix)]
fn a_moved_daemon_is_reached_through_the_settings_its_move_carried() {
    // One rule for the daemon's home and socket: the move to acpmux.service
    // carries them into its drop-in (#24079), and every update script reads
    // them back from the unit (SERVICE_ENV), so the next update, from a
    // shell that has neither, checks the daemon where it listens instead of
    // rolling a healthy one back.
    let peer = FakePeer::new("carried-socket");
    peer.under_foreign_unit(false);
    peer.offer(NEW, Some(NEW));
    assert_eq!(peer.update(true).outcome, Outcome::Updated);
    let socket = peer.home.join(".acpmux-supervised/hb/acpmux.sock").display().to_string();
    let carried = peer.read(&format!("{UNITS}/acpmux.service.d/10-migrated.conf"));
    assert!(carried.contains(&format!("Environment=ACPMUX_SOCKET={socket}\n")), "{carried}");
    let newer = "b2c3d4e5f 2026-10-22";
    let binary = listening_at(&socket, &fake_acpmux(newer, Some(newer)));
    peer.exe(&format!("binaries/acpmux-{TARGET}"), &binary);
    let up = peer.update(true);
    assert_eq!((up.outcome, up.build.as_deref()), (Outcome::Updated, Some(newer)), "{up:?}");
    assert_eq!(up.migrated_from, None);
}

#[test]
#[cfg(unix)]
fn huge_blues_stale_binary_never_runs() {
    // The hand-written unit already runs the build to push: current, and
    // acpmux.service is not started on the stale binary at its path.
    let peer = FakePeer::new("stale-current");
    peer.under_foreign_unit(false);
    peer.offer(OLD, Some(OLD));
    assert_eq!(peer.update(true).outcome, Outcome::Current);
    peer.assert_untouched(&fake_acpmux(STALE, Some(STALE)), OLD);
    assert!(peer.exists(&format!("{UNITS}/{FOREIGN}")));

    // A new build: pushed over the stale one before acpmux.service starts.
    let peer = FakePeer::new("stale-update");
    peer.under_foreign_unit(false);
    peer.offer(NEW, Some(NEW));
    let up = peer.update(true);
    assert_eq!(up.outcome, Outcome::Updated, "{up:?}");
    assert_eq!(peer.daemon(), NEW);
    assert_eq!(peer.read("started").trim(), NEW, "only the pushed build started");
    // `~/.acpmux` links to the unit's home, but the daemon never opens its
    // home through a link: the home is carried (huge-blue, 2026-10-22).
    let home = peer.home.join(".acpmux-supervised/hb");
    assert_eq!(
        peer.read(&format!("{UNITS}/acpmux.service.d/10-migrated.conf")),
        format!(
            "[Service]\nEnvironment=ACPMUX_HOME={h}\nEnvironment=ACPMUX_SOCKET={h}/acpmux.sock\n",
            h = home.display()
        )
    );
    assert!(peer.read("started-with").contains("MemoryHigh=5G"));

    // The unit names the link itself, with a trailing `/`: the old daemon
    // opens it, acpmux.service without it would not, so it is carried.
    let peer = FakePeer::new("stale-slash");
    peer.under_foreign_unit(false);
    let linked = format!("{}/.acpmux/", peer.home.display());
    peer.write("proc/4242/environ", &format!("PATH=/usr/bin\0ACPMUX_HOME={linked}\0"));
    peer.offer(NEW, Some(NEW));
    let up = peer.update(true);
    assert_eq!(up.outcome, Outcome::Updated, "{up:?}");
    assert_eq!(
        peer.read(&format!("{UNITS}/acpmux.service.d/10-migrated.conf")),
        format!("[Service]\nEnvironment=ACPMUX_HOME={linked}\n")
    );

    // A drop-in of the unit's own with the carried settings' name would
    // replace them: refused before anything changes.
    let peer = FakePeer::new("stale-clash");
    peer.under_foreign_unit(false);
    peer.write(&format!("{UNITS}/{FOREIGN}.d/10-migrated.conf"), "[Service]\nNice=5\n");
    peer.offer(NEW, Some(NEW));
    let up = peer.update(true);
    assert_eq!(
        (up.outcome, up.reason.as_deref()),
        (Outcome::Failed, Some("unitSettings")),
        "{up:?}"
    );
    peer.assert_untouched(&fake_acpmux(STALE, Some(STALE)), OLD);
}

#[test]
#[cfg(unix)]
fn a_failed_move_restores_the_hand_written_unit_and_never_runs_the_old_binary_under_acpmux_service()
{
    for (tag, runs, fails, reason) in [
        ("migrate-no-answer", None, false, "noAnswer"),
        ("migrate-no-start", Some(NEW), true, "restartFailed"),
    ] {
        let peer = FakePeer::new(tag);
        peer.under_foreign_unit(false);
        peer.offer(NEW, runs);
        if fails {
            peer.write("fails-acpmux.service", "");
        }
        let up = peer.update(true);
        assert_eq!(
            (up.outcome, up.reason.as_deref()),
            (Outcome::RolledBack, Some(reason)),
            "{tag}: {up:?}"
        );
        assert_eq!(up.migrated_from, None);
        assert_eq!(up.build.as_deref(), Some(OLD), "{tag}: the old unit's daemon answers");
        assert!(peer.exists(&format!("{UNITS}/{FOREIGN}")), "{tag}");
        assert!(!peer.exists(&format!("{UNITS}/{FOREIGN}.migrated")), "{tag}");
        assert!(
            !peer.exists(&format!("run/systemd/user/{FOREIGN}.d/zzz-acpmux-migrate.conf")),
            "{tag}"
        );
        assert!(peer.exists(&format!("active-{FOREIGN}")) && !peer.exists("active-acpmux.service"));
        assert_eq!(peer.read(".local/bin/acpmux"), fake_acpmux(STALE, Some(STALE)), "{tag}");
        assert!(!peer.read("started").contains(STALE), "{tag}");
        let calls = peer.take_calls();
        let starts =
            calls.iter().filter(|c| *c == "systemctl --user enable --now acpmux.service").count();
        assert_eq!(starts, 1, "{tag}: acpmux.service is not started again: {calls:?}");
        assert!(calls.contains(&format!("systemctl --user enable --now {FOREIGN}")), "{calls:?}");
        assert!(peer.exists("agents"), "{tag}");
    }
}

#[test]
#[cfg(unix)]
fn an_acpmux_service_someone_else_wrote_is_refused_and_a_matching_one_adopted() {
    for (tag, unit, drop_in) in [
        ("conflict-unit", "[Service]\nExecStart=/opt/acpmux daemon run\n", BACKSTOP),
        ("conflict-drop-in", SYSTEMD_UNIT, "[Service]\nMemoryMax=1G\n"),
    ] {
        let peer = FakePeer::new(tag);
        peer.under_foreign_unit(false);
        peer.write(&format!("{UNITS}/acpmux.service"), unit);
        peer.write(&format!("{UNITS}/acpmux.service.d/memory-backstop.conf"), drop_in);
        peer.offer(NEW, Some(NEW));
        let up = peer.update(true);
        assert_eq!(
            (up.outcome, up.reason.as_deref()),
            (Outcome::Failed, Some("unitConflict")),
            "{tag}: {up:?}"
        );
        assert!(up.error.as_deref().unwrap_or("").contains("differs"), "{up:?}");
        assert_eq!(peer.read(&format!("{UNITS}/acpmux.service")), unit);
        assert_eq!(peer.read(&format!("{UNITS}/acpmux.service.d/memory-backstop.conf")), drop_in);
        assert!(peer.exists(&format!("{UNITS}/{FOREIGN}")));
        peer.assert_untouched(&fake_acpmux(STALE, Some(STALE)), OLD);
    }

    use std::os::unix::fs::MetadataExt;
    let peer = FakePeer::new("adopt");
    peer.under_foreign_unit(false);
    peer.write(&format!("{UNITS}/acpmux.service"), SYSTEMD_UNIT);
    peer.write(&format!("{UNITS}/acpmux.service.d/memory-backstop.conf"), BACKSTOP);
    let unit = peer.home.join(format!("{UNITS}/acpmux.service"));
    let before = std::fs::metadata(&unit).unwrap();
    peer.offer(NEW, Some(NEW));
    let up = peer.update(true);
    assert_eq!(
        (up.outcome, up.migrated_from.as_deref()),
        (Outcome::Updated, Some(FOREIGN)),
        "{up:?}"
    );
    let after = std::fs::metadata(&unit).unwrap();
    assert_eq!(
        (before.ino(), before.mtime(), before.mtime_nsec()),
        (after.ino(), after.mtime(), after.mtime_nsec())
    );
}

#[test]
#[cfg(unix)]
fn a_listen_address_acpmux_service_would_lose_is_refused() {
    let peer = FakePeer::new("listen");
    peer.under_foreign_unit(false);
    peer.write(
        ".acpmux-supervised/hb/config.json",
        "{\n  \"websocket\": {\n    \"listen\": \"127.0.0.1:47811\"\n  }\n}\n",
    );
    peer.offer(NEW, Some(NEW));
    let up = peer.update(true);
    assert_eq!(
        (up.outcome, up.reason.as_deref()),
        (Outcome::Failed, Some("listenConflict")),
        "{up:?}"
    );
    assert!(up.error.as_deref().unwrap_or("").contains("127.0.0.1:47822"), "{up:?}");
    peer.assert_untouched(&fake_acpmux(STALE, Some(STALE)), OLD);
}

#[cfg(unix)]
#[path = "host_lock_tests.rs"]
mod lock;
