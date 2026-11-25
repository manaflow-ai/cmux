//! A subagent keeps its identity across an app update (live, 2026-11-18): Sparkle replaced the
//! nightly bundle under the running `acpmux __agent-host` processes, so the kernel no longer
//! named their executable (`proc_pidpath` gave nothing; the old binary lives on in Sparkle's
//! cache). The tools socket binds a caller to its subagent session through the agent's parent
//! being this host's acpmux, so every subagent started before the update lost it: a1225's
//! `tell` to a1212, by MCP and by shell, was refused with "only a subagent session of this
//! Chief may tell another subagent".

#![cfg(unix)]

use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use optchat_chief::turn_caller::TurnBinding;

const HOME: &str = "h0me";
const STAND_IN: &str = "TURN_CALLER_STAND_IN_HOST";

/// Run as the stand-in agent host (a copy of this test binary, see `agent_host`): start one
/// agent (this test binary again, as `stand_in_agent`) under subagent session a7, the way
/// `acpmux __agent-host` starts Claude Code, and wait for it. Not `/bin/sleep`: macOS hides a
/// platform binary's environment.
#[test]
fn stand_in_agent_host() {
    if std::env::var_os(STAND_IN).as_deref() != Some("host".as_ref()) {
        return;
    }
    let _ = Command::new(std::env::current_exe().unwrap())
        .args(["stand_in_agent", "--exact", "--test-threads=1"])
        .env(STAND_IN, "agent")
        .env("ACPMUX_SESSION_NAME", format!("optchat-sub-{HOME}-a7"))
        .stdout(Stdio::null())
        .status();
}

/// Run as the stand-in agent: wait until the test ends it.
#[test]
fn stand_in_agent() {
    if std::env::var_os(STAND_IN).as_deref() == Some("agent".as_ref()) {
        std::thread::sleep(Duration::from_secs(30));
    }
}

/// A stand-in "acpmux" at `bin`: a copy of this test binary (a copied system binary is killed
/// on macOS), run as `stand_in_agent_host`.
fn agent_host(bin: &Path) -> Child {
    let mut command = Command::new(bin);
    command
        .args(["stand_in_agent_host", "--exact", "--test-threads=1"])
        .env(STAND_IN, "host")
        .stdin(Stdio::null())
        .stdout(Stdio::null());
    // A parallel test that forks while `install` still holds the copy open for writing
    // leaves the child with that fd until it execs: Linux refuses the exec with ETXTBSY
    // for that moment (the same race `claude_shim.rs` waits out).
    for _ in 0..50 {
        match command.spawn() {
            Err(e) if e.kind() == std::io::ErrorKind::ExecutableFileBusy => {
                std::thread::sleep(Duration::from_millis(20));
            }
            result => return result.expect("start the agent host"),
        }
    }
    command.spawn().expect("start the agent host")
}

fn install(to: &Path) {
    std::fs::copy(std::env::current_exe().unwrap(), to).expect("copy the stand-in");
}

/// An app update, the way Sparkle does it: the running binary at `bin` moves to an
/// installation folder, a new one takes its place, and the folder goes away.
fn update(bin: &Path) {
    let old = bin.with_file_name("Installation");
    std::fs::create_dir(&old).unwrap();
    std::fs::rename(bin, old.join("acpmux")).unwrap();
    install(bin);
    std::fs::remove_dir_all(&old).unwrap();
}

/// The agent the host started.
fn agent_of(host: u32) -> i32 {
    let until = Instant::now() + Duration::from_secs(10);
    loop {
        let out = Command::new("/usr/bin/pgrep")
            .args(["-P", &host.to_string()])
            .output()
            .unwrap();
        if let Some(pid) = String::from_utf8_lossy(&out.stdout)
            .split_whitespace()
            .next()
            .and_then(|p| p.parse().ok())
        {
            return pid;
        }
        assert!(Instant::now() < until, "the agent never started");
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn binding(acpmux: &Path) -> TurnBinding {
    TurnBinding {
        turn_prefix: format!("optchat-{HOME}-"),
        subagent_prefix: format!("optchat-sub-{HOME}-"),
        agent_parent: Some(std::fs::canonicalize(acpmux).unwrap()),
    }
}

#[test]
fn a_subagent_keeps_its_identity_after_its_acpmux_binary_is_replaced() {
    let dir = tempfile::tempdir().unwrap();
    let bin: PathBuf = dir.path().join("acpmux");
    install(&bin);
    let mut host = agent_host(&bin);
    let agent = agent_of(host.id());
    assert_eq!(
        binding(&bin).subagent_of(agent).as_deref(),
        Some("a7"),
        "before the update"
    );

    // The update: a new file at the same path, the running host keeps the old one.
    update(&bin);
    let after = binding(&bin).subagent_of(agent);
    let _ = host.kill();
    let _ = Command::new("/bin/kill").arg(agent.to_string()).status();
    let _ = host.wait();
    assert_eq!(after.as_deref(), Some("a7"), "after the update");
}

/// A process under another program's tree is no subagent, whatever its environment says.
#[test]
fn a_process_under_another_program_is_no_subagent() {
    let dir = tempfile::tempdir().unwrap();
    let (bin, other) = (dir.path().join("acpmux"), dir.path().join("other"));
    install(&bin);
    install(&other);
    let mut host = agent_host(&other);
    let agent = agent_of(host.id());
    let got = binding(&bin).subagent_of(agent);
    let _ = host.kill();
    let _ = Command::new("/bin/kill").arg(agent.to_string()).status();
    let _ = host.wait();
    assert_eq!(got, None);
}
