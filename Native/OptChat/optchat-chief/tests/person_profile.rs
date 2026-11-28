//! The person profile (`optchat/person.md`, Chief review cause 4): the
//! Chief ran with no word of who the user is, so it asked "Should I...?"
//! after "make it happen" and ran builds and tests on the user's Mac. A host
//! start writes a default profile once, the user may edit it, and the
//! profile heads the user's part of every turn's system prompt (the cached
//! prefix: read once per host start). Checked at the binary's boundary: the
//! session directory's AGENTS.md, the system text a turn session reads.
#![cfg(unix)]

use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

const DEFAULT_LINE: &str = "Do not run heavy builds or tests on this Mac";

fn start_host(dir: &Path) -> Child {
    let token = dir.join("agent-token");
    std::fs::write(&token, "secret\n").unwrap();
    // The native engine with the API compactor needs no acpmux; the missing
    // daemon socket stops the host after it wrote its session directory.
    Command::new(env!("CARGO_BIN_EXE_optchat-chief"))
        .args(["host", "--daemon-socket"])
        .arg(dir.join("missing.sock"))
        .arg("--mux-home")
        .arg(dir.join("mux"))
        .env("HOME", dir)
        .env("MUX_AGENT_TOKEN_FILE", &token)
        .env("OPTCHAT_CHIEF_ENGINE", "native")
        .env("OPTCHAT_COMPACTOR", "api")
        .env("ACPMUX_BIN", "/usr/bin/false")
        .env("ACPMUX_HOME", dir.join("acpmux"))
        .env("OPTCHAT_INSPECTOR", "0")
        .env_remove("OPTCHAT_ACPMUX_SUPERVISED")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap()
}

fn stop(mut host: Child) {
    // SAFETY: the pid is this test's own child.
    unsafe { libc::kill(host.id() as i32, libc::SIGTERM) };
    let _ = host.wait();
}

/// The session directory's AGENTS.md once it holds `needle`.
fn system_text_with(dir: &Path, needle: &str) -> String {
    let file = dir.join("mux/optchat/session/AGENTS.md");
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let text = std::fs::read_to_string(&file).unwrap_or_default();
        if text.contains(needle) {
            return text;
        }
        assert!(
            Instant::now() < deadline,
            "the session's system text never held {needle:?}; it is:\n{text}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn a_host_writes_a_default_person_profile_and_the_turns_read_the_users_edit() {
    let dir = tempfile::tempdir().unwrap();
    let person = dir.path().join("mux/optchat/person.md");

    let host = start_host(dir.path());
    let first = system_text_with(dir.path(), DEFAULT_LINE);
    stop(host);
    let written = std::fs::read_to_string(&person).expect("the host writes person.md");
    assert!(written.contains(DEFAULT_LINE), "{written}");
    assert!(written.contains("without asking"), "{written}");
    assert!(
        first.contains(written.trim()),
        "the profile is in the system text"
    );
    // The Chief's own Turns paragraph replaces the spec's (cause 3).
    assert!(first.contains("Keep your own turns short."), "{first}");
    assert!(
        !first.contains("Use subagents only when the user asks"),
        "{first}"
    );

    // The user's edit, and their own instructions file after it.
    std::fs::write(&person, "# The user\n\nCall me Ada. Ask before any push.\n").unwrap();
    std::fs::write(
        dir.path().join("mux/optchat/AGENTS.md"),
        "Reply in French.\n",
    )
    .unwrap();
    let host = start_host(dir.path());
    let second = system_text_with(dir.path(), "Call me Ada.");
    stop(host);
    assert!(
        !second.contains(DEFAULT_LINE),
        "the edit replaces the default:\n{second}"
    );
    let profile_at = second.find("Call me Ada.").unwrap();
    let own_at = second
        .find("Reply in French.")
        .expect("the instructions file stays");
    assert!(profile_at < own_at, "the profile comes first:\n{second}");
    assert_eq!(
        std::fs::read_to_string(&person).unwrap(),
        "# The user\n\nCall me Ada. Ask before any push.\n",
        "a host never rewrites the user's profile"
    );
}
