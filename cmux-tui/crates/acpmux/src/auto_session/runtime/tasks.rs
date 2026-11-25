//! The loop's work that calls the store or reads the disk. Each function runs as a task of its
//! own and tells the loop what came of it as a [`Command`]; none touches the loop's state.

use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use cmux_auto_session::AutoCloud;
use cmux_auto_session::cloud::{AutoCloudError, CloudResult};
use cmux_auto_session::consts::RENEW_MS;
use cmux_auto_session::holder::{Change, Event, ImportReason};
use cmux_auto_session::wire::{
    Fence, Holder, InboxPost, LeaseRequest, OpenTool, PutRequest, Repo, SessionView,
};
use serde_json::{Value, json};

use super::chats::LaneOp;
use super::clock::WallClock;
use super::{Command, Commands, Reply, inbox};
use crate::auto_session::export::snapshot::Failed;
use crate::auto_session::export::{self, folder, leftover};
use crate::auto_session::record::Leftover;
use crate::auto_session::{ImportError, Imported, SessionImporter};
use crate::hub::{Hub, Session};
use crate::rpc::RpcError;

/// A renewal or a registration is given up this long after it was sent: within one period, so
/// the next one never overlaps it.
const ANSWER_MS: u64 = RENEW_MS - 1_000;

/// The longest title the store keeps.
const TITLE_MAX_CHARS: usize = 200;

/// What a task needs of the loop: the daemon, the store, this machine's name and the way back.
pub(super) struct Ctx<C> {
    pub hub: Arc<Hub>,
    pub cloud: Arc<C>,
    pub me: Holder,
    pub commands: Commands,
    pub clock: Arc<dyn WallClock>,
    pub importer: Arc<dyn SessionImporter>,
}

impl<C> Clone for Ctx<C> {
    fn clone(&self) -> Ctx<C> {
        Ctx {
            hub: self.hub.clone(),
            cloud: self.cloud.clone(),
            me: self.me.clone(),
            commands: self.commands.clone(),
            clock: self.clock.clone(),
            importer: self.importer.clone(),
        }
    }
}

/// The store's answer, or "no answer" once [`ANSWER_MS`] passed.
pub(super) async fn answered<T>(call: impl Future<Output = CloudResult<T>>) -> CloudResult<T> {
    match tokio::time::timeout(Duration::from_millis(ANSWER_MS), call).await {
        Ok(result) => result,
        Err(_) => Err(AutoCloudError::transport("the Cloud did not answer in time")),
    }
}

/// The harness's name as the store takes it: lower case letters, digits, `_ . -`, at most 32.
fn harness_name(harness: &str) -> String {
    let name: String = harness
        .chars()
        .map(|c| c.to_ascii_lowercase())
        .filter(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '_' | '.' | '-'))
        .take(32)
        .collect();
    match name.chars().next() {
        Some(first) if first.is_ascii_lowercase() || first.is_ascii_digit() => name,
        _ => "agent".to_owned(),
    }
}

/// The error a request gets when the store refused or did not answer.
pub(super) fn cloud_error(error: &AutoCloudError) -> RpcError {
    let reason = error.code().map_or("auto.unreachable", |code| code.as_str());
    RpcError::new(-32000, format!("{reason}: {error}"))
        .with_data(json!({"reason": reason, "retryable": error.retryable()}))
}

impl<C: AutoCloud + 'static> Ctx<C> {
    pub(super) fn tell(&self, command: Command) {
        // The loop ends only with its daemon.
        let _ = self.commands.send(command);
    }

    /// Starts one of the loop's tasks. The hub owns it: it ends when the hub's tasks end, and
    /// what it had not finished the loop asks for again when the daemon next starts.
    pub(super) fn start(
        &self,
        name: &'static str,
        task: impl Future<Output = ()> + Send + 'static,
    ) {
        self.hub.scope.spawn_until_cancelled(name, task);
    }

    pub(super) fn fence(&self, epoch: u64) -> Fence {
        Fence::new(self.me.clone(), epoch)
    }

    pub(super) fn session(&self, id: &str) -> Option<Arc<Session>> {
        self.hub.auto_session(id)
    }

    /// What `PUT /:id` says of the chat: its title, harness, this device and its repository.
    async fn put_request(&self, id: &str, auto: bool, keep: Option<bool>) -> PutRequest {
        let device = match &self.me {
            Holder::Device(device) => device.clone(),
            Holder::Vm(machine) => machine.clone(),
            Holder::Parked => String::new(),
        };
        let Some(session) = self.session(id) else {
            return PutRequest {
                auto,
                title: String::new(),
                harness: harness_name(""),
                device,
                keep_in_cloud: keep,
                repo: None,
            };
        };
        let meta = session.meta();
        let title: String =
            meta.title.clone().unwrap_or_default().chars().take(TITLE_MAX_CHARS).collect();
        let cwd = meta.cwd.clone();
        let repo = tokio::task::spawn_blocking(move || {
            let top = folder::top_of(&cwd)?;
            let (remote, branch) = folder::remote_and_branch(&top)?;
            Some(Repo { remote, branch })
        })
        .await
        .ok()
        .flatten();
        PutRequest {
            auto,
            title,
            harness: harness_name(&meta.harness),
            device,
            keep_in_cloud: keep,
            repo,
        }
    }

    /// `Register`: Auto on for the chat in the store. The loop gets the store's own answer:
    /// whoever switched Auto on waits for it (`register.rs`).
    pub(super) async fn register(self, id: String, request: u64, keep: Option<bool>) {
        let put = self.put_request(&id, true, keep).await;
        let result = answered(self.cloud.put(&id, &put)).await;
        if let Err(error) = &result {
            tracing::info!(session = %id, "auto session: registering did not go through: {error}");
        }
        self.tell(Command::Registered { id, request, result });
    }

    /// `Renew`: the lease, as the holder or as a laptop standing by.
    pub(super) async fn renew(
        self,
        id: String,
        request: u64,
        epoch: u64,
        needs_run: bool,
        standby: bool,
    ) {
        let lease = LeaseRequest {
            holder: self.me.clone(),
            epoch,
            needs_run,
            standby: standby.then_some(true),
        };
        let result = answered(self.cloud.lease(&id, &lease)).await;
        let event = Event::from_renewal(request, &self.me, &result);
        let view = match &result {
            Ok(answer) => Some(Box::new(answer.session.clone())),
            Err(error) => error.session().cloned().map(Box::new),
        };
        self.tell(Command::Step { id, event, view });
    }

    /// `Close`: Auto off for the chat in the store.
    pub(super) async fn close(self, id: String) {
        let put = self.put_request(&id, false, None).await;
        let result = answered(self.cloud.put(&id, &put)).await;
        self.tell(Command::Closed { id, result });
    }

    /// Whether the chat stays in the Cloud when this machine returns. `reply` goes back with
    /// the store's answer: the loop answers it once the row follows that answer.
    pub(super) async fn keep(self, id: String, keep: bool, reply: Option<Reply>) {
        let result = answered(self.cloud.keep(&id, keep)).await;
        self.tell(Command::Kept { id, result, reply });
    }

    /// One copy: the events the store lacks after `after`, then a snapshot.
    pub(super) async fn copy(
        self,
        id: String,
        epoch: u64,
        copy: u64,
        after: u64,
        tool: Option<OpenTool>,
    ) {
        let result = match self.session(&id) {
            Some(session) => {
                let (fence, now) = (self.fence(epoch), self.clock.now_ms());
                export::copy(&self.hub, &*self.cloud, &session, &fence, after, tool, now).await
            }
            None => Err((None, Failed::Local("the chat is not on this machine".to_owned()))),
        };
        self.tell(Command::Copied { id, copy, result });
    }

    /// Reads the chat's `needsRun` off the async workers: it reads process records.
    pub(super) async fn work(self, id: String, change: Option<Change>) {
        let Some(session) = self.session(&id) else {
            self.tell(Command::Work { id, change, needs_run: false, settles: None });
            return;
        };
        // Taken before the read: work that ends right after the read still changes it.
        let settles = self.hub.auto_work_settles(&session);
        let hub = self.hub.clone();
        let needs_run = tokio::task::spawn_blocking(move || hub.auto_needs_run(&session))
            .await
            .unwrap_or(false);
        self.tell(Command::Work { id, change, needs_run, settles: needs_run.then_some(settles) });
    }

    /// A prompt for a chat this machine may not run now: into its Cloud inbox. `standby`: this
    /// laptop stands by for the chat, and renews at once, which takes a parked chat home. A
    /// holder in the middle of a give does not: whoever holds the chat after the give takes the
    /// message from the inbox.
    pub(super) async fn post(self, id: String, post: InboxPost, reply: Reply, standby: bool) {
        let result = answered(self.cloud.post_inbox(&id, &post)).await;
        let answer = match &result {
            Ok(posted) => Ok(json!({
                "stopReason": "end_turn",
                "_meta": {"acpmux": {
                    "promptId": post.id,
                    "autoSession": {"delivery": posted.state.as_str()},
                }},
            })),
            Err(error) => Err(cloud_error(error)),
        };
        let _ = reply.send(answer);
        if let (Ok(posted), true) = (result, standby) {
            let view = Some(Box::new(posted.session));
            self.tell(Command::Step { id, event: Event::Wake, view });
        }
    }

    /// One thing of the chat's lane, then word that the lane is free. What runs git in the
    /// chat's folder takes the folder's turn (`turns.rs`), so the person settling kept changes
    /// never does it in a folder an import is changing.
    pub(super) async fn lane(
        self,
        id: String,
        op: LaneOp,
        epoch: Option<u64>,
        view: Option<SessionView>,
        anchor: Option<String>,
    ) {
        match op {
            LaneOp::Leftover => {
                let turn = self.hub.auto_turns.take(&id).await;
                let result = self.leftover(&id, anchor).await;
                drop(turn);
                self.tell(Command::Leftover { id: id.clone(), result });
            }
            LaneOp::Import { reason, epoch } => {
                let turn = self.hub.auto_turns.take(&id).await;
                let result = self.import(&id, view, reason, epoch).await;
                drop(turn);
                self.tell(Command::Imported { id: id.clone(), epoch, result });
            }
            LaneOp::Drain => {
                if let Some(epoch) = epoch
                    && let Err(error) = inbox::drain(&self, &id, self.fence(epoch)).await
                {
                    tracing::warn!(session = %id, "auto session: the inbox was not taken: {error}");
                }
            }
            LaneOp::Ack { epoch } => {
                if let Err(error) = self.cloud.ack_assignment(&id, &self.fence(epoch)).await {
                    tracing::warn!(session = %id, "auto session: assignment not acked: {error}");
                }
            }
        }
        self.tell(Command::LaneDone { id, drained: op == LaneOp::Drain });
    }

    /// The leftover patch: what the folder holds beyond the snapshot whose tree is `anchor`.
    /// A chat with no such snapshot (none stored, or a folder that went as a tar) keeps none.
    async fn leftover(&self, id: &str, anchor: Option<String>) -> Result<Option<Leftover>, String> {
        let (Some(session), Some(anchor)) = (self.session(id), anchor) else { return Ok(None) };
        leftover::write(&self.hub, &session, &anchor, self.clock.now_ms()).await
    }

    /// Brings the chat's Cloud copy in, under the store's view at `epoch`.
    async fn import(
        &self,
        id: &str,
        view: Option<SessionView>,
        reason: ImportReason,
        epoch: u64,
    ) -> Result<Imported, ImportError> {
        let view = match view.filter(|view| view.epoch == epoch) {
            Some(view) => view,
            None => self.cloud.get(id).await?,
        };
        self.importer.import(&view, reason).await
    }
}

/// The row's `autoSession` of a chat, for a request's answer.
pub(super) fn row(hub: &Hub, id: &str) -> Value {
    let record = hub.auto_session(id).and_then(|session| hub.auto_record(&session));
    crate::auto_session::record::AutoRecord::row_of(record.as_ref())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_harness_name_is_what_the_store_takes() {
        assert_eq!(harness_name("claude"), "claude");
        assert_eq!(harness_name("Claude Code"), "claudecode");
        assert_eq!(harness_name("-odd"), "agent");
        assert_eq!(harness_name(""), "agent");
        assert_eq!(harness_name(&"x".repeat(40)).len(), 32);
    }
}
