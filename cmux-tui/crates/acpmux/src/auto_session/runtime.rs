//! The holder loop. Owned by slice B (the laptop daemon).
//!
//! One task per daemon behind [`super::spawn_holder`]. For every Auto chat it keeps a
//! `cmux_auto_session::holder::Chat`, feeds it events with the wall clock in milliseconds, and
//! runs the effects `step` returns. A Cloud machine runs the same loop with its own transport
//! ([`super::machine`]).
//!
//! - [`run`]: the task: it waits for a command, a hub event, the next time a chat asked for, or
//!   a change of this machine's network. Nothing is polled.
//! - [`signals`]: a hub event read as a change of the chat's work.
//! - [`settle`]: work that ends with no hub event, read again when the hub says it settled.
//! - [`effects`]: what the loop does for each effect, and what comes back of it.
//! - [`tasks`]: the work that calls the store or reads the disk. Each runs as a task of its own
//!   and comes back as a [`Command`], so a slow answer never holds another chat's renewal.
//! - [`inbox`]: the Cloud inbox's messages into the chat's queue, each once.
//! - [`switch`]: Auto switched on or off for a chat, and a prompt to a chat held elsewhere.
//! - [`register`]: the store's answer to Auto on, which answers whoever switched it on.
//! - [`away`]: the person's Auto chats this laptop does not have, which it stands by for.
//! - [`chats`]: what the loop keeps of each chat, and the chat's record and row kept in step.
//! - [`clock`]: the wall clock, injected.
//! - [`projection`]: the Cloud's events of a chat held elsewhere, read only, for the pane.
//!
//! Order within a chat. A stop, a continue and a kill of the process tree run before the next
//! effect. The leftover patch, an import, the inbox and the assignment's ack run one at a time
//! in the order the state machine asked (the chat's lane), so a patch is cut before an import
//! changes the folder and an ack follows its drain. Renewals, registrations and copies go at
//! once, beside the lane: a slow copy or import never holds a lease.

mod away;
mod chats;
pub mod clock;
mod effects;
mod inbox;
pub(crate) mod projection;
mod register;
mod run;
mod settle;
mod signals;
mod switch;
mod tasks;

use std::sync::Arc;

use cmux_auto_session::AutoCloud;
use cmux_auto_session::cloud::AutoCloudError;
use cmux_auto_session::holder::{Change, Event};
use cmux_auto_session::wire::{Assignment, Holder, InboxPost, SessionView};
use serde_json::Value;
use tokio::sync::{mpsc, oneshot, watch};

pub use clock::{ManualClock, SystemClock, WallClock};

use super::export::Copied;
use super::export::snapshot::Failed;
use super::record::Leftover;
use super::{HolderHandle, ImportError, Imported, SessionImporter};
use crate::hub::Hub;
use crate::rpc::RpcError;

/// What the holder loop runs with besides its transport.
#[derive(Clone)]
pub struct HolderOptions {
    /// The wall clock.
    pub clock: Arc<dyn WallClock>,
    /// Changes of this machine's network (`peer::network::changes`); None: never told.
    pub network: Option<watch::Receiver<u64>>,
    /// Whether a new chat starts with Auto on (the setting `cloud.autoCloud`), asked when a chat
    /// is made. None: never.
    pub new_chats: Option<Arc<dyn Fn() -> bool + Send + Sync>>,
}

impl Default for HolderOptions {
    fn default() -> HolderOptions {
        HolderOptions { clock: Arc::new(SystemClock), network: None, new_chats: None }
    }
}

/// A reply to a request that waits for the loop.
pub(crate) type Reply = oneshot::Sender<Result<Value, RpcError>>;

/// What the loop is told, by the daemon and by its own tasks.
pub(crate) enum Command {
    /// Step chat `id` with `event`. `view` is the store's view that came with it.
    Step { id: String, event: Event, view: Option<Box<SessionView>> },
    /// The chat's `needsRun` was read. `change`: what it was read for; None tells the state
    /// machine only when `needsRun` differs from what it has. `settles`: with work, what
    /// changes when that work ends with no record (`settle.rs`).
    Work {
        id: String,
        change: Option<Change>,
        needs_run: bool,
        settles: Option<watch::Receiver<u64>>,
    },
    /// The chat's work settled with no record in its log (`settle.rs`).
    Settled { id: String },
    /// Auto on or off for a chat, and whether it stays in the Cloud.
    Switch { id: String, auto: bool, keep: Option<bool>, reply: Option<Reply> },
    /// The system woke.
    Wake,
    /// The owner's open chats were read (`away.rs`).
    Listed { result: Result<Vec<SessionView>, AutoCloudError> },
    /// The store assigned a chat to this Cloud machine.
    Assigned(Box<Assignment>),
    /// A prompt for a chat this machine may not run now.
    Away { id: String, post: InboxPost, reply: Reply },
    /// A copy ended.
    Copied { id: String, copy: u64, result: Result<Copied, (Option<u64>, Failed)> },
    /// An import ended.
    Imported { id: String, epoch: u64, result: Result<Imported, ImportError> },
    /// The leftover patch was written, or there was nothing to keep.
    Leftover { id: String, result: Result<Option<Leftover>, String> },
    /// The registration numbered `request` ended: the store's answer to Auto on, or none.
    Registered { id: String, request: u64, result: Result<SessionView, AutoCloudError> },
    /// The store answered Auto off.
    Closed { id: String, result: Result<SessionView, AutoCloudError> },
    /// The store answered whether the chat stays in the Cloud. `reply`: who asked.
    Kept { id: String, result: Result<SessionView, AutoCloudError>, reply: Option<Reply> },
    /// The chat's lane finished what it was doing. `drained`: it was the inbox.
    LaneDone { id: String, drained: bool },
}

pub(crate) type Commands = mpsc::UnboundedSender<Command>;

/// Starts the loop and answers its handle, which the hub keeps for the Auto methods.
pub(super) fn spawn<C>(
    hub: Arc<Hub>,
    cloud: Arc<C>,
    me: Holder,
    importer: Arc<dyn SessionImporter>,
    options: HolderOptions,
) -> HolderHandle
where
    C: AutoCloud + 'static,
{
    let (commands, inbox) = mpsc::unbounded_channel();
    let projections = Arc::new(projection::Projections::default());
    let handle = HolderHandle {
        me: me.clone(),
        commands: commands.clone(),
        projections: projections.clone(),
        clock: options.clock.clone(),
    };
    // The first loop of a daemon is the one its Auto methods reach.
    let _ = hub.auto_holder.set(handle.clone());
    let mut state = run::Loop::new(hub.clone(), cloud, me, importer, options, commands);
    state.projections = projections;
    // It ends with the hub's own tasks.
    drop(hub.scope.spawn_until_cancelled("auto-session holder", state.run(inbox)));
    handle
}

impl HolderHandle {
    fn tell(&self, command: Command) {
        // The loop ends only with its daemon: a command after that has nobody to act on it.
        let _ = self.commands.send(command);
    }

    async fn ask(&self, command: impl FnOnce(Reply) -> Command) -> Result<Value, RpcError> {
        let (reply, answer) = oneshot::channel();
        self.tell(command(reply));
        answer.await.unwrap_or_else(|_| Err(RpcError::internal("Auto mode is not running")))
    }

    /// The store assigned a chat to this Cloud machine (slice C's assignment reader calls it for
    /// each assignment it reads; a repeat of one the loop already took changes nothing).
    pub fn assigned(&self, assignment: &Assignment) {
        self.tell(Command::Assigned(Box::new(assignment.clone())));
    }

    /// The Cloud's events of chat `id` after seq `after`, while another holder runs it
    /// (`projection.rs`). None: the chat is held here, and its own log is its transcript.
    pub(crate) fn transcript(&self, session_id: &str, after: u64) -> Option<Value> {
        self.projections.reply(session_id, after, self.clock.now_ms())
    }

    /// The system woke from sleep: every Auto chat stops and asks the store before it goes on.
    pub fn wake(&self) {
        self.tell(Command::Wake);
    }

    /// Switches Auto on or off for a chat (`_acpmux/auto_session/set`) and answers its row's
    /// `autoSession`. Off waits for the store, which refuses while the Cloud holds the chat.
    pub async fn set_auto(
        &self,
        session_id: &str,
        auto: bool,
        keep_in_cloud: Option<bool>,
    ) -> Result<Value, RpcError> {
        let id = session_id.to_owned();
        self.ask(|reply| Command::Switch { id, auto, keep: keep_in_cloud, reply: Some(reply) })
            .await
    }

    /// A prompt for a chat this machine may not run now: it goes to the chat's Cloud inbox, or
    /// is refused while the chat waits for the network.
    pub(crate) async fn send_while_away(
        &self,
        session_id: &str,
        blocks: &[Value],
        prompt_id: Option<&str>,
    ) -> Result<Value, RpcError> {
        let text = blocks
            .iter()
            .filter_map(|block| block.get("text").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join("\n");
        if text.trim().is_empty() {
            return Err(RpcError::invalid_params(
                "this chat runs in the Cloud now, which takes text only",
            ));
        }
        let post = InboxPost { id: switch::message_id(prompt_id), text };
        let id = session_id.to_owned();
        self.ask(|reply| Command::Away { id, post, reply }).await
    }
}
