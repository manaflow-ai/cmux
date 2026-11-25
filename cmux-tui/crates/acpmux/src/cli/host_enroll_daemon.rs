//! The daemon step of `host enroll` and `host doctor` (cli/host_enroll.rs):
//! the port the host's daemon serves the peer link on, and whether to start,
//! restart or leave it. A daemon on another port than a known peer's is
//! never moved from here.

use super::*;

/// The port the daemon serves the peer link on: the running daemon's own
/// listener (its `daemon status`), else the config's. Err(why) when the
/// config gives the link no listener or no token, which the link reads.
fn listener_port(probe: &Probe) -> Result<u16, String> {
    let cfg: Value = serde_json::from_str(&probe.config).unwrap_or(Value::Null);
    let configured = cfg.pointer("/websocket/listen").and_then(Value::as_str);
    let has_token =
        cfg.pointer("/websocket/token").and_then(Value::as_str).is_some_and(|t| !t.is_empty());
    let running = probe.running.as_ref().and_then(|run| run.listen.as_deref());
    match running.or(configured) {
        None => Err("no WebSocket listener is configured".into()),
        Some(_) if !has_token => Err("the WebSocket listener has no token".into()),
        Some(l) => port_of(l).ok_or_else(|| format!("the WebSocket listener {l} names no port")),
    }
}

/// The port of a `host:port` listen address.
fn port_of(listen: &str) -> Option<u16> {
    listen.rsplit_once(':').and_then(|(_, p)| p.parse::<u16>().ok()).filter(|p| *p > 0)
}

/// A daemon that listens on `listening` while the peer link uses `port`:
/// never moved from here (another peer or person may use that port, and
/// the port may be another daemon's), so the step fails before it changes
/// anything, naming both ways to line them up.
fn port_mismatch(host: &str, name: &str, whose: &str, listening: u16, port: u16) -> StepResult {
    let url = hosts::ssh_peer_url(host, listening);
    fail(
        Step::Daemon,
        format!("{whose} listens on port {listening}, the peer uses port {port}"),
        format!(
            "Point the peer at the daemon with `acpmux machine add {name} {url}`, then check again; or set websocket.listen to 127.0.0.1:{port} in {}/config.json on {host} and restart that daemon.",
            hosts::REMOTE_HOME
        ),
    )
}

/// The daemon of the acpmux the host uses, judged.
#[derive(Debug)]
pub(super) enum Verdict {
    /// Nothing to repair from here: ours and current, or cmux's own.
    Done(StepResult),
    /// Ours, of another build: it serves the peer link, a restart updates it.
    OtherBuild(StepResult),
    /// Ours and not usable: why.
    Repair(String),
}

/// The daemon judged, and the port the peer link uses: `want` (a known
/// peer's), else the one the daemon listens on, else the default.
pub(super) fn judge_daemon(
    host: &str,
    name: &str,
    probe: &Probe,
    want: Option<u16>,
) -> (Verdict, u16) {
    let build = crate::hub::build();
    let listening = listener_port(probe);
    // A daemon bound without a usable config (`--listen`, no token) keeps
    // its port when the config is written.
    let bound = probe.running.as_ref().and_then(|run| run.listen.as_deref()).and_then(port_of);
    let port =
        want.or(listening.as_ref().ok().copied()).or(bound).unwrap_or(crate::peer::SSH_PEER_PORT);
    let used = probe.in_use();
    if let Some(used) = used.as_ref().filter(|u| u.app) {
        // cmux owns this daemon: never start, configure or restart it here.
        let Some(pid) = used.pid else {
            let result = fail(
                Step::Daemon,
                format!("cmux is installed on {host} but its acpmux daemon is not running"),
                format!("Open cmux on {host}, then check again."),
            );
            return (Verdict::Done(result), port);
        };
        let result = match listening {
            Err(why) => fail(
                Step::Daemon,
                format!("cmux's own daemon runs on {host}, but {why}"),
                format!(
                    "Give the daemon a WebSocket listener on 127.0.0.1:{port} with a token in {}/config.json on {host}, then restart cmux there.",
                    hosts::REMOTE_HOME
                ),
            ),
            Ok(l) if l != port => port_mismatch(host, name, "cmux's own daemon", l, port),
            Ok(_) => {
                let ok =
                    format!("cmux's own daemon runs, pid {pid}, build {build}, on port {port}");
                app_build(Step::Daemon, host, used, &ok)
            }
        };
        return (Verdict::Done(result), port);
    }
    let verdict = match listening {
        // A daemon bound on another port than the peer's (run with
        // `--listen` and `--token`, its config lacking one): refused before
        // the config is written, as below.
        Err(_) if bound.is_some_and(|b| b != port) => {
            let b = bound.unwrap_or(port);
            Verdict::Done(port_mismatch(host, name, "the daemon", b, port))
        }
        Err(why) => Verdict::Repair(why),
        // Configured or running on another port than the peer's: refused
        // before any change (a stopped daemon's listener is kept too).
        Ok(l) if l != port => Verdict::Done(port_mismatch(host, name, "the daemon", l, port)),
        Ok(_) => match used.and_then(|u| u.pid.map(|pid| (pid, u.build))) {
            None => Verdict::Repair("the daemon is not running".into()),
            Some((_, Some(b))) if b != build => {
                let result = StepResult::new(
                    Step::Daemon,
                    StepState::Warn,
                    format!("the daemon runs build {b}, this is {build}"),
                );
                // A different build is not a protocol verdict. The peer step
                // negotiates with this daemon; its own updater owns upgrades.
                if foreign_platform(&probe.uname) {
                    return (Verdict::Done(result), port);
                }
                let result = result
                    .with_fix(format!("Run `acpmux machine update {name}`."))
                    .with_reason("peer_version_skew")
                    .with_try(format!("acpmux machine update {name}"));
                Verdict::OtherBuild(result)
            }
            Some((pid, _)) => Verdict::Done(StepResult::new(
                Step::Daemon,
                StepState::Ok,
                format!("running, pid {pid}, build {build}, on port {port}"),
            )),
        },
    };
    (verdict, port)
}

/// The daemon step, and the port the peer link uses. With `fix`, a daemon
/// missing its listener, stopped or of another build is configured on that
/// port (an existing listener and token kept) and restarted; one listening
/// on another port than a known peer's is left alone.
pub(super) fn daemon(
    r: &dyn Remote,
    name: &str,
    want: Option<u16>,
    fix: bool,
) -> (StepResult, u16) {
    let bwrap = std::cell::RefCell::new(None);
    let (result, port) = daemon_only(r, name, want, fix, &bwrap);
    (sandbox(r, result, bwrap.into_inner().as_deref(), fix), port)
}

/// The daemon step with the host's sandbox (`bwrap`, [`PROBE_BWRAP`]): a Linux
/// host that cannot make one refuses every session another machine starts
/// there, so a passing step warns with the fix; `fix` installs a missing
/// bubblewrap as root or when sudo needs no password. A failed step stays as it is.
fn sandbox(r: &dyn Remote, result: StepResult, bwrap: Option<&str>, fix: bool) -> StepResult {
    let passed = matches!(result.state, StepState::Ok | StepState::Fixed | StepState::Warn);
    let Some(state) = bwrap.filter(|s| passed && *s != "ok") else { return result };
    if fix
        && state == "missing"
        && hosts::run(r, &super::super::host_sandbox::install_script()).is_ok()
    {
        let detail = format!(
            "{}; installed bubblewrap, so sessions from other machines run sandboxed here",
            result.detail
        );
        return StepResult { state: StepState::Fixed, detail, ..result };
    }
    let detail = format!("{}; {}", result.detail, super::super::host_sandbox::detail(state));
    let command = r
        .exec(&super::super::host_sandbox::fix_script(), None)
        .ok()
        .filter(|out| out.ok)
        .map(|out| out.stdout);
    let fix = format!("On {}: {}", r.host(), super::super::host_sandbox::fix(command.as_deref()));
    StepResult { state: StepState::Warn, detail, fix: Some(fix), ..result }
}

fn daemon_only(
    r: &dyn Remote,
    name: &str,
    want: Option<u16>,
    fix: bool,
    bwrap: &std::cell::RefCell<Option<String>>,
) -> (StepResult, u16) {
    let host = r.host();
    let judge = |r: &dyn Remote| match probe(r) {
        Ok(p) => {
            bwrap.replace(p.bwrap.clone());
            judge_daemon(host, name, &p, want)
        }
        Err(e) => (Verdict::Repair(format!("{e:#}")), want.unwrap_or(crate::peer::SSH_PEER_PORT)),
    };
    let (verdict, port) = judge(r);
    let why = match verdict {
        Verdict::Done(result) => return (result, port),
        Verdict::OtherBuild(result) => {
            if !fix {
                return (result, port);
            }
            result.detail
        }
        Verdict::Repair(why) => why,
    };
    let look = format!("Run `{DAEMON_BIN} daemon start` on {host} to see why it does not start.");
    if !fix {
        let next = format!("Run the check with --fix to configure and start the daemon on {host}.");
        return (fail(Step::Daemon, why, next), port);
    }
    let started = hosts::lock_to_install(r)
        .and_then(|lock| hosts::install_daemon(&lock.fence(r), port, true));
    let auto_update_off = match started {
        Ok((_, off)) => off.map(|why| format!("; auto-update off: {why}")).unwrap_or_default(),
        Err(e) => {
            return (fail(Step::Daemon, format!("{why}; starting it failed: {e:#}"), look), port);
        }
    };
    // Where it listens now: a port another daemon holds moved it to a free
    // one (`daemon.rs`), which the peer then uses unless it is a known one.
    let (after, port) = judge(r);
    let result = match after {
        Verdict::Done(after) if matches!(after.state, StepState::Ok | StepState::Warn) => {
            let detail = format!("{why}; now {}{auto_update_off}", after.detail);
            StepResult::new(Step::Daemon, StepState::Fixed, detail)
        }
        Verdict::Done(after) => {
            let next = after.fix.unwrap_or(look);
            fail(Step::Daemon, format!("{why}; after a restart, {}", after.detail), next)
        }
        Verdict::OtherBuild(after) => {
            fail(Step::Daemon, format!("{why}; after a restart, {}", after.detail), look)
        }
        Verdict::Repair(after) => {
            fail(Step::Daemon, format!("{why}; after a restart, {after}"), look)
        }
    };
    (result, port)
}
