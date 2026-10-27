//! Every thread the Chief starts runs under one [`Supervisor`]
//! (`cmux_panic_log::supervise`), built by the process's composition root
//! (`host::run`, a CLI command) and passed to the code that starts threads.
//!
//! The policy is [`Fatal`], Chromium's: a thread that crashes takes the
//! process down (`content/browser/browser_main_loop.cc`), and its host
//! relaunches it. A worker that panicked used to end alone and leave the
//! host running with a turn, a link or a ticker gone: alive, serving
//! nothing. Now the host logs one `FATAL` line (stderr, which the app writes
//! to `host.log`; the error journal reads it by its level word) and exits
//! [`SUPERVISED_FATAL_EXIT_CODE`]; `ChiefBrainWatch` starts it again and the
//! memory database restores its state.

use std::sync::Arc;
use std::time::Duration;

use cmux_panic_log::{
    Failure, FailureSink, Fatal, FatalReport, SUPERVISED_FATAL_EXIT_CODE, ShutdownBehavior,
    StopToken, SuperviseError, Supervisor, WorkerHandle,
};

/// The sink of a Chief process: a `FATAL` line, then `exit`.
pub struct ExitChief {
    exit: fn(i32),
}

impl ExitChief {
    /// `exit` ends the process; [`exiting`] passes `std::process::exit`.
    pub fn new(exit: fn(i32)) -> ExitChief {
        ExitChief { exit }
    }
}

impl FailureSink for ExitChief {
    fn restarting(&self, worker: &str, failure: &Failure, backoff: Duration) {
        crate::log::log(format!(
            "WARN supervised worker {worker} {failure}; restarting in {} ms",
            backoff.as_millis()
        ));
    }

    fn fatal(&self, report: &FatalReport) {
        crate::log::log(format!(
            "FATAL {report}; exiting {SUPERVISED_FATAL_EXIT_CODE} so the app starts the Chief again"
        ));
        (self.exit)(SUPERVISED_FATAL_EXIT_CODE);
    }
}

fn exit_process(code: i32) {
    std::process::exit(code);
}

/// The supervisor of one Chief process (the host, or a CLI command): a fatal
/// worker failure ends the process. Tests use it too, so a worker panic in a
/// test fails the test run instead of hanging it.
pub fn exiting() -> Supervisor {
    Supervisor::new(Arc::new(ExitChief::new(exit_process)))
}

/// Runs `body` once on its own thread `name`: background work for one
/// request (a turn, a fetch, a timer). [`Fatal`]: the request's owner waits
/// on its answer, so a panic ends the process rather than leaving it
/// waiting. Skipped at shutdown (`base::TaskShutdownBehavior::SKIP_ON_SHUTDOWN`).
pub fn background(
    supervisor: &Supervisor,
    name: &str,
    body: impl FnOnce() + Send + 'static,
) -> Result<WorkerHandle, SuperviseError> {
    supervisor.supervise_thread(name, Fatal, ShutdownBehavior::Skip, move |_: &StopToken| {
        body();
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicI32, Ordering};
    use std::sync::mpsc;

    static EXITED: AtomicI32 = AtomicI32::new(0);

    fn record_exit(code: i32) {
        EXITED.store(code, Ordering::SeqCst);
    }

    /// Exits through `record_exit`, then forwards the fatal report.
    struct Forward(std::sync::Mutex<mpsc::Sender<FatalReport>>, ExitChief);

    impl FailureSink for Forward {
        fn fatal(&self, report: &FatalReport) {
            self.1.fatal(report);
            let tx = self
                .0
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let _ = tx.send(report.clone());
        }
    }

    #[test]
    fn a_background_panic_is_fatal_and_exits_70() {
        let (tx, rx) = mpsc::channel();
        let sink = Forward(std::sync::Mutex::new(tx), ExitChief::new(record_exit));
        let supervisor = Supervisor::new(Arc::new(sink));
        background(&supervisor, "optchat-test-panics", || {
            panic!("a worker bug")
        })
        .unwrap_or_else(|e| panic!("the worker did not start: {e}"));
        let report = rx
            .recv_timeout(Duration::from_secs(10))
            .unwrap_or_else(|e| panic!("no fatal report: {e}"));
        assert_eq!(report.worker, "optchat-test-panics");
        assert!(
            matches!(
                &report.reason,
                cmux_panic_log::FatalReason::Failed(Failure::Panicked { message })
                    if message == "a worker bug"
            ),
            "{report:?}"
        );
        assert_eq!(EXITED.load(Ordering::SeqCst), SUPERVISED_FATAL_EXIT_CODE);
    }

    #[test]
    fn a_background_body_that_returns_is_not_a_failure() {
        let supervisor = exiting();
        let (tx, rx) = mpsc::channel();
        background(&supervisor, "optchat-test-returns", move || {
            let _ = tx.send(());
        })
        .unwrap_or_else(|e| panic!("the worker did not start: {e}"));
        rx.recv_timeout(Duration::from_secs(10))
            .unwrap_or_else(|e| panic!("the body did not run: {e}"));
    }
}
