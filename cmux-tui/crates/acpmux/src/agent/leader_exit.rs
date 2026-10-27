//! A direct agent's leader exit as an event, for its stdout reader: the leader can exit while a
//! descendant still holds stdout open, and its exit ends the read regardless.

use tokio::process::Child;
#[cfg(windows)]
use tokio::sync::oneshot;

/// How long the reader keeps draining stdout after the agent process exits.
const LEADER_DRAIN: std::time::Duration = std::time::Duration::from_secs(2);

/// The exit of a direct agent's leader process, as an event: its own exit only, with no timer
/// and no wakeup before it (Unix: [`cmux_process::ExitEvent`], a kqueue `NOTE_EXIT` or a pidfd
/// in the reactor; Windows: a thread waiting on the process handle). The leader is not reaped
/// by it. Chromium waits for a child's exit the same way (`base/process/kill_mac.cc`, kqueue
/// `NOTE_EXIT`).
pub(super) struct LeaderExit {
    /// None when no event could be opened, or once it fired: the reader then ends only with
    /// stdout, as a leader's descendants that keep it open end.
    #[cfg(unix)]
    event: Option<tokio::io::unix::AsyncFd<cmux_process::ExitEvent>>,
    #[cfg(windows)]
    event: Option<oneshot::Receiver<()>>,
}

impl LeaderExit {
    /// The leader's exit event; open it before anything can reap `child`.
    #[cfg(unix)]
    pub(super) fn watch(child: &Child) -> Self {
        let event = child
            .id()
            .ok_or_else(|| std::io::Error::other("the agent has no pid"))
            .and_then(cmux_process::ExitEvent::open)
            .and_then(|event| {
                tokio::io::unix::AsyncFd::with_interest(event, tokio::io::Interest::READABLE)
            })
            .map_err(|e| tracing::warn!("no exit event for an agent reader: {e}"))
            .ok();
        Self { event }
    }

    /// The leader's exit event: a thread blocked on a duplicate of its process handle.
    #[cfg(windows)]
    pub(super) fn watch(child: &Child) -> Self {
        use std::os::windows::io::{AsRawHandle, BorrowedHandle};
        let Some(raw) = child.raw_handle() else { return Self { event: None } };
        // SAFETY: the handle of `child`, which owns it and outlives this call.
        let handle = match unsafe { BorrowedHandle::borrow_raw(raw) }.try_clone_to_owned() {
            Ok(handle) => handle,
            Err(e) => {
                tracing::warn!("no exit event for an agent reader: {e}");
                return Self { event: None };
            }
        };
        let (ended, event) = oneshot::channel();
        let spawned =
            std::thread::Builder::new().name("acpmux-leader-exit".into()).spawn(move || {
                // SAFETY: a live process handle this thread owns until it returns.
                unsafe {
                    windows_sys::Win32::System::Threading::WaitForSingleObject(
                        handle.as_raw_handle() as windows_sys::Win32::Foundation::HANDLE,
                        windows_sys::Win32::System::Threading::INFINITE,
                    );
                }
                let _ = ended.send(());
            });
        match spawned {
            Ok(_) => Self { event: Some(event) },
            Err(e) => {
                tracing::warn!("no exit event for an agent reader: {e}");
                Self { event: None }
            }
        }
    }

    /// Resolves once, when the leader has ended; pending after that and without an event.
    /// Cancel safe: the reader selects it with its stdout lines.
    pub(super) async fn ended(&mut self) {
        if let Some(event) = &mut self.event {
            #[cfg(unix)]
            let seen = event.readable().await.is_ok();
            #[cfg(windows)]
            let seen = event.await.is_ok();
            self.event = None;
            if seen {
                return;
            }
        }
        std::future::pending::<()>().await;
    }
}

/// The end of the [`LEADER_DRAIN`] window after the leader was seen gone at `gone`; pending
/// while the leader runs.
pub(super) async fn drain_end(gone: Option<tokio::time::Instant>) {
    match gone {
        Some(at) => tokio::time::sleep_until(at + LEADER_DRAIN).await,
        None => std::future::pending::<()>().await,
    }
}

#[cfg(all(test, unix))]
mod tests {
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    use tokio::sync::mpsc;

    use super::super::{ChildAgent, Inbound, Tap, WriteTicket};
    use crate::config::HarnessProfile;

    /// A leader that exits while its background child still holds stdout open: the exit event
    /// ends the read (no SIGCHLD, no poll), the reader reports the leader's own exit code, and
    /// the group's leftover is killed. Without the event the read would wait out the
    /// descendant's 60 s.
    #[tokio::test]
    async fn a_leader_exit_under_a_descendant_holding_stdout_is_reported() {
        let dir = std::env::temp_dir().join(format!(
            "acpmux-leader-exit-{}-{}",
            std::process::id(),
            line!()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let pid_file = dir.join("bg.pid");
        let script = format!("sleep 60 & echo $! > '{}'; exit 7", pid_file.display());
        let profile: HarnessProfile =
            serde_json::from_value(serde_json::json!({"argv": ["/bin/sh", "-c", script]})).unwrap();
        let (inbound, mut rx) = mpsc::channel(16);
        let tap: Tap = Arc::new(|_, _, _| Some(WriteTicket::done()));
        let started = Instant::now();
        let agent =
            ChildAgent::spawn("leader-exit", &profile, &dir, inbound, tap).await.expect("spawn");
        let code = loop {
            let next = tokio::time::timeout(Duration::from_secs(30), rx.recv())
                .await
                .expect("the leader's exit was not reported while a descendant held stdout")
                .expect("the reader ended without reporting the exit");
            if let Inbound::Exited { code, .. } = next {
                break code;
            }
        };
        assert!(started.elapsed() < Duration::from_secs(10), "late: {:?}", started.elapsed());
        assert_eq!(code, Some(7), "the leader's own exit code");
        assert!(!agent.is_alive().await);
        let pid: i32 = std::fs::read_to_string(&pid_file).unwrap().trim().parse().unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        // SAFETY: signal 0 only checks that the process exists.
        while unsafe { libc::kill(pid, 0) } == 0 {
            assert!(Instant::now() < deadline, "the descendant {pid} outlived its leader");
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
}
