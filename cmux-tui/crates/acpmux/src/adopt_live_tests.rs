use super::*;

/// The probe of a Codex writer leaves no lock on either lock file, also while the descriptions
/// it probed through stay open: a child that another daemon thread forked during the probe
/// keeps a copy of each until it execs, and a lock the probe took and only closed stays held
/// through that copy. Codex then finds its thread busy (or its coordination lock held) and
/// refuses to write (LOCK-AUDIT adopt_live.rs:201 and :208).
#[cfg(unix)]
#[test]
fn a_writer_probe_leaves_no_lock_while_its_descriptions_stay_open() {
    let dir = std::env::temp_dir().join(format!(
        "acpmux-writer-probe-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let path = |name: &str| dir.join(name);
    std::fs::write(path(".coordination.lock"), b"").unwrap();
    std::fs::write(path("t.lock"), b"").unwrap();
    let open = |name: &str| std::fs::File::open(path(name)).unwrap();
    let free = |name: &str| {
        let file = open(name);
        let taken = file.try_lock().is_ok();
        let _ = file.unlock();
        taken
    };
    // The probe's descriptions stay open, as a forked child's copies of them do.
    let (coordination, thread) = (open(".coordination.lock"), open("t.lock"));
    let copy = coordination.try_clone().unwrap();
    assert!(!writer_holds(Some(copy), &thread), "no writer holds the thread");
    let (coordination_free, thread_free) = (free(".coordination.lock"), free("t.lock"));
    // The probe's descriptions go (as a forked child's copies do at its exec): a writer that
    // holds the thread lock is then seen.
    drop((coordination, thread));
    let writer = open("t.lock");
    let seen = writer.try_lock().is_ok()
        && writer_holds(Some(open(".coordination.lock")), &open("t.lock"));
    let _ = writer.unlock();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(coordination_free, "the probe left the coordination lock held");
    assert!(thread_free, "the probe left the thread lock held");
    assert!(seen, "a writer that holds the thread lock is not seen");
}

fn procs(rows: &[(u32, u32, &str)]) -> Vec<Proc> {
    rows.iter()
        .map(|&(pid, ppid, command)| Proc { pid, ppid, command: command.to_owned() })
        .collect()
}

fn host(session_id: &str, host_pid: u32, harness_pid: Option<u32>) -> OwnHost {
    OwnHost { session_id: session_id.to_owned(), host_pid, harness_pid }
}

/// The machine this was seen on: the app's acpmux, Chief's acpmux and a dev build's
/// each run Claude Code under their own agent hosts, and all of them register in
/// one `~/.claude/sessions`. A registered `claude` under one of this home's hosts is
/// this acpmux's own chat; one under another home's host is open elsewhere.
fn machine() -> Vec<Proc> {
    procs(&[
        (30816, 1, "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux daemon run"),
        (70686, 30816, "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux __agent-host"),
        (70701, 70686, "/opt/homebrew/bin/claude -p --input-format stream-json --resume abc"),
        // A host the previous daemon started: reparented to launchd, this home's still.
        (1887, 1, "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux __agent-host"),
        (1900, 1887, "/bin/sh -c claude"),
        (1906, 1900, "/opt/homebrew/bin/claude -p --input-format stream-json"),
        // Chief's acpmux: another home.
        (50849, 1, "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux daemon run"),
        (38030, 50849, "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux __agent-host"),
        (38031, 38030, "/opt/homebrew/bin/claude -p --input-format stream-json"),
        // A `claude` that chat-a's harness ran from its Bash tool.
        (70800, 70701, "/bin/zsh -c claude -p --resume other"),
        (70801, 70800, "/opt/homebrew/bin/claude -p --resume other"),
        // A `claude` in a terminal.
        (2523, 2400, "claude"),
    ])
}

#[test]
fn own_host_session_finds_this_homes_harness_by_its_host() {
    let hosts = [host("chat-a", 70686, None), host("chat-b", 1887, None)];
    let procs = machine();
    assert_eq!(own_host_session(70701, &hosts, &procs), Some("chat-a".to_owned()));
    // Under a wrapper, under a host whose daemon restarted.
    assert_eq!(own_host_session(1906, &hosts, &procs), Some("chat-b".to_owned()));
}

#[test]
fn own_host_session_matches_the_recorded_harness_pid_without_a_process_table() {
    let hosts = [host("chat-a", 70686, Some(70701))];
    assert_eq!(own_host_session(70701, &hosts, &[]), Some("chat-a".to_owned()));
}

#[test]
fn own_host_session_leaves_another_homes_harness_and_a_terminal_claude_live() {
    let hosts = [host("chat-a", 70686, Some(70701)), host("chat-b", 1887, None)];
    let procs = machine();
    // Chief's acpmux runs it: open elsewhere, though an acpmux runs it.
    assert_eq!(own_host_session(38031, &hosts, &procs), None);
    assert_eq!(own_host_session(2523, &hosts, &procs), None);
    // A `claude` that this home's harness started is not that host's harness.
    assert_eq!(own_host_session(70801, &hosts, &procs), None);
    // No host of this home at all.
    assert_eq!(own_host_session(70701, &[], &procs), None);
}

#[test]
fn own_host_session_ends_on_a_parent_cycle() {
    let procs = procs(&[(10, 11, "a"), (11, 10, "b")]);
    assert_eq!(own_host_session(10, &[host("x", 99, None)], &procs), None);
}
