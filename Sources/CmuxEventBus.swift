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
    private var asyncWaiters: [CheckedContinuation<[String: Any]?, Never>] = []
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
        let waiter: CheckedContinuation<[String: Any]?, Never>?
        if closed {
            shouldSignal = false
            accepted = false
            waiter = nil
        } else if let nextWaiter = asyncWaiters.first {
            asyncWaiters.removeFirst()
            shouldSignal = false
            accepted = true
            waiter = nextWaiter
        } else if queue.count >= maxPendingEvents {
            closed = true
            closedReason = "pending event buffer exceeded \(maxPendingEvents) events"
            queue.removeAll()
            shouldSignal = true
            accepted = false
            waiter = nil
        } else {
            queue.append(event)
            shouldSignal = true
            accepted = true
            waiter = nil
        }
        lock.unlock()
        if let waiter {
            waiter.resume(returning: event)
        } else if shouldSignal {
            semaphore.signal()
        }
        return accepted
    }

    /// Awaits the next event without tying up a thread in a semaphore wait.
    /// Cancellation closes the subscription so the waiter is always resumed.
    func nextAsync() async -> [String: Any]? {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                lock.lock()
                if !queue.isEmpty {
                    let event = queue.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: event)
                } else if closed {
                    lock.unlock()
                    continuation.resume(returning: nil)
                } else {
                    asyncWaiters.append(continuation)
                    lock.unlock()
                }
            }
        }, onCancel: {
            close(reason: "consumer cancelled")
        })
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
        let waiters = asyncWaiters
        asyncWaiters.removeAll(keepingCapacity: true)
        lock.unlock()
        semaphore.signal()
        waiters.forEach { $0.resume(returning: nil) }
    }
}

// Sendable safety: event state is protected by `lock`; disk appends are delegated to `CmuxEventLogWriter`.
final class CmuxEventBus: @unchecked Sendable {
    private struct PendingPublish {
        let name: String
        let category: String
        let source: String
        let occurredAt: String
        let workspaceId: String?
        let surfaceId: String?
        let paneId: String?
        let windowId: String?
        let payload: Any
        let automationOrigin: Any?
    }

    private struct PendingSubscription {
        let subscription: CmuxEventSubscription
        let afterSequence: Int64?
        let liveOnly: Bool
    }

    private struct EventPublication {
        let event: [String: Any]
        let encodedLine: String?
        let subscriptions: [CmuxEventSubscription]
    }

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
    private var restorePending: Bool
    private var restoreGap = false
    private var restoreTask: Task<Void, Never>?
    private var nextSequence: Int64 = 1
    private var retained: [[String: Any]] = []
    private var subscriptions: [UUID: CmuxEventSubscription] = [:]
    private var pendingPublishes: [PendingPublish] = []
    private var pendingSubscriptions: [UUID: PendingSubscription] = [:]

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
        self.restorePending = eventLogURL != nil
        self.restoreTask = nil
        self.eventLogWriter = eventLogURL.map {
            CmuxEventLogWriter(
                eventLogURL: $0,
                maxEventLogBytes: maxEventLogBytes,
                maxPendingLines: maxPendingEventLogLines
            )
        }

        if let eventLogURL {
            self.restoreTask = Task.detached(priority: .utility) { [weak self] in
                let restored = Self.loadPersistedEvents(
                    eventLogURL: eventLogURL,
                    maxEventLogBytes: maxEventLogBytes,
                    retainedEventLimit: retainedEventLimit
                )
                self?.completeRestore(restored)
            }
        }
    }

    deinit {
        restoreTask?.cancel()
    }

    /// Waits for the initial durable event restore, if one was scheduled.
    func waitUntilRestored() async {
        await restoreTask?.value
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
        let pending = PendingPublish(
            name: name,
            category: category,
            source: source,
            occurredAt: occurredAt,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            paneId: paneId,
            windowId: windowId,
            payload: cleanPayload,
            automationOrigin: CmuxAutomationInvocationContext.eventOrigin?.foundationObject
        )

        lock.lock()
        if restorePending {
            pendingPublishes.append(pending)
            lock.unlock()
            return
        }
        lock.unlock()

        publish(pending)
    }

    private func publish(_ pending: PendingPublish) {
        lock.lock()
        let publication = appendEventLocked(pending)
        lock.unlock()
        deliver(publication)
    }

    /// The caller must hold ``lock`` while appending the event.
    private func appendEventLocked(_ pending: PendingPublish) -> EventPublication {
        let sequence = nextSequence
        nextSequence += 1

        var event: [String: Any] = [
            "type": "event",
            "protocol": Self.protocolName,
            "version": Self.protocolVersion,
            "boot_id": bootId,
            "seq": sequence,
            "id": "\(bootId)-\(sequence)",
            "name": pending.name,
            "category": pending.category,
            "source": pending.source,
            "occurred_at": pending.occurredAt,
            "workspace_id": pending.workspaceId ?? NSNull(),
            "surface_id": pending.surfaceId ?? NSNull(),
            "pane_id": pending.paneId ?? NSNull(),
            "window_id": pending.windowId ?? NSNull(),
            "payload": pending.payload
        ]
        if let automationOrigin = pending.automationOrigin {
            event["automation_origin"] = automationOrigin
        }

        event = Self.eventByApplyingEncodedByteLimit(event, maxBytes: maxEventLineBytes)
        retained.append(event)
        if retained.count > retainedEventLimit {
            retained.removeFirst(retained.count - retainedEventLimit)
        }
        let encodedLine = Self.encodeLine(event)
        let liveSubscriptions = Array(subscriptions.values)
        return EventPublication(event: event, encodedLine: encodedLine, subscriptions: liveSubscriptions)
    }

    private func deliver(_ publication: EventPublication) {
        if let encodedLine = publication.encodedLine { eventLogWriter?.enqueue(encodedLine) }

        for subscription in publication.subscriptions where subscription.accepts(publication.event) {
            if !subscription.enqueue(publication.event) {
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
        if restorePending {
            subscriptions[subscription.id] = subscription
            pendingSubscriptions[subscription.id] = PendingSubscription(
                subscription: subscription,
                afterSequence: afterSequence,
                liveOnly: afterSequence == nil
            )
            let latestSequence = nextSequence - 1
            lock.unlock()

            let resume: [String: Any] = [
                "after_seq": afterSequence.map { NSNumber(value: $0) } ?? NSNull(),
                "requested_after_seq": NSNumber(value: afterSequence ?? latestSequence),
                "oldest_seq": NSNumber(value: latestSequence + 1),
                "latest_seq": NSNumber(value: latestSequence),
                "next_seq": NSNumber(value: latestSequence + 1),
                "gap": true,
                "gap_reason": "durable event restore is still in progress",
                "restore_pending": true,
                "restore_gap": false
            ]
            let ack: [String: Any] = [
                "type": "ack",
                "protocol": Self.protocolName,
                "version": Self.protocolVersion,
                "boot_id": bootId,
                "subscription_id": subscription.id.uuidString,
                "heartbeat_interval_seconds": NSNumber(value: Self.defaultHeartbeatIntervalSeconds),
                "replay_count": 0,
                "resume": resume,
                "filters": [
                    "names": Array(names).sorted(),
                    "categories": Array(categories).sorted()
                ]
            ]
            return CmuxEventSubscriptionSnapshot(subscription: subscription, replay: [], ack: ack)
        }
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
        let hasRestoreGap = restoreGap
        subscriptions[subscription.id] = subscription
        lock.unlock()

        var resume: [String: Any] = [
            "after_seq": afterSequence.map { NSNumber(value: $0) } ?? NSNull(),
            "requested_after_seq": NSNumber(value: requestedAfter),
            "oldest_seq": NSNumber(value: oldestSequence),
            "latest_seq": NSNumber(value: latestSequence),
            "next_seq": NSNumber(value: latestSequence + 1),
            "gap": gap || (hasRestoreGap && afterSequence != nil),
            "restore_gap": hasRestoreGap
        ]
        if let gapReason {
            resume["gap_reason"] = gapReason
        } else if hasRestoreGap, afterSequence != nil {
            resume["gap_reason"] = "durable event log contains unreadable records"
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

    private func completeRestore(
        _ restored: (events: [[String: Any]], nextSequence: Int64, gap: Bool)
    ) {
        lock.lock()
        guard restorePending else {
            lock.unlock()
            return
        }
        retained = restored.events
        nextSequence = restored.nextSequence
        restoreGap = restored.gap
        lock.unlock()

        while true {
            lock.lock()
            let subscriptionsToReplay = Array(pendingSubscriptions.values)
            pendingSubscriptions.removeAll()
            let publishesToFlush = pendingPublishes
            pendingPublishes.removeAll()
            let publicationsToFlush = publishesToFlush.map { appendEventLocked($0) }
            if subscriptionsToReplay.isEmpty, publicationsToFlush.isEmpty {
                restorePending = false
                lock.unlock()
                break
            }
            lock.unlock()

            for pending in subscriptionsToReplay {
                let afterSequence = pending.liveOnly
                    ? restored.nextSequence - 1
                    : (pending.afterSequence ?? restored.nextSequence - 1)
                let replay = restored.events.filter { event in
                    let sequence = Self.int64(event["seq"]) ?? 0
                    return sequence > afterSequence && pending.subscription.accepts(event)
                }
                for event in replay where !pending.subscription.enqueue(event) {
                    removeSubscriptionIfStillActive(pending.subscription)
                    break
                }
            }

            for publication in publicationsToFlush {
                deliver(publication)
            }
        }
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
        restoreTask?.cancel()
        lock.lock()
        restorePending = false
        restoreGap = false
        nextSequence = 1
        retained.removeAll()
        let active = Array(subscriptions.values)
        subscriptions.removeAll()
        pendingPublishes.removeAll()
        pendingSubscriptions.removeAll()
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

    /// Restores the most recent event window from the append-only log.
    ///
    /// The original stream used a per-process sequence counter. When an old
    /// segment starts again at one, rebase that segment onto the last restored
    /// sequence so a cursor can continue across a restart. Keep the original
    /// sequence for diagnostics without changing the event's stable id.
    private static func loadPersistedEvents(
        eventLogURL: URL,
        maxEventLogBytes: UInt64,
        retainedEventLimit: Int
    ) -> (events: [[String: Any]], nextSequence: Int64, gap: Bool) {
        let rotatedURL = eventLogURL.appendingPathExtension("1")
        var loaded: [[String: Any]] = []
        var gap = false

        for url in [rotatedURL, eventLogURL] {
            guard FileManager.default.fileExists(atPath: url.path) else {
                continue
            }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber,
                  size.uint64Value <= maxEventLogBytes,
                  let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                gap = true
                continue
            }

            for line in text.split(whereSeparator: \.isNewline) {
                guard let lineData = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      object["type"] as? String == "event",
                      let sequence = int64(object["seq"]),
                      sequence > 0 else {
                    gap = true
                    continue
                }
                loaded.append(object)
            }
        }

        var highestSequence: Int64 = 0
        for index in loaded.indices {
            guard let originalSequence = int64(loaded[index]["seq"]) else { continue }
            let normalizedSequence = originalSequence > highestSequence
                ? originalSequence
                : highestSequence + 1
            if normalizedSequence != originalSequence {
                loaded[index]["legacy_seq"] = NSNumber(value: originalSequence)
                loaded[index]["seq"] = NSNumber(value: normalizedSequence)
            }
            highestSequence = normalizedSequence
        }

        return (
            Array(loaded.suffix(max(1, retainedEventLimit))),
            highestSequence + 1,
            gap
        )
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
