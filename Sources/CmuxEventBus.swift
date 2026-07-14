import Foundation

struct CmuxBoundedRingBuffer<Element> {
    private var storage: [Element?]
    private(set) var count = 0
    private var head = 0

    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.storage = Array(repeating: nil, count: self.capacity)
    }

    var isEmpty: Bool { count == 0 }

    var first: Element? {
        guard count > 0 else { return nil }
        return storage[head]
    }

    var elements: [Element] {
        guard count > 0 else { return [] }
        return (0..<count).compactMap { storage[(head + $0) % capacity] }
    }

    @discardableResult
    mutating func appendDroppingOldest(_ element: Element) -> Bool {
        if count < capacity {
            storage[(head + count) % capacity] = element
            count += 1
            return false
        }

        storage[head] = element
        head = (head + 1) % capacity
        return true
    }

    mutating func removeFirst() -> Element? {
        guard count > 0 else { return nil }
        let element = storage[head]
        storage[head] = nil
        head = (head + 1) % capacity
        count -= 1
        if count == 0 { head = 0 }
        return element
    }

    mutating func removeAll() {
        for offset in 0..<count {
            storage[(head + offset) % capacity] = nil
        }
        count = 0
        head = 0
    }
}

// Sendable safety: the sanitized JSON graph and encoded bytes are immutable after initialization.
final class CmuxEventFrame: @unchecked Sendable {
    let object: [String: Any]
    let wireData: Data
    let sequence: Int64
    let name: String
    let category: String

    init(
        object: [String: Any],
        encodedLine: String,
        sequence: Int64,
        name: String,
        category: String
    ) {
        self.object = object
        var wireData = Data(encodedLine.utf8)
        wireData.append(0x0A)
        self.wireData = wireData
        self.sequence = sequence
        self.name = name
        self.category = category
    }

    /// Debug/test view of the cached wire bytes without retaining a second copy.
    var encodedLine: String {
        String(decoding: wireData.dropLast(), as: UTF8.self)
    }
}

struct CmuxEventSubscriptionSnapshot {
    let subscription: CmuxEventSubscription
    let replay: [[String: Any]]
    let replayFrames: [CmuxEventFrame]
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
    private var queue: CmuxBoundedRingBuffer<CmuxEventFrame>
    private var closed = false
    private var closedReason: String?

    init(id: UUID = UUID(), names: Set<String>, categories: Set<String>, maxPendingEvents: Int) {
        self.id = id
        self.names = names
        self.categories = categories
        self.maxPendingEvents = max(1, maxPendingEvents)
        self.queue = CmuxBoundedRingBuffer(capacity: self.maxPendingEvents)
    }

    func accepts(_ frame: CmuxEventFrame) -> Bool {
        if !names.isEmpty {
            guard names.contains(frame.name) else { return false }
        }
        if !categories.isEmpty {
            guard categories.contains(frame.category) else { return false }
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

    func enqueue(_ frame: CmuxEventFrame) -> Bool {
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
            queue.appendDroppingOldest(frame)
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
        nextFrame(timeout: timeout)?.object
    }

    func nextFrame(timeout: TimeInterval) -> CmuxEventFrame? {
        lock.lock()
        if !queue.isEmpty {
            let frame = queue.removeFirst()
            lock.unlock()
            return frame
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
    private let sanitize: (Any) -> Any
    private let encodeSanitizedLine: ([String: Any]) -> String?
    private let bootId = UUID().uuidString
    private var nextSequence: Int64 = 1
    private var retained: CmuxBoundedRingBuffer<CmuxEventFrame>
    private var subscriptions: [UUID: CmuxEventSubscription] = [:]

    init(
        retainedEventLimit: Int = CmuxEventBus.defaultRetainedEventLimit,
        eventLogURL: URL? = nil,
        maxEventLogBytes: UInt64 = CmuxEventBus.defaultMaxEventLogBytes,
        maxEventLineBytes: Int = CmuxEventBus.defaultMaxEventLineBytes,
        maxPendingEventLogLines: Int = CmuxEventBus.defaultMaxPendingEventLogLines,
        maxPendingEventsPerSubscription: Int = CmuxEventBus.defaultMaxPendingEventsPerSubscription,
        sanitize: @escaping (Any) -> Any = CmuxEventBus.sanitizedJSONValue,
        encodeSanitizedLine: @escaping ([String: Any]) -> String? = CmuxEventBus.encodeSanitizedLine
    ) {
        self.retainedEventLimit = max(1, retainedEventLimit)
        self.maxEventLineBytes = max(1, maxEventLineBytes)
        self.maxPendingEventsPerSubscription = max(1, maxPendingEventsPerSubscription)
        self.sanitize = sanitize
        self.encodeSanitizedLine = encodeSanitizedLine
        self.retained = CmuxBoundedRingBuffer(capacity: self.retainedEventLimit)
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

        lock.lock()
        defer { lock.unlock() }
        let sequence = nextSequence

        let unsanitizedEvent: [String: Any] = [
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
            "payload": payload
        ]
        guard let event = sanitize(unsanitizedEvent) as? [String: Any],
              let frame = makeFrame(event: event, sequence: sequence) else { return }

        nextSequence += 1
        retained.appendDroppingOldest(frame)
        eventLogWriter?.enqueue(frame.wireData)

        var closedSubscriptionIds: [UUID] = []
        for (id, subscription) in subscriptions where subscription.accepts(frame) {
            if !subscription.enqueue(frame) {
                closedSubscriptionIds.append(id)
            }
        }
        for id in closedSubscriptionIds {
            subscriptions.removeValue(forKey: id)
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
        let retainedFrames = retained.elements
        let oldestSequence = retained.first?.sequence ?? nextSequence
        let latestSequence = nextSequence - 1
        let replayFrames = retainedFrames.filter { frame in
            let after = afterSequence ?? latestSequence
            return frame.sequence > after && subscription.accepts(frame)
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
            "replay_count": replayFrames.count,
            "resume": resume,
            "filters": [
                "names": Array(names).sorted(),
                "categories": Array(categories).sorted()
            ]
        ]

        return CmuxEventSubscriptionSnapshot(
            subscription: subscription,
            replay: replayFrames.map(\.object),
            replayFrames: replayFrames,
            ack: ack
        )
    }

    func unsubscribe(_ subscription: CmuxEventSubscription) {
        lock.lock()
        subscriptions.removeValue(forKey: subscription.id)
        lock.unlock()
        subscription.close()
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
        return retained.elements.map(\.object)
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
        guard let cleanObject = clean as? [String: Any] else { return nil }
        return encodeSanitizedLine(cleanObject)
    }

    static func encodeSanitizedLine(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
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

    private func makeFrame(
        event: [String: Any],
        sequence: Int64
    ) -> CmuxEventFrame? {
        guard let encodedLine = encodeSanitizedLine(event) else { return nil }
        guard encodedLine.utf8.count > maxEventLineBytes else {
            return makeFrame(object: event, encodedLine: encodedLine, sequence: sequence)
        }

        var compact = event
        let payload = event["payload"] as? [String: Any] ?? [:]
        compact["payload_truncated"] = true
        compact["payload"] = [
            "truncated": true,
            "reason": "event exceeded max encoded byte limit",
            "max_bytes": maxEventLineBytes,
            "original_payload_keys": Array(payload.keys.sorted().prefix(64))
        ]

        if let line = encodeSanitizedLine(compact), line.utf8.count <= maxEventLineBytes {
            return makeFrame(object: compact, encodedLine: line, sequence: sequence)
        }

        compact["payload"] = [
            "truncated": true,
            "reason": "event exceeded max encoded byte limit",
            "max_bytes": maxEventLineBytes
        ]
        for stringBudget in Self.topLevelMetadataBudgets(maxEventLineBytes: maxEventLineBytes) {
            var bounded = compact
            for key in Self.userControlledTopLevelStringKeys {
                if let value = bounded[key] as? String {
                    bounded[key] = Self.truncatedString(value, maxUTF8Bytes: stringBudget)
                }
            }
            guard let line = encodeSanitizedLine(bounded) else { continue }
            if line.utf8.count <= maxEventLineBytes {
                return makeFrame(object: bounded, encodedLine: line, sequence: sequence)
            }
        }

        return nil
    }

    private func makeFrame(
        object: [String: Any],
        encodedLine: String,
        sequence: Int64
    ) -> CmuxEventFrame {
        let name = object["name"] as? String ?? ""
        let category = object["category"] as? String ?? ""
        return CmuxEventFrame(
            object: object,
            encodedLine: encodedLine,
            sequence: sequence,
            name: name,
            category: category
        )
    }

    private static let userControlledTopLevelStringKeys = [
        "name",
        "category",
        "source",
        "workspace_id",
        "surface_id",
        "pane_id",
        "window_id"
    ]

    private static func topLevelMetadataBudgets(maxEventLineBytes: Int) -> [Int] {
        let proportionalBudget = max(3, min(256, maxEventLineBytes / 16))
        return [proportionalBudget, 128, 64, 32, 16, 8, 3]
            .filter { $0 <= proportionalBudget }
            .reduce(into: []) { budgets, budget in
                if budgets.last != budget { budgets.append(budget) }
            }
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
