//! One acpmux per Chief home (hq-6d 2026-10-14): every Chief brain the
//! daemon's supervisor starts (cmux-tui-core chief_brains.rs) uses the Chief
//! home's acpmux, `<home>/acpmux`, the default Chief's, with
//! `OPTCHAT_ACPMUX_SHARED=1`. Through the real `optchat-chief` binary and a
//! fake acpmux daemon that holds the sessions of two Chiefs and a person:
//!
//! - a Chief's `agents` verbs list, prompt, allow and deny only its own
//!   children (`mux.parent` = `optchat-chief:<its home id>`): another Chief's
//!   session, by name or id, is refused and gets no request;
//! - `end-sessions` stops only that Chief's sessions (its turns and
//!   compactor, `cmux.chief` = its home id, and its children), never another
//!   Chief's or the person's, and never shuts the daemon down;
//! - a shared host that started the daemon leaves it running when it stops
//!   (other Chiefs use it) and ends only its own sessions; the daemon's
//!   `ACPMUX_CHIEF_MUX_HOME` is the Chief home (`CMUX_CHIEF_HOME`), so the
//!   app's Chief-home check keeps it;
//! - a host started with its own `ACPMUX_HOME` and no shared flag (the VM
//!   Chiefs, one acpmux each) keeps its own daemon: its Chief home is its
//!   `MUX_HOME`, and it shuts the daemon it started down when it stops.

use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

use optchat_chief::paths::home_id;
use serde_json::json;

mod real_python;

/// A fake acpmux. `daemon run` listens on $ACPMUX_SOCKET (JSON-RPC lines),
/// writes its pid and its `ACPMUX_CHIEF_MUX_HOME`, lists the sessions of
/// `sessions.json` and records each kill, prompt, info and permission answer
/// in `calls`; other methods get no answer. `daemon shutdown` records the
/// call and ends it.
const FAKE: &str = r#"import json, os, signal, socket, sys, threading
home = os.environ["ACPMUX_HOME"]
def record(line):
    with open(home + "/calls", "a") as f:
        f.write(line + "\n")
def serve(conn):
    f = conn.makefile("rwb")
    for raw in f:
        msg = json.loads(raw)
        method, params, mid = msg.get("method"), msg.get("params") or {}, msg.get("id")
        if mid is None:
            continue
        if method == "initialize":
            result = {"protocolVersion": 1}
        elif method == "_acpmux/sessions":
            try:
                result = {"sessions": json.load(open(home + "/sessions.json"))}
            except FileNotFoundError:
                result = {"sessions": []}
        elif method in ("_acpmux/kill", "session/prompt", "_acpmux/info", "_acpmux/permission_respond"):
            record(method + " " + params.get("sessionId", ""))
            result = {"pending": []} if method == "_acpmux/info" else {}
        else:
            continue
        f.write((json.dumps({"jsonrpc": "2.0", "id": mid, "result": result}) + "\n").encode())
        f.flush()
if sys.argv[1:2] == ["run"]:
    s = socket.socket(socket.AF_UNIX); s.bind(os.environ["ACPMUX_SOCKET"]); s.listen(16)
    open(home + "/chief-mux-home", "w").write(os.environ.get("ACPMUX_CHIEF_MUX_HOME", ""))
    keys = ["MUX_HOME", "MUX_AGENT_TOKEN_FILE", "OPTCHAT_CHIEF_PARTICIPANT", "MUX_CHIEF_TITLE", "OPTCHAT_ACPMUX_SHARED", "CMUX_CHIEF_HOME"]
    json.dump({k: os.environ[k] for k in keys if k in os.environ}, open(home + "/identity.json", "w"))
    open(home + "/run.pid", "w").write(str(os.getpid()))
    while True:
        conn = s.accept()[0]
        threading.Thread(target=serve, args=(conn,), daemon=True).start()
elif sys.argv[1:2] == ["shutdown"]:
    record("shutdown")
    os.kill(int(open(home + "/run.pid").read()), signal.SIGTERM)
"#;

/// The fake's interpreter image (`ACPMUX_BIN`); the script is `daemon` in
/// `acpmux_home`, where it runs.
fn fake_acpmux(acpmux_home: &Path) -> PathBuf {
    std::fs::create_dir_all(acpmux_home).unwrap();
    std::fs::write(acpmux_home.join("daemon"), FAKE).unwrap();
    real_python::image()
}

fn session(id: &str, name: &str, tags: serde_json::Value) -> serde_json::Value {
    json!({"sessionId": id, "name": name, "harness": "claude", "cwd": "/",
           "status": "idle", "tags": tags})
}

/// The sessions of Chief homes `a` and `b` and one of the person.
fn sessions(a: &Path, b: &Path) -> serde_json::Value {
    let (ia, ib) = (home_id(a), home_id(b));
    json!([
        session("s-a-turn", &format!("optchat-{ia}-turn"),
                json!({"cmux.chief": ia, "cmux.chief.role": "turn"})),
        session("s-a-sub", &format!("optchat-sub-{ia}-a1"),
                json!({"mux.parent": format!("optchat-chief:{ia}")})),
        session("s-b-turn", &format!("optchat-{ib}-turn"),
                json!({"cmux.chief": ib, "cmux.chief.role": "turn"})),
        session("s-b-sub", &format!("optchat-sub-{ib}-a1"),
                json!({"mux.parent": format!("optchat-chief:{ib}")})),
        session("s-person", "my-chat", json!({})),
    ])
}

fn wait_for(what: &str, limit: Duration, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + limit;
    while !done() {
        assert!(Instant::now() < deadline, "{what} did not happen within {limit:?}");
        std::thread::sleep(Duration::from_millis(50)); // test harness: poll a file the fake writes
    }
}

fn alive(pid: i32) -> bool {
    // SAFETY: signal 0 only checks that the process exists.
    unsafe { libc::kill(pid, 0) == 0 }
}

fn calls(acpmux_home: &Path) -> Vec<String> {
    std::fs::read_to_string(acpmux_home.join("calls"))
        .unwrap_or_default()
        .lines()
        .map(str::to_owned)
        .collect()
}

/// Kills the given pids (this test's fake daemons and hosts) when dropped,
/// also when an assertion fails.
struct Leftovers(Vec<i32>);

impl Drop for Leftovers {
    fn drop(&mut self) {
        for &pid in &self.0 {
            // SAFETY: pids this test started; a dead one returns ESRCH.
            unsafe { libc::kill(pid, libc::SIGKILL) };
        }
    }
}

/// `optchat-chief ARGS` as the Chief of `mux_home` on the shared acpmux.
fn chief(mux_home: &Path, acpmux_home: &Path, bin: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_optchat-chief"))
        .args(args)
        .env("MUX_HOME", mux_home)
        .env("ACPMUX_BIN", bin)
        .env("ACPMUX_HOME", acpmux_home)
        .env("ACPMUX_SOCKET", acpmux_home.join("acpmux.sock"))
        .env("OPTCHAT_ACPMUX_SHARED", "1")
        .stdin(Stdio::null())
        .output()
        .unwrap()
}

#[test]
fn two_chiefs_on_one_acpmux_reach_only_their_own_sessions() {
    let dir = tempfile::tempdir().unwrap();
    let chief_home = dir.path().join("h");
    let (a, b) = (chief_home.join("c/aaaa1111"), chief_home.join("c/bbbb2222"));
    let acpmux_home = chief_home.join("acpmux");
    let bin = fake_acpmux(&acpmux_home);
    std::fs::write(acpmux_home.join("sessions.json"), sessions(&a, &b).to_string()).unwrap();
    let socket = acpmux_home.join("acpmux.sock");
    let mut daemon = Command::new(&bin)
        .args(["daemon", "run"])
        .current_dir(&acpmux_home)
        .env("ACPMUX_HOME", &acpmux_home)
        .env("ACPMUX_SOCKET", &socket)
        .spawn()
        .unwrap();
    let _guard = Leftovers(vec![daemon.id() as i32]);
    wait_for("the daemon listening", Duration::from_secs(10), || {
        acpmux_home.join("run.pid").exists()
    });

    // Chief A sees its own child only.
    let listed = chief(&a, &acpmux_home, &bin, &["agents", "list"]);
    let text = String::from_utf8_lossy(&listed.stdout);
    assert!(listed.status.success(), "{listed:?}");
    assert!(text.contains(&format!("optchat-sub-{}-a1", home_id(&a))), "{text}");
    assert!(!text.contains(&home_id(&b)), "Chief A listed Chief B's session: {text}");
    assert!(!text.contains("my-chat"), "Chief A listed the person's session: {text}");

    // Chief A cannot send to, allow or deny Chief B's sessions, by name or id.
    let b_sub = format!("optchat-sub-{}-a1", home_id(&b));
    for target in [b_sub.as_str(), "s-b-sub", "s-b-turn", "s-person"] {
        for args in [
            vec!["agents", "prompt", target, "do", "this"],
            vec!["agents", "allow", target],
            vec!["agents", "deny", target],
        ] {
            let out = chief(&a, &acpmux_home, &bin, &args);
            assert!(!out.status.success(), "{args:?} reached another Chief: {out:?}");
        }
    }
    assert!(calls(&acpmux_home).is_empty(), "requests reached other sessions: {:?}", calls(&acpmux_home));

    // Ending Chief A ends its turn and its child only; the daemon stays.
    let ended = chief(&a, &acpmux_home, &bin, &["end-sessions"]);
    assert!(ended.status.success(), "{ended:?}");
    let mut got = calls(&acpmux_home);
    got.sort();
    assert_eq!(got, ["_acpmux/kill s-a-sub", "_acpmux/kill s-a-turn"]);
    assert!(daemon.try_wait().unwrap().is_none(), "the shared daemon was stopped");
    let _ = daemon.kill();
    let _ = daemon.wait();
}

/// A host on `acpmux_home` (it starts the fake there), stopped with SIGTERM
/// once the fake runs; the fake's pid.
fn host_stops(dir: &Path, mux_home: &Path, acpmux_home: &Path, shared: Option<&Path>) -> i32 {
    let bin = fake_acpmux(acpmux_home);
    let token = dir.join("agent-token");
    std::fs::write(&token, "secret\n").unwrap();
    let mut command = Command::new(env!("CARGO_BIN_EXE_optchat-chief"));
    command
        .args(["host", "--daemon-socket"])
        .arg(dir.join("missing.sock"))
        .arg("--mux-home")
        .arg(mux_home)
        .env("MUX_HOME", mux_home)
        .env("MUX_AGENT_TOKEN_FILE", &token)
        .env("ACPMUX_BIN", &bin)
        .env("ACPMUX_HOME", acpmux_home)
        .env("ACPMUX_SOCKET", acpmux_home.join("acpmux.sock"))
        .env_remove("OPTCHAT_ACPMUX_SUPERVISED")
        .env_remove("OPTCHAT_ACPMUX_SHARED")
        .env_remove("CMUX_CHIEF_HOME")
        .env("OPTCHAT_INSPECTOR", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    // A Chief's identity the shared daemon must not get (the participant
    // stays the default: a non-default one needs the owner daemon to start).
    command.env("MUX_CHIEF_TITLE", "Test Chief");
    if let Some(chief_home) = shared {
        command.env("OPTCHAT_ACPMUX_SHARED", "1").env("CMUX_CHIEF_HOME", chief_home);
    }
    let mut host = command.spawn().unwrap();
    let mut guard = Leftovers(vec![host.id() as i32]);
    let pid_file = acpmux_home.join("run.pid");
    wait_for("the host starting acpmux", Duration::from_secs(30), || {
        std::fs::read_to_string(&pid_file).is_ok_and(|p| !p.is_empty())
    });
    let fake: i32 = std::fs::read_to_string(&pid_file).unwrap().trim().parse().unwrap();
    guard.0.push(fake);
    // SAFETY: the pid is our own child.
    unsafe { libc::kill(host.id() as i32, libc::SIGTERM) };
    let mut status = None;
    wait_for("the host exiting", Duration::from_secs(30), || {
        status = host.try_wait().unwrap();
        status.is_some()
    });
    assert_eq!(status.unwrap().code(), Some(0), "a stop on request exits 0");
    guard.0.retain(|&pid| pid != host.id() as i32);
    // The caller decides about the fake; the guard must not kill it now.
    guard.0.clear();
    fake
}

#[test]
fn a_shared_host_leaves_the_chief_homes_acpmux_running_and_ends_only_its_sessions() {
    let dir = tempfile::tempdir().unwrap();
    let chief_home = dir.path().join("h");
    let (mine, other) = (chief_home.join("c/aaaa1111"), chief_home.join("c/bbbb2222"));
    let acpmux_home = chief_home.join("acpmux");
    std::fs::create_dir_all(&acpmux_home).unwrap();
    std::fs::write(acpmux_home.join("sessions.json"), sessions(&mine, &other).to_string()).unwrap();
    let fake = host_stops(dir.path(), &mine, &acpmux_home, Some(&chief_home));
    let _guard = Leftovers(vec![fake]);
    assert_eq!(
        std::fs::read_to_string(acpmux_home.join("chief-mux-home")).unwrap(),
        chief_home.display().to_string(),
        "the shared daemon's Chief home is the Chief home, not one Chief's"
    );
    // None of the starting Chief's identity reaches the daemon (its
    // sessions would act as that Chief): it looks as if the default Chief's
    // host had started it.
    let identity: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(acpmux_home.join("identity.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(
        identity,
        json!({"MUX_HOME": chief_home.display().to_string(),
               "CMUX_CHIEF_HOME": chief_home.display().to_string()}),
        "the shared daemon carries one Chief's identity"
    );
    let mut got = calls(&acpmux_home);
    got.sort();
    assert_eq!(got, ["_acpmux/kill s-a-sub", "_acpmux/kill s-a-turn"], "no shutdown, own sessions only");
    assert!(alive(fake), "the shared acpmux stopped with one Chief's host");
}

#[test]
fn a_host_with_its_own_acpmux_home_keeps_its_own_daemon() {
    let dir = tempfile::tempdir().unwrap();
    let mux_home = dir.path().join("chiefs/scout");
    let acpmux_home = dir.path().join("chiefs/scout-acpmux");
    let fake = host_stops(dir.path(), &mux_home, &acpmux_home, None);
    let _guard = Leftovers(vec![fake]);
    assert_eq!(
        std::fs::read_to_string(acpmux_home.join("chief-mux-home")).unwrap(),
        mux_home.display().to_string(),
        "its own daemon's Chief home is its MUX_HOME"
    );
    assert_eq!(calls(&acpmux_home), ["shutdown"], "it shuts the daemon it started down");
    wait_for("its daemon ending", Duration::from_secs(5), || !alive(fake));
}
