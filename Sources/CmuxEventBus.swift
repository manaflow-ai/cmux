import Foundation

struct CmuxEventSubscriptionSnapshot {
    let subscription: CmuxEventSubscription
    let replay: [[String: Any]]
    let ack: [String: Any]
}

final class CmuxEventSubscription: @unchecked Sendable {
    let id: UUID
    let names: Set<String>
    let categories: Set<String>

    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var queue: [[String: Any]] = []
    private var closed = false

    init(id: UUID = UUID(), names: Set<String>, categories: Set<String>) {
        self.id = id
        self.names = names
        self.categories = categories
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

    func enqueue(_ event: [String: Any]) {
        lock.lock()
        let shouldSignal: Bool
        if closed {
            shouldSignal = false
        } else {
            queue.append(event)
            shouldSignal = true
        }
        lock.unlock()
        if shouldSignal {
            semaphore.signal()
        }
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

    func close() {
        lock.lock()
        closed = true
        queue.removeAll()
        lock.unlock()
        semaphore.signal()
    }
}

final class CmuxEventBus: @unchecked Sendable {
    static let shared = CmuxEventBus(eventLogURL: defaultEventLogURL())

    static let protocolName = "cmux-events"
    static let protocolVersion = 1
    static let defaultHeartbeatIntervalSeconds: TimeInterval = 15
    static let defaultRetainedEventLimit = 4_096

    private let lock = NSLock()
    private let retainedEventLimit: Int
    private let eventLogURL: URL?
    private let bootId = UUID().uuidString
    private var nextSequence: Int64 = 1
    private var retained: [[String: Any]] = []
    private var subscriptions: [UUID: CmuxEventSubscription] = [:]

    init(retainedEventLimit: Int = CmuxEventBus.defaultRetainedEventLimit, eventLogURL: URL? = nil) {
        self.retainedEventLimit = max(1, retainedEventLimit)
        self.eventLogURL = eventLogURL
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

        event = Self.sanitizedJSONValue(event) as? [String: Any] ?? event
        retained.append(event)
        if retained.count > retainedEventLimit {
            retained.removeFirst(retained.count - retainedEventLimit)
        }
        if let line = Self.encodeLine(event) {
            appendEventLogLine(line)
        }
        let liveSubscriptions = Array(subscriptions.values)
        lock.unlock()

        for subscription in liveSubscriptions where subscription.accepts(event) {
            subscription.enqueue(event)
        }
    }

    func subscribe(
        afterSequence: Int64?,
        names: Set<String>,
        categories: Set<String>
    ) -> CmuxEventSubscriptionSnapshot {
        let subscription = CmuxEventSubscription(names: names, categories: categories)

        lock.lock()
        let oldestSequence = (retained.first?["seq"] as? NSNumber)?.int64Value
            ?? (retained.first?["seq"] as? Int64)
            ?? nextSequence
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

    func resetForTesting() {
        lock.lock()
        nextSequence = 1
        retained.removeAll()
        let active = Array(subscriptions.values)
        subscriptions.removeAll()
        lock.unlock()
        active.forEach { $0.close() }
    }

    private func appendEventLogLine(_ line: String) {
        guard let eventLogURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: eventLogURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: eventLogURL.path) {
                _ = FileManager.default.createFile(atPath: eventLogURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: eventLogURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            NSLog("Failed to append cmux event log: \(error)")
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
        if let number = value as? NSNumber { return number.int64Value }
        if let int = value as? Int { return Int64(int) }
        if let int64 = value as? Int64 { return int64 }
        if let double = value as? Double { return Int64(double) }
        if let string = value as? String { return Int64(string) }
        return nil
    }

    static func sanitizedJSONValue(_ value: Any) -> Any {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let child = mirror.children.first else { return NSNull() }
            return sanitizedJSONValue(child.value)
        }

        switch value {
        case let value as NSNull:
            return value
        case let value as UUID:
            return value.uuidString
        case let value as Date:
            return isoTimestamp(value)
        case let value as String:
            return value
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
            return value.reduce(into: [String: Any]()) { result, pair in
                result[pair.key] = sanitizedJSONValue(pair.value)
            }
        case let value as [Any]:
            return value.map { sanitizedJSONValue($0) }
        default:
            return String(describing: value)
        }
    }

    private static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
