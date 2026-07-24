import os

/// A thread-safe, byte-and-count-bounded mailbox for serialized socket sends.
///
/// Payloads live only in this mailbox. A separate coalesced wake-up may be
/// dropped safely because it carries no work. Entries remain budgeted while a
/// sender has them in flight and are never evicted to admit newer work.
public final class WorkspaceShareOutboundMailbox<Payload: Sendable>: Sendable {
    /// Serialization priority. FIFO order is preserved within each lane.
    public enum Priority: Equatable, Sendable {
        /// Reconnection hello, which must precede all later work.
        case handshake

        /// Flow-control acknowledgement.
        case acknowledgement

        /// Other JSON protocol work.
        case control

        /// Binary render-grid work.
        case bulk
    }

    /// One admitted mailbox entry.
    public struct Entry: Sendable {
        /// Caller-owned payload.
        public let payload: Payload

        /// Encoded bytes charged to the mailbox.
        public let byteCount: Int

        /// Lane used for serialized ordering.
        public let priority: Priority
    }

    /// One entry claimed by the serialized sender.
    public struct Claim: Sendable {
        /// Opaque claim identifier used to complete the send.
        public let id: UInt64

        /// The claimed entry.
        public let entry: Entry
    }

    private struct Lane {
        var entries: [Entry] = []
        var head = 0

        var isEmpty: Bool {
            head >= entries.count
        }

        mutating func append(_ entry: Entry) {
            entries.append(entry)
        }

        mutating func popFirst() -> Entry? {
            guard head < entries.count else { return nil }
            let entry = entries[head]
            head += 1
            if head >= 64, head * 2 >= entries.count {
                entries.removeFirst(head)
                head = 0
            }
            return entry
        }

        mutating func removeAll() -> [Entry] {
            let remaining = Array(entries[head...])
            entries.removeAll(keepingCapacity: true)
            head = 0
            return remaining
        }
    }

    private struct State {
        var handshake = Lane()
        var acknowledgement = Lane()
        /// Ordinary work released by a valid marker, in original admission
        /// order across JSON and binary frames.
        var releasedDeferred = Lane()
        var control = Lane()
        var bulk = Lane()
        /// Ordinary work admitted after an accepted server payload and before
        /// its adjacent acknowledgement marker.
        var deferred = Lane()
        var inFlight: [UInt64: Entry] = [:]
        var nextClaimID: UInt64 = 0
        var pendingMessages = 0
        var pendingBytes = 0
        var isStopped = false
        var acknowledgementBarrierActive = false

        var hasPending: Bool {
            !handshake.isEmpty
                || !acknowledgement.isEmpty
                || !releasedDeferred.isEmpty
                || !control.isEmpty
                || !bulk.isEmpty
                || !deferred.isEmpty
        }

        var hasClaimablePending: Bool {
            !handshake.isEmpty
                || !acknowledgement.isEmpty
                || (!acknowledgementBarrierActive
                    && (!releasedDeferred.isEmpty
                        || !control.isEmpty
                        || !bulk.isEmpty))
        }

        mutating func append(_ entry: Entry) {
            switch entry.priority {
            case .handshake:
                handshake.append(entry)
            case .acknowledgement:
                acknowledgement.append(entry)
            case .control:
                if acknowledgementBarrierActive {
                    deferred.append(entry)
                } else {
                    control.append(entry)
                }
            case .bulk:
                if acknowledgementBarrierActive {
                    deferred.append(entry)
                } else {
                    bulk.append(entry)
                }
            }
        }

        mutating func popNext() -> Entry? {
            if let entry = handshake.popFirst()
                ?? acknowledgement.popFirst() {
                return entry
            }
            guard !acknowledgementBarrierActive else { return nil }
            return releasedDeferred.popFirst()
                ?? control.popFirst()
                ?? bulk.popFirst()
        }

        mutating func releaseDeferred() {
            for entry in deferred.removeAll() {
                releasedDeferred.append(entry)
            }
            acknowledgementBarrierActive = false
        }

        mutating func discardDeferred() -> [Entry] {
            guard acknowledgementBarrierActive else { return [] }
            acknowledgementBarrierActive = false
            return deferred.removeAll()
        }

        mutating func removeQueued() -> [Entry] {
            handshake.removeAll()
                + acknowledgement.removeAll()
                + releasedDeferred.removeAll()
                + control.removeAll()
                + bulk.removeAll()
                + deferred.removeAll()
        }
    }

    /// Maximum admitted and in-flight message count.
    public let maximumMessages: Int

    /// Maximum admitted and in-flight encoded bytes.
    public let maximumBytes: Int

    /// Capacity unavailable to bulk frames so JSON control can still enter.
    public let reservedControlMessages: Int

    /// Bytes unavailable to bulk frames so JSON control can still enter.
    public let reservedControlBytes: Int

    /// Capacity unavailable to non-ACK work so ACKs can still enter.
    public let reservedAcknowledgementMessages: Int

    /// Bytes unavailable to non-ACK work so ACKs can still enter.
    public let reservedAcknowledgementBytes: Int

    private let state: OSAllocatedUnfairLock<State>

    /// Creates an empty mailbox.
    public init(
        maximumMessages: Int,
        maximumBytes: Int,
        reservedControlMessages: Int,
        reservedControlBytes: Int,
        reservedAcknowledgementMessages: Int,
        reservedAcknowledgementBytes: Int
    ) {
        self.maximumMessages = max(0, maximumMessages)
        self.maximumBytes = max(0, maximumBytes)
        self.reservedControlMessages = max(0, reservedControlMessages)
        self.reservedControlBytes = max(0, reservedControlBytes)
        self.reservedAcknowledgementMessages = max(0, reservedAcknowledgementMessages)
        self.reservedAcknowledgementBytes = max(0, reservedAcknowledgementBytes)
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    /// Admits one entry if its lane's reserved-capacity and total bounds permit it.
    @discardableResult
    public func admit(
        _ payload: Payload,
        byteCount: Int,
        priority: Priority
    ) -> Bool {
        state.withLock { state in
            admit(
                payload,
                byteCount: byteCount,
                priority: priority,
                state: &state
            )
        }
    }

    /// Starts an ACK barrier and drops a displaced barrier's deferred batch.
    ///
    /// While active, ordinary control and bulk work remains bounded in one
    /// FIFO lane and cannot be claimed by the serialized sender.
    @discardableResult
    public func beginAcknowledgementBarrier() -> [Entry] {
        state.withLock { state in
            let displaced = state.discardDeferred()
            releaseBudget(for: displaced, state: &state)
            guard !state.isStopped else { return displaced }
            state.acknowledgementBarrierActive = true
            return displaced
        }
    }

    /// Atomically admits an ACK and releases its deferred FIFO behind it.
    ///
    /// Fails closed when there is no active barrier or ACK capacity is
    /// exhausted. In either case the barrier stays active for explicit
    /// discard or connection teardown.
    @discardableResult
    public func admitAcknowledgementAndRelease(
        _ payload: Payload,
        byteCount: Int
    ) -> Bool {
        state.withLock { state in
            guard state.acknowledgementBarrierActive,
                  admit(
                    payload,
                    byteCount: byteCount,
                    priority: .acknowledgement,
                    state: &state
                  ) else {
                return false
            }
            state.releaseDeferred()
            return true
        }
    }

    /// Drops ordinary work admitted behind an unresolved or orphan marker.
    @discardableResult
    public func discardAcknowledgementBarrier() -> [Entry] {
        state.withLock { state in
            let discarded = state.discardDeferred()
            releaseBudget(for: discarded, state: &state)
            return discarded
        }
    }

    /// Claims the next serialized entry without releasing its budget.
    public func claimNext() -> Claim? {
        state.withLock { state in
            guard let entry = state.popNext() else { return nil }
            let id = state.nextClaimID
            state.nextClaimID &+= 1
            state.inFlight[id] = entry
            return Claim(id: id, entry: entry)
        }
    }

    /// Completes one in-flight entry and releases its budget.
    ///
    /// Returns `nil` when teardown already discarded the claim.
    public func complete(_ claim: Claim) -> Entry? {
        state.withLock { state in
            guard let entry = state.inFlight.removeValue(forKey: claim.id) else {
                return nil
            }
            state.pendingMessages = max(0, state.pendingMessages - 1)
            state.pendingBytes = max(0, state.pendingBytes - entry.byteCount)
            return entry
        }
    }

    /// Removes queued and in-flight work and releases all reservations.
    @discardableResult
    public func discardAll() -> [Entry] {
        state.withLock { state in
            let entries = state.removeQueued() + Array(state.inFlight.values)
            state.inFlight.removeAll(keepingCapacity: true)
            state.pendingMessages = 0
            state.pendingBytes = 0
            state.acknowledgementBarrierActive = false
            return Array(entries)
        }
    }

    /// Permanently stops admission and returns every discarded entry.
    @discardableResult
    public func stop() -> [Entry] {
        state.withLock { state in
            state.isStopped = true
            let entries = state.removeQueued() + Array(state.inFlight.values)
            state.inFlight.removeAll(keepingCapacity: true)
            state.pendingMessages = 0
            state.pendingBytes = 0
            state.acknowledgementBarrierActive = false
            return Array(entries)
        }
    }

    /// Whether at least one unclaimed entry is ready.
    public var hasPending: Bool {
        state.withLock { $0.hasPending }
    }

    /// Whether at least one entry can be claimed under the current barrier.
    public var hasClaimablePending: Bool {
        state.withLock { $0.hasClaimablePending }
    }

    /// Whether a connection-opening message is waiting to be sent.
    public var hasHandshakePending: Bool {
        state.withLock { !$0.handshake.isEmpty }
    }

    /// Current queued plus in-flight message count.
    public var pendingMessages: Int {
        state.withLock { $0.pendingMessages }
    }

    /// Current queued plus in-flight encoded bytes.
    public var pendingBytes: Int {
        state.withLock { $0.pendingBytes }
    }

    /// Whether ordinary work is waiting for an adjacent ACK marker.
    public var hasAcknowledgementBarrier: Bool {
        state.withLock { $0.acknowledgementBarrierActive }
    }

    private func admit(
        _ payload: Payload,
        byteCount: Int,
        priority: Priority,
        state: inout State
    ) -> Bool {
        guard !state.isStopped, byteCount >= 0 else { return false }
        let reservedMessages: Int
        let reservedBytes: Int
        switch priority {
        case .acknowledgement:
            reservedMessages = 0
            reservedBytes = 0
        case .handshake, .control:
            reservedMessages = reservedAcknowledgementMessages
            reservedBytes = reservedAcknowledgementBytes
        case .bulk:
            reservedMessages =
                reservedAcknowledgementMessages + reservedControlMessages
            reservedBytes =
                reservedAcknowledgementBytes + reservedControlBytes
        }
        let messageLimit = max(0, maximumMessages - reservedMessages)
        let byteLimit = max(0, maximumBytes - reservedBytes)
        guard state.pendingMessages < messageLimit,
              byteCount <= byteLimit - state.pendingBytes else {
            return false
        }
        state.append(Entry(
            payload: payload,
            byteCount: byteCount,
            priority: priority
        ))
        state.pendingMessages += 1
        state.pendingBytes += byteCount
        return true
    }

    private func releaseBudget(
        for entries: [Entry],
        state: inout State
    ) {
        state.pendingMessages = max(
            0,
            state.pendingMessages - entries.count
        )
        state.pendingBytes = max(
            0,
            state.pendingBytes - entries.reduce(0) { $0 + $1.byteCount }
        )
    }
}
