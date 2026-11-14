use super::*;
use crate::config::HarnessKind;

/// `sr2 claude` is the case that starved (module docs, item 2).
#[test]
fn a_claude_launcher_defaults_to_normal_and_claude_itself_to_background() {
    let default = |kind, program: &str| default_for(kind, &[program.to_owned()]);
    for launcher in ["/Users/me/.local/bin/claude-sr2", "/Users/me/bin/sr", "sr2", "python3"] {
        assert_eq!(default(HarnessKind::ClaudeStdio, launcher), CpuClass::Normal, "{launcher}");
    }
    for agent in [
        "claude",
        "/opt/homebrew/bin/claude",
        "/x/bin/claude.exe",
        "/Users/me/.local/share/claude/versions/2.1.34",
        "/Users/me/.claude/local/node_modules/.bin/cli",
        "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js",
    ] {
        assert_eq!(default(HarnessKind::ClaudeStdio, agent), DEFAULT, "{agent}");
    }
    // An empty argv runs `claude`.
    assert_eq!(default_for(HarnessKind::ClaudeStdio, &[]), DEFAULT);
    // Another protocol keeps the default: no case of a relay is known there.
    assert_eq!(default(HarnessKind::Acp, "/Users/me/.local/bin/codex"), DEFAULT);
    assert_eq!(default(HarnessKind::Acp, "sr2"), DEFAULT);
}

#[test]
fn the_first_valid_source_names_the_class_else_the_default() {
    let bg = Some(CpuClass::Background);
    let normal = Some(CpuClass::Normal);
    let resolve = |profile, daemon, config| CpuClass::resolve(profile, daemon, config, DEFAULT);
    assert_eq!(resolve(None, None, None), CpuClass::Background);
    assert_eq!(resolve(None, None, normal), CpuClass::Normal);
    // The daemon's env overrides config; the profile overrides both.
    assert_eq!(resolve(None, Some("normal".into()), bg), CpuClass::Normal);
    assert_eq!(resolve(Some("background"), Some("normal".into()), None), CpuClass::Background);
    assert_eq!(resolve(Some(" Normal "), None, bg), CpuClass::Normal);
    // A value that names no class is skipped.
    assert_eq!(resolve(Some("utility"), Some("normal".into()), bg), CpuClass::Normal);
    assert_eq!(resolve(Some(""), None, None), CpuClass::Background);
    // What the harness defaults to comes last: any named class wins over it.
    let launcher = |profile, config| CpuClass::resolve(profile, None, config, CpuClass::Normal);
    assert_eq!(launcher(None, None), CpuClass::Normal);
    assert_eq!(launcher(Some("background"), None), CpuClass::Background);
    assert_eq!(launcher(None, bg), CpuClass::Background);
}

/// The 2026-11-04 stall: `sr2 claude` waits on its `claude`, which does the work. A launcher
/// that only waits must not read as a harness that does nothing.
#[cfg(target_os = "macos")]
#[test]
fn a_launchers_harness_state_counts_the_work_of_the_agent_it_started() {
    use std::io::BufRead;
    // The launcher (`sh`, kept by the `; :` after its one command) waits on its agent, which
    // spends CPU, says so, then waits on its input.
    let agent = "i=0; while [ $i -lt 100000 ]; do i=$((i+1)); done; echo worked; cat";
    let mut launcher = std::process::Command::new("/bin/sh")
        .args(["-c", &format!("/bin/sh -c '{agent}'; :")])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .expect("spawn the launcher");
    let mut said = String::new();
    let stdout = launcher.stdout.take().expect("its stdout");
    std::io::BufReader::new(stdout).read_line(&mut said).expect("the agent's line");
    assert_eq!(said.trim(), "worked");
    let state = harness_state(launcher.id()).expect("read the launcher");
    drop(launcher.stdin.take());
    let _ = launcher.kill();
    let _ = launcher.wait();
    // The launcher alone used a few ms; its agent's loop took far more.
    assert!(state.cpu_ms >= 100, "the agent's CPU time counts: {state:?}");
    // The error names the launcher and the agent it started, with the agent's own work.
    // Named by the kernel (macOS's `/bin/sh` runs as `bash`, so no fixed name is asserted).
    assert!(!state.name.is_empty(), "the launcher's name: {state:?}");
    let agent = state.first_child.as_ref().expect("the agent the launcher started");
    assert!(!agent.name.is_empty(), "the agent's name: {state:?}");
    assert_ne!(agent.pid, state.pid);
    assert!(agent.cpu_ms >= 50, "the agent's own CPU time: {state:?}");
    let said = state.to_string();
    let named = format!("; the first process it started is {} (pid {}), ", agent.name, agent.pid);
    assert!(said.contains(&named), "{said}");
}

/// #36028: a start's error says which process it read and what its launcher started, so a
/// launcher that never started its agent reads apart from an agent that is slow.
#[test]
fn a_deadline_clause_names_the_launcher_and_the_agent_it_started() {
    let launcher = HarnessState {
        pid: 9104,
        priority: 20,
        background: false,
        ran_secs: 87,
        cpu_ms: 140,
        threads: 20,
        threads_running: 0,
        processes: 2,
        pageins: 1800,
        name: "sr2".to_owned(),
        first_child: Some(ChildSeen {
            pid: 9120,
            name: "claude".to_owned(),
            cpu_ms: 40,
            pageins: 1700,
        }),
    };
    assert_eq!(
        launcher.to_string(),
        "its agent process (pid 9104, sr2, 2 processes in all) is alive at normal CPU class \
             (priority 20), ran 87 s, used 0.1 s of CPU, 0 of 20 threads running, 1800 page-ins; \
             the first process it started is claude (pid 9120), which used 0.0 s of CPU and 1700 \
             page-ins"
    );
    let alone = HarnessState { first_child: None, processes: 1, ..launcher.clone() };
    assert!(alone.to_string().ends_with("; it has started no process"), "{alone}");
    // A platform that names no process adds nothing.
    let unnamed = HarnessState { name: String::new(), ..alone };
    assert!(unnamed.to_string().ends_with(" page-ins"), "{unnamed}");
}

#[test]
fn a_page_in_or_a_process_change_is_work_and_waiting_alone_is_not() {
    let idle = HarnessState {
        pid: 1,
        priority: 31,
        background: false,
        ran_secs: 60,
        cpu_ms: 100,
        threads: 12,
        threads_running: 0,
        processes: 2,
        pageins: 500,
        name: String::new(),
        first_child: None,
    };
    let w = WORK_WINDOW;
    assert!(!idle.worked_since(&idle, w));
    assert!(HarnessState { pageins: 501, ..idle.clone() }.worked_since(&idle, w));
    assert!(HarnessState { processes: 3, ..idle.clone() }.worked_since(&idle, w));
    assert!(HarnessState { cpu_ms: 100 + WORK_CPU_MS, ..idle.clone() }.worked_since(&idle, w));
    // #36028: an idle launcher's runtime ticks (0.6 ms per 10 s for `sr2`) are not work.
    assert!(!HarnessState { cpu_ms: 101, ..idle.clone() }.worked_since(&idle, w));
    assert!(HarnessState { threads_running: 1, ..idle.clone() }.worked_since(&idle, w));
    // The bar is a rate: a read 1 s on asks for a whole window's budget, a read 30 s on (a
    // skipped tick) for three.
    let second = std::time::Duration::from_secs(1);
    assert!(!HarnessState { cpu_ms: 104, ..idle.clone() }.worked_since(&idle, second));
    assert!(HarnessState { cpu_ms: 105, ..idle.clone() }.worked_since(&idle, second));
    let late = std::time::Duration::from_secs(30);
    assert!(!HarnessState { cpu_ms: 114, ..idle.clone() }.worked_since(&idle, late));
    assert!(HarnessState { cpu_ms: 115, ..idle.clone() }.worked_since(&idle, late));
}

#[cfg(target_os = "linux")]
#[test]
fn linux_harness_cpu_ticks_reads_one_process_record() {
    assert!(harness_cpu_ticks(std::process::id()).is_some());
}
