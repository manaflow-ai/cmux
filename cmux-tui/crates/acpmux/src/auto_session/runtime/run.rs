//! The holder loop's task: it waits for what it is told, for the hub's events, for the next time
//! a chat asked for and for a change of the network, and steps the chats.

use std::collections::HashMap;
use std::sync::Arc;

use cmux_auto_session::AutoCloud;
use cmux_auto_session::consts::STREAM_COPY_MS;
use cmux_auto_session::holder::{self, Change, Chat, CopyState, Effect, Event, Side, State};
use cmux_auto_session::wire::{Assignment, Holder, SessionView};
use tokio::sync::broadcast::error::RecvError;
use tokio::sync::{mpsc, watch};

use super::away::Look;
use super::chats::{LaneOp, Tracked, WorkRead, frozen};
use super::signals::{self, Signal};
use super::tasks::Ctx;
use super::{Command, Commands, HolderOptions};
use crate::auto_session::SessionImporter;
use crate::hub::{Hub, HubEvent};

/// The loop's state: every Auto chat of this daemon.
pub(super) struct Loop<C> {
    pub hub: Arc<Hub>,
    pub ctx: Ctx<C>,
    pub side: Side,
    pub chats: HashMap<String, Tracked>,
    /// The read of the owner's chats, when one is on its way.
    pub look: Look,
    /// The Cloud's events of the chats held elsewhere, shared with the daemon's read.
    pub projections: Arc<super::projection::Projections>,
    network: Option<watch::Receiver<u64>>,
    new_chats: Option<Arc<dyn Fn() -> bool + Send + Sync>>,
}

/// Ends when the network changed. Never, for a machine that is not told.
async fn network_changed(network: &mut Option<watch::Receiver<u64>>) {
    match network {
        Some(changes) => {
            if changes.changed().await.is_err() {
                // Nobody tells any more.
                *network = None;
            }
        }
        None => std::future::pending().await,
    }
}

impl<C: AutoCloud + 'static> Loop<C> {
    pub(super) fn new(
        hub: Arc<Hub>,
        cloud: Arc<C>,
        me: Holder,
        importer: Arc<dyn SessionImporter>,
        options: HolderOptions,
        commands: Commands,
    ) -> Loop<C> {
        let side = if me.is_vm() { Side::Machine } else { Side::Laptop };
        let ctx = Ctx { hub: hub.clone(), cloud, me, commands, clock: options.clock, importer };
        Loop {
            hub,
            ctx,
            side,
            chats: HashMap::new(),
            look: Look::Idle,
            projections: Arc::default(),
            network: options.network,
            new_chats: options.new_chats,
        }
    }

    pub(super) fn now(&self) -> u64 {
        self.ctx.clock.now_ms()
    }

    pub(super) async fn run(mut self, mut inbox: mpsc::UnboundedReceiver<Command>) {
        // Subscribed before the chats are read, so no chat made meanwhile is missed.
        let mut events = self.hub.subscribe();
        let mut network = self.network.take();
        self.resume_chats().await;
        // The person's chats this laptop does not have yet (`away.rs`).
        self.look();
        loop {
            let due = self.chats.values().filter_map(|tracked| tracked.timer).min();
            let clock = self.ctx.clock.clone();
            let timer = async move {
                match due {
                    Some(at) => clock.wait_until(at).await,
                    None => std::future::pending().await,
                }
            };
            tokio::select! {
                command = inbox.recv() => match command {
                    Some(command) => self.command(command).await,
                    None => break,
                },
                event = events.recv() => match event {
                    Ok(event) => self.heard(&event).await,
                    // Events were missed: read every chat's work again.
                    Err(RecvError::Lagged(_)) => self.read_all(),
                    Err(RecvError::Closed) => break,
                },
                () = timer => self.ticks().await,
                () = network_changed(&mut network) => self.network_changed().await,
            }
        }
    }

    /// The Auto chats this daemon had when it last ran, from their own records. Each is treated
    /// as a wake: a chat this machine held stops and asks the store before anything runs.
    async fn resume_chats(&mut self) {
        for session in self.hub.sessions() {
            self.resume(&session.id).await;
        }
    }

    /// Takes up a chat this daemon has with Auto on and the loop does not follow yet: one from
    /// before the daemon started, or one that came back out of the archive since.
    async fn resume(&mut self, id: &str) {
        let Some(session) = self.hub.auto_session(id) else { return };
        let Some(record) = self.hub.auto_record(&session).filter(|record| record.auto) else {
            return;
        };
        let now = self.now();
        let fresh = Chat::new(self.side, now);
        let (chat, effects) = match self.side {
            // Auto was switched on and the store never answered: register again.
            Side::Laptop if record.epoch == 0 => holder::step(fresh, Event::AutoOn, now),
            Side::Laptop if record.here => {
                Chat::resume(Side::Laptop, record.epoch, record.snapshot, now)
            }
            Side::Laptop => Chat::standby(record.epoch, now),
            Side::Machine if record.here => {
                Chat::resume(Side::Machine, record.epoch, record.snapshot, now)
            }
            // The store assigns it again if it is still this machine's.
            Side::Machine => return,
        };
        let mut tracked = Tracked::new(chat);
        tracked.anchor = record.anchor.clone();
        self.chats.insert(id.to_owned(), tracked);
        self.settle(id, fresh, effects).await;
    }

    async fn command(&mut self, command: Command) {
        match command {
            Command::Step { id, event, view } => {
                if let (Some(tracked), Some(view)) = (self.chats.get_mut(&id), view) {
                    tracked.note_view(*view);
                }
                self.step(&id, event).await;
            }
            Command::Work { id, change, needs_run, settles } => {
                self.watch_settle(&id, settles);
                self.work_read(&id, change, needs_run).await;
            }
            Command::Settled { id } => self.settled(&id),
            Command::Switch { id, auto, keep, reply } => self.switch(&id, auto, keep, reply).await,
            Command::Wake => {
                for id in self.ids() {
                    self.step(&id, Event::Wake).await;
                }
                self.look();
            }
            Command::Listed { result } => self.listed(result).await,
            Command::Assigned(assignment) => self.assigned(*assignment).await,
            Command::Away { id, post, reply } => self.away(&id, post, reply),
            Command::Copied { id, copy, result } => self.copied(&id, copy, result).await,
            Command::Imported { id, epoch, result } => self.imported(&id, epoch, result).await,
            Command::Leftover { id, result } => self.leftover_written(&id, result),
            Command::Registered { id, request, result } => {
                self.registered(&id, request, result).await;
            }
            Command::Closed { id, result } => self.closed(&id, result).await,
            Command::Kept { id, result, reply } => self.kept(&id, result, reply),
            Command::LaneDone { id, drained } => self.lane_done(&id, drained),
        }
    }

    pub(super) fn ids(&self) -> Vec<String> {
        self.chats.keys().cloned().collect()
    }

    /// Steps one chat and does what the state machine asks.
    pub(super) async fn step(&mut self, id: &str, event: Event) {
        let now = self.now();
        let Some(tracked) = self.chats.get_mut(id) else { return };
        let before = tracked.chat;
        let (chat, effects) = holder::step(before, event, now);
        tracked.chat = chat;
        self.settle(id, before, effects).await;
    }

    /// Runs a step's effects in order and brings the chat's record, row and freeze in step.
    /// `before` is the chat as it was.
    pub(super) async fn settle(&mut self, id: &str, before: Chat, effects: Vec<Effect>) {
        let Some(chat) = self.chats.get(id).map(|tracked| tracked.chat) else { return };
        let session = self.hub.auto_session(id);
        // Frozen first: nothing new starts while the chat's processes are stopped or killed.
        if let Some(session) = &session
            && frozen(&chat)
        {
            self.hub.auto_hold(session, true);
        }
        for effect in effects {
            self.effect(id, session.as_ref(), effect).await;
        }
        self.sync(id);
        self.project(id);
        // A chat that may run here again takes what the Cloud holds for it and what an
        // earlier drain still owes it. The drain's end reads its work, which copies it.
        if !before.may_run() && chat.may_run() && chat.here() {
            self.lane(id, LaneOp::Drain);
        }
        self.forget_spent(id);
    }

    /// Every chat whose time has come gets its `Tick`. Its work is read again too: a background
    /// task that ended says so nowhere else.
    async fn ticks(&mut self) {
        let now = self.now();
        let due: Vec<String> = self
            .chats
            .iter()
            .filter(|(_, tracked)| tracked.timer.is_some_and(|at| at <= now))
            .map(|(id, _)| id.clone())
            .collect();
        for id in due {
            if let Some(tracked) = self.chats.get_mut(&id) {
                tracked.timer = None;
            }
            self.step(&id, Event::Tick).await;
            // No session here is not a chat the person deleted when it is one of the owner's
            // list that never had one, or when an import is replacing it right now.
            let expected = self.chats.get(&id).is_some_and(|tracked| {
                tracked.absent || matches!(tracked.chat.state, State::ComingHome { .. })
            });
            let here = self.side == Side::Machine || self.hub.auto_session(&id).is_some();
            if !here {
                if !expected {
                    // The chat was deleted here: Auto is off for it, once the store agrees.
                    self.step(&id, Event::AutoOff).await;
                }
            } else if let Some(chat) = self.chats.get(&id).map(|tracked| tracked.chat)
                && chat.may_run()
            {
                // A copy that did not get there is sent again with the renewal.
                let again = chat.copy == CopyState::Failed && !chat.too_large;
                self.read_work(&id, again.then_some(Change::QueueChanged));
            }
        }
    }

    /// The network changed: a chat that waits for the store asks at once. A chat that runs
    /// goes on, and its next renewal says where it stands.
    async fn network_changed(&mut self) {
        for id in self.ids() {
            let waits = self.chats.get(&id).is_some_and(|tracked| {
                !tracked.chat.may_run() || matches!(tracked.chat.state, State::Registering)
            });
            if waits {
                self.step(&id, Event::Wake).await;
            }
        }
        // The store may have chats this laptop has not heard of (`away.rs`).
        self.look();
    }

    fn read_all(&mut self) {
        for id in self.ids() {
            if self.chats.get(&id).is_some_and(|tracked| tracked.chat.may_run()) {
                self.read_work(&id, Some(Change::QueueChanged));
            }
        }
    }

    /// The store assigned a chat to this Cloud machine.
    async fn assigned(&mut self, assignment: Assignment) {
        if self.side != Side::Machine {
            return;
        }
        let Assignment { kind, session } = assignment;
        let (id, epoch, now) = (session.id.clone(), session.epoch, self.now());
        let tracked = self
            .chats
            .entry(id.clone())
            .or_insert_with(|| Tracked::new(Chat::new(Side::Machine, now)));
        tracked.note_view(session);
        self.step(&id, Event::Assigned { kind, epoch }).await;
    }

    /// One hub event: a chat made here, or a tracked chat's work changing.
    async fn heard(&mut self, event: &HubEvent) {
        let Some(signal) = signals::read(event) else { return };
        let id = event.session_id.as_str();
        if !self.chats.contains_key(id) {
            match signal {
                Signal::Created => self.created(id).await,
                // A chat with Auto on that this daemon got back since it started.
                Signal::TurnStarted | Signal::Queue | Signal::Other => self.resume(id).await,
                Signal::TurnEnded
                | Signal::ToolStarted(_)
                | Signal::ToolEnded
                | Signal::Streaming => {}
            }
            return;
        }
        let Some(tracked) = self.chats.get_mut(id) else { return };
        // A chat that does not run here has no work of its own: an import writes its log.
        if !tracked.chat.may_run() {
            return;
        }
        match signal {
            Signal::Created | Signal::Other => self.read_work(id, None),
            Signal::TurnStarted => {
                tracked.tool = None;
                self.step(id, Event::Changed { change: Change::TurnStarted, needs_run: true })
                    .await;
            }
            Signal::ToolStarted(tool) => {
                tracked.tool = Some(tool);
                self.streaming(id).await;
            }
            Signal::Streaming => self.streaming(id).await,
            Signal::ToolEnded => {
                tracked.tool = None;
                self.read_work(id, Some(Change::ToolEnded));
            }
            Signal::TurnEnded => {
                tracked.tool = None;
                self.read_work(id, Some(Change::TurnEnded));
            }
            Signal::Queue => self.read_work(id, Some(Change::QueueChanged)),
        }
    }

    /// A streaming turn is told to the state machine at most once per copy period: it copies
    /// no more often than that.
    async fn streaming(&mut self, id: &str) {
        let now = self.now();
        let Some(tracked) = self.chats.get_mut(id) else { return };
        let due =
            now >= tracked.streamed_at.saturating_add(STREAM_COPY_MS) || now < tracked.streamed_at;
        if !due {
            return;
        }
        let turn_runs = self.hub.auto_session(id).is_some_and(|session| session.turn().is_some());
        if !turn_runs {
            return;
        }
        if let Some(tracked) = self.chats.get_mut(id) {
            tracked.streamed_at = now;
        }
        self.step(id, Event::Changed { change: Change::Streaming, needs_run: true }).await;
    }

    /// A chat was made on this laptop: Auto is on for it when the setting says so. A chat
    /// another chat started (a sub-session) follows its own switch only.
    async fn created(&mut self, id: &str) {
        if self.side != Side::Laptop || !self.new_chats.as_ref().is_some_and(|on| on()) {
            return;
        }
        let Some(session) = self.hub.auto_session(id) else { return };
        if session.read_meta(|meta| meta.parent_id.is_some() || meta.auto_session.is_some()) {
            return;
        }
        self.switch(id, true, None, None).await;
    }

    /// Asks for the chat's `needsRun` to be read; `change` is what it is read for. One read
    /// runs at a time, and a second request waits for it with the stronger reason.
    pub(super) fn read_work(&mut self, id: &str, change: Option<Change>) {
        let Some(tracked) = self.chats.get_mut(id) else { return };
        match tracked.work {
            WorkRead::Idle => {
                tracked.work = WorkRead::Reading { again: None };
                let task = self.ctx.clone().work(id.to_owned(), change);
                self.ctx.start("auto-session work", task);
            }
            WorkRead::Reading { again } => {
                let next = match (again, change) {
                    (Some(Some(known)), None) => Some(known),
                    (_, change) => change,
                };
                tracked.work = WorkRead::Reading { again: Some(next) };
            }
        }
    }

    /// The chat's `needsRun` was read.
    async fn work_read(&mut self, id: &str, change: Option<Change>, needs_run: bool) {
        let Some(tracked) = self.chats.get_mut(id) else { return };
        let again = match tracked.work {
            WorkRead::Reading { again } => again,
            WorkRead::Idle => None,
        };
        tracked.work = WorkRead::Idle;
        let differs = tracked.chat.needs_run != needs_run;
        match change {
            Some(change) => self.step(id, Event::Changed { change, needs_run }).await,
            None if differs => {
                self.step(id, Event::Changed { change: Change::QueueChanged, needs_run }).await;
            }
            None => {}
        }
        if let Some(change) = again {
            self.read_work(id, change);
        }
    }
}

impl Tracked {
    /// The store's newest view of the chat. Its last event is where the next copy resumes,
    /// unless a copy is on its way and knows better.
    pub(super) fn note_view(&mut self, view: SessionView) {
        if self.copying.is_none() {
            self.sent = view.last_seq;
        }
        self.view = Some(view);
    }
}
