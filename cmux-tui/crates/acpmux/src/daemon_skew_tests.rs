use std::cell::{Cell, RefCell};

use serde_json::json;

use super::*;

const CLI: &str = "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux";

fn stale() -> Value {
    json!({
        "build_id": "2bd4478a3a04", "build_time": 1_794_859_912u64,
        "cli_path": CLI, "capabilities": ["daemon-build-v1"], "pid": 72464,
    })
}

fn installed(id: &str, time: u64) -> Value {
    json!({"build_identity": id, "build_time": time})
}

fn unknown(cmd: &str) -> DaemonError {
    DaemonError::Refused {
        code: "refused".into(),
        message: format!("bad request: unknown variant `{cmd}`, expected one of `identify`"),
    }
}

/// A cmux-tui daemon left running from before an update: it knows only the
/// commands in `knows` until it is restarted, which brings up the installed
/// build (another pid), knowing every command when `installed_has_it`.
struct OldDaemon {
    knows: &'static [&'static str],
    pid: u64,
    installed: Value,
    installed_has_it: bool,
    restarts: Cell<u32>,
    sent: RefCell<Vec<String>>,
}

impl OldDaemon {
    fn new(pid: u64, knows: &'static [&'static str]) -> Self {
        Self {
            knows,
            pid,
            installed: installed("221e5a18db61", 1_795_171_738),
            installed_has_it: true,
            restarts: Cell::new(0),
            sent: RefCell::new(Vec::new()),
        }
    }
}

impl RawDaemon for OldDaemon {
    fn send_once(&self, cmd: &str, _params: Value) -> Result<Value, DaemonError> {
        self.sent.borrow_mut().push(cmd.to_owned());
        let restarted = self.restarts.get() > 0;
        if cmd == IDENTIFY {
            let mut identity = stale();
            identity["pid"] = json!(self.pid);
            if restarted {
                identity["pid"] = json!(self.pid + 1);
                identity["build_id"] = self.installed["build_identity"].clone();
                identity["build_time"] = self.installed["build_time"].clone();
            }
            return Ok(identity);
        }
        if self.knows.contains(&cmd) || (restarted && self.installed_has_it) {
            Ok(json!({"answered": cmd}))
        } else {
            Err(unknown(cmd))
        }
    }

    fn installed_build(&self, cli: &Path) -> Option<Value> {
        assert_eq!(cli, Path::new(CLI), "the daemon's own CLI is asked");
        Some(self.installed.clone())
    }

    fn restart_in_place(&self, cli: &Path) -> Result<(), String> {
        assert_eq!(cli, Path::new(CLI));
        self.restarts.set(self.restarts.get() + 1);
        Ok(())
    }
}

/// The class behind #48044: not only `computer-use-endpoint`. Any command
/// newer than the daemon (here `list-workspaces`, then a later one) restarts
/// it once with the installed build and goes through.
#[test]
fn any_command_an_older_daemon_lacks_restarts_it_once_and_goes_through() {
    let daemon = OldDaemon::new(980_001, &[]);
    assert_eq!(
        request(&daemon, "list-workspaces", json!({})).unwrap(),
        json!({"answered": "list-workspaces"})
    );
    assert_eq!(daemon.restarts.get(), 1);
    assert_eq!(*daemon.sent.borrow(), ["list-workspaces", "identify", "list-workspaces"]);
    // The restarted daemon knows the next new command: no second restart.
    assert!(request(&daemon, "computer-use-endpoint", json!({})).is_ok());
    assert_eq!(daemon.restarts.get(), 1);
}

#[test]
fn a_daemon_still_lacking_the_command_after_its_restart_is_not_restarted_again() {
    let mut daemon = OldDaemon::new(980_011, &[]);
    // The installed build is newer, but it too lacks the command.
    daemon.installed_has_it = false;
    let Err(DaemonError::Refused { message, .. }) = request(&daemon, "list-workspaces", json!({}))
    else {
        panic!("still refused")
    };
    assert!(message.contains("unknown variant"), "{message}");
    // A second command meets the restarted daemon: another pid, already the
    // installed build, so nothing newer to swap in.
    let Err(DaemonError::Refused { message, .. }) = request(&daemon, "new-command", json!({}))
    else {
        panic!("still refused")
    };
    assert!(message.contains("already runs the installed build"), "{message}");
    assert_eq!(daemon.restarts.get(), 1);
}

#[test]
fn the_same_daemon_is_never_restarted_twice() {
    let daemon = OldDaemon::new(980_021, &[]);
    assert!(first_restart(Some(980_021)), "this test owns its pid");
    let Err(DaemonError::Refused { message, .. }) = request(&daemon, "list-workspaces", json!({}))
    else {
        panic!("refused")
    };
    assert!(message.contains("after a restart"), "{message}");
    assert_eq!(daemon.restarts.get(), 0);
}

#[test]
fn other_refusals_and_known_commands_never_restart() {
    let daemon = OldDaemon::new(980_031, &["list-workspaces"]);
    assert!(request(&daemon, "list-workspaces", json!({})).is_ok());
    struct Refuses;
    impl RawDaemon for Refuses {
        fn send_once(&self, _: &str, _: Value) -> Result<Value, DaemonError> {
            Err(DaemonError::Refused { code: "not_found".into(), message: "no such pane".into() })
        }
        fn restart_in_place(&self, _: &Path) -> Result<(), String> {
            panic!("a refusal that is not version skew restarts nothing")
        }
    }
    assert!(matches!(
        request(&Refuses, "close-pane", json!({})),
        Err(DaemonError::Refused { code, .. }) if code == "not_found"
    ));
    assert_eq!(daemon.restarts.get(), 0);
}

#[test]
fn nothing_newer_installed_keeps_the_refusal_with_its_reason() {
    let mut daemon = OldDaemon::new(980_041, &[]);
    daemon.installed = installed("2bd4478a3a04", 1_795_171_738);
    let Err(DaemonError::Refused { message, .. }) =
        request(&daemon, "computer-use-endpoint", json!({}))
    else {
        panic!("refused")
    };
    assert!(message.contains("already runs the installed build"), "{message}");
    assert_eq!(daemon.restarts.get(), 0);
}

/// The reported case (#48044): the app's daemon kept running from before an update.
#[test]
fn an_older_daemon_restarts_with_its_updated_cli() {
    assert_eq!(
        verdict(&stale(), Some(&installed("221e5a18db61", 1_795_171_738))),
        Verdict::Restart { cli: PathBuf::from(CLI) }
    );
    // A daemon from before identify reported its time is older too.
    let mut untimed = stale();
    untimed.as_object_mut().unwrap().remove("build_time");
    assert!(matches!(
        verdict(&untimed, Some(&installed("221e5a18db61", 1_795_171_738))),
        Verdict::Restart { .. }
    ));
}

#[test]
fn nothing_newer_installed_is_never_a_restart() {
    // The same build is installed: a restart would start it again.
    assert!(matches!(
        verdict(&stale(), Some(&installed("2bd4478a3a04", 1_795_171_738))),
        Verdict::NoNewerBuild(_)
    ));
    // An older or untimed install, a CLI that did not answer, no CLI path.
    assert!(matches!(
        verdict(&stale(), Some(&installed("old", 1_700_000_000))),
        Verdict::NoNewerBuild(_)
    ));
    assert!(matches!(
        verdict(&stale(), Some(&json!({"build_identity": "new"}))),
        Verdict::NoNewerBuild(_)
    ));
    assert!(matches!(verdict(&stale(), None), Verdict::NoNewerBuild(_)));
    let mut relative = stale();
    relative["cli_path"] = json!("bin/cmux");
    assert!(matches!(
        verdict(&relative, Some(&installed("new", u64::MAX))),
        Verdict::NoNewerBuild(_)
    ));
    // A daemon whose time is unknown (null) orders nothing.
    let mut null_time = stale();
    null_time["build_time"] = Value::Null;
    assert!(matches!(
        verdict(&null_time, Some(&installed("new", u64::MAX))),
        Verdict::NoNewerBuild(_)
    ));
}

#[test]
fn each_daemon_is_restarted_once() {
    assert!(first_restart(Some(990_001)));
    assert!(!first_restart(Some(990_001)));
    assert!(first_restart(Some(990_002)));
}
