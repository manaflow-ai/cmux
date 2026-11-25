//! Who sent the daemon's SIGTERM. The stop line names the sender (its pid, parent and command
//! line), so a stop that no client asked for can be traced to the process that signalled it.
//!
//! After a NIGHTLY update relaunch on macOS the old daemon sometimes got a SIGTERM about 1 s after
//! the app quit, before the new app started, and its agent host was lost with it
//! (manaflow-ai/cmuxterm-hq#6338): the log said only "SIGTERM", so nothing named who sent it.
//!
//! A `SA_SIGINFO` action beside tokio's own records `si_pid` (both go through
//! `signal-hook-registry`, which runs every action registered for the signal). The action only
//! stores an integer, so it is async-signal-safe; the description is read later, on the stop.

use std::sync::atomic::{AtomicI32, Ordering};

/// The pid of the last SIGTERM's sender; 0 when none came or the kernel named none.
static SENDER: AtomicI32 = AtomicI32::new(0);

/// Records each SIGTERM's sender from now on. Call it only after tokio's own SIGTERM stream is
/// registered: this action alone would replace SIGTERM's default action (the process would no
/// longer end on it). Every action runs inside the same signal delivery, so the sender is stored
/// before the daemon's task reads the stream's wake-up.
pub(crate) fn record() {
    // SAFETY: the action only does an atomic store, which is async-signal-safe.
    let registered = unsafe {
        signal_hook_registry::register_sigaction(libc::SIGTERM, |info: &libc::siginfo_t| {
            // SAFETY: SIGTERM's siginfo carries the sender's pid (kill(2), or 0 from the kernel).
            SENDER.store(info.si_pid(), Ordering::SeqCst);
        })
    };
    if let Err(error) = registered {
        tracing::warn!(%error, "cannot record who sends SIGTERM");
    }
}

/// The last SIGTERM's sender, if one was recorded.
pub(crate) fn last() -> Option<i32> {
    match SENDER.load(Ordering::SeqCst) {
        pid if pid > 0 => Some(pid),
        _ => None,
    }
}

/// [`last`], once the action that stores it has run. Tokio's own action runs first and may wake
/// the reader on another thread before ours stored the sender: wait for it, briefly and bounded
/// (#35147 review F1).
pub(crate) async fn settled() -> Option<i32> {
    for _ in 0..20 {
        if let Some(pid) = last() {
            return Some(pid);
        }
        tokio::time::sleep(std::time::Duration::from_millis(1)).await;
    }
    last()
}

/// The text the stop line gives the sender `pid`: its pid, then its parent and command line when
/// the process table still lists it (`ps`, bounded by the process's own speed).
pub(crate) fn describe(pid: i32) -> String {
    let row = |pid: i32| -> Option<(i32, String)> {
        let out = std::process::Command::new("/bin/ps")
            .args(["-o", "ppid=,command=", "-p", &pid.to_string()])
            .stdin(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .output()
            .ok()?;
        parse_row(&String::from_utf8_lossy(&out.stdout))
    };
    match row(pid) {
        Some((ppid, command)) => {
            let parent = row(ppid).map(|(_, c)| c).unwrap_or_else(|| "gone".into());
            format!("pid {pid} ({command}), parent {ppid} ({parent})")
        }
        None => format!("pid {pid} (already gone)"),
    }
}

/// `ppid command` from one `ps -o ppid=,command=` row.
fn parse_row(text: &str) -> Option<(i32, String)> {
    let line = text.lines().find(|l| !l.trim().is_empty())?.trim_start();
    let (ppid, command) = line.split_once(char::is_whitespace)?;
    let mut command = command.trim().to_string();
    if command.len() > 300 {
        let mut end = 300;
        while !command.is_char_boundary(end) {
            end -= 1;
        }
        command.truncate(end);
    }
    Some((ppid.parse().ok()?, command))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_ps_row_gives_the_parent_and_the_command() {
        assert_eq!(
            parse_row("  4021 /bin/sh -c kill -TERM 12\n"),
            Some((4021, "/bin/sh -c kill -TERM 12".into()))
        );
        assert_eq!(parse_row(""), None);
    }

    #[test]
    fn this_process_is_described_with_its_command() {
        let text = describe(std::process::id() as i32);
        assert!(text.starts_with(&format!("pid {} (", std::process::id())), "{text}");
        assert!(!text.contains("already gone"), "{text}");
    }
}
