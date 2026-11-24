//! What the holder loop keeps of each Auto chat besides its state machine, and the chat's own
//! record and freeze kept in step with it.

use std::collections::VecDeque;

use cmux_auto_session::AutoCloud;
use cmux_auto_session::holder::{Change, Chat, ImportReason, Side, State};
use cmux_auto_session::wire::{self, Blocked, OpenTool, SessionView};

use super::Reply;
use super::run::Loop;
use super::tasks::row;
use crate::auto_session::record::AutoRecord;

/// One thing a chat does in order, after the one before it ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum LaneOp {
    /// Write the leftover patch.
    Leftover,
    /// Bring the Cloud copy in.
    Import { reason: ImportReason, epoch: u64 },
    /// Take the inbox's messages, and give the chat the ones it still owes.
    Drain,
    /// Tell the store the assignment was picked up.
    Ack { epoch: u64 },
}

/// Whether the chat's work is being read, and what to read it for next.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) enum WorkRead {
    #[default]
    Idle,
    /// A read is on its way. `again`: read once more when it ends, for this change (None: tell
    /// the state machine only if `needsRun` differs).
    Reading { again: Option<Option<Change>> },
}

/// A request that switched Auto on and waits for the store's answer to the registration.
pub(super) struct Opening {
    pub reply: Reply,
    /// Whether the request said the chat stays in the Cloud. The store is asked for it once
    /// it has the chat, when the registration's answer says otherwise.
    pub keep: Option<bool>,
}

/// One Auto chat, as the loop keeps it.
pub(super) struct Tracked {
    pub chat: Chat,
    /// When the state machine asked for its next `Tick`.
    pub timer: Option<u64>,
    /// The store's last view of the chat.
    pub view: Option<SessionView>,
    /// The store's last event, as far as this machine knows.
    pub sent: u64,
    /// The epoch of the copy that is on its way.
    pub copying: Option<u64>,
    /// The newest copy asked for while one was on its way. It goes at the chat's epoch then.
    pub wanted: Option<u64>,
    /// What waits its turn, and whether one of them runs.
    pub lane: VecDeque<LaneOp>,
    pub lane_busy: bool,
    /// Who waits for the store's answer to Auto off.
    pub closing: Vec<Reply>,
    /// Who waits for the store's answer to Auto on (`register.rs`).
    pub opening: Vec<Opening>,
    /// The tool call in flight, for a snapshot's open turn.
    pub tool: Option<OpenTool>,
    /// When a streaming turn was last told to the state machine.
    pub streamed_at: u64,
    pub work: WorkRead,
    /// The folder's tree as the last acknowledged snapshot has it.
    pub anchor: Option<String>,
    /// The chat never had a session on this laptop: it is one of the owner's list
    /// (`away.rs`), and its first import makes it one. A session that is missing is then not
    /// one the person deleted.
    pub absent: bool,
    /// A task waits for the chat's work to settle (`settle.rs`).
    pub settling: bool,
    /// What a give keeps of the turn it stopped (`give.rs`).
    pub give: super::give::Stopped,
}

impl Tracked {
    pub fn new(chat: Chat) -> Tracked {
        Tracked {
            chat,
            timer: None,
            view: None,
            sent: 0,
            copying: None,
            wanted: None,
            lane: VecDeque::new(),
            lane_busy: false,
            closing: Vec::new(),
            opening: Vec::new(),
            tool: None,
            streamed_at: 0,
            work: WorkRead::Idle,
            anchor: None,
            absent: false,
            settling: false,
            give: super::give::Stopped::default(),
        }
    }

    /// Nothing of the chat is left for the loop to do: Auto is off and nobody waits.
    pub fn spent(&self) -> bool {
        matches!(self.chat.state, State::Off) && self.closing.is_empty() && !self.lane_busy
    }
}

/// Auto is on for the chat on this machine. A Cloud machine has only Auto chats.
pub(super) fn auto(chat: &Chat) -> bool {
    match chat.side() {
        Side::Laptop => !matches!(chat.state, State::Off),
        Side::Machine => true,
    }
}

/// The chat is kept from running here: no prompt starts a turn and its queue stays as it is.
pub(super) fn frozen(chat: &Chat) -> bool {
    auto(chat) && !chat.may_run()
}

/// Where the chat stands, for its row: this machine's own state first, the store's word for a
/// chat that is elsewhere.
fn stands(chat: &Chat, view: Option<&SessionView>) -> wire::State {
    match chat.state {
        // A chat its holder is giving away is still where it was until the store took it.
        State::Off
        | State::Registering
        | State::Holding { .. }
        | State::Stopped { .. }
        | State::Giving { .. } => wire::State::Local,
        State::ComingHome { .. } => wire::State::ComingBack,
        State::Taking { .. } => wire::State::Resuming,
        State::Serving { .. } | State::Returning { .. } => wire::State::Cloud,
        State::Standby { .. } | State::Away => view.map_or(wire::State::Cloud, |view| view.state),
    }
}

/// The chat's record as the loop's state says it is now. `old` gives what only the record
/// keeps (the leftover patch).
pub(super) fn record_of(tracked: &Tracked, old: Option<AutoRecord>) -> Option<AutoRecord> {
    let chat = &tracked.chat;
    let view = tracked.view.as_ref();
    let mut record = old.unwrap_or_else(AutoRecord::on);
    record.auto = auto(chat);
    // A chat that is being registered runs here as any chat does.
    record.here = chat.here() || matches!(chat.state, State::Off | State::Registering);
    record.epoch = chat.epoch().unwrap_or(record.epoch);
    record.snapshot = chat.snapshot;
    record.state = stands(chat, view);
    record.blocked = chat.blocked().or_else(|| {
        view.and_then(|view| view.blocked).filter(|blocked| *blocked == Blocked::NoMachine)
    });
    if let Some(view) = view {
        record.keep_in_cloud = view.keep_in_cloud;
    }
    record.anchor = tracked.anchor.clone();
    (!record.spent()).then_some(record)
}

impl<C: AutoCloud + 'static> Loop<C> {
    /// Writes the chat's record and row from the loop's state, and frees or freezes the chat.
    /// A chat this daemon does not have yet (a Cloud machine before its import) has neither.
    pub(super) fn sync(&mut self, id: &str) {
        let Some(tracked) = self.chats.get(id) else { return };
        let Some(session) = self.hub.auto_session(id) else { return };
        self.hub.auto_hold(&session, frozen(&tracked.chat));
        self.hub.update_auto_record(&session, |old| record_of(tracked, old));
    }

    /// Drops a chat the loop has nothing left to do for. Auto went off while a request waited
    /// for it to come on: no registration answers that request any more, so the row does.
    pub(super) fn forget_spent(&mut self, id: &str) {
        let Some(tracked) = self.chats.get_mut(id) else { return };
        if matches!(tracked.chat.state, State::Off) {
            for Opening { reply, .. } in std::mem::take(&mut tracked.opening) {
                // Whoever asked may have gone.
                let _ = reply.send(Ok(row(&self.hub, id)));
            }
        }
        if tracked.spent() {
            self.chats.remove(id);
        }
    }
}

#[cfg(test)]
mod tests {
    use cmux_auto_session::holder::Stop;

    use super::*;

    fn chat(state: State) -> Tracked {
        Tracked::new(Chat { state, ..Chat::new(Side::Laptop, 0) })
    }

    #[test]
    fn a_chat_being_given_reads_where_it_still_is_and_is_frozen() {
        use cmux_auto_session::holder::GiveStep;
        use cmux_auto_session::wire::MoveTo;
        let step = GiveStep::Copying;
        let giving = chat(State::Giving { epoch: 3, step, to: MoveTo::Cloud });
        assert!(frozen(&giving.chat));
        let record = record_of(&giving, None).unwrap();
        assert!(record.here);
        assert_eq!(record.state, wire::State::Local);
        let returning = chat(State::Returning { epoch: 4, step, to: MoveTo::Local });
        assert!(frozen(&returning.chat));
        let record = record_of(&returning, None).unwrap();
        assert!(record.here);
        assert_eq!(record.state, wire::State::Cloud);
    }

    #[test]
    fn a_chat_stopped_here_reads_as_here_and_frozen() {
        let stopped = chat(State::Stopped { epoch: 3, why: Stop::Offline });
        assert!(frozen(&stopped.chat));
        let record = record_of(&stopped, None).unwrap();
        assert!(record.auto && record.here);
        assert_eq!(record.epoch, 3);
        assert_eq!(record.state, wire::State::Local);
        assert_eq!(record.blocked, Some(Blocked::Offline));
    }

    #[test]
    fn a_chat_with_auto_off_keeps_a_record_only_for_its_leftover() {
        let off = chat(State::Off);
        assert!(!frozen(&off.chat));
        assert_eq!(record_of(&off, None), None);
        assert_eq!(record_of(&off, Some(AutoRecord::on())), None);
        let mut kept = AutoRecord::on();
        kept.leftover = Some(crate::auto_session::record::Leftover {
            files: vec!["a".into()],
            at: 1,
            path: "/x/p".into(),
            top: "/x".into(),
        });
        let record = record_of(&off, Some(kept)).unwrap();
        assert!(!record.auto);
        assert!(record.leftover.is_some());
    }

    #[test]
    fn a_standby_chat_reads_where_the_store_says_it_is() {
        let standby = chat(State::Standby { epoch: 2 });
        assert!(frozen(&standby.chat));
        let record = record_of(&standby, None).unwrap();
        assert!(!record.here);
        assert_eq!(record.state, wire::State::Cloud);
        let home = chat(State::ComingHome { epoch: 4, failed: false });
        assert_eq!(record_of(&home, None).unwrap().state, wire::State::ComingBack);
    }
}
