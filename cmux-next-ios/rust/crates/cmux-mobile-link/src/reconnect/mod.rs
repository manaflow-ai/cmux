//! The phone's link to its selected Mac as one pure step: events in, effects out. A port of
//! `cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLive/LinkMachine.swift` (`LinkMachine.handle`),
//! with the same phases, events, effects, backoff, silent retry and generation rules.
//!
//! Nothing calls this yet. A later change exports it over uniffi (`cmux-mobile-link-ffi`) and
//! switches `LinkController.swift` to it; until then the Swift machine decides, and the tests here
//! (one Rust test per Swift `LinkMachine` test, same name in snake_case, same events and effects)
//! keep the two equal.
//!
//! The shape is `cmux-tui/crates/cmux-cloud-machine/src/power.rs`'s: [`step`] is pure (no clock,
//! no I/O), every (phase, event) pair is written out with no wildcard arm, an event that changes
//! nothing is a named [`Refusal`], and [`table`] is the whole table as data, committed as
//! `schemas/mobile-link-reconnect/table.json`.
//!
//! A [`Generation`] tags every dial and timer: an answer from a dial the machine already abandoned
//! (a transport switch, a Mac change, a newer dial) carries an older generation and is refused
//! ([`Refusal::StaleGeneration`]). A refusal leaves the machine exactly as it was; Swift returns
//! `[]` for those and changes nothing either.

use std::time::Duration;

use crate::dial::{LinkPath, TransportKind};

mod step;
mod table;
pub mod timings;

pub use table::{sample_events, sample_machines, table};

/// The number a dial, a retry timer or a promoted standby link is issued under. Swift's `Int`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Generation(pub u64);

impl Generation {
    fn next(self) -> Self {
        Generation(self.0.saturating_add(1))
    }
}

/// The Mac to keep a link to (Swift `LinkMachine.Target`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Target {
    pub mac_id: String,
    pub name: String,
    pub is_online: bool,
}

/// The WebRTC media session beside a WireGuard link (Swift `VideoMediaState`). Not
/// [`crate::hybrid::MediaStatus`]: Swift's carries the round trip in whole milliseconds and a
/// failure without its retry time.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum VideoMedia {
    #[default]
    Off,
    Connecting,
    Up {
        path: LinkPath,
        rtt_millis: Option<u32>,
    },
    Failed {
        reason: String,
    },
}

/// Where the link is (Swift `LinkMachine.Phase`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum Phase {
    /// No Mac selected.
    #[default]
    Idle,
    /// The selected Mac's presence is offline, or a dial made while it said so failed; no dial
    /// until presence brings it back or a surface of the Mac opens ([`Event::Open`]).
    MacOffline,
    Connecting {
        transport: TransportKind,
        attempt: u32,
    },
    Connected {
        transport: TransportKind,
        path: LinkPath,
        rtt_millis: Option<u32>,
    },
    /// The last dial or link failed; the next dial is scheduled.
    Waiting {
        transport: TransportKind,
        attempt: u32,
        reason: String,
        retry_in: Duration,
    },
    /// The account's session was revoked. Nothing redials and nothing leaves it; a target change
    /// is recorded, never dialed.
    SignedOut,
}

impl Phase {
    /// Every phase's name, in the table's order.
    pub const KINDS: [&'static str; 6] =
        ["idle", "mac_offline", "connecting", "connected", "waiting", "signed_out"];

    pub fn kind(&self) -> &'static str {
        match self {
            Phase::Idle => "idle",
            Phase::MacOffline => "mac_offline",
            Phase::Connecting { .. } => "connecting",
            Phase::Connected { .. } => "connected",
            Phase::Waiting { .. } => "waiting",
            Phase::SignedOut => "signed_out",
        }
    }

    pub fn is_connected(&self) -> bool {
        matches!(self, Phase::Connected { .. })
    }

    /// Swift `isActive`: a link is being kept, made or retried.
    fn is_active(&self) -> bool {
        match self {
            Phase::Connecting { .. } | Phase::Connected { .. } | Phase::Waiting { .. } => true,
            Phase::Idle | Phase::MacOffline | Phase::SignedOut => false,
        }
    }
}

/// What happened (Swift `LinkMachine.Event`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Event {
    Target(Option<Target>),
    Transport(TransportKind),
    /// Debug relay-only mode on or off; a change redials.
    RelayOnly(bool),
    /// Debug UDP-blocked mode on or off; a change redials (WireGuard only).
    BlockUdp(bool),
    DialSucceeded {
        generation: Generation,
        path: LinkPath,
    },
    DialFailed {
        generation: Generation,
        reason: String,
    },
    /// The link reported a new path or round trip.
    LinkUpdated {
        generation: Generation,
        path: LinkPath,
        rtt_millis: Option<u32>,
    },
    /// The WebRTC media session beside a WireGuard link changed.
    MediaUpdated {
        generation: Generation,
        media: VideoMedia,
    },
    LinkDropped {
        generation: Generation,
        reason: String,
    },
    RetryDue {
        generation: Generation,
    },
    /// The app came to the foreground (or the network came back).
    Foreground,
    /// A surface of this Mac opened on screen: try the link now, whatever presence last said.
    Open,
    /// The scene entered the background.
    Background,
    /// The scene became active. Replace any link kept across suspension.
    Resume,
    ProbeFailed {
        generation: Generation,
        reason: String,
    },
    /// A presence frame says the target Mac's signaling socket is up (again).
    MacSignaled,
    /// The phone's network changed or came back.
    NetworkChanged,
    /// The dial of `generation` failed because the account's session was revoked.
    SignedOut {
        generation: Generation,
    },
    /// The standby link kept beside a redial answered a probe.
    StandbyAlive {
        generation: Generation,
        path: LinkPath,
        rtt_millis: Option<u32>,
    },
    /// The standby link closed, or stayed silent past [`timings::STANDBY_LIMIT`].
    StandbyLost {
        generation: Generation,
    },
}

impl Event {
    /// Every event's name, in the table's order.
    pub const KINDS: [&'static str; 20] = [
        "target",
        "transport",
        "relay_only",
        "block_udp",
        "dial_succeeded",
        "dial_failed",
        "link_updated",
        "media_updated",
        "link_dropped",
        "retry_due",
        "foreground",
        "open",
        "background",
        "resume",
        "probe_failed",
        "mac_signaled",
        "network_changed",
        "signed_out",
        "standby_alive",
        "standby_lost",
    ];

    pub fn kind(&self) -> &'static str {
        match self {
            Event::Target(_) => "target",
            Event::Transport(_) => "transport",
            Event::RelayOnly(_) => "relay_only",
            Event::BlockUdp(_) => "block_udp",
            Event::DialSucceeded { .. } => "dial_succeeded",
            Event::DialFailed { .. } => "dial_failed",
            Event::LinkUpdated { .. } => "link_updated",
            Event::MediaUpdated { .. } => "media_updated",
            Event::LinkDropped { .. } => "link_dropped",
            Event::RetryDue { .. } => "retry_due",
            Event::Foreground => "foreground",
            Event::Open => "open",
            Event::Background => "background",
            Event::Resume => "resume",
            Event::ProbeFailed { .. } => "probe_failed",
            Event::MacSignaled => "mac_signaled",
            Event::NetworkChanged => "network_changed",
            Event::SignedOut { .. } => "signed_out",
            Event::StandbyAlive { .. } => "standby_alive",
            Event::StandbyLost { .. } => "standby_lost",
        }
    }
}

/// What the runner does (Swift `LinkMachine.Effect`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Effect {
    Dial {
        generation: Generation,
        mac_id: String,
        transport: TransportKind,
    },
    /// Close the current link (if any) and drop its channels; closes the standby link too.
    Close,
    ScheduleRetry {
        generation: Generation,
        after: Duration,
    },
    /// Ping the live link; a failure comes back as [`Event::ProbeFailed`].
    Probe {
        generation: Generation,
    },
    /// Ping the live link with a short timeout (presence changed under it).
    QuickProbe {
        generation: Generation,
    },
    /// Keep the live link as the standby instead of closing it; a dial follows. The standby's
    /// generation is [`Machine::standby`] after the step.
    KeepStandby,
    /// The standby link is the link again, under `generation`.
    PromoteStandby {
        generation: Generation,
    },
    /// Close the standby link (the redial won, or it died).
    CloseStandby,
}

impl Effect {
    /// Every effect's name.
    pub const KINDS: [&'static str; 8] = [
        "dial",
        "close",
        "schedule_retry",
        "probe",
        "quick_probe",
        "keep_standby",
        "promote_standby",
        "close_standby",
    ];

    pub fn kind(&self) -> &'static str {
        match self {
            Effect::Dial { .. } => "dial",
            Effect::Close => "close",
            Effect::ScheduleRetry { .. } => "schedule_retry",
            Effect::Probe { .. } => "probe",
            Effect::QuickProbe { .. } => "quick_probe",
            Effect::KeepStandby => "keep_standby",
            Effect::PromoteStandby { .. } => "promote_standby",
            Effect::CloseStandby => "close_standby",
        }
    }
}

/// Why an event changed nothing. Swift returns `[]` for each of these and leaves every field as
/// it was; an event that returns `[]` but records something (a target, a setting, the background
/// flag) is a transition with no effects, not a refusal.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Refusal {
    /// The phase is `signed_out`: only a target change is recorded.
    SignedOut,
    /// The answer's generation is not the current one (or not the standby's).
    StaleGeneration,
    /// A standby event while no standby link is kept.
    NoStandby,
    /// The setting already has that value.
    Unchanged,
    /// A dial answer while no dial is in flight.
    NotConnecting,
    /// A link answer while no link is up.
    NotConnected,
    /// A retry timer while nothing waits.
    NotWaiting,
    /// The event means nothing in this phase (a presence or scene nudge with nothing to nudge).
    NothingToDo,
}

impl Refusal {
    pub const ALL: [Refusal; 8] = [
        Refusal::SignedOut,
        Refusal::StaleGeneration,
        Refusal::NoStandby,
        Refusal::Unchanged,
        Refusal::NotConnecting,
        Refusal::NotConnected,
        Refusal::NotWaiting,
        Refusal::NothingToDo,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Refusal::SignedOut => "signed_out",
            Refusal::StaleGeneration => "stale_generation",
            Refusal::NoStandby => "no_standby",
            Refusal::Unchanged => "unchanged",
            Refusal::NotConnecting => "not_connecting",
            Refusal::NotConnected => "not_connected",
            Refusal::NotWaiting => "not_waiting",
            Refusal::NothingToDo => "nothing_to_do",
        }
    }
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

impl std::error::Error for Refusal {}

/// Retry delays after the silent retries (Swift `backoff`, seconds); the last one repeats.
pub const BACKOFF: [Duration; 6] = [
    Duration::from_secs(1),
    Duration::from_secs(2),
    Duration::from_secs(4),
    Duration::from_secs(8),
    Duration::from_secs(15),
    Duration::from_secs(30),
];

/// Failed dials retried at once, before any failure shows (Swift `silentRetries`).
pub const SILENT_RETRIES: u32 = 1;

/// The machine: its phase and everything the step reads (Swift `LinkMachine`'s stored state).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Machine {
    phase: Phase,
    target: Option<Target>,
    transport: TransportKind,
    relay_only: bool,
    block_udp: bool,
    generation: Generation,
    standby: Option<Generation>,
    is_backgrounded: bool,
    media: VideoMedia,
    /// Retry delays after the silent retries; the last one repeats.
    pub backoff: Vec<Duration>,
    /// Whether an unanswered probe keeps the link beside the redial. Off only in tests that
    /// measure the old way.
    pub keeps_standby: bool,
}

/// The next machine and the effects to run, or why nothing changed.
pub type Step = Result<(Machine, Vec<Effect>), Refusal>;

/// One event: the machine it leaves and the effects to run, or a refusal (the machine unchanged).
pub fn step(machine: &Machine, event: &Event) -> Step {
    let mut next = machine.clone();
    let effects = next.apply(event)?;
    Ok((next, effects))
}

impl Machine {
    pub fn new(transport: TransportKind, relay_only: bool, block_udp: bool) -> Self {
        Machine {
            phase: Phase::Idle,
            target: None,
            transport,
            relay_only,
            block_udp,
            generation: Generation(0),
            standby: None,
            is_backgrounded: false,
            media: VideoMedia::Off,
            backoff: BACKOFF.to_vec(),
            keeps_standby: true,
        }
    }

    pub fn phase(&self) -> &Phase {
        &self.phase
    }
    pub fn target(&self) -> Option<&Target> {
        self.target.as_ref()
    }
    pub fn transport(&self) -> TransportKind {
        self.transport
    }
    pub fn relay_only(&self) -> bool {
        self.relay_only
    }
    pub fn block_udp(&self) -> bool {
        self.block_udp
    }
    pub fn generation(&self) -> Generation {
        self.generation
    }
    /// The generation of a link kept beside a redial ([`Effect::KeepStandby`]).
    pub fn standby(&self) -> Option<Generation> {
        self.standby
    }
    pub fn is_backgrounded(&self) -> bool {
        self.is_backgrounded
    }
    /// The current link's media session, `Off` between links.
    pub fn media(&self) -> &VideoMedia {
        &self.media
    }

    /// Swift `handle(_:)`: the step in place; a refusal is no effects and no change.
    pub fn handle(&mut self, event: &Event) -> Vec<Effect> {
        self.apply(event).unwrap_or_default()
    }
}

#[cfg(test)]
mod tests;
#[cfg(test)]
mod tests_props;
