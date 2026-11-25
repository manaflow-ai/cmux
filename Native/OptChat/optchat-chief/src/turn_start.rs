//! The turn-start digest: shell commands the user names in cmux.json
//! (`chief.turnStart`, an array of strings) that the host runs at the start
//! of each main Chief turn, their output put in the turn's tail as a
//! `<turn-start>` block next to `<turn-checks>` (after the cache marks,
//! never logged). What a person would glance at before answering (open
//! pull requests, a fleet's state, the inbox count) reaches the turn
//! without a tool call (Leo, 2026-11-24: "refresh chief ... against
//! capabilities of cmux and other optimizations we've done on workflows").
//!
//! Bounded so the brain loop never waits past it: every command runs at
//! once (`sh -c`, cwd `$HOME`, stdin closed) in its own process group; a
//! command still running at the deadline is killed with its group and adds
//! one line `<cmd>: timed out`; a failed one adds `<cmd>: exit N`. Output
//! is trimmed, empty output adds nothing, and the whole block is capped.
//! None named, or no shell on the host: no block and nothing runs.

use std::io::Read;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

/// The cmux.json key of the commands.
pub const KEY: &str = "chief.turnStart";
/// How long one command may run.
pub const TIMEOUT: Duration = Duration::from_secs(8);
/// The digest's most bytes (all commands together).
pub const CAP: usize = 2000;
/// The shell the commands run in.
const SHELL: &str = "/bin/sh";

/// The commands the user named (cmux.json `chief.turnStart`), read now so
/// an edit applies from the next turn.
pub fn commands() -> Vec<String> {
    crate::turn_user_extras::named(crate::turn_user_extras::document().as_ref(), KEY)
}

/// The `<turn-start>` block for this turn: the named commands' digest, or
/// None when none is named, the host has no shell or nothing came out.
pub fn block() -> Option<String> {
    let commands = commands();
    if commands.is_empty() || !Path::new(SHELL).exists() {
        return None;
    }
    let home = std::env::var_os("HOME")?;
    let text = digest(&commands, Path::new(&home), TIMEOUT, CAP)?;
    Some(format!("<turn-start>\n{text}\n</turn-start>"))
}

/// What one command left: its trimmed output and a short line when it failed.
fn run_one(cmd: &str, cwd: &Path, timeout: Duration) -> String {
    let label = label(cmd);
    let child = Command::new(SHELL)
        .arg("-c")
        .arg(cmd)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn();
    let mut child = match child {
        Ok(c) => c,
        Err(e) => return format!("{label}: could not start ({e})"),
    };
    let pgid = child.id() as i32;
    // The output is read on its own thread: a command that fills the pipe
    // never blocks on us, and one whose grandchild keeps the pipe open
    // never blocks the reader's caller past the deadline.
    let (tx, rx) = mpsc::channel();
    if let Some(mut out) = child.stdout.take() {
        std::thread::spawn(move || {
            let mut buf = Vec::new();
            let _ = out.by_ref().take(CAP as u64 * 4).read_to_end(&mut buf);
            let _ = tx.send(buf);
        });
    }
    let deadline = Instant::now() + timeout;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(20));
            }
            _ => {
                // SAFETY: a signal to the group this runner started; its
                // leader is not reaped yet, so the id is still that group's.
                unsafe {
                    libc::kill(-pgid, libc::SIGKILL);
                }
                let _ = child.wait();
                break None;
            }
        }
    };
    let out = rx
        .recv_timeout(Duration::from_millis(200))
        .map(|b| String::from_utf8_lossy(&b).trim().to_owned())
        .unwrap_or_default();
    let note = match status {
        None => Some(format!("{label}: timed out")),
        Some(s) if s.success() => None,
        Some(s) => Some(match s.code() {
            Some(code) => format!("{label}: exit {code}"),
            None => format!("{label}: killed"),
        }),
    };
    [Some(out), note]
        .into_iter()
        .flatten()
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}

/// A command as its failure line names it: its first 60 characters.
fn label(cmd: &str) -> String {
    let cmd = cmd.trim();
    match cmd.char_indices().nth(60) {
        Some((i, _)) => format!("{}…", &cmd[..i]),
        None => cmd.to_owned(),
    }
}

/// Runs every command at once and joins what each left, in their order,
/// capped at `cap` bytes; None when all left nothing. Returns by `timeout`
/// plus a short grace even when a command ignores its kill.
pub fn digest(commands: &[String], cwd: &Path, timeout: Duration, cap: usize) -> Option<String> {
    let (tx, rx) = mpsc::channel();
    for (i, cmd) in commands.iter().enumerate() {
        let (tx, cmd, cwd) = (tx.clone(), cmd.clone(), cwd.to_owned());
        std::thread::spawn(move || {
            let _ = tx.send((i, run_one(&cmd, &cwd, timeout)));
        });
    }
    drop(tx);
    let deadline = Instant::now() + timeout + Duration::from_millis(500);
    let mut parts: Vec<Option<String>> = vec![None; commands.len()];
    while let Some(left) = deadline.checked_duration_since(Instant::now()) {
        match rx.recv_timeout(left) {
            Ok((i, text)) => parts[i] = Some(text),
            Err(_) => break,
        }
    }
    let mut text = parts
        .into_iter()
        .enumerate()
        .map(|(i, p)| p.unwrap_or_else(|| format!("{}: timed out", label(&commands[i]))))
        .filter(|p| !p.is_empty())
        .collect::<Vec<_>>()
        .join("\n");
    if text.len() > cap {
        let mut end = cap.saturating_sub("\n…".len());
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        text.truncate(end);
        text.push_str("\n…");
    }
    (!text.is_empty()).then_some(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(cmds: &[&str], timeout: Duration, cap: usize) -> Option<String> {
        let cmds: Vec<String> = cmds.iter().map(|c| (*c).to_owned()).collect();
        digest(&cmds, &std::env::temp_dir(), timeout, cap)
    }

    #[test]
    fn output_is_trimmed_and_kept_in_order() {
        let text = run(&["sleep 0.2; echo '  one  '", "echo two"], TIMEOUT, CAP).unwrap();
        assert_eq!(text, "one\ntwo");
    }

    #[test]
    fn empty_output_is_omitted_and_all_empty_is_no_block() {
        assert_eq!(run(&["true", "printf '  \\n'"], TIMEOUT, CAP), None);
        assert_eq!(run(&["true", "echo x"], TIMEOUT, CAP).as_deref(), Some("x"));
        assert_eq!(run(&[], TIMEOUT, CAP), None);
    }

    #[test]
    fn a_failure_adds_one_short_line() {
        let text = run(&["echo partial; exit 3"], TIMEOUT, CAP).unwrap();
        assert_eq!(text, "partial\necho partial; exit 3: exit 3");
    }

    #[test]
    fn a_slow_command_is_killed_at_the_bound_and_others_still_count() {
        let started = Instant::now();
        let text = run(
            &["sleep 30 & sleep 30; echo late", "echo fast"],
            Duration::from_millis(300),
            CAP,
        )
        .unwrap();
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "{:?}",
            started.elapsed()
        );
        assert_eq!(text, "sleep 30 & sleep 30; echo late: timed out\nfast");
    }

    #[test]
    fn the_digest_is_capped() {
        let text = run(&["yes 'a line of output' | head -500"], TIMEOUT, 100).unwrap();
        assert!(text.len() <= 100, "{}", text.len());
        assert!(text.ends_with('…'), "{text}");
    }
}
