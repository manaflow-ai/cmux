public import Foundation

/// Identity of one unit of terminal input for exactly-once delivery.
///
/// The phone owns one input stream per terminal for the life of its process.
/// Every unit it sends on that stream carries the terminal it was typed into,
/// the stream, and a sequence that starts at 1 and increases by one. The host
/// applies each sequence exactly once and in order, no matter how many times
/// or over which path (input lane, RPC, a new connection) the unit arrives.
public struct MobileTerminalInputDelivery: Equatable, Hashable, Sendable {
    /// Host capability: the host verifies, deduplicates, orders and
    /// acknowledges delivery identities on every terminal input path.
    public static let capability = "terminal.input.exactly_once.v1"
    /// RPC parameter keys carrying the identity next to the explicit
    /// `surface_id`.
    public static let streamParameter = "input_stream_id"
    public static let sequenceParameter = "input_stream_seq"
    public static let encodedByteCount = 40

    public let surfaceID: UUID
    public let streamID: UUID
    public let sequence: UInt64

    public init(surfaceID: UUID, streamID: UUID, sequence: UInt64) {
        self.surfaceID = surfaceID
        self.streamID = streamID
        self.sequence = sequence
    }

    public func encoded() -> Data {
        var data = Data(capacity: Self.encodedByteCount)
        data.append(contentsOf: surfaceID.uuidBytes)
        data.append(contentsOf: streamID.uuidBytes)
        var sequence = sequence.bigEndian
        withUnsafeBytes(of: &sequence) { data.append(contentsOf: $0) }
        return data
    }

    /// Decodes exactly ``encodedByteCount`` bytes; nil for any other length.
    public init?(decoding data: Data) {
        guard data.count == Self.encodedByteCount else { return nil }
        let bytes = [UInt8](data)
        self.surfaceID = UUID(uuidBytes: Array(bytes[0..<16]))
        self.streamID = UUID(uuidBytes: Array(bytes[16..<32]))
        self.sequence = bytes[32..<40].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    /// RPC parameters for this identity; the caller also sends `surface_id`.
    public var rpcParameters: [String: String] {
        [
            Self.streamParameter: streamID.uuidString,
            Self.sequenceParameter: String(sequence),
        ]
    }

    /// Reads an identity from RPC parameters. Returns nil when the request
    /// carries none (a legacy phone). The surface comes from the request's
    /// explicit `surface_id`, never from focus.
    public static func fromRPC(parameters: [String: Any], surfaceID: UUID) -> Self? {
        guard let rawStream = parameters[streamParameter] as? String,
              let streamID = UUID(uuidString: rawStream),
              let sequence = Self.sequenceValue(parameters[sequenceParameter]),
              sequence > 0 else {
            return nil
        }
        return Self(surfaceID: surfaceID, streamID: streamID, sequence: sequence)
    }

    private static func sequenceValue(_ value: Any?) -> UInt64? {
        switch value {
        case let string as String: return UInt64(string)
        case let number as NSNumber: return number.uint64Value
        default: return nil
        }
    }
}

/// The host's answer to one delivered input unit.
public struct MobileTerminalInputAcknowledgement: Equatable, Sendable {
    public enum Status: UInt8, Equatable, Sendable {
        /// Applied now; every sequence through `sequence` is applied.
        case applied = 1
        /// Already applied earlier; every sequence through `sequence` is applied.
        case duplicate = 2
        /// Not applied: an earlier sequence is missing. Resend from `expected`.
        case gap = 3
        /// Not applied: the unit reached a lane or request for another
        /// terminal. Resent on its own terminal's path, never applied here.
        case surfaceMismatch = 4
        /// Not applied: the terminal is gone or its process exited. Never
        /// redirected to another terminal.
        case terminalUnavailable = 5
        /// Not applied: the host's input queue is full. Retry the same unit.
        case busy = 6
        /// Consumed without writing: the host admitted the unit but could not
        /// use it (an image it could not store). Later units still apply;
        /// this one is reported undelivered and never resent.
        case rejected = 7
    }

    public static let encodedByteCount = 34

    public let status: Status
    public let streamID: UUID
    /// For applied and duplicate: the highest applied sequence. For the
    /// rejections: the rejected unit's sequence.
    public let sequence: UInt64
    /// For gap: the next sequence the host will apply. Otherwise zero.
    public let expected: UInt64

    public init(status: Status, streamID: UUID, sequence: UInt64, expected: UInt64 = 0) {
        self.status = status
        self.streamID = streamID
        self.sequence = sequence
        self.expected = expected
    }

    public func encoded() -> Data {
        var data = Data(capacity: Self.encodedByteCount)
        data.append(1) // body version
        data.append(status.rawValue)
        data.append(contentsOf: streamID.uuidBytes)
        var sequence = sequence.bigEndian
        withUnsafeBytes(of: &sequence) { data.append(contentsOf: $0) }
        var expected = expected.bigEndian
        withUnsafeBytes(of: &expected) { data.append(contentsOf: $0) }
        return data
    }

    public init?(decoding data: Data) {
        guard data.count == Self.encodedByteCount else { return nil }
        let bytes = [UInt8](data)
        guard bytes[0] == 1, let status = Status(rawValue: bytes[1]) else { return nil }
        self.status = status
        self.streamID = UUID(uuidBytes: Array(bytes[2..<18]))
        self.sequence = bytes[18..<26].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        self.expected = bytes[26..<34].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    /// RPC response payload keys.
    public var rpcPayload: [String: Any] {
        [
            "input_ack": [
                "status": Self.statusName(status),
                "stream_id": streamID.uuidString,
                "sequence": String(sequence),
                "expected": String(expected),
            ],
        ]
    }

    public static func fromRPC(payload: [String: Any]) -> Self? {
        guard let body = payload["input_ack"] as? [String: Any],
              let rawStatus = body["status"] as? String,
              let status = statusValue(rawStatus),
              let rawStream = body["stream_id"] as? String,
              let streamID = UUID(uuidString: rawStream),
              let sequence = (body["sequence"] as? String).flatMap(UInt64.init) else {
            return nil
        }
        let expected = (body["expected"] as? String).flatMap(UInt64.init) ?? 0
        return Self(status: status, streamID: streamID, sequence: sequence, expected: expected)
    }

    private static func statusName(_ status: Status) -> String {
        switch status {
        case .applied: "applied"
        case .duplicate: "duplicate"
        case .gap: "gap"
        case .surfaceMismatch: "surface_mismatch"
        case .terminalUnavailable: "terminal_unavailable"
        case .busy: "busy"
        case .rejected: "rejected"
        }
    }

    private static func statusValue(_ name: String) -> Status? {
        switch name {
        case "applied": .applied
        case "duplicate": .duplicate
        case "gap": .gap
        case "surface_mismatch": .surfaceMismatch
        case "terminal_unavailable": .terminalUnavailable
        case "busy": .busy
        case "rejected": .rejected
        default: nil
        }
    }
}

/// Host-side record of the highest applied sequence per input stream.
///
/// A stream is bound to the terminal of its first unit; a later unit naming a
/// different terminal is refused, so one stream can never write to two
/// terminals. Callers check ``admit(_:now:)`` before applying and call
/// ``recordApplied(_:now:)`` only after the terminal accepted the input, so a
/// unit the terminal refused (queue full) is not marked applied.
public struct MobileTerminalInputLedger: Sendable {
    public enum Admission: Equatable, Sendable {
        case apply
        case duplicate(appliedThrough: UInt64)
        case gap(expected: UInt64)
        case surfaceMismatch
    }

    private struct Entry: Sendable {
        let surfaceID: UUID
        var appliedThrough: UInt64
        var lastUsed: Date
    }

    public static let defaultCapacity = 4_096
    private let capacity: Int
    private var entries: [UUID: Entry] = [:]

    public init(capacity: Int = MobileTerminalInputLedger.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    public var streamCount: Int { entries.count }

    public mutating func admit(_ delivery: MobileTerminalInputDelivery, now: Date) -> Admission {
        guard var entry = entries[delivery.streamID] else {
            // A stream starts at 1. Admitting a later unit first would let a
            // fast path overtake a slow one and turn the earlier units into
            // "duplicates". A phone whose stream this host forgot (restart)
            // sees an expected sequence below its oldest pending unit and
            // moves its pending units onto a new stream.
            return delivery.sequence == 1 ? .apply : .gap(expected: 1)
        }
        guard entry.surfaceID == delivery.surfaceID else { return .surfaceMismatch }
        entry.lastUsed = now
        entries[delivery.streamID] = entry
        if delivery.sequence <= entry.appliedThrough {
            return .duplicate(appliedThrough: entry.appliedThrough)
        }
        if delivery.sequence == entry.appliedThrough + 1 {
            return .apply
        }
        return .gap(expected: entry.appliedThrough + 1)
    }

    public mutating func recordApplied(_ delivery: MobileTerminalInputDelivery, now: Date) {
        if var entry = entries[delivery.streamID] {
            guard entry.surfaceID == delivery.surfaceID else { return }
            entry.appliedThrough = max(entry.appliedThrough, delivery.sequence)
            entry.lastUsed = now
            entries[delivery.streamID] = entry
            return
        }
        entries[delivery.streamID] = Entry(
            surfaceID: delivery.surfaceID,
            appliedThrough: delivery.sequence,
            lastUsed: now
        )
        evictIfNeeded()
    }

    public func appliedThrough(streamID: UUID) -> UInt64? {
        entries[streamID]?.appliedThrough
    }

    private mutating func evictIfNeeded() {
        while entries.count > capacity,
              let oldest = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
            entries.removeValue(forKey: oldest)
        }
    }
}

/// Phone-side outbox for one terminal's input stream.
///
/// Every unit gets the next sequence when it is enqueued and stays until the
/// host acknowledges it. Sending never removes a unit: a failure, a gap
/// report, or a reconnect only marks units unsent again so they are resent
/// with the same identity, and the host's ledger makes the resend harmless.
public struct MobileTerminalInputOutbox<Item: Sendable>: Sendable {
    public struct Entry: Sendable {
        public let delivery: MobileTerminalInputDelivery
        public var item: Item
        public var isSent: Bool
        public fileprivate(set) var byteCount: Int
    }

    /// What the caller does after ``apply(_:)``.
    public enum AcknowledgementOutcome: Equatable, Sendable {
        /// The acknowledgement belongs to another stream or changes nothing.
        case ignored
        /// Units were confirmed; send whatever is still unsent.
        case progressed
        /// Units must be sent again now, with the identities they now have.
        case resend
        /// The terminal's input queue was full; send again after a pause.
        case retryLater
        /// The terminal is gone. The returned units were never written and
        /// must be reported to the user, never sent anywhere else.
        case undeliverable
    }

    public let surfaceID: UUID
    public private(set) var streamID: UUID
    public let maximumPendingBytes: Int
    public private(set) var nextSequence: UInt64 = 1
    public private(set) var entries: [Entry] = []
    public private(set) var pendingBytes = 0

    public init(
        surfaceID: UUID,
        streamID: UUID = UUID(),
        maximumPendingBytes: Int = 1 << 20
    ) {
        self.surfaceID = surfaceID
        self.streamID = streamID
        self.maximumPendingBytes = maximumPendingBytes
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var hasUnsent: Bool { entries.contains { !$0.isSent } }

    /// Adds a unit; nil when accepting it would exceed the pending byte cap.
    public mutating func enqueue(_ item: Item, byteCount: Int) -> MobileTerminalInputDelivery? {
        guard pendingBytes + byteCount <= maximumPendingBytes else { return nil }
        let delivery = MobileTerminalInputDelivery(
            surfaceID: surfaceID,
            streamID: streamID,
            sequence: nextSequence
        )
        nextSequence += 1
        entries.append(Entry(delivery: delivery, item: item, isSent: false, byteCount: byteCount))
        pendingBytes += byteCount
        return delivery
    }

    /// The oldest unit not yet sent. Units are always sent in sequence order.
    public func nextUnsent() -> Entry? {
        entries.first { !$0.isSent }
    }

    public mutating func markSent(_ sequence: UInt64) {
        guard let index = entries.firstIndex(where: { $0.delivery.sequence == sequence }) else { return }
        entries[index].isSent = true
    }

    /// Marks every unit from `sequence` on unsent (a gap report, or an
    /// ambiguous failure of the path that carried them).
    public mutating func rewind(from sequence: UInt64) {
        for index in entries.indices where entries[index].delivery.sequence >= sequence {
            entries[index].isSent = false
        }
    }

    /// Marks every pending unit unsent (a new connection or lane).
    public mutating func rewindAll() {
        for index in entries.indices { entries[index].isSent = false }
    }

    /// Drops every unit through `sequence`: the host applied them.
    @discardableResult
    public mutating func acknowledge(through sequence: UInt64) -> [Entry] {
        let removed = entries.filter { $0.delivery.sequence <= sequence }
        guard !removed.isEmpty else { return [] }
        entries.removeAll { $0.delivery.sequence <= sequence }
        pendingBytes -= removed.reduce(0) { $0 + $1.byteCount }
        return removed
    }

    /// Drops every pending unit because the terminal is gone and returns them
    /// in order, so the caller can report them undelivered. They are never
    /// sent to another terminal.
    public mutating func abandonAll() -> [Entry] {
        let abandoned = entries
        entries.removeAll()
        pendingBytes = 0
        return abandoned
    }

    /// The effect of one acknowledgement on this outbox.
    public struct AcknowledgementResult: Sendable {
        public var outcome: AcknowledgementOutcome
        /// Units the host confirmed written, in order.
        public var delivered: [Entry] = []
        /// Units that will never be written, in order.
        public var undeliverable: [Entry] = []
    }

    /// Applies one host acknowledgement for this stream.
    ///
    /// Only ``MobileTerminalInputAcknowledgement/Status/rejected`` and
    /// ``MobileTerminalInputAcknowledgement/Status/terminalUnavailable`` give
    /// up on a unit. Every other status keeps it: the host confirms applied
    /// units and the rest are resent with their identity, so the host's ledger
    /// drops any it already wrote.
    public mutating func apply(
        _ acknowledgement: MobileTerminalInputAcknowledgement
    ) -> AcknowledgementResult {
        guard acknowledgement.streamID == streamID else { return AcknowledgementResult(outcome: .ignored) }
        switch acknowledgement.status {
        case .applied, .duplicate:
            let delivered = acknowledge(through: acknowledgement.sequence)
            return AcknowledgementResult(
                outcome: delivered.isEmpty ? .ignored : .progressed,
                delivered: delivered
            )
        case .rejected:
            // Admission passed, so everything before it is written; the unit
            // itself is consumed and later units continue on this stream.
            var delivered = acknowledge(through: acknowledgement.sequence)
            guard let last = delivered.last,
                  last.delivery.sequence == acknowledgement.sequence else {
                return AcknowledgementResult(outcome: delivered.isEmpty ? .ignored : .progressed, delivered: delivered)
            }
            delivered.removeLast()
            return AcknowledgementResult(outcome: .progressed, delivered: delivered, undeliverable: [last])
        case .gap:
            let expected = acknowledgement.expected
            if let oldest = entries.first?.delivery.sequence, expected < oldest {
                // The host expects a unit this outbox already saw
                // acknowledged, so it lost the stream (it restarted). The
                // pending units were never written to the terminal the host
                // has now; they move to a new stream starting at 1.
                rebaseOntoNewStream()
                return AcknowledgementResult(outcome: .resend)
            }
            let delivered = expected > 1 ? acknowledge(through: expected - 1) : []
            rewind(from: expected)
            return AcknowledgementResult(outcome: .resend, delivered: delivered)
        case .busy:
            // Admission passed, so everything before this unit is applied.
            let delivered = acknowledgement.sequence > 1
                ? acknowledge(through: acknowledgement.sequence - 1)
                : []
            rewind(from: acknowledgement.sequence)
            return AcknowledgementResult(outcome: .retryLater, delivered: delivered)
        case .surfaceMismatch:
            // The unit reached a lane or request for another terminal and was
            // refused unwritten. Send it again on this terminal's own path.
            rewind(from: acknowledgement.sequence)
            return AcknowledgementResult(outcome: .resend)
        case .terminalUnavailable:
            return AcknowledgementResult(outcome: .undeliverable, undeliverable: abandonAll())
        }
    }

    /// Moves every pending unit, in order, onto a fresh stream numbered from 1.
    public mutating func rebaseOntoNewStream(_ newStreamID: UUID = UUID()) {
        streamID = newStreamID
        var sequence: UInt64 = 1
        entries = entries.map { entry in
            defer { sequence += 1 }
            return Entry(
                delivery: MobileTerminalInputDelivery(
                    surfaceID: surfaceID,
                    streamID: newStreamID,
                    sequence: sequence
                ),
                item: entry.item,
                isSent: false,
                byteCount: entry.byteCount
            )
        }
        nextSequence = sequence
    }

    /// The unit with this sequence, if it is still pending.
    public func entry(sequence: UInt64) -> Entry? {
        entries.first { $0.delivery.sequence == sequence }
    }

    /// Lets the caller merge new input into the newest unit that has not been
    /// sent yet, keeping one sequence for the merged unit. Refused when the
    /// added bytes would exceed the pending byte cap.
    public mutating func mergeIntoLastUnsent(
        addingBytes byteCount: Int = 0,
        _ merge: (inout Item) -> Bool
    ) -> Bool {
        guard let index = entries.indices.last, !entries[index].isSent,
              pendingBytes + byteCount <= maximumPendingBytes,
              merge(&entries[index].item) else { return false }
        entries[index].byteCount += byteCount
        pendingBytes += byteCount
        return true
    }

    /// Whether a unit before `sequence` was sent and is not yet acknowledged.
    /// A request on another path must not overtake it.
    public func hasUnacknowledgedSend(before sequence: UInt64) -> Bool {
        entries.contains { $0.isSent && $0.delivery.sequence < sequence }
    }
}

extension UUID {
    var uuidBytes: [UInt8] {
        let bytes = uuid
        return [
            bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7,
            bytes.8, bytes.9, bytes.10, bytes.11, bytes.12, bytes.13, bytes.14, bytes.15,
        ]
    }

    init(uuidBytes bytes: [UInt8]) {
        self.init(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
