//! The machine's assignments: what the store asks this Cloud machine to do with a chat.
//!
//! The daemon holds one request open at the store (at most 25 s) and asks again as soon as it
//! returns, so an assignment arrives when it is made, also right after a start or a resume.
//!
//! The reader only reads. Each assignment it reads is told to the holder loop
//! (`HolderHandle::assigned`), which does the work in the chat's own order
//! (`runtime/run.rs` `assigned`): import the chat, take its inbox (`runtime/inbox.rs`), ack the
//! assignment, renew at work. So one place imports, drains and acks.
//!
//! - `takeover`: the chat's copy becomes a chat here and goes on with its work.
//! - `create`: a chat started with no laptop; its first message is in its inbox.
//! - `deliver`: messages for a chat that is here.
//!
//! An assignment stays at the store until it is acked, so the reader reads it again while its
//! work runs. A repeat changes nothing in the loop, and the reader asks less often for as long
//! as a round brings only repeats.

use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_auto_session::AutoCloud;
use cmux_auto_session::consts::WAIT_MAX_MS;
use cmux_auto_session::wire::Assignment;

/// The shortest time between two asks that had nothing to do: a wait that comes back empty at
/// once (a resume, a store that does not hold) does not spin.
const ROUND_MIN: Duration = Duration::from_secs(1);
/// The shortest time before asking again when every assignment read was told before: the
/// store answers an assignment at once until it is acked, and its work may take a while.
const REPEAT_MIN: Duration = Duration::from_secs(5);
/// After a failure the next ask waits this long, doubling up to [`BACKOFF_MAX`].
const BACKOFF_MIN: Duration = Duration::from_secs(1);
const BACKOFF_MAX: Duration = Duration::from_secs(60);

/// Told of each assignment the reader reads.
type Tell = Box<dyn Fn(&Assignment) + Send + Sync>;

/// One assignment as the reader remembers it: the chat, its epoch and what was asked.
type Told = (String, u64, &'static str);

/// How one round of the reader ended.
enum Round {
    /// Something read was told for the first time, or nothing was assigned.
    Done,
    /// Everything read was told before and is still not acked.
    Repeat,
    Failed,
}

/// This machine's reader of its assignments.
pub struct Machine<C> {
    cloud: Arc<C>,
    /// Who does an assignment's work: the holder loop.
    tell: Tell,
}

impl<C: AutoCloud + 'static> Machine<C> {
    /// A reader over `cloud`, this machine's transport. `tell` gets each assignment and does
    /// its work (the holder loop: it imports, drains and acks in the chat's own order). An
    /// assignment is told again each time the store answers it, until it is acked.
    pub fn telling(
        cloud: Arc<C>,
        tell: impl Fn(&Assignment) + Send + Sync + 'static,
    ) -> Arc<Machine<C>> {
        Arc::new(Machine { cloud, tell: Box::new(tell) })
    }

    /// Asks for assignments and tells them, for as long as the daemon runs.
    pub async fn run(self: Arc<Self>) {
        let mut backoff = BACKOFF_MIN;
        let mut told: Vec<Told> = Vec::new();
        loop {
            let asked = Instant::now();
            let round = match self.cloud.assignments(WAIT_MAX_MS).await {
                Ok(assignments) => tell_all(&self.tell, &assignments, &mut told),
                Err(error) => {
                    tracing::debug!("auto mode: assignments were not read: {error}");
                    Round::Failed
                }
            };
            // A timer, not a poll: the store holds the next ask until there is news.
            let floor = match round {
                Round::Done => ROUND_MIN,
                Round::Repeat => REPEAT_MIN,
                Round::Failed => backoff,
            };
            backoff = match round {
                Round::Failed => (backoff * 2).min(BACKOFF_MAX),
                Round::Done | Round::Repeat => BACKOFF_MIN,
            };
            tokio::time::sleep(floor.saturating_sub(asked.elapsed())).await;
        }
    }
}

/// Tells each of `assignments`, and keeps in `told` what this round read.
fn tell_all(tell: &Tell, assignments: &[Assignment], told: &mut Vec<Told>) -> Round {
    let now: Vec<Told> = assignments
        .iter()
        .map(|assignment| {
            let view = &assignment.session;
            (view.id.clone(), view.epoch, assignment.kind.as_str())
        })
        .collect();
    for assignment in assignments {
        tell(assignment);
    }
    let repeat = !now.is_empty() && now.iter().all(|one| told.contains(one));
    *told = now;
    if repeat { Round::Repeat } else { Round::Done }
}
