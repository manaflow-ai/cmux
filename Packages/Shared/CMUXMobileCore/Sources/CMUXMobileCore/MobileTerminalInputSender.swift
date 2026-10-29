public import Foundation

/// Delivers a phone's terminal input exactly once, in order, and only to the
/// terminal each unit was typed into.
///
/// Every unit joins the outbox of one (Mac, terminal) pair when it is
/// submitted and keeps that identity until the Mac acknowledges it. A unit is
/// sent on the terminal's input lane when one is ready and over RPC otherwise;
/// a lost lane, a failed request or a reconnect only marks units unsent, and
/// the resend carries the same identity so the Mac's ledger drops any copy it
/// already wrote. Units are settled once: delivered, undeliverable (the
/// terminal is gone or refused the unit, and it was never written), or
/// abandoned (the sender gave up on the Mac without an answer).
@MainActor
public final class MobileTerminalInputSender<Payload: Sendable> {
    public struct Key: Hashable, Sendable {
        /// The Mac that owns the terminal.
        public let hostID: String
        public let surfaceID: UUID

        public init(hostID: String, surfaceID: UUID) {
            self.hostID = hostID
            self.surfaceID = surfaceID
        }
    }

    public enum Settlement: Equatable, Sendable {
        case delivered
        case undeliverable
        case abandoned
    }

    public enum SendResult: Sendable {
        /// Written to a lane; the acknowledgement arrives through ``receive(_:)``.
        case awaitingAcknowledgement
        /// The Mac answered this unit.
        case acknowledged(MobileTerminalInputAcknowledgement)
        /// The Mac accepted and wrote the unit but did not identify it: it no
        /// longer supports exactly-once delivery (a downgraded build). The
        /// unit is settled as delivered and never resent, because a resend
        /// would be written again.
        case appliedWithoutIdentity
        /// The Mac answered with an error before admitting the unit, so it was
        /// not written.
        case refused
        /// The outcome is unknown (the transport failed). Resend it.
        case failed
        /// This path cannot carry the unit right now. Nothing was sent.
        case unavailable
    }

    public struct Transport {
        public var sendOnLane: @MainActor (Key, Payload, MobileTerminalInputDelivery) async -> SendResult
        public var sendOverRPC: @MainActor (Key, Payload, MobileTerminalInputDelivery) async -> SendResult
        /// Whether the Mac that owns `Key` can be reached for this unit.
        public var isReachable: @MainActor (Key, Payload) -> Bool
        /// Waits before retry `attempt` (1-based). Throws when the sender is
        /// torn down.
        public var pause: @MainActor (Int) async throws -> Void

        public init(
            sendOnLane: @escaping @MainActor (Key, Payload, MobileTerminalInputDelivery) async -> SendResult,
            sendOverRPC: @escaping @MainActor (Key, Payload, MobileTerminalInputDelivery) async -> SendResult,
            isReachable: @escaping @MainActor (Key, Payload) -> Bool,
            pause: @escaping @MainActor (Int) async throws -> Void
        ) {
            self.sendOnLane = sendOnLane
            self.sendOverRPC = sendOverRPC
            self.isReachable = isReachable
            self.pause = pause
        }

        public static var unreachable: Transport {
            Transport(
                sendOnLane: { _, _, _ in .unavailable },
                sendOverRPC: { _, _, _ in .unavailable },
                isReachable: { _, _ in false },
                pause: { _ in }
            )
        }
    }

    private struct Unit: Sendable {
        let token: UUID
        var payload: Payload
    }

    public typealias SettlementHandler = @MainActor (Settlement) -> Void

    /// A request error is retried this many times before the unit and every
    /// later unit of its stream are reported undeliverable.
    public static var maximumRefusals: Int { 3 }
    /// An ambiguous transport or busy response is retried this many times
    /// before the stream is abandoned. The outcome may be unknown, so these
    /// units must never be sent again under a new identity.
    public static var maximumRetryAttempts: Int { 3 }

    public var transport: Transport
    private let merge: (inout Payload, Payload) -> Bool
    private let maximumPendingBytes: Int
    private var outboxes: [Key: MobileTerminalInputOutbox<Unit>] = [:]
    private var keyByStream: [UUID: Key] = [:]
    private var handlers: [UUID: [SettlementHandler]] = [:]
    private var pumps: [Key: (id: UUID, task: Task<Void, Never>)] = [:]
    private var repump: Set<Key> = []
    private var retryAttempts: [Key: Int] = [:]
    private var refusals: [Key: Int] = [:]

    /// - Parameters:
    ///   - maximumPendingBytes: Per-terminal cap; a submit past it is refused
    ///     instead of dropping older input.
    ///   - merge: Folds a new payload into the newest unsent one (typed keys),
    ///     returning false when they must stay separate units.
    public init(
        transport: Transport = .unreachable,
        maximumPendingBytes: Int = 16 << 20,
        merge: @escaping (inout Payload, Payload) -> Bool = { _, _ in false }
    ) {
        self.transport = transport
        self.maximumPendingBytes = maximumPendingBytes
        self.merge = merge
    }

    // MARK: Submitting

    /// Queues a unit for its terminal. Returns false when the terminal's
    /// outbox is full; the unit was not queued and `onSettled` is not called.
    @discardableResult
    public func submit(
        _ payload: Payload,
        byteCount: Int,
        to key: Key,
        onSettled: SettlementHandler? = nil
    ) -> Bool {
        var outbox = outboxes[key] ?? newOutbox(for: key)
        var mergedToken: UUID?
        let merged = outbox.mergeIntoLastUnsent(addingBytes: byteCount) { unit in
            guard merge(&unit.payload, payload) else { return false }
            mergedToken = unit.token
            return true
        }
        let token: UUID
        if merged, let mergedToken {
            token = mergedToken
        } else {
            token = UUID()
            guard outbox.enqueue(Unit(token: token, payload: payload), byteCount: byteCount) != nil else {
                return false
            }
        }
        outboxes[key] = outbox
        keyByStream[outbox.streamID] = key
        if let onSettled { handlers[token, default: []].append(onSettled) }
        pump(key)
        return true
    }

    // MARK: Events

    /// An acknowledgement that arrived on a lane.
    public func receive(_ acknowledgement: MobileTerminalInputAcknowledgement) {
        guard let key = keyByStream[acknowledgement.streamID] else { return }
        apply(acknowledgement, key: key)
    }

    /// The paths that carried unacknowledged units are gone (a lane closed or
    /// the connection was replaced). Those units are sent again.
    public func resendUnacknowledged(where matches: (Key) -> Bool = { _ in true }) {
        for key in outboxes.keys where matches(key) {
            outboxes[key]?.rewindAll()
            retryAttempts[key] = nil
            pump(key)
        }
    }

    /// A path became available (a lane is ready, or the Mac reconnected).
    public func resume(where matches: (Key) -> Bool = { _ in true }) {
        for key in outboxes.keys where matches(key) {
            pump(key)
        }
    }

    /// Gives up on every unit for the matching terminals without an answer,
    /// for a Mac this phone is leaving (sign-out, a different Mac). The units
    /// are settled as abandoned; they are never sent anywhere else.
    public func abandon(where matches: (Key) -> Bool) {
        for key in Array(outboxes.keys) where matches(key) {
            pumps.removeValue(forKey: key)?.task.cancel()
            repump.remove(key)
            retryAttempts[key] = nil
            refusals[key] = nil
            guard var outbox = outboxes.removeValue(forKey: key) else { continue }
            keyByStream = keyByStream.filter { $0.value != key }
            for entry in outbox.abandonAll() {
                settle(entry.item.token, .abandoned)
            }
        }
    }

    // MARK: Inspection

    public func pendingUnitCount(for key: Key) -> Int {
        outboxes[key]?.entries.count ?? 0
    }

    public func pendingKeys() -> [Key] {
        outboxes.filter { !$0.value.isEmpty }.map(\.key)
    }

    public func streamID(for key: Key) -> UUID? {
        outboxes[key]?.streamID
    }

    // MARK: Pump

    private func newOutbox(for key: Key) -> MobileTerminalInputOutbox<Unit> {
        MobileTerminalInputOutbox<Unit>(
            surfaceID: key.surfaceID,
            maximumPendingBytes: maximumPendingBytes
        )
    }

    private func pump(_ key: Key) {
        guard pumps[key] == nil else {
            repump.insert(key)
            return
        }
        // A cancelled pump can outlive its removal from `pumps` (it finishes
        // its in-flight send first), so only the task that still owns the
        // entry may clear it.
        let id = UUID()
        pumps[key] = (id, Task { @MainActor [weak self] in
            await self?.runPump(key)
            self?.pumpFinished(key, id: id)
        })
    }

    private func pumpFinished(_ key: Key, id: UUID) {
        guard pumps[key]?.id == id else { return }
        pumps[key] = nil
        if repump.remove(key) != nil { pump(key) }
    }

    private func runPump(_ key: Key) async {
        while !Task.isCancelled {
            if let attempt = retryAttempts[key] {
                do { try await transport.pause(attempt) } catch { return }
            }
            repump.remove(key)
            guard let entry = outboxes[key]?.nextUnsent(),
                  transport.isReachable(key, entry.item.payload) else { return }
            outboxes[key]?.markSent(entry.delivery.sequence)
            var result = await transport.sendOnLane(key, entry.item.payload, entry.delivery)
            if case .unavailable = result {
                guard isPending(entry, key: key) else { continue }
                if outboxes[key]?.hasUnacknowledgedSend(before: entry.delivery.sequence) == true {
                    // A request must not overtake units still on a lane:
                    // their acknowledgements (or the lane closing) restart us.
                    outboxes[key]?.rewind(from: entry.delivery.sequence)
                    return
                }
                result = await transport.sendOverRPC(key, entry.item.payload, entry.delivery)
            }
            switch result {
            case .awaitingAcknowledgement:
                retryAttempts[key] = nil
            case .acknowledged(let acknowledgement):
                retryAttempts[key] = nil
                apply(acknowledgement, key: key)
            case .appliedWithoutIdentity:
                retryAttempts[key] = nil
                guard isPending(entry, key: key) else { continue }
                apply(MobileTerminalInputAcknowledgement(
                    status: .applied,
                    streamID: entry.delivery.streamID,
                    sequence: entry.delivery.sequence
                ), key: key)
            case .failed:
                guard isPending(entry, key: key) else { continue }
                outboxes[key]?.rewind(from: entry.delivery.sequence)
                guard scheduleRetry(for: key) else { return }
            case .refused:
                guard isPending(entry, key: key) else { continue }
                refused(entry, key: key)
            case .unavailable:
                guard isPending(entry, key: key) else { continue }
                // Neither path can carry it now; a reconnect or a ready lane
                // resumes the pump.
                outboxes[key]?.rewind(from: entry.delivery.sequence)
                return
            }
        }
    }

    /// Whether this exact unit is still pending under the identity it was
    /// sent with (an acknowledgement may have settled or renumbered it while
    /// the send was suspended).
    private func isPending(_ entry: MobileTerminalInputOutbox<Unit>.Entry, key: Key) -> Bool {
        guard let outbox = outboxes[key], outbox.streamID == entry.delivery.streamID else { return false }
        return outbox.entry(sequence: entry.delivery.sequence)?.item.token == entry.item.token
    }

    private func apply(_ acknowledgement: MobileTerminalInputAcknowledgement, key: Key) {
        guard var outbox = outboxes[key] else { return }
        let previousStream = outbox.streamID
        let result = outbox.apply(acknowledgement)
        outboxes[key] = outbox
        if outbox.streamID != previousStream {
            keyByStream[previousStream] = nil
            keyByStream[outbox.streamID] = key
        }
        if result.outcome != .ignored { refusals[key] = nil }
        for entry in result.delivered { settle(entry.item.token, .delivered) }
        for entry in result.undeliverable { settle(entry.item.token, .undeliverable) }
        switch result.outcome {
        case .ignored:
            return
        case .progressed, .resend, .undeliverable:
            pump(key)
        case .retryLater:
            guard scheduleRetry(for: key) else { return }
            pump(key)
        }
    }

    /// Records one retryable response. Once the outcome is too ambiguous to
    /// keep retrying, abandon the whole ordered stream so later input cannot
    /// overtake an unresolved unit.
    @discardableResult
    private func scheduleRetry(for key: Key) -> Bool {
        let attempts = (retryAttempts[key] ?? 0) + 1
        guard attempts < Self.maximumRetryAttempts else {
            abandon { $0 == key }
            return false
        }
        retryAttempts[key] = attempts
        return true
    }

    /// The Mac answered this unit with an error before admitting it, so its
    /// ledger still expects it. It is retried a few times; after that it and
    /// every later unit are undeliverable (none of them can have been written,
    /// because the ledger applies in order) and the terminal starts a fresh
    /// stream. Nothing earlier is in flight: a request never overtakes a lane.
    private func refused(_ entry: MobileTerminalInputOutbox<Unit>.Entry, key: Key) {
        let count = (refusals[key] ?? 0) + 1
        guard count >= Self.maximumRefusals else {
            refusals[key] = count
            outboxes[key]?.rewind(from: entry.delivery.sequence)
            retryAttempts[key] = (retryAttempts[key] ?? 0) + 1
            return
        }
        refusals[key] = nil
        retryAttempts[key] = nil
        guard var outbox = outboxes[key] else { return }
        keyByStream[outbox.streamID] = nil
        let abandoned = outbox.abandonAll()
        let fresh = newOutbox(for: key)
        outboxes[key] = fresh
        keyByStream[fresh.streamID] = key
        for unit in abandoned {
            settle(unit.item.token, .undeliverable)
        }
    }

    private func settle(_ token: UUID, _ settlement: Settlement) {
        guard let pending = handlers.removeValue(forKey: token) else { return }
        for handler in pending { handler(settlement) }
    }
}
