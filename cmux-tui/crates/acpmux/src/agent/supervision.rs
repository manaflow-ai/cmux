//! A daemon agent's own tasks run under the daemon's supervisor: its readers log to and
//! act on the hub's session, so a panic in them is `Fatal` (`crate::supervised`).

use std::future::Future;

use super::ChildAgent;
use crate::supervised::{Fatal, ShutdownBehavior};

impl ChildAgent {
    /// Starts `work`, a task of this agent, under the daemon's supervisor with `policy`
    /// and `shutdown`.
    pub(super) fn supervise(
        &self,
        name: &str,
        policy: Fatal,
        shutdown: ShutdownBehavior,
        work: impl Future<Output = ()> + Send + 'static,
    ) {
        crate::supervised::task_boxed(&self.supervisor, name, policy, shutdown, Box::pin(work));
    }
}
