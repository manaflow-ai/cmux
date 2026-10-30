import CmuxNextCompat
import CmuxNextWakeups
import Foundation

/// Off-main event buffer. The pump appends; the main actor takes whole
/// batches. At most one frame is requested per non-empty buffer.
///
/// Coalescing (plans/cmux-next/main-thread-budget.md): an event that states
/// the whole current value of one surface's field (title, size, scroll,
/// agent presence: ``CoalesceKey``) replaces an earlier one for the same
/// surface still in the buffer, so a batch applies each object's newest
/// value once, however often it changed since the last frame. Workspace,
/// screen, pane and tab deltas are never coalesced: they carry consecutive
/// revisions and structural moves. Agent statuses are never coalesced
/// either: the store records each transition.
///
/// The connection holds the events no consumer took yet in one too
/// (``DaemonEventRoute/backlog``), as does its handshake gate (``EventGate``).
///
/// Bounded (architecture.md 5a): past `limit` events the buffer collapses
/// into one `.overflow` marker, which the store answers with one snapshot
/// that supersedes everything dropped. Lifecycle events and transaction
/// echoes (which settle intents and waiters) survive the collapse; every
/// other event is dropped until the next `take()`. ``Retention`` says how
/// many of the survivors a collapsed buffer holds.
///
/// Cause (plans/cmux-next/chrome-parity/p06-scheduler.md, "Person cause, app side"): an event
/// that replaces others carries the highest cause of them all (person > frontend > program >
/// automation), so automation never hides a person's change behind it. The `.overflow` marker,
/// which becomes one resync, carries the highest cause of everything the collapse dropped, with
/// no floor: a flood of automation events resyncs as automation.
final class EventInbox: Sendable {
    /// What a collapsed inbox keeps of the events a resync cannot restore (notifications, session
    /// state, the `apps-*` events, every event of a page relay's raw stream).
    enum Retention: Sendable {
        /// All of them: the store's inbox, which its drain empties every frame.
        case all
        /// At most `limit` events in all, then only the newest of each connection lifecycle event:
        /// a backlog whose reader may fall behind for good. Its reader re-reads on the `overflow`
        /// marker, as mojo ends a pipe whose receiver passed its unread quota
        /// (`MOJO_QUOTA_TYPE_UNREAD_MESSAGE_COUNT`, mojo/public/cpp/bindings/message_quota_checker.h).
        case upToLimit
    }

    fileprivate struct State {
        /// Buffered events in order; nil where a newer event of the same slot replaced one.
        var events: [DaemonEventEnvelope?] = []
        /// Live (non-nil) entries of `events`.
        var live = 0
        /// The index of the newest event per slot: coalescing keys in normal mode, the newest-only
        /// kinds once collapsed.
        var latest: [EventSlot: Int] = [:]
        /// Events replaced by a newer one since creation, normal mode (debug).
        var coalesced = 0
        var framePending = false
        /// Set once the buffer collapsed; cleared by `take()`.
        var collapsed = false
        /// The highest cause of the events the collapse dropped (the resync's), from the lowest.
        var collapseCause = ObservationCause.automation
        var echoes: Set<ClientTransactionID> = []
        /// Events a resync cannot restore that a full ``Retention/upToLimit`` buffer dropped.
        var lost = 0
    }

    /// Matches the daemon's own per-client mailbox.
    static let defaultLimit = 4096

    private let state = Mutex(State())
    private let limit: Int
    private let retention: Retention

    init(limit: Int = EventInbox.defaultLimit, retention: Retention = .all) {
        self.limit = max(limit, 1)
        self.retention = retention
    }

    /// Returns true when the caller must schedule a frame.
    func append(_ envelope: DaemonEventEnvelope) -> Bool {
        state.withLock { state in
            let key = CoalesceKey(envelope.event).map(EventSlot.field)
            if state.collapsed {
                keep(envelope, in: &state)
            } else if let key, state.newest(key) != nil {
                // The newest value of the same field of the same surface: the older one never applies.
                state.coalesced += 1
                state.append(envelope, slot: key)
            } else if state.live >= limit {
                let buffered = state.events.compactMap { $0 }
                state.events = [DaemonEventEnvelope(sequence: envelope.sequence, event: .overflow("app event inbox exceeded \(limit) events"))]
                state.live = 1
                state.latest.removeAll(keepingCapacity: true)
                state.collapsed = true
                state.collapseCause = .automation
                for old in buffered { keep(old, in: &state) }
                keep(envelope, in: &state)
            } else {
                state.append(envelope, slot: key)
            }
            guard !state.framePending else { return false }
            state.framePending = true
            return true
        }
    }

    /// Events a newer one replaced so far (debug).
    var coalescedCount: Int { state.withLock { $0.coalesced } }

    /// Events buffered and not taken yet (debug, tests).
    var bufferedCount: Int { state.withLock { $0.live } }

    /// While collapsed: keep lifecycle and bookmark events, the newest agent status, presence and
    /// registry stamp per key, and one echo per transaction (as a `tree-changed` carrying it); drop
    /// the rest.
    private func keep(_ envelope: DaemonEventEnvelope, in state: inout State) {
        switch envelope.event {
        case .connected, .disconnected, .daemonShutdown, .sessionState:
            // Session state: not in the snapshot the collapse refetches.
            admit(envelope, slot: nil, in: &state)
        case .terminalRegistryChanged:
            // Only an invalidation: keep the newest from each original control
            // connection. A replacement source must not inherit the old stamp.
            admit(envelope, slot: .registry(source: envelope.sourceID, serial: envelope.connectionSerial), in: &state)
        case .agentChanged(let status):
            // Agent state is not in the snapshot either (cx-ag5.6.8). Each event is the whole state
            // of one surface, so a collapsed inbox keeps only the newest one per surface.
            admit(envelope, slot: .agent(status.surface), in: &state)
        case .notification:
            // Its text is not in the snapshot either (`outlivesSnapshot`).
            admit(envelope, slot: nil, in: &state)
        case .agentPresenceChanged(let presence):
            admit(envelope, slot: .field(.presence(presence.surface)), in: &state)
        case .bookmarksChanged, .historyChanged, .keybindingsChanged, .conversationChanged, .conversationTyping, .conversationDraft, .conversationLive, .conversationRunChanged, .cloudConversations,
             .terminalClipboardRead, .terminalClipboardReadCancelled, .unknown:
            // Not part of the tree snapshot a resync refetches (.unknown: the `apps-*` events of apps-v1).
            admit(envelope, slot: nil, in: &state)
        default:
            // Dropped: the resync stands for it.
            state.collapseCause = max(state.collapseCause, envelope.cause)
            guard let transaction = envelope.event.clientTransactionID, state.echoes.insert(transaction).inserted else { return }
            admit(DaemonEventEnvelope(sequence: envelope.sequence, event: .treeChanged(transaction: transaction), cause: envelope.cause),
                  slot: nil, in: &state)
        }
    }

    /// Holds a survivor of the collapse. A full ``Retention/upToLimit`` buffer takes only one that
    /// replaces a held event of its slot, or the newest of each lifecycle event; it drops the rest.
    private func admit(_ envelope: DaemonEventEnvelope, slot: EventSlot?, in state: inout State) {
        guard case .upToLimit = retention, state.live >= limit, slot.flatMap({ state.newest($0) }) == nil else {
            state.append(envelope, slot: slot)
            return
        }
        if let lifecycle = EventSlot(lifecycle: envelope.event) {
            let held = state.newest(lifecycle).flatMap { index in state.events[checked: index].flatMap { $0 } }
            state.append(Self.keepingGenerationChange(envelope, over: held), slot: lifecycle)
            return
        }
        state.collapseCause = max(state.collapseCause, envelope.cause)
        state.lost += 1
    }

    /// `envelope`, a `connected` that replaces `held`, still says the generation changed when
    /// `held` did: a handle from before either reconnect is invalid.
    private static func keepingGenerationChange(_ envelope: DaemonEventEnvelope, over held: DaemonEventEnvelope?) -> DaemonEventEnvelope {
        guard case .connected(let identity, generationChanged: false) = envelope.event,
              case .connected(_, generationChanged: true)? = held?.event else { return envelope }
        return DaemonEventEnvelope(sequence: envelope.sequence, event: .connected(identity, generationChanged: true),
                                   sourceID: envelope.sourceID, cause: envelope.cause)
    }

    /// Takes everything buffered and clears the pending-frame flag.
    func take() -> [DaemonEventEnvelope] {
        state.withLock { state in
            let collapseCause = state.collapsed ? state.collapseCause : nil
            let lost = state.lost
            state.framePending = false
            state.collapsed = false
            state.collapseCause = .automation
            state.lost = 0
            state.echoes.removeAll(keepingCapacity: true)
            state.latest.removeAll(keepingCapacity: true)
            state.live = 0
            defer { state.events.removeAll(keepingCapacity: true) }
            guard let collapseCause else { return state.events.compactMap { $0 } }
            return Self.events(state.events, overflowCause: collapseCause, lost: lost)
        }
    }

    /// The live `events`, the `.overflow` marker among them carrying `cause` and, when `lost` is
    /// positive, how many events a resync cannot restore were dropped.
    private static func events(_ events: [DaemonEventEnvelope?], overflowCause cause: ObservationCause, lost: Int = 0) -> [DaemonEventEnvelope] {
        events.compactMap { (envelope: DaemonEventEnvelope?) -> DaemonEventEnvelope? in
            guard let envelope, case .overflow(let reason) = envelope.event else { return envelope }
            let event: DaemonEvent = lost > 0 ? .overflow("\(reason); dropped \(lost) events a resync cannot restore") : envelope.event
            return DaemonEventEnvelope(sequence: envelope.sequence, event: event, sourceID: envelope.sourceID, cause: cause)
        }
    }

    /// `envelopes` collapsed as the buffer collapses past its limit: one `.overflow` (with the
    /// highest cause of what it drops, and the newest sequence), then the events that outlive the
    /// snapshot it asks for, all of them (``Retention/all``). The drain's tail collapses this way
    /// past its own limit (``DrainTail``).
    static func collapse(_ envelopes: [DaemonEventEnvelope], reason: String) -> [DaemonEventEnvelope] {
        guard let newest = envelopes.lazy.map(\.sequence).max() else { return [] }
        let collapsing = EventInbox(retention: .all)
        var state = State(events: [DaemonEventEnvelope(sequence: newest, event: .overflow(reason))], live: 1, collapsed: true)
        for envelope in envelopes { collapsing.keep(envelope, in: &state) }
        return events(state.events, overflowCause: state.collapseCause)
    }

    /// Keeps new events from scheduling frames (during a resync).
    func hold() {
        state.withLock { $0.framePending = true }
    }
}

extension EventInbox.State {
    /// Holes allowed past the live count before a compaction: a flood of one slot compacts once
    /// per this many events, not on each.
    static let holeSlack = 64

    /// The index in `events` of the newest event held for `slot`, if one is.
    func newest(_ slot: EventSlot) -> Int? { latest[slot] }

    /// Appends a live event. With a `slot`, it replaces the one held for that slot in O(1), with the
    /// higher cause of the two: the replaced entry becomes a hole, and the holes are compacted away
    /// once they outnumber the live entries, so `events` stays O(live).
    mutating func append(_ envelope: DaemonEventEnvelope, slot: EventSlot?) {
        var envelope = envelope
        if let slot, let old = latest[slot], let held = events[checked: old].flatMap({ $0 }) {
            envelope = envelope.raisingCause(to: held.cause)
            events.modify(checked: old) { $0 = nil }
            live -= 1
        }
        if let slot { latest[slot] = events.count }
        events.append(envelope)
        live += 1
        if events.count > 2 * live + Self.holeSlack { compact() }
    }

    /// Drops the holes and moves each slot's index with its event.
    private mutating func compact() {
        var moved = [Int?](repeating: nil, count: events.count)
        var compacted: [DaemonEventEnvelope?] = []
        compacted.reserveCapacity(live)
        for (index, envelope) in events.enumerated() where envelope != nil {
            moved.modify(checked: index) { $0 = compacted.count }
            compacted.append(envelope)
        }
        events = compacted
        latest = latest.compactMapValues { moved[checked: $0].flatMap { $0 } }
    }
}

/// What one ``EventInbox`` entry stands for when a newer event replaces it in place: the newest
/// value of a field (normal mode), and, once the inbox collapsed, the newest agent status per
/// surface, the newest registry stamp per control connection and the newest of each lifecycle event.
enum EventSlot: Hashable {
    case field(CoalesceKey)
    case agent(SurfaceID)
    case registry(source: UUID?, serial: UInt64)
    case connected
    case disconnected
    case daemonShutdown

    /// The slot in which a full bounded inbox keeps the newest `event` of a connection lifecycle
    /// kind: the store needs the newest `connected` (a new generation invalidates every handle).
    init?(lifecycle event: DaemonEvent) {
        switch event {
        case .connected: self = .connected
        case .disconnected: self = .disconnected
        case .daemonShutdown: self = .daemonShutdown
        default: return nil
        }
    }
}
