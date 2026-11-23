//! The machine's assignments: what the store asks this Cloud machine to do with a chat.
//!
//! The daemon holds one request open at the store (at most 25 s) and asks again as soon as it
//! returns, so an assignment arrives when it is made, also right after a start or a resume.
//! Each one is handled whole, in this order: import the chat ([`SessionImporter`]), put its
//! inbox into the chat's queue, ack the inbox, ack the assignment. An assignment that fails at
//! any step is not acked: the store answers it again and the steps that were done answer the
//! same (an import by chat and epoch, a message by its id).
//!
//! - `takeover`: the chat's copy becomes a chat here and goes on with its work.
//! - `create`: a chat started with no laptop; its first message is in its inbox.
//! - `deliver`: messages for a chat that is here.
//!
//! A reader made with [`Machine::telling`] does none of that work: it reads, and tells the
//! holder loop, which does it.
//!
//! A message is in the chat's own log before the inbox is acked: its prompt is queued under
//! the message's id and the ack waits until the hub has recorded it. Sent again after a crash
//! between the two, the same id is answered from the log and does not run twice.

use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_auto_session::AutoCloud;
use cmux_auto_session::consts::WAIT_MAX_MS;
use cmux_auto_session::wire::{Assignment, Fence, Holder, InboxAck, InboxMessage, SessionView};
use serde_json::json;

use crate::auto_session::{ImportError, ImportReason, Imported, SessionImporter};
use crate::hub::{Hub, PromptOptions, Session};

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
    /// Everything read was done, or told for the first time.
    Done,
    /// Everything read was told before and is still not acked.
    Repeat,
    Failed,
}

/// This machine's side of its assignments.
pub struct Machine<C> {
    hub: Arc<Hub>,
    cloud: Arc<C>,
    me: Holder,
    importer: Arc<dyn SessionImporter>,
    /// Who does an assignment's work: None, this reader ([`Machine::handle`]); else the one
    /// told, and the reader only reads.
    tell: Option<Tell>,
}

impl<C: AutoCloud + 'static> Machine<C> {
    /// `me` is this machine's holder name, `vm:<machine>`. The reader does each assignment's
    /// work itself.
    pub fn new(
        hub: Arc<Hub>,
        cloud: Arc<C>,
        me: Holder,
        importer: Arc<dyn SessionImporter>,
    ) -> Arc<Machine<C>> {
        Arc::new(Machine { hub, cloud, me, importer, tell: None })
    }

    /// A reader that only reads: `tell` gets each assignment and does its work (the holder
    /// loop: it imports, drains and acks in the chat's own order). An assignment is told again
    /// each time the store answers it, until it is acked.
    pub fn telling(
        hub: Arc<Hub>,
        cloud: Arc<C>,
        me: Holder,
        importer: Arc<dyn SessionImporter>,
        tell: impl Fn(&Assignment) + Send + Sync + 'static,
    ) -> Arc<Machine<C>> {
        Arc::new(Machine { hub, cloud, me, importer, tell: Some(Box::new(tell)) })
    }

    /// One assignment, whole: import, inbox, acks. `Ok` means the store was told it is done.
    pub async fn handle(&self, assignment: &Assignment) -> Result<Imported, ImportError> {
        let view = &assignment.session;
        let imported = self.importer.import(view, ImportReason::from(assignment.kind)).await?;
        self.drain(view).await?;
        let fence = Fence::new(self.me.clone(), view.epoch);
        self.cloud.ack_assignment(&view.id, &fence).await?;
        Ok(imported)
    }

    /// [`drain_inbox`] as this machine.
    pub async fn drain(&self, view: &SessionView) -> Result<u64, ImportError> {
        drain_inbox(&self.hub, self.cloud.as_ref(), &self.me, view).await
    }

    /// Asks for assignments and handles them, for as long as the daemon runs.
    pub async fn run(self: Arc<Self>) {
        let mut backoff = BACKOFF_MIN;
        let mut told: Vec<Told> = Vec::new();
        loop {
            let asked = Instant::now();
            let round = match self.cloud.assignments(WAIT_MAX_MS).await {
                Ok(assignments) => match &self.tell {
                    Some(tell) => tell_all(tell, &assignments, &mut told),
                    None => self.handle_all(&assignments).await,
                },
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

    async fn handle_all(&self, assignments: &[Assignment]) -> Round {
        let mut round = Round::Done;
        for assignment in assignments {
            let (kind, id) = (assignment.kind.as_str(), assignment.session.id.as_str());
            match self.handle(assignment).await {
                Ok(_) => tracing::info!(session = id, "auto mode: {kind} done"),
                Err(error) => {
                    tracing::warn!(session = id, "auto mode: {kind} failed: {error}");
                    round = Round::Failed;
                }
            }
        }
        round
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

/// The holder `me` puts the unread inbox of a chat that is here into the chat's queue, then
/// acks it at `view`'s epoch. Returns the last message acked. Either side's holder may call
/// it: each message is in the chat's log before the ack, and one that was queued before (its
/// id is the prompt's) is not queued again.
pub async fn drain_inbox<C: AutoCloud>(
    hub: &Arc<Hub>,
    cloud: &C,
    me: &Holder,
    view: &SessionView,
) -> Result<u64, ImportError> {
    let messages = cloud.inbox(&view.id, view.inbox_acked).await?;
    let Some(through) = messages.last().map(|message| message.n) else {
        return Ok(view.inbox_acked);
    };
    let Some(session) = hub.auto_local(&view.id) else {
        return Err(ImportError::Local("the chat is not on this machine".to_owned()));
    };
    for message in &messages {
        deliver(hub, &session, message).await.map_err(ImportError::Local)?;
    }
    let ack = InboxAck { holder: me.clone(), epoch: view.epoch, through };
    cloud.ack_inbox(&view.id, &ack).await?;
    Ok(through)
}

/// Queues one inbox message as a prompt of the chat, and returns once the hub has recorded it
/// in the chat's log (queued, started, or seen before under the same id).
async fn deliver(
    hub: &Arc<Hub>,
    session: &Arc<Session>,
    message: &InboxMessage,
) -> Result<(), String> {
    let (recorded_tx, recorded) = tokio::sync::oneshot::channel();
    let options = PromptOptions {
        // The message's own id: a message that reached the chat before is not run again.
        prompt_id: Some(message.id.clone()),
        resend: true,
        on_accepted: Some(Box::new(move |_| {
            let _ = recorded_tx.send(());
        })),
        ..PromptOptions::default()
    };
    let blocks = vec![json!({ "type": "text", "text": message.text })];
    let (owner, session) = (Arc::clone(hub), Arc::clone(session));
    // The prompt's future ends with its turn; only its acceptance is waited for here. The turn
    // is the hub's task, as any chat's is: it ends with the daemon.
    let mut turn = hub.scope.spawn_named("auto-mode-inbox-message", async move {
        owner.prompt_with(&session, blocks, "auto-mode", false, options).await
    });
    let ended = tokio::select! {
        accepted = recorded => match accepted {
            Ok(()) => return Ok(()),
            // Dropped unused: the prompt ended without being recorded; its result says why.
            Err(_) => (&mut turn).await,
        },
        ended = &mut turn => ended,
    };
    match ended {
        Ok(Ok(_)) => Ok(()),
        Ok(Err(refused)) => {
            Err(format!("the chat did not take message {}: {}", message.id, refused.message))
        }
        Err(error) => Err(format!("message {}: {error}", message.id)),
    }
}
