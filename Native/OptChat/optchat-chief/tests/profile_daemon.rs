//! A Chief's own profile in its brain (multi-Chief S5, bead cx-ebm.60.5).
//! The person makes a Chief in the daemon's registry (`chief.profile.create`)
//! with a role, a personality, added instructions, a tool grant and a
//! self-edit list. The brain, bound as that Chief on a real headless
//! cmux-tui daemon (`CMUX_TUI_BIN`):
//!
//! - renders the profile after the base prompt in the cloud brain's format
//!   (backend chief-brain/prompts.ts); the default Chief renders nothing, so
//!   its prompt stays byte-identical;
//! - offers through the real `optchat-chief mcp` server (which asks the
//!   host's tools socket for the grant) only the tools the person granted, plus `profile` when the record allows any self-edit;
//! - refuses an ungranted tool at the tools socket, also when a turn asks
//!   for it by name;
//! - changes its own role and picture through `profile` on its own bound
//!   connection, and is refused a field the person did not allow.
//!
//! - (the default Chief, hq-6d decision 2026-10-14) a real host that starts
//!   while the daemon is away serves zoom and date only, and gets its
//!   record's grant when the daemon comes up and the link connects;
//! - (S5 gap 3) a Chief with a self-edit grant reads of `chief profile` in
//!   its launcher prompt (AGENTS.md).
//!
//! Run: `CMUX_TUI_BIN=<cmux-tui target>/debug/cmux-tui cargo test --test
//! profile_daemon -- --ignored`.

mod common;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::time::Duration;

use common::open_chat;
use optchat_chief::chief_profile::{ChiefTools, ProfileClient};
use serde_json::{Value, json};

/// A 1x1 PNG.
const PNG: &[u8] = &[
    0x89, b'P', b'N', b'G', b'\r', b'\n', 0x1a, b'\n', 0, 0, 0, 13, b'I', b'H', b'D', b'R', 0, 0,
    0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 0x1f, 0x15, 0xc4, 0x89, 0, 0, 0, 10, b'I', b'D', b'A', b'T',
    0x78, 0x9c, 0x63, 0, 1, 0, 0, 5, 0, 1, 0x0d, 0x0a, 0x2d, 0xb4, 0, 0, 0, 0, b'I', b'E', b'N',
    b'D', 0xae, 0x42, 0x60, 0x82,
];

fn bin() -> PathBuf {
    PathBuf::from(std::env::var("CMUX_TUI_BIN").expect("CMUX_TUI_BIN names a cmux-tui binary"))
}

/// One JSON-lines connection to the daemon (the person's: unbound, local).
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

    fn line(&mut self, what: &Value) -> Value {
        let mut line = String::new();
        assert!(
            self.reader.read_line(&mut line).unwrap() > 0,
            "the daemon closed: {what}"
        );
        serde_json::from_str(&line).unwrap()
    }

    /// One v1 request; its `data`.
    fn req(&mut self, mut body: Value) -> Value {
        self.next += 1;
        body["id"] = json!(self.next);
        writeln!(self.writer, "{body}").unwrap();
        loop {
            let value = self.line(&body);
            if value["id"] == body["id"] {
                assert_eq!(value["ok"], true, "{body} failed: {value}");
                return value["data"].clone();
            }
        }
    }

    /// One `cmux.protocol/2` request; its `result`.
    fn v2(&mut self, operation: &str, params: Value, key: Option<&str>) -> Value {
        self.next += 1;
        let id = format!("p-{}", self.next);
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
            let value = self.line(&frame);
            if value["id"] == json!(id) && value["type"] == "response" {
                assert_eq!(value["ok"], true, "{frame} failed: {value}");
                return value["result"].clone();
            }
        }
    }

    /// A participant token for `participant`, in a 0600 file under `dir`.
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
}

/// A headless daemon in its own home; stopped (by its own CLI) on drop.
struct Daemon {
    dir: tempfile::TempDir,
    socket: PathBuf,
}

impl Daemon {
    fn start() -> Daemon {
        let dir = tempfile::Builder::new()
            .prefix("ocp")
            .tempdir_in("/tmp")
            .unwrap();
        let socket = dir.path().join("d.sock");
        Daemon::start_at(dir, socket)
    }

    /// A daemon in `dir` listening on `socket` (a path a host already uses).
    fn start_at(dir: tempfile::TempDir, socket: PathBuf) -> Daemon {
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
        .env("LC_ALL", "C");
    command
}

/// The real `optchat-chief mcp` server for the tools socket `socket`, with
/// the `mcp_args` the host writes into the session's `.mcp.json`.
struct Mcp {
    child: std::process::Child,
    out: BufReader<std::process::ChildStdout>,
    next: u64,
}

impl Mcp {
    fn start(mcp_args: &[String]) -> Mcp {
        let mut child = Command::new(env!("CARGO_BIN_EXE_optchat-chief"))
            .args(mcp_args)
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
        assert!(
            self.out.read_line(&mut line).unwrap() > 0,
            "mcp closed: {request}"
        );
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

    /// A tool call: (is_error, text).
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

#[test]
#[ignore = "needs CMUX_TUI_BIN"]
fn a_chief_gets_its_profile_its_granted_tools_and_edits_only_what_the_person_allowed() {
    let daemon = Daemon::start();
    let mut me = Conn::open(&daemon.socket);
    let made = me.v2(
        "chief.profile.create",
        json!({"display_name": "Scout", "role": "Release captain",
               "personality": "Terse and exact.", "instructions": "Always name the branch.",
               "tools": ["tell"], "self_edit": ["avatar", "role"]}),
        Some("make-scout"),
    );
    let scout = made["value"]["id"].as_str().unwrap().to_owned();
    let dir = tempfile::tempdir().unwrap();
    me.req(json!({"cmd": "conversation-create", "idempotency_key": "dm-scout",
                  "actor": "user_local", "title": "Scout", "participants": [
                      {"id": "user_local", "kind": "human", "display_name": "Ada"},
                      {"id": scout, "kind": "agent", "display_name": "Scout", "agent_class": "mux"}]}));
    let token = me.token_file(dir.path(), &scout);

    // The brain reads its own record on its own bound connection.
    let client = ProfileClient::new(daemon.socket.clone(), Some(token), scout.clone());
    let tools = ChiefTools::load(Some(client)).expect("the brain reads its record");

    // The prompt: the base and the person's instructions first, then the
    // profile in the cloud brain's format.
    let base = optchat_chief::prompt::system_text(
        Some("Person text."),
        &optchat_chief::prompt::Tools::Mcp,
    );
    let instructions = tools.instructions(Some("Person text.".to_owned()));
    let text = optchat_chief::prompt::system_text(
        instructions.as_deref(),
        &optchat_chief::prompt::Tools::Mcp,
    );
    let head = base.trim_end();
    assert!(
        text.starts_with(head),
        "the base prompt and the person's text come first"
    );
    assert!(
        text.contains("## This Chief (the rules above come first)\nName: Scout\nRole: Release captain\nPersonality: Terse and exact."),
        "{text}"
    );
    assert!(
        text.contains(
            "## Added instructions (the rules above come first)\nAlways name the branch."
        )
    );
    assert_eq!(
        text,
        optchat_chief::prompt::system_text(
            tools
                .instructions(Some("Person text.".to_owned()))
                .as_deref(),
            &optchat_chief::prompt::Tools::Mcp
        ),
        "byte-stable while the record does not change"
    );

    // A Chief with no record (started before it had one) keeps every tool.
    me.req(json!({"cmd": "conversation-create", "idempotency_key": "dm-ghost",
                  "actor": "user_local", "title": "Ghost", "participants": [
                      {"id": "user_local", "kind": "human", "display_name": "Ada"},
                      {"id": "agent_ghost", "kind": "agent", "display_name": "Ghost", "agent_class": "mux"}]}));
    let ghost_token = me.token_file(dir.path(), "agent_ghost");
    let ghost = ChiefTools::load(Some(ProfileClient::new(
        daemon.socket.clone(),
        Some(ghost_token),
        "agent_ghost".into(),
    )));
    assert!(
        matches!(
            ghost,
            Err(optchat_chief::chief_profile::LoadError::NoRecord(_))
        ),
        "{ghost:?}"
    );

    // The default Chief renders nothing: its prompt stays byte-identical.
    let mux_token = me.token_file(dir.path(), "agent_mux");
    let default = ChiefTools::load(Some(ProfileClient::new(
        daemon.socket.clone(),
        Some(mux_token),
        "agent_mux".into(),
    )))
    .expect("the default Chief reads its record");
    assert_eq!(
        default
            .instructions(Some("Person text.".to_owned()))
            .as_deref(),
        Some("Person text.")
    );

    // The tools socket, served as the host serves it, and the real MCP server.
    let socket = dir.path().join("tools.sock");
    let memory = open_chat(&dir.path().join("memory"));
    let mcp_args = vec![
        "mcp".to_owned(),
        "--socket".to_owned(),
        socket.display().to_string(),
    ];
    optchat_chief::tools::serve_all(
        &socket,
        optchat_chief::tools::Served {
            memory,
            orchestrator: None,
            control: None,
            inspector: None,
            chief: Some(Arc::new(tools)),
            turn: None,
            peers: None,
        },
    )
    .unwrap();
    let mut mcp = Mcp::start(&mcp_args);
    assert_eq!(
        mcp.names(),
        [
            "zoom",
            "date",
            "tell",
            "profile",
            "version",
            "react",
            "reply",
            "send",
            "transcript",
            "stop",
            "sleep"
        ],
        "only the granted tools, and profile; react, reply, send, stop and sleep always"
    );
    let (refused, why) = mcp.call("spawn", json!({"tasks": ["build it"]}));
    assert!(
        refused && why.contains("spawn"),
        "an ungranted tool is refused by name: {why}"
    );
    // A turn that asks the socket directly (the `chief` launcher) is refused too.
    let direct = optchat_chief::tools::ask(
        &socket,
        optchat_chief::tools::Call::parse("spawn", &json!({"tasks": ["x"]})).unwrap(),
    );
    assert!(
        direct.is_err_and(|e| e.contains("not given")),
        "the socket refuses spawn"
    );

    // profile: read, change an allowed field, refuse another, set the picture.
    let (err, read) = mcp.call("profile", json!({}));
    assert!(
        !err && read.contains("Release captain") && read.contains("self_edit"),
        "{read}"
    );
    let (err, changed) = mcp.call("profile", json!({"role": "Build captain"}));
    assert!(!err, "{changed}");
    let record = me.v2("chief.profile.get", json!({"chief": scout}), None);
    assert_eq!(
        record["role"], "Build captain",
        "the daemon holds the Chief's own change"
    );
    let (err, denied) = mcp.call("profile", json!({"display_name": "Boss"}));
    assert!(
        err && denied.contains("Not allowed: display_name"),
        "{denied}"
    );
    assert_eq!(
        me.v2("chief.profile.get", json!({"chief": scout}), None)["display_name"],
        "Scout"
    );
    let png = dir.path().join("me.png");
    std::fs::write(&png, PNG).unwrap();
    let (err, set) = mcp.call("profile", json!({"avatar_path": png.display().to_string()}));
    assert!(!err, "{set}");
    let avatar = me.v2("chief.profile.avatar.get", json!({"chief": scout}), None);
    assert_eq!(avatar["avatar"]["media_type"], "image/png", "{avatar}");
    let text_file = dir.path().join("me.txt");
    std::fs::write(&text_file, b"not a picture").unwrap();
    let (err, bad) = mcp.call(
        "profile",
        json!({"avatar_path": text_file.display().to_string()}),
    );
    assert!(err && bad.contains("PNG, JPEG, GIF or WebP"), "{bad}");
}

/// Waits (bounded) until `done`; the host and the daemon are other processes.
fn wait_until(host_log: &Path, what: &str, mut done: impl FnMut() -> bool) {
    let deadline = std::time::Instant::now() + Duration::from_secs(60);
    while !done() {
        assert!(
            std::time::Instant::now() < deadline,
            "{what} did not happen in 60 s; host log:\n{}",
            std::fs::read_to_string(host_log).unwrap_or_default()
        );
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// The real host process; SIGTERM and wait on drop.
struct Host(std::process::Child);

impl Drop for Host {
    fn drop(&mut self) {
        // SAFETY: the pid is this test's own child.
        unsafe { libc::kill(self.0.id() as i32, libc::SIGTERM) };
        let _ = self.0.wait();
    }
}

/// The real host for `participant` on `socket`, its MUX_HOME `dir/mux`,
/// its log `dir/host.log`. The native engine with the API compactor needs
/// no acpmux (person_profile.rs).
fn start_host(dir: &Path, socket: &Path, token: &Path, participant: Option<&str>) -> Host {
    start_host_with(dir, socket, token, participant, &[])
}

/// [`start_host`] with `env` added to the host's environment.
fn start_host_with(
    dir: &Path,
    socket: &Path,
    token: &Path,
    participant: Option<&str>,
    env: &[(&str, &str)],
) -> Host {
    let mut command = Command::new(env!("CARGO_BIN_EXE_optchat-chief"));
    command
        .args(["host", "--daemon-socket"])
        .arg(socket)
        .arg("--mux-home")
        .arg(dir.join("mux"))
        .env("HOME", dir)
        .env("MUX_AGENT_TOKEN_FILE", token)
        .env("OPTCHAT_CHIEF_ENGINE", "native")
        .env("OPTCHAT_COMPACTOR", "api")
        .env("ACPMUX_BIN", "/usr/bin/false")
        .env("ACPMUX_HOME", dir.join("acpmux"))
        .env("OPTCHAT_INSPECTOR", "0")
        .env_remove("OPTCHAT_ACPMUX_SUPERVISED")
        .env_remove("OPTCHAT_CHIEF_PARTICIPANT")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(std::fs::File::create(dir.join("host.log")).unwrap());
    if let Some(participant) = participant {
        command.env("OPTCHAT_CHIEF_PARTICIPANT", participant);
    }
    command.envs(env.iter().copied());
    Host(command.spawn().unwrap())
}

/// hq-6d decision (2026-10-14): the default Chief no longer fails open. A
/// host that cannot read its record at start (the daemon is away) serves
/// zoom and date only; when the daemon comes up and the link connects, it
/// reads the record and serves the record's grant. A Chief whose record is
/// absent (registry present) keeps every tool (the S5 test above).
#[test]
#[ignore = "needs CMUX_TUI_BIN"]
fn the_default_chief_serves_only_zoom_and_date_until_it_reads_its_record() {
    let dir = tempfile::Builder::new()
        .prefix("ocd")
        .tempdir_in("/tmp")
        .unwrap();
    let socket = dir.path().join("d.sock");
    let token = dir.path().join("agent-token");
    // A token from an earlier daemon: the host needs one to start; this
    // daemon will not know it.
    std::fs::write(&token, "from-an-earlier-daemon\n").unwrap();
    let host_log = dir.path().join("host.log");
    let host = start_host(dir.path(), &socket, &token, None);
    let tools_socket = dir.path().join("mux").join("optchat").join("tools.sock");
    wait_until(&host_log, "the host serving its tools socket", || {
        UnixStream::connect(&tools_socket).is_ok()
    });
    let mcp_args = vec![
        "mcp".to_owned(),
        "--socket".to_owned(),
        tools_socket.display().to_string(),
    ];
    let mut mcp = Mcp::start(&mcp_args);
    assert_eq!(
        mcp.names(),
        [
            "zoom",
            "date",
            "version",
            "react",
            "reply",
            "send",
            "transcript",
            "stop",
            "sleep"
        ],
        "the daemon is away: the default Chief's grant is not known, so it gets zoom and date only (and its own react and reply)"
    );
    let (refused, why) = mcp.call("tell", json!({"id": "a1", "message": "x"}));
    assert!(
        refused && why.contains("not given"),
        "tell is refused while the grant is not known: {why}"
    );

    // The daemon comes up; the person narrows the default Chief's tools; the
    // brain's token is there; the link connects and the brain reads its record.
    let daemon_dir = tempfile::Builder::new()
        .prefix("ocdd")
        .tempdir_in("/tmp")
        .unwrap();
    let daemon = Daemon::start_at(daemon_dir, socket.clone());
    let mut me = Conn::open(&daemon.socket);
    let record = me.v2("chief.profile.get", json!({"chief": "agent_mux"}), None);
    let updated = me.v2(
        "chief.profile.update",
        json!({"chief": "agent_mux", "expected_rev": record["rev"], "tools": ["tell"]}),
        Some("narrow-default"),
    );
    let record = &updated["value"];
    assert_eq!(record["tools"], json!(["tell"]), "{updated}");
    let mut expected = vec!["zoom", "date", "tell"];
    if record["self_edit"]
        .as_array()
        .is_some_and(|a| !a.is_empty())
    {
        expected.push("profile");
    }
    expected.extend([
        "version",
        "react",
        "reply",
        "send",
        "transcript",
        "stop",
        "sleep",
    ]);
    let minted = me.token_file(dir.path(), "agent_mux");
    std::fs::rename(&minted, &token).unwrap();
    wait_until(
        &host_log,
        "the host reading the default Chief's record",
        || mcp.names() == expected,
    );
    let (refused, why) = mcp.call("spawn", json!({"tasks": ["build it"]}));
    assert!(
        refused && why.contains("not given"),
        "the record's grant holds: {why}"
    );
    drop(mcp);
    drop(host);
}

/// S5 gap 3: a Chief whose record grants `profile` (any self_edit) learns of
/// `chief profile` in the launcher section of its harness-without-MCP
/// prompt (the session directory's AGENTS.md, what a codex turn reads).
#[test]
#[ignore = "needs CMUX_TUI_BIN"]
fn a_chief_with_self_edit_reads_of_chief_profile_in_its_launcher_prompt() {
    let daemon = Daemon::start();
    let mut me = Conn::open(&daemon.socket);
    let made = me.v2(
        "chief.profile.create",
        json!({"display_name": "Scout", "tools": ["tell"], "self_edit": ["avatar", "role"]}),
        Some("make-scout"),
    );
    let scout = made["value"]["id"].as_str().unwrap().to_owned();
    let dir = tempfile::Builder::new()
        .prefix("ocs")
        .tempdir_in("/tmp")
        .unwrap();
    me.req(json!({"cmd": "conversation-create", "idempotency_key": "dm-scout",
                  "actor": "user_local", "title": "Scout", "participants": [
                      {"id": "user_local", "kind": "human", "display_name": "Ada"},
                      {"id": scout, "kind": "agent", "display_name": "Scout", "agent_class": "mux"}]}));
    let token = me.token_file(dir.path(), &scout);
    let host_log = dir.path().join("host.log");
    let _host = start_host(dir.path(), &daemon.socket, &token, Some(&scout));
    let agents_md = dir.path().join("mux/optchat/session/AGENTS.md");
    let chief = dir
        .path()
        .join("mux/optchat/bin/chief")
        .display()
        .to_string();
    let line = format!("- Your profile: `{chief} profile` prints your record");
    wait_until(
        &host_log,
        "the launcher prompt naming chief profile",
        || std::fs::read_to_string(&agents_md).is_ok_and(|text| text.contains(&line)),
    );
}

/// S5 gap 4: the person's `harnesses` grant reaches the spawn path. A Chief
/// whose record allows spawn but only the codex harness asks for a claude
/// subagent: the spawn is refused with the allowed list and starts no
/// session. The record is the real daemon's; the brain and spawner are the
/// host's; acpmux is the in-repo fake, only to show that nothing started.
#[test]
#[ignore = "needs CMUX_TUI_BIN"]
fn a_spawn_on_a_harness_outside_the_grant_starts_nothing() {
    use optchat_chief::subagents::{Spawner, SubagentSettings};
    use optchat_chief::tools::Orchestrator;
    let daemon = Daemon::start();
    let mut me = Conn::open(&daemon.socket);
    let made = me.v2(
        "chief.profile.create",
        json!({"display_name": "Builder", "tools": ["spawn", "tell"], "harnesses": ["codex"]}),
        Some("make-builder"),
    );
    let builder = made["value"]["id"].as_str().unwrap().to_owned();
    let dir = tempfile::tempdir().unwrap();
    me.req(json!({"cmd": "conversation-create", "idempotency_key": "dm-builder",
                  "actor": "user_local", "title": "Builder", "participants": [
                      {"id": "user_local", "kind": "human", "display_name": "Ada"},
                      {"id": builder, "kind": "agent", "display_name": "Builder", "agent_class": "mux"}]}));
    let token = me.token_file(dir.path(), &builder);
    let tools = Arc::new(
        ChiefTools::start(
            Some(ProfileClient::new(
                daemon.socket.clone(),
                Some(token),
                builder.clone(),
            )),
            false,
            &|_| {},
        )
        .expect("the brain reads its record"),
    );

    let mut h = common::Harness::new(Box::new(|_, _| Vec::new()));
    h.connect();
    let spawner = Arc::new(
        Spawner::new(
            h.chat.clone(),
            h.agents.clone(),
            SubagentSettings {
                harness: "claude".into(),
                policy: "approve-all".into(),
                model: None,
                effort: None,
                preset: None,
                cwd: h.dir.path().join("subagent"),
                prefix: "optchat-sub-h0me".into(),
                parent: optchat_chief::brain::PARENT.into(),
                claude_md: None,
            },
            h.tx.clone(),
            Arc::new(|_: &str| {}),
        )
        .with_harness_grant(tools),
    );
    let worker = {
        let spawner = spawner.clone();
        std::thread::spawn(move || spawner.spawn(vec!["build it".into()], None))
    };
    while !worker.is_finished() {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
        }
    }
    let answer = worker.join().unwrap();
    let text = match &answer {
        Ok(text) | Err(text) => text.clone(),
    };
    assert!(
        text.contains("has not given this Chief's subagents the claude harness; it may use codex"),
        "{answer:?}"
    );
    let started = h.agents.inner.lock().unwrap().specs.len();
    assert_eq!(started, 0, "a refused spawn starts no session");
}

/// One cmux MCP server per Chief turn (hq-6d 2026-10-14): acpmux gives every
/// agent chat, the Chief's turns and subagents included, its own `cmux mcp
/// serve` (cx-wx93i, acpmux agent_tools.rs). A host started with
/// `CMUX_MCP_COMMAND` (the app passes it when its own env has it) adds no
/// second `cmux` server: the turn's and the subagent's `.mcp.json` hold only
/// `optchat`, and their project settings enable only `optchat`.
#[test]
#[ignore = "needs CMUX_TUI_BIN"]
fn a_chief_turn_gets_no_second_cmux_mcp_server() {
    let daemon = Daemon::start();
    let mut me = Conn::open(&daemon.socket);
    let made = me.v2(
        "chief.profile.create",
        json!({"display_name": "Scout", "tools": ["tell"]}),
        Some("make-scout-mcp"),
    );
    let scout = made["value"]["id"].as_str().unwrap().to_owned();
    let dir = tempfile::Builder::new()
        .prefix("ocm")
        .tempdir_in("/tmp")
        .unwrap();
    me.req(json!({"cmd": "conversation-create", "idempotency_key": "dm-scout-mcp",
                  "actor": "user_local", "title": "Scout", "participants": [
                      {"id": "user_local", "kind": "human", "display_name": "Ada"},
                      {"id": scout, "kind": "agent", "display_name": "Scout", "agent_class": "mux"}]}));
    let token = me.token_file(dir.path(), &scout);
    let host_log = dir.path().join("host.log");
    let _host = start_host_with(
        dir.path(),
        &daemon.socket,
        &token,
        Some(&scout),
        &[("CMUX_MCP_COMMAND", "/tmp/no-such-cmux-mcp")],
    );
    let root = dir.path().join("mux/optchat");
    let read = |path: &Path| -> Option<Value> {
        serde_json::from_str(&std::fs::read_to_string(path).ok()?).ok()
    };
    for place in ["session", "subagent"] {
        let mcp = root.join(place).join(".mcp.json");
        let settings = root.join(place).join(".claude/settings.json");
        wait_until(&host_log, &format!("the {place} directory"), || {
            read(&mcp).is_some() && read(&settings).is_some()
        });
        let servers: Vec<String> = read(&mcp).unwrap()["mcpServers"]
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect();
        assert_eq!(servers, vec!["optchat".to_owned()], "{place}: {mcp:?}");
        let settings = read(&settings).unwrap();
        let enabled = &settings["enabledMcpjsonServers"];
        assert_eq!(enabled, &json!(["optchat"]), "{place}");
        // Nor is the variable passed to the turn's tools.
        assert!(
            settings["env"].get("CMUX_MCP_COMMAND").is_none(),
            "{place}: {settings}"
        );
    }
    let launcher = std::fs::read_to_string(root.join("bin/chief")).unwrap();
    assert!(!launcher.contains("CMUX_MCP_COMMAND"), "{launcher}");
}
