//! The runner behind the Chief's `watch` tool (brain/watches.rs): one thread
//! per watch runs its command (`sh -c`, stdout and stderr together) in its
//! own process group, off the Chief's turn, and reports once how it ended:
//! a line matched `until`, the command exited (no `until`), or the deadline
//! passed. A command that exits without a match runs again after
//! [`POLL`]. The host signals only the process group it started for the
//! watch: on a match, on the deadline, on cancel, and when the host stops
//! (dropping the [`Running`] handle kills it at once).

use std::collections::VecDeque;
use std::io::{BufRead, BufReader};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, channel};
use std::time::Duration;

use crate::state::Watch;

/// How long a command that exited without matching waits to run again.
pub const POLL: Duration = Duration::from_secs(chief_kernel::tools::WATCH_POLL_SECONDS);

/// How many output lines the note shows.
pub const TAIL_LINES: usize = 5;

/// The longest output line the note shows, in characters.
const LINE_MAX: usize = 300;

/// How a watch ended.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Ending {
    /// A line matched `until`: that line.
    Matched(String),
    /// The command exited (no `until`): its code, or the signal that ended it.
    Exited(String),
    /// The deadline passed.
    TimedOut,
    /// The command could not start.
    Failed(String),
}

/// One watch's ending with its last output lines.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Fired {
    pub id: String,
    pub ending: Ending,
    pub tail: Vec<String>,
}

enum Event {
    Line(String),
    Eof,
    Cancel,
}

/// A running watch. Dropping it (cancel, or the host stopping) kills its
/// process group at once and ends its thread without a report.
pub struct Running {
    events: Sender<Event>,
    /// The running command's process group, 0 when none runs.
    group: Arc<AtomicI32>,
    /// Its last output lines so far (the `watch` list shows them).
    latest: Arc<Mutex<VecDeque<String>>>,
}

impl Running {
    /// The watch's last output lines so far, oldest first (at most
    /// [`TAIL_LINES`]): what it printed most recently, across its reruns.
    pub fn latest(&self) -> Vec<String> {
        self.latest
            .lock()
            .map(|l| l.iter().cloned().collect())
            .unwrap_or_default()
    }
}

impl Drop for Running {
    fn drop(&mut self) {
        kill_group(&self.group);
        let _ = self.events.send(Event::Cancel);
    }
}

/// Kills the process group in `group` (once) when one runs.
fn kill_group(group: &AtomicI32) {
    let pgid = group.swap(0, Ordering::SeqCst);
    if pgid > 0 {
        // SAFETY: a plain signal to the process group this runner started;
        // its leader is not reaped yet, so the id is still that group's.
        unsafe {
            libc::kill(-pgid, libc::SIGKILL);
        }
    }
}

/// Starts `watch` on its own thread; `fired` gets its ending once, unless the
/// handle is dropped first. `now_ms` is the wall clock (ms since the epoch).
pub fn start(
    watch: &Watch,
    now_ms: fn() -> u64,
    fired: impl FnOnce(Fired) + Send + 'static,
) -> Running {
    let (events, rx) = channel::<Event>();
    let group = Arc::new(AtomicI32::new(0));
    let latest = Arc::new(Mutex::new(VecDeque::new()));
    let handle = Running {
        events: events.clone(),
        group: group.clone(),
        latest: latest.clone(),
    };
    let watch = watch.clone();
    std::thread::spawn(move || {
        if let Some(ending) = run(&watch, now_ms, &events, &rx, &group, &latest) {
            fired(ending);
        }
    });
    handle
}

/// Runs `watch` to its ending; None when it was cancelled.
fn run(
    watch: &Watch,
    now_ms: fn() -> u64,
    events: &Sender<Event>,
    rx: &Receiver<Event>,
    group: &AtomicI32,
    latest: &Mutex<VecDeque<String>>,
) -> Option<Fired> {
    let until = watch
        .until
        .as_deref()
        .and_then(|u| regex::Regex::new(u).ok());
    let left = || Duration::from_millis(watch.deadline_ms.saturating_sub(now_ms()));
    let mut tail: VecDeque<String> = VecDeque::new();
    let report = |ending: Ending, tail: &VecDeque<String>| {
        Some(Fired {
            id: watch.id.clone(),
            ending,
            tail: tail.iter().cloned().collect(),
        })
    };
    loop {
        if left().is_zero() {
            return report(Ending::TimedOut, &tail);
        }
        let mut child = match Command::new("/bin/sh")
            .arg("-c")
            .arg(format!("exec 2>&1\n{}", watch.command))
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .process_group(0)
            .spawn()
        {
            Ok(child) => child,
            Err(e) => return report(Ending::Failed(e.to_string()), &tail),
        };
        let pid = child.id() as i32;
        group.store(pid, Ordering::SeqCst);
        if let Some(out) = child.stdout.take() {
            let lines = events.clone();
            std::thread::spawn(move || {
                for line in BufReader::new(out).split(b'\n') {
                    let Ok(line) = line else { break };
                    let line = String::from_utf8_lossy(&line).trim_end().to_owned();
                    if lines.send(Event::Line(line)).is_err() {
                        return;
                    }
                }
                let _ = lines.send(Event::Eof);
            });
        }
        tail.clear();
        let ending = loop {
            match rx.recv_timeout(left()) {
                Ok(Event::Line(line)) => {
                    if line.trim().is_empty() {
                        continue;
                    }
                    let shown: String = line.chars().take(LINE_MAX).collect();
                    if tail.len() == TAIL_LINES {
                        tail.pop_front();
                    }
                    tail.push_back(shown.clone());
                    // The list's copy is kept across reruns: a polled command
                    // shows what its last run printed.
                    if let Ok(mut l) = latest.lock() {
                        if l.len() == TAIL_LINES {
                            l.pop_front();
                        }
                        l.push_back(shown.clone());
                    }
                    if until.as_ref().is_some_and(|re| re.is_match(&line)) {
                        break Some(Ending::Matched(shown));
                    }
                }
                Ok(Event::Eof) => break None,
                Ok(Event::Cancel) | Err(RecvTimeoutError::Disconnected) => {
                    kill_group(group);
                    let _ = child.wait();
                    return None;
                }
                Err(RecvTimeoutError::Timeout) => break Some(Ending::TimedOut),
            }
        };
        if let Some(ending) = ending {
            kill_group(group);
            let _ = child.wait();
            return report(ending, &tail);
        }
        // Its output ended: wait for the leader without reaping it, so its
        // group id stays this group's while what it left behind is killed.
        wait_unreaped(pid);
        kill_group(group);
        let status = child.wait();
        if until.is_none() {
            let code = match status {
                Ok(s) => match (s.code(), s.signal()) {
                    (Some(c), _) => format!("exit code {c}"),
                    (None, Some(sig)) => format!("signal {sig}"),
                    _ => "an unknown status".to_owned(),
                },
                Err(e) => e.to_string(),
            };
            return report(Ending::Exited(code), &tail);
        }
        // A check that did not match yet: run it again after POLL.
        if let Ok(Event::Cancel) | Err(RecvTimeoutError::Disconnected) =
            rx.recv_timeout(POLL.min(left()))
        {
            return None;
        }
    }
}

/// Waits until process `pid` (a child) exits, leaving it unreaped.
fn wait_unreaped(pid: i32) {
    // SAFETY: waitid on our own child with WNOWAIT only reads its state;
    // `info` is a zeroed out-parameter.
    unsafe {
        let mut info: libc::siginfo_t = std::mem::zeroed();
        while libc::waitid(
            libc::P_PID,
            pid as libc::id_t,
            &mut info,
            libc::WEXITED | libc::WNOWAIT,
        ) == -1
            && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted
        {}
    }
}
