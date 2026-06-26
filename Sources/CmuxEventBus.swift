import Foundation

struct CmuxEventSubscriptionSnapshot {
    let subscription: CmuxEventSubscription
    let replay: [[String: Any]]
    let ack: [String: Any]
}

// Sendable safety: every mutable field is protected by `lock`; `semaphore` only wakes `next(timeout:)`.
final class CmuxEventSubscription: @unchecked Sendable {
    let id: UUID
    let names: Set<String>
    let categories: Set<String>
    let maxPendingEvents: Int

    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var queue: [[String: Any]] = []
    private var closed = false
    private var closedReason: String?

    init(id: UUID = UUID(), names: Set<String>, categories: Set<String>, maxPendingEvents: Int) {
        self.id = id
        self.names = names
        self.categories = categories
        self.maxPendingEvents = max(1, maxPendingEvents)
    }

    func accepts(_ event: [String: Any]) -> Bool {
        if !names.isEmpty {
            guard let name = event["name"] as? String, names.contains(name) else { return false }
        }
        if !categories.isEmpty {
            guard let category = event["category"] as? String, categories.contains(category) else { return false }
        }
        return true
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    var closeReason: String? {
        lock.lock()
        defer { lock.unlock() }
        return closedReason
    }

    func enqueue(_ event: [String: Any]) -> Bool {
        lock.lock()
        let shouldSignal: Bool
        let accepted: Bool
        if closed {
            shouldSignal = false
            accepted = false
        } else if queue.count >= maxPendingEvents {
            closed = true
            closedReason = "pending event buffer exceeded \(maxPendingEvents) events"
            queue.removeAll()
            shouldSignal = true
            accepted = false
        } else {
            queue.append(event)
            shouldSignal = true
            accepted = true
        }
        lock.unlock()
        if shouldSignal {
            semaphore.signal()
        }
        return accepted
    }

    func next(timeout: TimeInterval) -> [String: Any]? {
        lock.lock()
        if !queue.isEmpty {
            let event = queue.removeFirst()
            lock.unlock()
            return event
        }
        if closed {
            lock.unlock()
            return nil
        }
        lock.unlock()

        let result = semaphore.wait(timeout: .now() + timeout)
        guard result == .success else { return nil }

        lock.lock()
        defer { lock.unlock() }
        guard !queue.isEmpty else { return nil }
        return queue.removeFirst()
    }

    func close(reason: String? = nil) {
        lock.lock()
        closed = true
        if let reason {
            closedReason = reason
        }
        queue.removeAll()
        lock.unlock()
        semaphore.signal()
    }
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
    static let maxSanitizedStringBytes = 8 * 1024
    static let maxSanitizedArrayItems = 256
    static let maxSanitizedObjectEntries = 256
    static let maxSanitizedDepth = 12
    private static let isoFormatter: ISO8601DateFormatter = { let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter }()
    private static let isoFormatterLock = NSLock()

    private let lock = NSLock()
    private let retainedEventLimit: Int
    private let maxEventLineBytes: Int
    private let maxPendingEventsPerSubscription: Int
    private let eventLogWriter: CmuxEventLogWriter?
    private let bootId = UUID().uuidString
    private var nextSequence: Int64 = 1
    private var retained: [[String: Any]] = []
    private var subscriptions: [UUID: CmuxEventSubscription] = [:]

    init(
        retainedEventLimit: Int = CmuxEventBus.defaultRetainedEventLimit,
        eventLogURL: URL? = nil,
        maxEventLogBytes: UInt64 = CmuxEventBus.defaultMaxEventLogBytes,
        maxEventLineBytes: Int = CmuxEventBus.defaultMaxEventLineBytes,
        maxPendingEventLogLines: Int = CmuxEventBus.defaultMaxPendingEventLogLines,
        maxPendingEventsPerSubscription: Int = CmuxEventBus.defaultMaxPendingEventsPerSubscription
    ) {
        self.retainedEventLimit = max(1, retainedEventLimit)
        self.maxEventLineBytes = max(1, maxEventLineBytes)
        self.maxPendingEventsPerSubscription = max(1, maxPendingEventsPerSubscription)
        self.eventLogWriter = eventLogURL.map {
            CmuxEventLogWriter(
                eventLogURL: $0,
                maxEventLogBytes: maxEventLogBytes,
                maxPendingLines: maxPendingEventLogLines
            )
        }
    }

    var latestSequence: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return nextSequence - 1
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
        let occurredAt = Self.isoTimestamp(Date())
        let cleanPayload = Self.sanitizedJSONValue(payload)

        lock.lock()
        let sequence = nextSequence
        nextSequence += 1

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
    }

    func subscribe(
        afterSequence: Int64?,
        names: Set<String>,
        categories: Set<String>
    ) -> CmuxEventSubscriptionSnapshot {
        let subscription = CmuxEventSubscription(
            names: names,
            categories: categories,
            maxPendingEvents: maxPendingEventsPerSubscription
        )

        lock.lock()
        let oldestSequence = Self.int64(retained.first?["seq"]) ?? nextSequence
        let latestSequence = nextSequence - 1
        let replay = retained.filter { event in
            let seq = Self.int64(event["seq"]) ?? 0
            let after = afterSequence ?? latestSequence
            return seq > after && subscription.accepts(event)
        }
        let requestedAfter = afterSequence ?? latestSequence
        let gapReason: String? = afterSequence.flatMap { after in
            if !retained.isEmpty, after < oldestSequence - 1 {
                return "requested sequence is older than the retained in-memory event log"
            }
            if after > latestSequence {
                return "requested sequence is newer than this cmux process; cmux probably restarted"
            }
            return nil
        }
        let gap = gapReason != nil
        subscriptions[subscription.id] = subscription
        lock.unlock()

        var resume: [String: Any] = [
            "after_seq": afterSequence.map { NSNumber(value: $0) } ?? NSNull(),
            "requested_after_seq": NSNumber(value: requestedAfter),
            "oldest_seq": NSNumber(value: oldestSequence),
            "latest_seq": NSNumber(value: latestSequence),
            "next_seq": NSNumber(value: latestSequence + 1),
            "gap": gap
        ]
        if let gapReason {
            resume["gap_reason"] = gapReason
        }

        let ack: [String: Any] = [
            "type": "ack",
            "protocol": Self.protocolName,
            "version": Self.protocolVersion,
            "boot_id": bootId,
            "subscription_id": subscription.id.uuidString,
            "heartbeat_interval_seconds": NSNumber(value: Self.defaultHeartbeatIntervalSeconds),
            "replay_count": replay.count,
            "resume": resume,
            "filters": [
                "names": Array(names).sorted(),
                "categories": Array(categories).sorted()
            ]
        ]

        return CmuxEventSubscriptionSnapshot(subscription: subscription, replay: replay, ack: ack)
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
        retained.removeAll()
        let active = Array(subscriptions.values)
        subscriptions.removeAll()
        lock.unlock()
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
