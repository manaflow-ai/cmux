//! `host update` against fake peers: its scripts run under `sh` in a fake
//! home, with fake `acpmux`, `systemctl`, `loginctl`, `uname` and `sleep`.

use super::super::*;
use super::*;

#[cfg(unix)]
use std::os::unix::fs::MetadataExt;

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
fn a_binarys_build_is_never_rustcs_own_version() {
    // ELF keeps .rodata (the stamp) before .comment (rustc's line), but the
    // stamp may also be missing or come after it.
    let rustc = b"\x00rustc version 1.95.0 (59807616e 2026-04-14)\x00";
    let llvm = b"\x00clang LLVM (rustc version 1.95.0 (59807616e 2026-04-14))\x00";
    let stamp = b"\x00acpmux 0.1.0 (3bdf1d5d4 2026-11-02)\x00";
    for (bytes, want) in [
        ([&rustc[..], stamp].concat(), Some("3bdf1d5d4 2026-11-02")),
        ([&stamp[..], rustc].concat(), Some("3bdf1d5d4 2026-11-02")),
        ([&llvm[..], stamp].concat(), Some("3bdf1d5d4 2026-11-02")),
        (rustc.to_vec(), None),
        ([&rustc[..], b"rustc 1.94.0 (4a4ef493e 2026-03-02)"].concat(), None),
        // A binary from before the `acpmux ` marker: its bare version line.
        ([&rustc[..], b"0.1.0 (0db068d0e 2026-11-01)"].concat(), Some("0db068d0e 2026-11-01")),
        // The marker wins over an earlier bare line.
        ([&b"9 (aaaaaaa 2026-01-01)\x00"[..], stamp].concat(), Some("3bdf1d5d4 2026-11-02")),
    ] {
        assert_eq!(embedded_build(&bytes).as_deref(), want, "{}", String::from_utf8_lossy(&bytes));
    }
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
    // An agent start under way (its spawn lease held) is busy: a restart would end it.
    let starting = json!({"sessions": [
        {"name": "starting", "status": "idle", "turn": null, "starting": true},
        {"name": "started", "status": "ready", "turn": null, "starting": false},
    ]});
    assert_eq!(busy_sessions(&starting.to_string(), None), Some(vec!["starting".into()]));
    // An older acpmux sends no `starting`: a session it just made may be starting; a long-idle one
    // is not.
    let now = crate::store::now_ms();
    let older = json!({"sessions": [
        {"name": "just-made", "status": "idle", "turn": null, "createdAt": now, "updatedAt": now},
        {"name": "long-idle", "status": "ready", "turn": null, "createdAt": 1, "updatedAt": 1},
    ]});
    assert_eq!(busy_sessions(&older.to_string(), None), Some(vec!["just-made".into()]));
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
/// that runs (absent: none), `$HOME/started` every build started. On a
/// macOS peer (`$HOME/launchd-host`) a daemon holds `daemon.lock`: one that
/// starts while another runs exits at once, and `$HOME/daemon-pid` says
/// whose it is (4242: launchd's job, 5151: started in place).
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
"--json daemon status") if [ -f "$HOME/daemon" ]; then printf '{{\n  "build": "%s",\n  "pid": %s,\n  "personInstance": "{PEER_DAEMON}"%s\n}}\n' "$(cat "$HOME/daemon")" "$(cat "$HOME/daemon-pid" 2>/dev/null || echo 4242)" "$(cat "$HOME/abi-$(cut -d' ' -f1 "$HOME/daemon")" 2>/dev/null)"; else printf '{{\n  "running": false,\n  "error": "daemon not running"\n}}\n'; fi;;
"--json ls") cat "$HOME/sessions.json";;
"daemon shutdown"*) rm -f "$HOME/daemon"; if [ -f "$HOME/unit-takes-over" ]; then rm -f "$HOME/unit-takes-over"; touch "$HOME/active-acpmux.service"; echo 5252 > "$HOME/daemon-pid"; echo 5252 > "$HOME/unit-main-pid"; ~/.local/bin/acpmux __start; fi;;
"--json daemon start"|__start) if [ -f "$HOME/launchd-host" ] && [ -f "$HOME/daemon" ]; then echo 'daemon.lock held' >> "$HOME/calls"
  else {start}; if [ -f "$HOME/launchd-host" ]; then if [ "$1" = __start ]; then echo 4242; else echo 5151; fi > "$HOME/daemon-pid"; fi; fi;;
esac
"#
    )
}

/// A user systemd manager: a unit with `$HOME/active-<unit>` runs the
/// daemon (acpmux.service the binary at the standard path, another unit
/// the build in `$HOME/old-build`), `$HOME/fails-<unit>` does not start,
/// and a stop without `KillMode=process` (the unit's, or the migration's
/// runtime drop-in) ends the agent host `$HOME/agents`. `$HOME/no-systemd`:
/// no manager answers. A timer only needs its unit file; `show -p LoadState`
/// and `-p FragmentPath` find a unit in `~/.config/systemd/user` only. `show` (not
/// logged: every update script reads it) answers as systemd does from the
/// unit, its own drop-ins and its name prefixes' (`acpmux-agent-.service.d`),
/// `%h` and blanks around `=` resolved: `ActiveState` (`$HOME/active-<unit>`),
/// the last `ExecStart`, `EnvironmentFiles`, `DropInPaths`, and otherwise the
/// `Environment=` settings, or `$HOME/unit-environment`
/// as it is (what systemd prints for values it quotes). Like the daemon
/// (`config::private_state_dir`, which opens its home with `O_NOFOLLOW`),
/// acpmux.service never answers when `~/.acpmux` is a link and no drop-in
/// sets `ACPMUX_HOME`.
#[cfg(unix)]
const FAKE_SYSTEMCTL: &str = r#"#!/bin/sh
d="$HOME/.config/systemd/user"; r="$XDG_RUNTIME_DIR/systemd/user"
if [ "$2" = show ] && [ "$5" = LoadState ]; then if [ -f "$d/$3" ]; then echo loaded; else echo not-found; fi; exit 0; fi
if [ "$2" = show ] && [ "$5" = FragmentPath ]; then if [ -f "$d/$3" ]; then echo "$d/$3"; fi; exit 0; fi
dirs() { n=${1%.service}; x=; while case "$n" in *-*) true;; *) false;; esac; do x="$x${n%%-*}-"; n=${n#*-}; echo "$d/$x.service.d"; done; echo "$d/$1.d"; }
lines() { { cat "$d/$1"; for x in $(dirs "$1"); do cat "$x/"*.conf; done; } 2>/dev/null | sed 's/^[[:space:]]*\([A-Za-z]*\)[[:space:]]*=[[:space:]]*/\1=/' | sed "s|%h|$HOME|g"; }
if [ "$2" = show ] && [ "$5" = MainPID ]; then cat "$HOME/unit-main-pid" 2>/dev/null || echo 0; exit 0; fi
if [ "$2" = show ] && [ "$5" = ActiveState ]; then if [ -f "$HOME/active-$3" ]; then echo active; else echo inactive; fi; exit 0; fi
if [ "$2" = show ] && [ "$5" = ExecStart ]; then a=$(lines "$3" | sed -n 's/^ExecStart=[-@:+!]*//p' | tail -1); [ -z "$a" ] || echo "{ path=${a%% *} ; argv[]=$a ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"; exit 0; fi
if [ "$2" = show ] && [ "$5" = EnvironmentFiles ]; then lines "$3" | sed -n 's/^EnvironmentFile=\(.*\)$/\1 (ignore_errors=no)/p'; exit 0; fi
if [ "$2" = show ] && [ "$5" = DropInPaths ]; then for x in $(dirs "$3"); do ls "$x/"*.conf 2>/dev/null; done | tr '\n' ' '; echo; exit 0; fi
if [ "$2" = show ] && [ -f "$HOME/unit-environment" ]; then cat "$HOME/unit-environment"; exit 0; fi
if [ "$2" = show ]; then lines "$3" | sed -n 's/^Environment=//p' | tr '\n' ' '; echo; exit 0; fi
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
  case "$4" in *.timer) test -f "$d/$4"; exit;; esac
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
    /// Right after the next copy the host goes away (a GCP VM stopped while
    /// idle): every later ssh fails with these words of ssh's.
    gone_after_copy: std::cell::Cell<Option<&'static str>>,
    /// The next copy drops part way, with these words of scp's.
    copy_drops: std::cell::Cell<Option<&'static str>>,
    /// Set once the host went away ([`FakePeer::gone_after_copy`]).
    gone: std::cell::Cell<Option<&'static str>>,
    /// The next restart runs, then ssh's link drops before it reports (a
    /// keepalive timeout through a ProxyJump, huge-blue 2026-11-06); `true`:
    /// the host stays gone after.
    link_drops_on_restart: std::cell::Cell<Option<bool>>,
}

#[cfg(unix)]
impl Remote for FakePeer {
    fn host(&self) -> &str {
        "fake"
    }

    fn exec(&self, script: &str, stdin: Option<&[u8]>) -> Result<RemoteOut> {
        assert!(stdin.is_none(), "host update feeds no stdin");
        if let Some(why) = self.gone.get() {
            return Ok(RemoteOut { ok: false, stdout: String::new(), stderr: why.to_owned() });
        }
        let out = self.sh(script).output()?;
        if script.contains("systemctl --user restart acpmux.service")
            && let Some(stays_gone) = self.link_drops_on_restart.take()
        {
            let why = "Connection to UNKNOWN port 65535 timed out";
            if stays_gone {
                self.gone.set(Some(why));
            }
            return Ok(RemoteOut {
                ok: false,
                stdout: String::new(),
                stderr: format!("{why}\r\n"),
            });
        }
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
        // As scp: a `~/` path is under the remote home. Written from a child
        // process (`test_exec`): the update runs the pushed binary next.
        if let Some(why) = self.copy_drops.take() {
            return Err(anyhow!("scp to fake failed: {why}"));
        }
        let dest = self.home.join(remote.strip_prefix("~/").unwrap_or(remote));
        crate::test_exec::write_executable(dest, std::fs::read(local)?);
        if let Some(why) = self.gone_after_copy.take() {
            self.gone.set(Some(why));
        }
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
        // FakePeer::drop owns cleanup. Two concurrent tests may use the same scenario tag.
        let home = tempfile::Builder::new().prefix(tag).tempdir().unwrap().keep();
        let peer = FakePeer {
            home,
            after_copy: Default::default(),
            lease_ends_after_copy: Default::default(),
            gone_after_copy: Default::default(),
            copy_drops: Default::default(),
            gone: Default::default(),
            link_drops_on_restart: Default::default(),
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
        let path = self.home.join(rel);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        crate::test_exec::write_executable(path, text);
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
        self.update_with(if_idle, false)
    }

    fn update_with(&self, if_idle: bool, keep_newer: bool) -> PeerUpdate {
        let binary_dir = Some(self.home.join("binaries"));
        update_peer(
            self,
            &UpdateOptions {
                binary_dir,
                if_idle,
                keep_newer,
                allow_downgrade: false,
                caller: None,
                now: true,
            },
        )
    }

    /// `update(true)` run from the session `session` of the daemon `daemon`.
    fn update_from(&self, session: &str, daemon: &str) -> PeerUpdate {
        let caller = Caller { session: session.to_owned(), daemon: daemon.to_owned() };
        let opts = UpdateOptions {
            binary_dir: Some(self.home.join("binaries")),
            if_idle: true,
            keep_newer: false,
            allow_downgrade: false,
            caller: Some(caller),
            now: true,
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
fn an_identical_push_leaves_the_installed_binary_and_previous_build_untouched() {
    let peer = FakePeer::new("identical-push");
    let previous = fake_acpmux("previous", Some("previous"));
    peer.exe(".local/bin/acpmux.prev", &previous);
    let installed = peer.home.join(".local/bin/acpmux");
    let prev = peer.home.join(".local/bin/acpmux.prev");
    let installed_before = std::fs::metadata(&installed).unwrap();
    let prev_before = std::fs::metadata(&prev).unwrap();
    let binary = peer.home.join(format!("binaries/acpmux-{TARGET}"));
    peer.exe(&format!("binaries/acpmux-{TARGET}"), &fake_acpmux(OLD, Some(OLD)));

    let version = push_update(&peer, &binary, Some(OLD), false, false).unwrap();

    assert_eq!(version, format!("acpmux 1.0.0 ({OLD})"));
    assert_eq!(peer.read(".local/bin/acpmux"), fake_acpmux(OLD, Some(OLD)));
    assert_eq!(peer.read(".local/bin/acpmux.prev"), previous);
    assert_eq!(std::fs::metadata(&installed).unwrap().ino(), installed_before.ino());
    assert_eq!(std::fs::metadata(&prev).unwrap().ino(), prev_before.ino());
    assert!(!peer.exists(".local/bin/.acpmux-new"));
}

#[test]
#[cfg(unix)]
fn an_identical_push_repairs_a_nonexecutable_install() {
    use std::os::unix::fs::PermissionsExt;

    let peer = FakePeer::new("identical-push-mode");
    let installed = peer.home.join(".local/bin/acpmux");
    std::fs::set_permissions(&installed, std::fs::Permissions::from_mode(0o644)).unwrap();
    let rel = format!("binaries/acpmux-{TARGET}");
    peer.exe(&rel, &fake_acpmux(OLD, Some(OLD)));

    push_update(&peer, &peer.home.join(rel), Some(OLD), false, false).unwrap();

    let out = peer.exec(".local/bin/acpmux --version", None).unwrap();
    assert!(out.ok, "{}", out.stderr);
    assert_eq!(out.stdout.trim(), format!("acpmux 1.0.0 ({OLD})"));
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

/// A host set up before the unit stopped giving up (huge-blue's
/// `StartLimitBurst=5`) gets the new unit text from the update, and keeps
/// its own drop-ins; an edited unit is the user's and stays.
#[test]
#[cfg(unix)]
fn an_update_rewrites_the_unit_an_older_acpmux_wrote() {
    let peer = FakePeer::new("refresh");
    peer.write(&format!("{UNITS}/acpmux.service"), OLD_SYSTEMD_UNITS[0]);
    peer.write(&format!("{UNITS}/acpmux.service.d/memory-backstop.conf"), BACKSTOP);
    peer.offer(NEW, Some(NEW));
    let up = peer.update(true);
    assert_eq!(up.outcome, Outcome::Updated, "{up:?}");
    assert_eq!(peer.read(&format!("{UNITS}/acpmux.service")), SYSTEMD_UNIT);
    assert_eq!(peer.read(&format!("{UNITS}/acpmux.service.d/memory-backstop.conf")), BACKSTOP);
    let calls = peer.take_calls();
    let at = |c: &str| calls.iter().position(|x| x == c);
    assert!(
        at("systemctl --user daemon-reload") < at("systemctl --user restart acpmux.service"),
        "{calls:?}"
    );

    let peer = FakePeer::new("refresh-edited");
    let edited = OLD_SYSTEMD_UNITS[0].replace("RestartSec=3", "RestartSec=10");
    peer.write(&format!("{UNITS}/acpmux.service"), &edited);
    peer.offer(NEW, Some(NEW));
    let up = peer.update(true);
    assert_eq!(up.outcome, Outcome::Updated, "{up:?}");
    assert_eq!(peer.read(&format!("{UNITS}/acpmux.service")), edited);
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

/// Leo, 2026-11-03, on a toast "Couldn't update gcp-codex-swarm-03: ssh gcp-codex-swarm-03 failed:
/// Timeout, server gcp-codex-swarm-03...internal not responding.": the GCP pool stops idle VMs, so
/// a host can go away while its binary is pushed. Nothing is installed or restarted before the
/// push ends, so that is `unreachable` (the app's quiet "offline; it will update when it's
/// back"), never a `pushFailed` the app shows as a failure.
#[test]
#[cfg(unix)]
fn a_host_that_goes_away_during_the_push_is_unreachable() {
    let drops = [
        ("ssh", "Timeout, server fake.us-west1-c.c.example.internal not responding.\r\n"),
        ("ssh", "Connection to 10.0.0.7 closed by remote host.\r\n"),
        ("ssh", "ssh: connect to host 10.0.0.7 port 22: No route to host\r\n"),
        ("scp", "client_loop: send disconnect: Broken pipe lost connection"),
    ];
    for (i, (how, why)) in drops.into_iter().enumerate() {
        let peer = FakePeer::new(&format!("gone-during-push-{i}"));
        peer.offer(NEW, Some(NEW));
        match how {
            "ssh" => peer.gone_after_copy.set(Some(why)),
            _ => peer.copy_drops.set(Some(why)),
        }
        let up = peer.update(false);
        assert_eq!(
            (up.outcome, up.reason.as_deref()),
            (Outcome::Failed, Some("unreachable")),
            "{why}: {up:?}"
        );
        // Nothing was installed or restarted: the next connect runs it again.
        assert_eq!(peer.read(".local/bin/acpmux"), fake_acpmux(OLD, Some(OLD)), "{why}");
        assert_eq!(peer.daemon(), OLD, "{why}");
    }
}

/// A push that fails on the host itself, not on the way there, still shows.
#[test]
fn only_ssh_losing_the_host_reads_as_unreachable() {
    for why in [
        "ssh fake failed: Timeout, server fake not responding.",
        "ssh fake failed: ssh: Could not resolve hostname fake: Name or service not known",
        "ssh fake failed: kex_exchange_identification: Connection reset by peer",
        "ssh fake failed: Connection closed by 10.0.0.7 port 22",
        "scp to fake failed: lost connection",
    ] {
        assert!(lost_the_host(&anyhow!("{why}")), "{why}");
    }
    for why in [
        "ssh fake failed: the pushed acpmux does not run on this host",
        "ssh fake failed: mkdir: cannot create directory: No space left on device",
        "scp to fake failed: scp: ~/.local/bin/.acpmux-new/acpmux: Permission denied",
    ] {
        assert!(!lost_the_host(&anyhow!("{why}")), "{why}");
    }
}

/// A cmux Cloud VM's daemon as cmux runs it: no `acpmux.service` of acpmux's
/// own, or one the `~/.acpmux` daemon does not run under, or a unit someone
/// else wrote. `cmux link machine update --to-bundled` owns that daemon.
#[cfg(unix)]
const CLOUD_SHAPES: [&str; 3] = ["no unit", "daemon outside the unit", "unit someone else wrote"];

#[cfg(unix)]
fn cloud_vm(tag: &str, shape: &str) -> FakePeer {
    let peer = FakePeer::new(tag);
    peer.write("etc/cmux/vm-kind", "team\n");
    let unit = format!("{UNITS}/acpmux.service");
    match shape {
        "no unit" => {
            std::fs::remove_file(peer.home.join(&unit)).unwrap();
            std::fs::remove_file(peer.home.join("active-acpmux.service")).unwrap();
            peer.under("run-cmux-tui-0123.scope");
        }
        "daemon outside the unit" => peer.under("session-26.scope"),
        "unit someone else wrote" => peer.write(&unit, &format!("{SYSTEMD_UNIT}# theirs\n")),
        other => panic!("no shape {other}"),
    }
    peer
}

#[test]
#[cfg(unix)]
fn a_cloud_vm_is_left_to_cmux_link_machine_update() {
    for shape in CLOUD_SHAPES {
        let peer = cloud_vm(&format!("cloud-vm-{}", shape.replace(' ', "-")), shape);
        peer.offer(NEW, Some(NEW));
        for if_idle in [false, true] {
            let up = peer.update(if_idle);
            assert_eq!(up.outcome, Outcome::Failed, "{shape}: {up:?}");
            assert_eq!(up.reason.as_deref(), Some("cloudMachine"), "{shape}");
            assert!(up.error.as_deref().unwrap_or_default().contains("--to-bundled"), "{up:?}");
            peer.assert_untouched(&fake_acpmux(OLD, Some(OLD)), OLD);
        }
    }
}

/// A cmux Cloud VM the fleet set up as a lane host (2026-10-30)
/// runs acpmux's own `acpmux.service` from `~/.local/bin/acpmux`, beside
/// cmux Cloud's `~/.cmux/bin/acpmux`, which is the only one `cmux link
/// machine update` replaces. Nobody else updates that daemon, so `host
/// update` (and the self-update timer) does.
#[test]
#[cfg(unix)]
fn a_cloud_vm_whose_daemon_is_acpmux_service_is_updated() {
    let peer = FakePeer::new("cloud-vm-own-unit");
    peer.write("etc/cmux/vm-kind", "team\n");
    peer.offer(NEW, Some(NEW));
    let up = peer.update(false);
    assert_eq!(up.outcome, Outcome::Updated, "{up:?}");
    assert_eq!(peer.read(".local/bin/acpmux"), fake_acpmux(NEW, Some(NEW)));
    assert_eq!(peer.daemon(), NEW);
    assert!(peer.take_calls().contains(&"systemctl --user restart acpmux.service".to_owned()));
}

/// The check both probes share: only acpmux's own unit with the daemon
/// under it lifts the Cloud VM mark, and a host without the mark is never one.
#[test]
#[cfg(unix)]
fn the_cloud_check_lifts_the_mark_only_for_acpmux_service() {
    let said = |peer: &FakePeer| {
        let script = format!("{}echo \"cloud=$acpmux_cloud\"", cloud_vm_check());
        let out = peer.exec(&script, None).unwrap();
        assert!(out.ok, "{}", out.stderr);
        out.stdout.lines().last().unwrap_or_default().to_owned()
    };
    for shape in CLOUD_SHAPES {
        let peer = cloud_vm(&format!("cloud-check-{}", shape.replace(' ', "-")), shape);
        assert_eq!(said(&peer), "cloud=1", "{shape}");
    }
    let own = FakePeer::new("cloud-check-own");
    assert_eq!(said(&own), "cloud=", "no mark");
    own.write("etc/cmux/vm-kind", "team\n");
    assert_eq!(said(&own), "cloud=", "acpmux.service runs the daemon");
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
    let opts = UpdateOptions {
        binary_dir: None,
        if_idle: false,
        keep_newer: false,
        allow_downgrade: false,
        caller: None,
        now: true,
    };
    let up = update_peer(&peer, &opts);
    assert_eq!((up.outcome, up.reason.as_deref()), (Outcome::NeedsBinary, Some("wrongPlatform")));
    let why = up.error.as_deref().unwrap_or("");
    assert!(why.contains("--binary-dir") && why.contains("fake is "), "{why}");
    peer.assert_untouched(&fake_acpmux(OLD, Some(OLD)), OLD);
}

#[test]
#[cfg(unix)]
fn keep_newer_leaves_a_later_or_own_build_and_updates_an_older_one() {
    // A self-update moved the peer past the pushed build (a later day).
    let peer = FakePeer::new("keep-newer");
    peer.write("daemon", "fedcba987 2026-10-25");
    peer.offer(NEW, Some(NEW));
    let up = peer.update_with(false, true);
    assert_eq!((up.outcome, up.reason.as_deref()), (Outcome::Current, Some("newer")), "{up:?}");
    assert!(!up.outcome.failed());
    peer.assert_untouched(&fake_acpmux(OLD, Some(OLD)), "fedcba987 2026-10-25");
    // Without --keep-newer it moves back, as before.
    assert_eq!(peer.update(false).outcome, Outcome::Updated);

    // Someone's own build (local changes) is kept, whatever its date.
    let peer = FakePeer::new("keep-own");
    peer.write("daemon", "fedcba987+dirty.0badf00d 2026-10-01");
    peer.offer(NEW, Some(NEW));
    let up = peer.update_with(false, true);
    assert_eq!((up.outcome, up.reason.as_deref()), (Outcome::Current, Some("ownBuild")), "{up:?}");
    peer.assert_untouched(&fake_acpmux(OLD, Some(OLD)), "fedcba987+dirty.0badf00d 2026-10-01");

    // Someone's own build is kept also when the pushed binary names no
    // build (a source-archive build stamped `nogit`).
    let peer = FakePeer::new("keep-own-unnamed");
    peer.write("daemon", "fedcba987+dirty.0badf00d 2026-10-01");
    peer.offer("nogit 2026-10-26", Some("nogit 2026-10-26"));
    let up = peer.update_with(false, true);
    assert_eq!((up.outcome, up.reason.as_deref()), (Outcome::Current, Some("ownBuild")), "{up:?}");
    peer.assert_untouched(&fake_acpmux(OLD, Some(OLD)), "fedcba987+dirty.0badf00d 2026-10-01");

    // An older build is still updated.
    let peer = FakePeer::new("keep-older");
    peer.offer(NEW, Some(NEW));
    assert_eq!(peer.update_with(false, true).outcome, Outcome::Updated);
}

/// A fake acpmux of `build` ([`fake_acpmux`]) that carries the commit-time
/// stamp `committed` (Unix seconds) as a shipped binary does.
#[cfg(unix)]
fn stamped_acpmux(build: &str, runs: Option<&str>, committed: u64) -> String {
    format!("{}# acpmux-commit-time={committed};\n", fake_acpmux(build, runs))
}

/// gcp-codex-swarm-08, 2026-11-15: its self-update timer installed
/// af330854e at 13:31, then a cmux app whose bundled acpmux was the older
/// c144c01f3 (same day, so `--keep-newer` saw nothing newer) pushed that
/// one at 13:40 and restarted the daemon. The host's install script now
/// refuses a binary built from an older commit than the installed one,
/// whatever the pusher asked, and changes nothing.
#[test]
#[cfg(unix)]
fn a_push_of_an_older_build_onto_a_newer_host_is_refused_on_the_host() {
    let peer = FakePeer::new("downgrade");
    let installed = stamped_acpmux(OLD, Some(OLD), 1_794_748_257);
    peer.exe(".local/bin/acpmux", &installed);
    peer.exe(&format!("binaries/acpmux-{TARGET}"), &stamped_acpmux(NEW, Some(NEW), 1_794_744_982));
    for keep_newer in [false, true] {
        let up = peer.update_with(false, keep_newer);
        assert_eq!(
            (up.outcome, up.reason.as_deref()),
            (Outcome::Current, Some("newerInstalled")),
            "{up:?}"
        );
        let why = up.error.as_deref().unwrap_or("");
        assert!(why.contains("newer commit") && why.contains("--allow-downgrade"), "{why}");
        assert_eq!(peer.read(".local/bin/acpmux"), installed);
        assert!(!peer.exists(".local/bin/acpmux.prev"));
        assert!(!peer.exists(".local/bin/.acpmux-new"));
        assert_eq!(peer.daemon(), OLD);
    }
    // A binary from before the stamp is older than any stamped one.
    peer.offer(NEW, Some(NEW));
    let up = peer.update_with(false, true);
    assert_eq!((up.outcome, up.reason.as_deref()), (Outcome::Current, Some("newerInstalled")));
    assert_eq!(peer.read(".local/bin/acpmux"), installed);
    assert!(up.line().starts_with("kept: "), "{}", up.line());

    // --allow-downgrade moves it back, keeping the newer one as acpmux.prev.
    let older = stamped_acpmux(NEW, Some(NEW), 1_794_744_982);
    peer.exe(&format!("binaries/acpmux-{TARGET}"), &older);
    let opts = UpdateOptions {
        binary_dir: Some(peer.home.join("binaries")),
        if_idle: false,
        keep_newer: false,
        allow_downgrade: true,
        caller: None,
        now: true,
    };
    let up = update_peer(&peer, &opts);
    assert_eq!(up.outcome, Outcome::Updated, "{up:?}");
    assert_eq!(peer.read(".local/bin/acpmux"), older);
    assert_eq!(peer.read(".local/bin/acpmux.prev"), installed);

    // The host's own install step refuses too, for a pusher that never asks
    // first (as an older acpmux does not): nothing installed, nothing staged.
    let peer = FakePeer::new("downgrade-host-side");
    peer.exe(".local/bin/acpmux", &installed);
    peer.exe(&format!("binaries/acpmux-{TARGET}"), &stamped_acpmux(NEW, Some(NEW), 1_794_744_982));
    let binary = peer.home.join(format!("binaries/acpmux-{TARGET}"));
    let e = push_update(&peer, &binary, None, false, false).expect_err("a refused push");
    assert!(e.is::<NewerInstalled>(), "{e:#}");
    assert!(e.to_string().contains("newer commit"), "{e:#}");
    assert_eq!(peer.read(".local/bin/acpmux"), installed);
    assert!(!peer.exists(".local/bin/acpmux.prev"));
    assert!(!peer.exists(".local/bin/.acpmux-new"));
    assert!(push_update(&peer, &binary, None, true, false).is_ok());
    assert_eq!(peer.read(".local/bin/acpmux.prev"), installed);

    // A newer push onto a stamped host goes in as before.
    let peer = FakePeer::new("upgrade-stamped");
    peer.exe(".local/bin/acpmux", &stamped_acpmux(OLD, Some(OLD), 1_794_744_982));
    let newer = stamped_acpmux(NEW, Some(NEW), 1_794_748_257);
    peer.exe(&format!("binaries/acpmux-{TARGET}"), &newer);
    assert_eq!(peer.update_with(false, true).outcome, Outcome::Updated);
    assert_eq!(peer.read(".local/bin/acpmux"), newer);
}

/// The host's restart stamp says an update restarted its daemon `ago`
/// seconds ago by its clock (negative: in the future, a clock that went back).
#[cfg(unix)]
fn restarted_ago(peer: &FakePeer, ago: i64) {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    let at = i64::try_from(now).unwrap_or(i64::MAX).saturating_sub(ago);
    peer.write(".acpmux/update.restarted", &format!("{at}\n"));
}

/// The host's own install step keeps the restart window, for a pusher that
/// never checks it first (an acpmux from before the check, or one that
/// skips it): inside the window nothing is installed or staged, and the
/// daemon is left alone.
#[test]
#[cfg(unix)]
fn the_hosts_install_step_refuses_a_push_inside_the_restart_window() {
    let peer = FakePeer::new("window-host-side");
    restarted_ago(&peer, 5 * 60);
    peer.offer(NEW, Some(NEW));
    let installed = peer.read(".local/bin/acpmux");
    let binary = peer.home.join(format!("binaries/acpmux-{TARGET}"));
    let e = push_update(&peer, &binary, None, false, false).expect_err("refused inside the window");
    let why = e.to_string();
    assert!(why.contains("restart window: last update restart 5 min ago"), "{why}");
    assert!(why.contains("--now"), "{why}");
    assert_eq!(peer.read(".local/bin/acpmux"), installed);
    assert!(!peer.exists(".local/bin/acpmux.prev"));
    assert!(!peer.exists(".local/bin/.acpmux-new"));
    assert_eq!(peer.daemon(), OLD);
    assert!(e.is::<RestartWindow>(), "{e:#}");
    // `--now` passes the host's check.
    assert!(push_update(&peer, &binary, None, false, true).is_ok());
    assert_eq!(peer.read(".local/bin/acpmux"), fake_acpmux(NEW, Some(NEW)));

    // The host's exemptions, each decided on the host.
    let exempt = |tag: &str, set: &dyn Fn(&FakePeer)| {
        let peer = FakePeer::new(tag);
        restarted_ago(&peer, 5 * 60);
        set(&peer);
        peer.offer(NEW, Some(NEW));
        let binary = peer.home.join(format!("binaries/acpmux-{TARGET}"));
        let pushed = push_update(&peer, &binary, None, false, false);
        assert!(pushed.is_ok(), "{tag}: {pushed:?}");
        assert_eq!(peer.read(".local/bin/acpmux"), fake_acpmux(NEW, Some(NEW)), "{tag}");
    };
    // A daemon that does not run has nothing to wake.
    exempt("window-down", &|p: &FakePeer| {
        let _ = std::fs::remove_file(p.home.join("daemon"));
    });
    // A stamp from the host's future (its clock went back) is ignored.
    exempt("window-future", &|p: &FakePeer| restarted_ago(p, -(2 * 60 * 60)));
    // The window is the host's: two minutes, or 0 (off), in its file.
    exempt("window-short", &|p: &FakePeer| p.write(".acpmux/update.restart-window", "120\n"));
    exempt("window-off", &|p: &FakePeer| p.write(".acpmux/update.restart-window", "0\n"));
}

/// The window's length comes from the host: its file, else the daemon
/// unit's `ACPMUX_UPDATE_RESTART_WINDOW_SECS`; the pusher's own environment
/// has no say.
#[test]
#[cfg(unix)]
fn the_restart_window_is_the_hosts_own() {
    let peer = FakePeer::new("window-unit-env");
    restarted_ago(&peer, 5 * 60);
    peer.write(
        &format!("{UNITS}/acpmux.service.d/window.conf"),
        "[Service]\nEnvironment=ACPMUX_UPDATE_RESTART_WINDOW_SECS=120\n",
    );
    let opts = UpdateOptions {
        binary_dir: Some(peer.home.join("binaries")),
        if_idle: false,
        keep_newer: false,
        allow_downgrade: false,
        caller: None,
        now: false,
    };
    // The unit's two minutes are over, five minutes after the last restart.
    peer.offer(NEW, Some(NEW));
    let up = update_peer(&peer, &opts);
    assert_eq!(up.outcome, Outcome::Updated, "{up:?}");
    // The file's hour wins over the unit's two minutes.
    restarted_ago(&peer, 5 * 60);
    peer.write(".acpmux/update.restart-window", "3600\n");
    peer.offer("c3d4e5f6a 2026-10-23", Some("c3d4e5f6a 2026-10-23"));
    let up = update_peer(&peer, &opts);
    assert_eq!(
        (up.outcome, up.reason.as_deref()),
        (Outcome::Busy, Some("restartWindow")),
        "{up:?}"
    );
    assert!(up.line().starts_with("left alone: restart window: "), "{}", up.line());
    assert_eq!(peer.daemon(), NEW);
}

/// `host setup` installs through the host's own install step too: inside
/// the restart window it refuses, and the installed binary stays.
#[test]
#[cfg(unix)]
fn a_host_setup_inside_the_restart_window_refuses_and_changes_nothing() {
    let peer = FakePeer::new("window-setup");
    restarted_ago(&peer, 5 * 60);
    let installed = peer.read(".local/bin/acpmux");
    let e = push_binary(&peer, DAEMON_BIN, false, false).expect_err("refused inside the window");
    let why = format!("{e:#}");
    assert!(why.contains("restart window: last update restart 5 min ago"), "{why}");
    assert!(why.contains("--now"), "{why}");
    assert_eq!(peer.read(".local/bin/acpmux"), installed);
    assert!(!peer.exists(".local/bin/acpmux.new"));
    assert_eq!(peer.daemon(), OLD);
    // `host setup` asks first, so nothing is copied, and refuses.
    let opts = SetupOptions { port: 47811, auto_update: true, allow_downgrade: false, now: false };
    let e = setup_locked(&peer, &opts).expect_err("refused inside the window");
    assert!(e.is::<RestartWindow>(), "{e:#}");
    assert!(e.to_string().contains("restart window: last update restart 5 min ago"), "{e:#}");
    assert!(!peer.exists(".local/bin/acpmux.new"));
    assert_eq!(peer.read(".local/bin/acpmux"), installed);

    // The window's length is the daemon unit's for setup too (review of
    // #43709): a unit with two hours holds setup 61 minutes after a restart,
    // where the default hour would let it through.
    restarted_ago(&peer, 61 * 60);
    peer.write(
        &format!("{UNITS}/acpmux.service.d/window.conf"),
        "[Service]\nEnvironment=ACPMUX_UPDATE_RESTART_WINDOW_SECS=7200\n",
    );
    let e = setup_locked(&peer, &opts).expect_err("the unit's window holds setup");
    assert!(e.is::<RestartWindow>(), "{e:#}");
    assert!(e.to_string().contains("last update restart 61 min ago"), "{e:#}");
    assert_eq!(peer.read(".local/bin/acpmux"), installed);
}

#[test]
fn a_binarys_commit_time_is_read_from_its_bytes() {
    let bytes =
        b"\0x acpmux-commit-time=[0-9]+; acpmux-commit-time=;\0acpmux-commit-time=1794748257;\0";
    assert_eq!(embedded_commit_time(bytes), Some(1_794_748_257));
    assert_eq!(embedded_commit_time(b"acpmux-commit-time=0;"), Some(0));
    assert_eq!(embedded_commit_time(b"acpmux 1.0.0 (a1b2c3d4e 2026-10-21)"), None);
}

#[test]
fn a_build_is_kept_over_an_older_days_or_as_someones_own() {
    let new = Some(NEW);
    assert_eq!(keeps_over("fedcba987 2026-10-25", new), Some("newer"));
    assert_eq!(keeps_over("fedcba987+dirty.0badf00d 2026-10-01", new), Some("ownBuild"));
    assert_eq!(keeps_over(NEW, new), None, "the same day is not newer");
    assert_eq!(keeps_over(OLD, new), None);
    assert_eq!(keeps_over("fedcba987", new), None, "no date is not newer");
    assert_eq!(keeps_over("fedcba987 2026-10-25", Some("a1b2c3d4e")), None);
    let own = "fedcba987+dirty.0badf00d 2026-10-01";
    assert_eq!(keeps_over(own, None), Some("ownBuild"), "own, whatever is pushed");
    assert_eq!(keeps_over("fedcba987 2026-10-25", None), None, "no pushed date: not newer");
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

/// `binary` (a fake acpmux) whose daemon answers only at `socket`: a daemon
/// whose home or socket a drop-in of `acpmux.service` moved.
#[cfg(unix)]
fn listening_at(socket: &str, binary: &str) -> String {
    let check = format!(
        "#!/bin/sh\nif [ \"$*\" = \"--json daemon status\" ] && [ \"$ACPMUX_SOCKET\" != '{socket}' ]; then printf '{{\"running\": false}}\\n'; exit 0; fi\n"
    );
    binary.replacen("#!/bin/sh\n", &check, 1)
}

#[path = "host_update_rollback_tests.rs"]
mod rollback;

#[cfg(unix)]
#[path = "host_lock_tests.rs"]
mod lock;

#[cfg(unix)]
#[path = "host_self_update_tests.rs"]
mod self_update;

/// The line of `script` that has a `case` inside a `$( )`, if any. macOS's
/// `/bin/sh` (bash 3.2) reads a case pattern's `)` there as the end of the
/// substitution and refuses the whole script ("syntax error near unexpected
/// token `;;'"), while dash and newer bash take it, so a parse on Linux
/// misses it. Quotes (each `$( )` has its own double quotes), backslashes
/// and `#` comments are read as sh reads them.
fn case_in_substitution(script: &str) -> Option<&str> {
    let bytes = script.as_bytes();
    // One frame per open `(`: whether it is a `$( )`, and whether a double
    // quote is open inside it. The bottom frame is the script itself.
    let mut frames = vec![(false, false)];
    let mut single = false;
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        let double = frames.last().is_some_and(|f| f.1);
        let word_start = i == 0 || matches!(bytes[i - 1], b' ' | b'\t' | b'\n' | b';' | b'(');
        if single {
            single = b != b'\'';
        } else if b == b'\\' {
            i += 1;
        } else if b == b'\'' && !double {
            single = true;
        } else if b == b'"' {
            if let Some(f) = frames.last_mut() {
                f.1 = !f.1;
            }
        } else if b == b'#' && !double && word_start {
            i = script[i..].find('\n').map_or(bytes.len(), |n| i + n);
        } else if b == b'(' && (!double || (i > 0 && bytes[i - 1] == b'$')) {
            let subst = i > 0 && bytes[i - 1] == b'$' && bytes.get(i + 1) != Some(&b'(');
            frames.push((subst, false));
        } else if b == b')' && !double && frames.len() > 1 {
            frames.pop();
        } else if !double
            && script[i..].starts_with("case ")
            && word_start
            && frames.iter().any(|f| f.0)
        {
            let start = script[..i].rfind('\n').map_or(0, |n| n + 1);
            let end = script[i..].find('\n').map_or(script.len(), |n| i + n);
            return Some(&script[start..end]);
        }
        i += 1;
    }
    None
}

/// Every script an update, setup or enroll runs on a host parses under
/// macOS's `/bin/sh`: nightly 2b74e78's restart window check had a `case`
/// in a `$( )`, so every push to a Mac failed before it changed anything
/// (`machine enroll`'s install step: "syntax error near unexpected token").
#[test]
fn the_host_scripts_keep_case_out_of_command_substitutions() {
    assert!(case_in_substitution("x=$(case a in a) echo;; esac)").is_some(), "the detector");
    assert!(case_in_substitution("case \"$(uname)\" in Linux*) x=$(date);; esac").is_none());
    // An apostrophe in a comment or a double-quoted string hides nothing.
    let hidden = "  # macOS's sh\n  x=$(case \"$(uname)\" in Linux*) date;; esac) || x='?'";
    assert!(case_in_substitution(hidden).is_some(), "past a comment's apostrophe");
    assert!(case_in_substitution("echo \"it's\"; x=$(case a in a) :;; esac)").is_some());
    assert!(case_in_substitution("x=\"$(echo \"a\")\"; case b in b) :;; esac").is_none());
    for (name, script) in [
        ("restart window", restart_window_check()),
        ("downgrade", downgrade_check()),
        ("probe", probe_script(false, false)),
        ("probe if idle", probe_script(true, false)),
        ("install pushed", INSTALL_PUSHED.to_owned()),
    ] {
        assert_eq!(case_in_substitution(&script), None, "{name}");
    }
}
