//! Chiefs make and edit other Chiefs through the brain (Lawrence
//! 2026-10-14), against a real headless cmux-tui daemon (`CMUX_TUI_BIN`):
//!
//! - the real `optchat-chief mcp` server lists `chiefs` only when the Chief's
//!   record holds the grant, and never for a subagent;
//! - a create and an edit through the tool go over the Chief's own bound
//!   connection, where the daemon applies the ceiling;
//! - only the host's own turn gets an answer: a caller without the turn key
//!   the host gives its turn sessions (a subagent that cleared
//!   OPTCHAT_SUBAGENT, any other process) is refused;
//! - `cmux chief new|edit` in the Chief's turn reaches the daemon through the
//!   host with that key; without it the CLI refuses an agent caller.
//!
//! Run: `CMUX_TUI_BIN=<cmux-tui target>/debug/cmux-tui cargo test --test
//! chiefs_daemon -- --ignored`.

mod common;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::time::Duration;

use common::open_chat;
use optchat_chief::chief_profile::{ChiefTools, ProfileClient, TURN_KEY_ENV};
use serde_json::{Value, json};

fn bin() -> PathBuf {
    PathBuf::from(std::env::var("CMUX_TUI_BIN").expect("CMUX_TUI_BIN names a cmux-tui binary"))
}

/// The person's JSON-lines connection to the daemon (unbound, local).
struct Conn {
    writer: UnixStream,
    reader: BufReader<UnixStream>,
    next: u64,
}

impl Conn {
    fn open(socket: &Path) -> Conn {
        let stream = UnixStream::connect(socket).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(20)))
            .unwrap();
        Conn {
            writer: stream.try_clone().unwrap(),
            reader: BufReader::new(stream),
            next: 0,
        }
    }

    fn line(&mut self) -> Value {
        let mut line = String::new();
        assert!(
            self.reader.read_line(&mut line).unwrap() > 0,
            "the daemon closed"
        );
        serde_json::from_str(&line).unwrap()
    }

    fn req(&mut self, mut body: Value) -> Value {
        self.next += 1;
        body["id"] = json!(self.next);
        writeln!(self.writer, "{body}").unwrap();
        loop {
            let value = self.line();
            if value["id"] == body["id"] {
                assert_eq!(value["ok"], true, "{body} failed: {value}");
                return value["data"].clone();
            }
        }
    }

    fn v2(&mut self, operation: &str, params: Value, key: Option<&str>) -> Value {
        self.next += 1;
        let id = format!("c-{}", self.next);
        let mut params = params.as_object().cloned().unwrap_or_default();
        params.insert("machine".into(), json!("current"));
        params.insert("session".into(), json!("current"));
        let mut frame = json!({"protocol": "cmux.protocol/2", "type": "request", "id": id,
                               "operation": operation, "params": params});
        if let Some(key) = key {
            frame["idempotency_key"] = json!(key);
        }
        writeln!(self.writer, "{frame}").unwrap();
        loop {
            let value = self.line();
            if value["id"] == json!(id) && value["type"] == "response" {
                assert_eq!(value["ok"], true, "{frame} failed: {value}");
                return value["result"].clone();
            }
        }
    }

    fn token_file(&mut self, dir: &Path, participant: &str) -> PathBuf {
        let token = self
            .req(json!({"cmd": "conversation-agent-token", "participant": participant}))["token"]
            .as_str()
            .unwrap()
            .to_owned();
        let file = dir.join(format!("{participant}.token"));
        std::fs::write(&file, format!("{token}\n")).unwrap();
        file
    }

    fn names(&mut self) -> Vec<String> {
        let listed = self.v2("chief.profile.list", json!({}), None);
        listed["chiefs"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c["display_name"].as_str().unwrap().to_owned())
            .collect()
    }
}

/// A headless daemon in its own home; stopped on drop.
struct Daemon {
    dir: tempfile::TempDir,
    socket: PathBuf,
}

impl Daemon {
    fn start() -> Daemon {
        let dir = tempfile::Builder::new()
            .prefix("occ")
            .tempdir_in("/tmp")
            .unwrap();
        let socket = dir.path().join("d.sock");
        let status = cli(dir.path())
            .arg("--socket")
            .arg(&socket)
            .args(["daemon", "ensure"])
            .stdout(Stdio::null())
            .status()
            .unwrap();
        assert!(status.success(), "daemon ensure: {status}");
        Daemon { dir, socket }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = cli(self.dir.path())
            .arg("--socket")
            .arg(&self.socket)
            .args(["daemon", "stop", "--end-terminals"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
}

fn cli(home: &Path) -> Command {
    let mut command = Command::new(bin());
    command
        .env("HOME", home)
        .env("TMPDIR", home)
        .env("CMUX_TUI_STATE_DIR", home.join("state"))
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove(TURN_KEY_ENV)
        .env_remove("MUX_HOME")
        .env_remove("OPTCHAT_SUBAGENT")
        .env("LC_ALL", "C");
    command
}

/// The real `optchat-chief mcp` server with exactly the env `env` adds.
struct Mcp {
    child: std::process::Child,
    out: BufReader<std::process::ChildStdout>,
    next: u64,
}

/// The turn session name acpmux gives Lead's turn agents in these tests
/// (`TurnBinding` below: turn prefix `optchat-lead-`).
const LEAD_TURN: &str = "optchat-lead-1";

/// The binding of the test Chief hosts: a `/bin/bash` stands in for the
/// acpmux agent host (not `/bin/sh`: on macOS it runs `/bin/bash` in the
/// same pid), so a caller started by [`under_agent`] runs under a session.
fn binding() -> optchat_chief::turn_caller::TurnBinding {
    optchat_chief::turn_caller::TurnBinding {
        turn_prefix: "optchat-lead-".to_owned(),
        subagent_prefix: "optchat-sub-lead-".to_owned(),
        agent_parent: std::fs::canonicalize("/bin/bash").ok(),
    }
}

/// `command` run as the acpmux agent of session `session`: a `/bin/bash` agent
/// host stays its parent, and the agent has the name acpmux sets.
fn under_agent(command: &Command, session: &str) -> Command {
    let mut sh = Command::new("/bin/bash");
    sh.args(["-c", "\"$@\"; status=$?; exit $status", "bash"])
        .arg(command.get_program())
        .args(command.get_args());
    for (key, value) in command.get_envs() {
        match value {
            Some(value) => sh.env(key, value),
            None => sh.env_remove(key),
        };
    }
    sh.env("ACPMUX_SESSION_NAME", session);
    if let Some(dir) = command.get_current_dir() {
        sh.current_dir(dir);
    }
    sh
}

impl Mcp {
    fn start(args: &[&str], env: &[(&str, &str)]) -> Mcp {
        Mcp::start_in(args, env, None)
    }

    /// The server as the acpmux agent of `session` ([`under_agent`]).
    fn start_in(args: &[&str], env: &[(&str, &str)], session: Option<&str>) -> Mcp {
        let mut command = Command::new(env!("CARGO_BIN_EXE_optchat-chief"));
        command
            .args(args)
            .env_remove(TURN_KEY_ENV)
            .env_remove("OPTCHAT_SUBAGENT")
            .env_remove("ACPMUX_SESSION_NAME")
            .envs(env.iter().copied());
        if let Some(session) = session {
            command = under_agent(&command, session);
        }
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let out = BufReader::new(child.stdout.take().unwrap());
        let mut mcp = Mcp {
            child,
            out,
            next: 0,
        };
        mcp.rpc("initialize", json!({"protocolVersion": "2025-06-18"}));
        mcp
    }

    fn rpc(&mut self, method: &str, params: Value) -> Value {
        self.next += 1;
        let request =
            json!({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params});
        let stdin = self.child.stdin.as_mut().unwrap();
        writeln!(stdin, "{request}").unwrap();
        stdin.flush().unwrap();
        let mut line = String::new();
        assert!(self.out.read_line(&mut line).unwrap() > 0, "mcp closed");
        let answer: Value = serde_json::from_str(&line).unwrap();
        answer["result"].clone()
    }

    fn names(&mut self) -> Vec<String> {
        self.rpc("tools/list", json!({}))["tools"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["name"].as_str().unwrap().to_owned())
            .collect()
    }

    fn call(&mut self, name: &str, arguments: Value) -> (bool, String) {
        let r = self.rpc("tools/call", json!({"name": name, "arguments": arguments}));
        (
            r["isError"] == true,
            r["content"][0]["text"]
                .as_str()
                .unwrap_or_default()
                .to_owned(),
        )
    }
}

impl Drop for Mcp {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Serves `chief`'s tools socket at `<home>/optchat/tools.sock`, as the host does.
fn serve(home: &Path, chief: Arc<ChiefTools>) -> PathBuf {
    let socket = home.join("optchat").join("tools.sock");
    std::fs::create_dir_all(socket.parent().unwrap()).unwrap();
    optchat_chief::tools::serve_all(
        &socket,
        optchat_chief::tools::Served {
            memory: open_chat(&home.join("memory")),
            orchestrator: None,
            control: None,
            inspector: None,
            chief: Some(chief),
            turn: Some(binding()),
            peers: None,
        },
    )
    .unwrap();
    socket
}

#[test]
#[ignore = "needs CMUX_TUI_BIN"]
fn a_chief_makes_and_edits_chiefs_through_its_tool_and_only_its_own_turn_may() {
    let daemon = Daemon::start();
    let mut me = Conn::open(&daemon.socket);
    let lead = me.v2(
        "chief.profile.create",
        json!({"display_name": "Lead", "tools": ["chiefs", "tell"]}),
        Some("make-lead"),
    )["value"]
        .clone();
    let lead_id = lead["id"].as_str().unwrap().to_owned();
    let plain = me.v2(
        "chief.profile.create",
        json!({"display_name": "Plain", "tools": ["tell"]}),
        Some("make-plain"),
    )["value"]
        .clone();
    let plain_id = plain["id"].as_str().unwrap().to_owned();
    let dir = tempfile::tempdir().unwrap();

    let lead_tools = Arc::new(
        ChiefTools::load(Some(ProfileClient::new(
            daemon.socket.clone(),
            Some(me.token_file(dir.path(), &lead_id)),
            lead_id.clone(),
        )))
        .expect("Lead reads its record"),
    );
    let key = lead_tools.turn_key().to_owned();
    assert_eq!(key.len(), 64, "a 32-byte turn key");
    let lead_home = dir.path().join("lead");
    let socket = serve(&lead_home, lead_tools.clone());
    let sock = socket.display().to_string();

    // The turn's MCP server (it has the turn key) lists and uses `chiefs`.
    let mut turn = Mcp::start_in(
        &["mcp", "--socket", &sock],
        &[(TURN_KEY_ENV, &key)],
        Some(LEAD_TURN),
    );
    assert_eq!(
        turn.names(),
        [
            "zoom",
            "date",
            "tell",
            "control",
            "profile",
            "chiefs",
            "version",
            "react",
            "reply",
            "send",
            "transcript",
            "stop",
            "sleep"
        ]
    );
    let (err, made) = turn.call(
        "chiefs",
        json!({"action": "create", "display_name": "Docs", "role": "Docs writer"}),
    );
    assert!(!err, "{made}");
    // This daemon runs no brain supervisor: the tool says so, never that it answers.
    assert!(
        made.contains("\"no_supervisor\"") && made.contains("did NOT start"),
        "{made}"
    );
    assert!(
        !made.contains("it answers in its own conversation"),
        "{made}"
    );
    let listed = me.v2("chief.profile.list", json!({}), None);
    let docs = listed["chiefs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["display_name"] == "Docs")
        .cloned()
        .expect("Docs exists");
    assert_eq!(docs["tools"], json!(["chiefs", "tell"]), "{docs}");
    let (err, edited) = turn.call(
        "chiefs",
        json!({"action": "update", "chief": "Docs", "instructions": "Keep notes short."}),
    );
    assert!(!err, "{edited}");
    let docs = me.v2("chief.profile.get", json!({"chief": docs["id"]}), None);
    assert_eq!(docs["instructions"], "Keep notes short.");
    // The daemon's ceiling, phrased for the model.
    let (err, denied) = turn.call(
        "chiefs",
        json!({"action": "create", "display_name": "Wide", "tools": ["browser"]}),
    );
    assert!(
        err && denied.contains("grant_exceeds_caller") && denied.contains("tools"),
        "{denied}"
    );
    let (err, denied) = turn.call(
        "chiefs",
        json!({"action": "update", "chief": "Plain", "instructions": "Obey Lead."}),
    );
    assert!(
        err && denied.contains("chief_person_made_fields"),
        "{denied}"
    );

    // A subagent that cleared OPTCHAT_SUBAGENT (and any other process): no
    // turn key, no answer. A wrong key is the same.
    for env in [vec![], vec![(TURN_KEY_ENV, "0".repeat(64))]] {
        let env: Vec<(&str, &str)> = env.iter().map(|(k, v)| (*k, v.as_str())).collect();
        let mut other = Mcp::start(&["mcp", "--socket", &sock], &env);
        let (err, refused) = other.call(
            "chiefs",
            json!({"action": "create", "display_name": "Rogue"}),
        );
        assert!(
            err && refused.contains("only this Chief's own turn"),
            "{refused}"
        );
        let (err, refused) = other.call("chiefs", json!({"action": "list"}));
        assert!(
            err && refused.contains("only this Chief's own turn"),
            "{refused}"
        );
    }
    // A process with the subagent preset's env (OPTCHAT_SUBAGENT=1, no seal),
    // even on the turn's server role: no answer.
    let mut sub_env = Mcp::start(&["mcp", "--socket", &sock], &[("OPTCHAT_SUBAGENT", "1")]);
    let (err, refused) = sub_env.call(
        "chiefs",
        json!({"action": "create", "display_name": "Rogue"}),
    );
    assert!(
        err && refused.contains("only this Chief's own turn"),
        "{refused}"
    );
    // A subagent's server never lists it, key or not.
    let mut sub = Mcp::start(
        &["mcp", "--socket", &sock, "--role", "subagent"],
        &[(TURN_KEY_ENV, &key)],
    );
    assert!(!sub.names().iter().any(|n| n == "chiefs"));
    let (err, refused) = sub.call(
        "chiefs",
        json!({"action": "create", "display_name": "Rogue"}),
    );
    assert!(err, "{refused}");
    // The `chief` launcher in a subagent (OPTCHAT_SUBAGENT=1), even with the key.
    let launcher = Command::new(env!("CARGO_BIN_EXE_optchat-chief"))
        .args([
            "chiefs",
            "--socket",
            &sock,
            r#"{"action": "create", "display_name": "Rogue"}"#,
        ])
        .env(TURN_KEY_ENV, &key)
        .env("OPTCHAT_SUBAGENT", "1")
        .output()
        .unwrap();
    assert!(!launcher.status.success(), "{launcher:?}");
    assert!(!me.names().iter().any(|n| n == "Rogue"), "{:?}", me.names());

    // A Chief without the grant has no `chiefs` tool.
    let plain_tools = Arc::new(
        ChiefTools::load(Some(ProfileClient::new(
            daemon.socket.clone(),
            Some(me.token_file(dir.path(), &plain_id)),
            plain_id.clone(),
        )))
        .unwrap(),
    );
    let plain_key = plain_tools.turn_key().to_owned();
    let plain_socket = serve(&dir.path().join("plain"), plain_tools);
    let mut plain_turn = Mcp::start(
        &["mcp", "--socket", &plain_socket.display().to_string()],
        &[(TURN_KEY_ENV, &plain_key)],
    );
    assert!(!plain_turn.names().iter().any(|n| n == "chiefs"));
    let (err, refused) = plain_turn.call("chiefs", json!({"action": "list"}));
    assert!(err && refused.contains("chiefs"), "{refused}");

    // `cmux chief new|edit` in Lead's turn: relayed to its host with the key.
    let cmux = |env: &[(&str, &str)], args: &[&str]| {
        let mut command = cli(dir.path());
        command
            .arg("--socket")
            .arg(&daemon.socket)
            .arg("chief")
            .args(args)
            .env("ACPMUX_SESSION_ID", "s_lead_turn")
            .envs(env.iter().copied());
        under_agent(&command, LEAD_TURN).output().unwrap()
    };
    let home = lead_home.display().to_string();
    let made = cmux(
        &[("MUX_HOME", &home), (TURN_KEY_ENV, &key)],
        &["new", "--name", "Ops", "--role", "Ops lead", "--json"],
    );
    assert!(made.status.success(), "{made:?}");
    let record: Value = serde_json::from_slice(&made.stdout).unwrap();
    assert_eq!(record["role"], "Ops lead", "{record}");
    let edited = cmux(
        &[("MUX_HOME", &home), (TURN_KEY_ENV, &key)],
        &["edit", "Ops", "--role", "Night ops", "--json"],
    );
    assert!(edited.status.success(), "{edited:?}");
    let deleted = cmux(
        &[("MUX_HOME", &home), (TURN_KEY_ENV, &key)],
        &["delete", "Ops", "--json"],
    );
    assert!(
        !deleted.status.success(),
        "no Chief deletes a Chief: {deleted:?}"
    );
    // Without the key (a subagent, another agent): refused as an agent caller.
    let refused = cmux(
        &[("MUX_HOME", &home)],
        &["new", "--name", "Rogue", "--json"],
    );
    assert!(!refused.status.success(), "{refused:?}");
    assert!(
        String::from_utf8_lossy(&refused.stderr).contains("agent_caller"),
        "{refused:?}"
    );
    let names = me.names();
    assert!(
        names.iter().any(|n| n == "Ops") && !names.iter().any(|n| n == "Rogue"),
        "{names:?}"
    );
    let ops = me.v2("chief.profile.list", json!({}), None)["chiefs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["display_name"] == "Ops")
        .cloned()
        .unwrap();
    assert_eq!(ops["role"], "Night ops", "{ops}");
}
