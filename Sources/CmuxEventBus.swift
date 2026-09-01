import Foundation

struct CmuxEventSubscriptionSnapshot {
    let subscription: CmuxEventSubscription
    let replay: [[String: Any]]
    let ack: [String: Any]
}

// Sendable safety: event state is protected by `lock`; disk appends are delegated to `CmuxEventLogWriter`.
final class CmuxEventBus: @unchecked Sendable {
    static let shared = CmuxEventBus(eventLogURL: defaultEventLogURL())
    static let protocolName = "cmux-events"
    static let protocolVersion = 1
    static let defaultHeartbeatIntervalSeconds: TimeInterval = 15
    static let defaultRetainedEventLimit = 4_096
    static let defaultMaxEventLineBytes = 16 * 1024
    static let defaultMaxEventLogBytes: UInt64 = 16 * 1024 * 1024
    static let defaultMaxPendingEventLogLines = CmuxEventLogWriter.defaultMaxPendingLines
    static let defaultMaxPendingEventsPerSubscription = 1_024
    // Reserving a range amortizes the durable-floor write while preserving a
    // monotonic sequence after a crash (unused reserved values become gaps).
    static let defaultSequenceReservationBlock: Int64 = 64
    static let maxSanitizedStringBytes = 8 * 1024
    static let maxSanitizedArrayItems = 256
    static let maxSanitizedObjectEntries = 256
    static let maxSanitizedDepth = 12
    // ISO8601DateFormatter is protected by `isoFormatterLock`; the explicit
    // nonisolated annotation keeps this synchronous utility available to the
    // socket and event-log paths without claiming the formatter is Sendable.
    private nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = { let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter }()
    private static let isoFormatterLock = NSLock()
    private static let sequenceFloorWriteQueue = DispatchQueue(
        label: "com.cmux.event-sequence-floor-write",
        qos: .utility
    )

    private let lock = NSLock()
    private let retainedEventLimit: Int
    private let maxEventLineBytes: Int
    private let maxPendingEventsPerSubscription: Int
    private let sequenceReservationBlock: Int64
    private let eventLogWriter: CmuxEventLogWriter?
    private let bootId = UUID().uuidString
    private var nextSequence: Int64 = 1
    private var latestAllocatedSequence: Int64 = 0
    private var reservedSequenceCeiling: Int64 = 0
    private let sequenceFloor: CmuxEventSequenceFloor?
    private var sequenceFloorGap = false
    private var durableSequenceSeeded = false
    private var retained: [[String: Any]] = []
    private var subscriptions: [UUID: CmuxEventSubscription] = [:]
    private let durableReplayStore: CmuxEventLogReplayStore?

    init(
        retainedEventLimit: Int = CmuxEventBus.defaultRetainedEventLimit,
        eventLogURL: URL? = nil,
        maxEventLogBytes: UInt64 = CmuxEventBus.defaultMaxEventLogBytes,
        maxEventLineBytes: Int = CmuxEventBus.defaultMaxEventLineBytes,
        maxPendingEventLogLines: Int = CmuxEventBus.defaultMaxPendingEventLogLines,
        maxPendingEventsPerSubscription: Int = CmuxEventBus.defaultMaxPendingEventsPerSubscription,
        sequenceReservationBlock: Int64 = CmuxEventBus.defaultSequenceReservationBlock
    ) {
        let normalizedMaxEventLineBytes = max(1, maxEventLineBytes)
        let normalizedMaxEventLogBytes = max(1, maxEventLogBytes)
        let normalizedSequenceReservationBlock = max(1, sequenceReservationBlock)
        self.retainedEventLimit = max(1, retainedEventLimit)
        self.maxEventLineBytes = normalizedMaxEventLineBytes
        self.maxPendingEventsPerSubscription = max(1, maxPendingEventsPerSubscription)
        self.sequenceReservationBlock = normalizedSequenceReservationBlock
        let replayStore = eventLogURL.map {
            CmuxEventLogReplayStore(
                eventLogURL: $0,
                maxEventLineBytes: normalizedMaxEventLineBytes,
                maxEventLogBytes: normalizedMaxEventLogBytes
            )
        }
        let onPersisted: (@Sendable (CmuxEventLogPersistedBatch) -> Void)?
        if let replayStore = replayStore {
            onPersisted = { [weak replayStore] batch in replayStore?.apply(batch) }
        } else {
            onPersisted = nil
        }
        let floor = eventLogURL.map(CmuxEventSequenceFloor.init(eventLogURL:))
        // The replay cache is loaded asynchronously. A first publish or
        // subscription seeds from its completed high-water mark before using
        // this provisional value, so no durable sequence can be reused.
        let restoration = floor?.restoration(durableLatestSequence: nil)
        let restoredNextSequence = restoration?.nextSequence ?? 1
        self.durableReplayStore = replayStore
        self.eventLogWriter = eventLogURL.map {
            CmuxEventLogWriter(
                eventLogURL: $0,
                maxEventLogBytes: normalizedMaxEventLogBytes,
                maxPendingLines: maxPendingEventLogLines,
                onPersisted: onPersisted
            )
        }
        self.sequenceFloor = floor
        self.nextSequence = restoredNextSequence
        self.latestAllocatedSequence = 0
        self.reservedSequenceCeiling = Self.sequenceBefore(restoredNextSequence)
        self.sequenceFloorGap = restoration?.hasGap ?? false
        self.durableSequenceSeeded = replayStore == nil
    }

    var latestSequence: Int64 {
        ensureDurableSequenceSeeded()
        lock.lock()
        defer { lock.unlock() }
        return latestAllocatedSequence
    }

    /// Seeds the in-memory counter from the utility-loaded durable cache once.
    func ensureDurableSequenceSeeded() {
        guard let durableReplayStore else { return }
        lock.lock()
        let alreadySeeded = durableSequenceSeeded
        lock.unlock()
        guard !alreadySeeded else { return }

        let durableLatestSequence = durableReplayStore.latestSequenceForStartup()
        let floorState = sequenceFloor?.read()
        lock.lock()
        defer { lock.unlock() }
        guard !durableSequenceSeeded else { return }

        if let durableLatestSequence {
            let durableNextSequence = Self.sequenceAfter(durableLatestSequence)
            if durableNextSequence > nextSequence {
                nextSequence = durableNextSequence
            }
            latestAllocatedSequence = max(latestAllocatedSequence, durableLatestSequence)
            if floorState?.isUnreadable == true
                || floorState?.nextSequence == nil
                || (floorState?.nextSequence ?? 0) < durableNextSequence {
                sequenceFloorGap = true
            }
            reservedSequenceCeiling = max(
                reservedSequenceCeiling,
                Self.sequenceBefore(durableNextSequence)
            )
        } else if let persistedNextSequence = floorState?.nextSequence,
                  persistedNextSequence > 1 {
            // A reserved range with no durable records may represent events
            // lost before append; retain a conservative gap signal and keep
            // latest_seq at the last known durable allocation (zero here).
            sequenceFloorGap = true
        }
        durableSequenceSeeded = true
    }

    func makeSubscriptionContext(
        names: Set<String>,
        categories: Set<String>
    ) -> (
        subscription: CmuxEventSubscription,
        retained: [[String: Any]],
        latestSequence: Int64,
        nextSequence: Int64,
        bootId: String,
        durableReplayStore: CmuxEventLogReplayStore?,
        sequenceFloorGap: Bool
    ) {
        let subscription = CmuxEventSubscription(
            names: names,
            categories: categories,
            maxPendingEvents: maxPendingEventsPerSubscription
        )

        lock.lock()
        let context = (
            subscription: subscription,
            retained: retained,
            latestSequence: latestAllocatedSequence,
            nextSequence: nextSequence,
            bootId: bootId,
            durableReplayStore: durableReplayStore,
            sequenceFloorGap: sequenceFloorGap
        )
        subscriptions[subscription.id] = subscription
        lock.unlock()
        return context
    }

    func publish(
        name: String,
        category: String,
        source: String,
        workspaceId: String? = nil,
        surfaceId: String? = nil,
        paneId: String? = nil,
        windowId: String? = nil,
        payload: [String: Any] = [:]
    ) {
        ensureDurableSequenceSeeded()
        let occurredAt = Self.isoTimestamp(Date())
        let cleanPayload = Self.sanitizedJSONValue(payload)

        while true {
            guard reserveSequenceBlockIfNeeded() else { return }
            lock.lock()
            let sequence = nextSequence
            if sequenceFloor != nil, sequence > reservedSequenceCeiling {
                lock.unlock()
                continue
            }
            self.nextSequence = Self.sequenceAfter(sequence)
            self.latestAllocatedSequence = sequence

            var event: [String: Any] = [
                "type": "event",
                "protocol": Self.protocolName,
                "version": Self.protocolVersion,
                "boot_id": bootId,
                "seq": sequence,
                "id": "\(bootId)-\(sequence)",
                "name": name,
                "category": category,
                "source": source,
                "occurred_at": occurredAt,
                "workspace_id": workspaceId ?? NSNull(),
                "surface_id": surfaceId ?? NSNull(),
                "pane_id": paneId ?? NSNull(),
                "window_id": windowId ?? NSNull(),
                "payload": cleanPayload
            ]

            event = Self.eventByApplyingEncodedByteLimit(event, maxBytes: maxEventLineBytes)
            retained.append(event)
            if retained.count > retainedEventLimit {
                retained.removeFirst(retained.count - retainedEventLimit)
            }
            let encodedLine = Self.encodeLine(event)
            let liveSubscriptions = Array(subscriptions.values)
            lock.unlock()

            if let encodedLine { eventLogWriter?.enqueue(encodedLine) }

            for subscription in liveSubscriptions where subscription.accepts(event) {
                if !subscription.enqueue(event) {
                    removeSubscriptionIfStillActive(subscription)
                }
            }
            return
        }
    }

    /// Reserves a durable sequence range outside the event-state lock.
    private func reserveSequenceBlockIfNeeded() -> Bool {
        guard let sequenceFloor else { return true }

        lock.lock()
        let sequence = nextSequence
        guard sequence > reservedSequenceCeiling else {
            lock.unlock()
            return true
        }
        let exclusiveEnd = Self.sequenceAfter(sequence, by: sequenceReservationBlock)
        lock.unlock()

        // Reservation writes are infrequent and serialized on their own lane;
        // the event-state lock is never held across filesystem I/O.
        let didWrite = Self.sequenceFloorWriteQueue.sync {
            sequenceFloor.write(nextSequence: exclusiveEnd)
        }
        lock.lock()
        if didWrite {
            let newCeiling = Self.sequenceBefore(exclusiveEnd)
            reservedSequenceCeiling = max(reservedSequenceCeiling, newCeiling)
        } else {
            sequenceFloorGap = true
        }
        lock.unlock()
        return didWrite
    }

    func unsubscribe(_ subscription: CmuxEventSubscription) {
        lock.lock()
        subscriptions.removeValue(forKey: subscription.id)
        lock.unlock()
        subscription.close()
    }

    private func removeSubscriptionIfStillActive(_ subscription: CmuxEventSubscription) {
        lock.lock()
        if subscriptions[subscription.id] === subscription {
            subscriptions.removeValue(forKey: subscription.id)
        }
        lock.unlock()
    }

    func heartbeat(subscription: CmuxEventSubscription) -> [String: Any] {
        [
            "type": "heartbeat",
            "protocol": Self.protocolName,
            "version": Self.protocolVersion,
            "boot_id": bootId,
            "subscription_id": subscription.id.uuidString,
            "latest_seq": NSNumber(value: latestSequence),
            "occurred_at": Self.isoTimestamp(Date())
        ]
    }

    func retainedSnapshot() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return retained
    }

    #if DEBUG
    func resetForTesting() {
        lock.lock()
        nextSequence = 1
        latestAllocatedSequence = 0
        reservedSequenceCeiling = 0
        sequenceFloorGap = false
        durableSequenceSeeded = true
        let floor = sequenceFloor
        retained.removeAll()
        let active = Array(subscriptions.values)
        subscriptions.removeAll()
        lock.unlock()
        if let floor,
           !Self.writeSequenceFloor(floor, nextSequence: 1) {
            lock.lock()
            sequenceFloorGap = true
            lock.unlock()
        }
        active.forEach { $0.close() }
        eventLogWriter?.resetForTesting()
    }

    func flushEventLogForTesting() {
        eventLogWriter?.flushForTesting()
    }

    func setEventLogFlushSuspendedForTesting(_ suspended: Bool) {
        eventLogWriter?.setFlushSuspendedForTesting(suspended)
    }

    func eventLogBacklogSnapshotForTesting() -> (pending: Int, dropped: Int) {
        eventLogWriter?.backlogSnapshotForTesting() ?? (0, 0)
    }
    #endif

    private static func sequenceAfter(_ sequence: Int64) -> Int64 {
        sequence == Int64.max ? Int64.max : sequence + 1
    }

    private static func sequenceAfter(_ sequence: Int64, by distance: Int64) -> Int64 {
        guard distance > 0,
              sequence <= Int64.max - distance else {
            return Int64.max
        }
        return sequence + distance
    }

    private static func sequenceBefore(_ nextSequence: Int64) -> Int64 {
        nextSequence <= 1 ? 0 : nextSequence - 1
    }

    private static func writeSequenceFloor(
        _ floor: CmuxEventSequenceFloor,
        nextSequence: Int64
    ) -> Bool {
        sequenceFloorWriteQueue.sync {
            floor.write(nextSequence: nextSequence)
        }
    }

    static func defaultEventLogURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    static func encodeLine(_ object: [String: Any]) -> String? {
        let clean = sanitizedJSONValue(object)
        guard JSONSerialization.isValidJSONObject(clean),
              let data = try? JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string.replacingOccurrences(of: "\n", with: "\\n")
    }

    static func int64(_ value: Any?) -> Int64? {
        if let string = value as? String { return Int64(string) }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let type = String(cString: number.objCType)
        guard ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"].contains(type) else { return nil }
        let int64 = number.int64Value
        return number.compare(NSNumber(value: int64)) == .orderedSame ? int64 : nil
    }

    static func sanitizedJSONValue(_ value: Any) -> Any {
        sanitizedJSONValue(value, depth: 0)
    }

    private static func sanitizedJSONValue(_ value: Any, depth: Int) -> Any {
        guard depth <= maxSanitizedDepth else {
            return "[truncated: max depth]"
        }

        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let child = mirror.children.first else { return NSNull() }
            return sanitizedJSONValue(child.value, depth: depth + 1)
        }

        switch value {
        case let value as NSNull:
            return value
        case let value as UUID:
            return value.uuidString
        case let value as Date:
            return isoTimestamp(value)
        case let value as String:
            return truncatedString(value, maxUTF8Bytes: maxSanitizedStringBytes)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return value.boolValue
            }
            return value
        case let value as Bool:
            return value
        case let value as Int:
            return value
        case let value as Int64:
            return NSNumber(value: value)
        case let value as UInt64:
            return NSNumber(value: min(value, UInt64(Int64.max)))
        case let value as Double:
            return value.isFinite ? value : NSNull()
        case let value as Float:
            return value.isFinite ? Double(value) : NSNull()
        case let value as [String: Any]:
            var result: [String: Any] = [:]
            for key in value.keys.sorted().prefix(maxSanitizedObjectEntries) {
                result[truncatedString(key, maxUTF8Bytes: 256)] = sanitizedJSONValue(value[key] as Any, depth: depth + 1)
            }
            if value.count > maxSanitizedObjectEntries {
                result["__cmux_truncated_entries"] = value.count - maxSanitizedObjectEntries
            }
            return result
        case let value as [Any]:
            var result = value.prefix(maxSanitizedArrayItems).map { sanitizedJSONValue($0, depth: depth + 1) }
            if value.count > maxSanitizedArrayItems {
                result.append(["__cmux_truncated_items": value.count - maxSanitizedArrayItems])
            }
            return result
        default:
            return truncatedString(String(describing: value), maxUTF8Bytes: maxSanitizedStringBytes)
        }
    }

    private static func eventByApplyingEncodedByteLimit(_ event: [String: Any], maxBytes: Int) -> [String: Any] {
        guard maxBytes > 0,
              let line = encodeLine(event),
              line.utf8.count > maxBytes else {
            return event
        }

        var compact = event
        let payload = event["payload"] as? [String: Any] ?? [:]
        compact["payload_truncated"] = true
        compact["payload"] = [
            "truncated": true,
            "reason": "event exceeded max encoded byte limit",
            "max_bytes": maxBytes,
            "original_payload_keys": Array(payload.keys.sorted().prefix(64))
        ]

        if let line = encodeLine(compact), line.utf8.count <= maxBytes {
            return compact
        }

        compact["payload"] = [
            "truncated": true,
            "reason": "event exceeded max encoded byte limit",
            "max_bytes": maxBytes
        ]
        return compact
    }

    private static func truncatedString(_ value: String, maxUTF8Bytes: Int) -> String {
        guard value.utf8.count > maxUTF8Bytes else { return value }
        let suffix = "..."
        let budget = max(0, maxUTF8Bytes - suffix.utf8.count)
        var result = ""
        var used = 0
        for scalar in value.unicodeScalars {
            let scalarText = String(scalar)
            let scalarBytes = scalarText.utf8.count
            guard used + scalarBytes <= budget else { break }
            result.append(scalarText)
            used += scalarBytes
        }
        return result + suffix
    }

    static func isoTimestamp(_ date: Date) -> String { isoFormatterLock.lock(); defer { isoFormatterLock.unlock() }; return isoFormatter.string(from: date) }
}
