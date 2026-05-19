import Foundation

struct CmuxEventSubscriptionSnapshot {
    let subscription: CmuxEventSubscription
    let replay: [[String: Any]]
    let ack: [String: Any]
}

final class CmuxEventWindowWorkspaceIndex: @unchecked Sendable {
    static let shared = CmuxEventWindowWorkspaceIndex()

    private let lock = NSLock()
    private var workspaceIdsByWindowId: [String: Set<String>] = [:]

    func replace(windowId: UUID?, workspaceIds: [UUID]) {
        replace(
            windowId: windowId?.uuidString,
            workspaceIds: Set(workspaceIds.map(\.uuidString))
        )
    }

    func replace(windowId: String?, workspaceIds: Set<String>) {
        guard let windowId = Self.normalizedId(windowId) else { return }
        lock.lock()
        workspaceIdsByWindowId[windowId] = Set(workspaceIds.compactMap(Self.normalizedId))
        lock.unlock()
    }

    func workspaceIds(windowId: String) -> Set<String> {
        guard let windowId = Self.normalizedId(windowId) else { return [] }
        lock.lock()
        defer { lock.unlock() }
        return workspaceIdsByWindowId[windowId] ?? []
    }

    private static func normalizedId(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        if let uuid = UUID(uuidString: trimmed) {
            return uuid.uuidString
        }
        return trimmed
    }
}

struct CmuxEventScope {
    enum Kind: String {
        case global
        case window
        case workspace
        case surface
        case pane
    }

    let kind: Kind
    let windowId: String?
    let workspaceId: String?
    let surfaceId: String?
    let paneId: String?
    let windowWorkspaceIds: Set<String>
    private let currentWindowWorkspaceIdsProvider: (() -> Set<String>)?

    static let global = CmuxEventScope(kind: .global)

    init(
        kind: Kind,
        windowId: String? = nil,
        workspaceId: String? = nil,
        surfaceId: String? = nil,
        paneId: String? = nil,
        windowWorkspaceIds: Set<String> = [],
        currentWindowWorkspaceIdsProvider: (() -> Set<String>)? = nil
    ) {
        self.kind = kind
        self.windowId = Self.normalizedId(windowId)
        self.workspaceId = Self.normalizedId(workspaceId)
        self.surfaceId = Self.normalizedId(surfaceId)
        self.paneId = Self.normalizedId(paneId)
        self.windowWorkspaceIds = Set(windowWorkspaceIds.compactMap(Self.normalizedId))
        self.currentWindowWorkspaceIdsProvider = currentWindowWorkspaceIdsProvider
    }

    func accepts(_ event: [String: Any], allowDynamicWindowWorkspaceIds: Bool = true) -> Bool {
        switch kind {
        case .global:
            return true
        case .window:
            guard let windowId else { return false }
            let explicitWindowIds = Self.windowIds(event)
            if !explicitWindowIds.isEmpty {
                return explicitWindowIds.contains(windowId)
            }
            let eventWorkspaceIds = Self.workspaceIds(event)
            let scopedWorkspaceIds: Set<String>
            if allowDynamicWindowWorkspaceIds, let currentWindowWorkspaceIdsProvider {
                scopedWorkspaceIds = Set(currentWindowWorkspaceIdsProvider().compactMap(Self.normalizedId))
            } else {
                scopedWorkspaceIds = windowWorkspaceIds
            }
            return eventWorkspaceIds.contains(where: { scopedWorkspaceIds.contains($0) })
        case .workspace:
            guard let workspaceId else { return false }
            return Self.stringValue(event["workspace_id"]) == workspaceId ||
                Self.payloadContains(event, key: "workspace_id", id: workspaceId) ||
                Self.payloadContains(event, key: "previous_workspace_id", id: workspaceId) ||
                Self.payloadContains(event, key: "source_workspace_id", id: workspaceId) ||
                Self.payloadContains(event, key: "target_workspace_id", id: workspaceId) ||
                Self.payloadContains(event, key: "destination_workspace_id", id: workspaceId) ||
                Self.payloadContains(event, key: "created_workspace_id", id: workspaceId)
        case .surface:
            guard let surfaceId else { return false }
            return Self.stringValue(event["surface_id"]) == surfaceId ||
                Self.payloadContains(event, key: "surface_id", id: surfaceId) ||
                Self.payloadContains(event, key: "tab_id", id: surfaceId) ||
                Self.payloadContains(event, key: "selected_surface_id", id: surfaceId) ||
                Self.payloadContains(event, key: "previous_surface_id", id: surfaceId) ||
                Self.payloadContains(event, key: "source_surface_id", id: surfaceId) ||
                Self.payloadContains(event, key: "target_surface_id", id: surfaceId) ||
                Self.payloadContains(event, key: "created_surface_id", id: surfaceId) ||
                Self.payloadContains(event, key: "created_tab_id", id: surfaceId) ||
                Self.payloadStringArray(event, key: "closed_surface_ids").contains(surfaceId)
        case .pane:
            guard let paneId else { return false }
            return Self.stringValue(event["pane_id"]) == paneId ||
                Self.payloadContains(event, key: "pane_id", id: paneId) ||
                Self.payloadContains(event, key: "source_pane_id", id: paneId) ||
                Self.payloadContains(event, key: "target_pane_id", id: paneId)
        }
    }

    var ackPayload: [String: Any] {
        var payload: [String: Any] = ["kind": kind.rawValue]
        if let windowId { payload["window_id"] = windowId }
        if let workspaceId { payload["workspace_id"] = workspaceId }
        if let surfaceId { payload["surface_id"] = surfaceId }
        if let paneId { payload["pane_id"] = paneId }
        if kind == .window {
            payload["workspace_ids"] = Array(windowWorkspaceIds).sorted()
        }
        return payload
    }

    private static func normalizedId(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        if let uuid = UUID(uuidString: trimmed) {
            return uuid.uuidString
        }
        return trimmed
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return normalizedId(string)
        }
        return nil
    }

    private static func payloadContains(_ event: [String: Any], key: String, id: String) -> Bool {
        payloadStrings(event, key: key).contains(id)
    }

    private static func payloadStrings(_ event: [String: Any], key: String) -> [String] {
        guard let payload = event["payload"] as? [String: Any] else { return [] }
        let containers: [[String: Any]] = [payload] + ["result", "params"].compactMap {
            payload[$0] as? [String: Any]
        }
        var result: [String] = []
        for container in containers {
            if let value = stringValue(container[key]) {
                result.append(value)
            }
        }
        return result
    }

    private static func payloadStringArray(_ event: [String: Any], key: String) -> [String] {
        guard let payload = event["payload"] as? [String: Any] else { return [] }
        let containers: [[String: Any]] = [payload] + ["result", "params"].compactMap {
            payload[$0] as? [String: Any]
        }
        var result: [String] = []
        for container in containers {
            if let values = container[key] as? [String] {
                result.append(contentsOf: values.compactMap(normalizedId))
            } else if let values = container[key] as? [Any] {
                result.append(contentsOf: values.compactMap { stringValue($0) })
            }
        }
        return result
    }

    private static func workspaceIds(_ event: [String: Any]) -> [String] {
        var ids: [String] = []
        if let workspaceId = stringValue(event["workspace_id"]) {
            ids.append(workspaceId)
        }
        for key in ["workspace_id", "previous_workspace_id", "source_workspace_id", "target_workspace_id", "destination_workspace_id", "created_workspace_id"] {
            ids.append(contentsOf: payloadStrings(event, key: key))
        }
        return ids
    }

    private static func windowIds(_ event: [String: Any]) -> Set<String> {
        var ids: Set<String> = []
        if let windowId = stringValue(event["window_id"]) {
            ids.insert(windowId)
        }
        for key in ["window_id", "source_window_id", "destination_window_id", "target_window_id", "previous_window_id"] {
            ids.formUnion(payloadStrings(event, key: key))
        }
        return ids
    }
}

// Sendable safety: every mutable field is protected by `lock`; `semaphore` only wakes `next(timeout:)`.
final class CmuxEventSubscription: @unchecked Sendable {
    let id: UUID
    let names: Set<String>
    let categories: Set<String>
    let scope: CmuxEventScope
    let maxPendingEvents: Int

    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var queue: [[String: Any]] = []
    private var closed = false
    private var closedReason: String?

    init(
        id: UUID = UUID(),
        names: Set<String>,
        categories: Set<String>,
        scope: CmuxEventScope,
        maxPendingEvents: Int
    ) {
        self.id = id
        self.names = names
        self.categories = categories
        self.scope = scope
        self.maxPendingEvents = max(1, maxPendingEvents)
    }

    func accepts(_ event: [String: Any], allowDynamicWindowWorkspaceIds: Bool = true) -> Bool {
        if !names.isEmpty {
            guard let name = event["name"] as? String, names.contains(name) else { return false }
        }
        if !categories.isEmpty {
            guard let category = event["category"] as? String, categories.contains(category) else { return false }
        }
        return scope.accepts(event, allowDynamicWindowWorkspaceIds: allowDynamicWindowWorkspaceIds)
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
        categories: Set<String>,
        scope: CmuxEventScope = .global
    ) -> CmuxEventSubscriptionSnapshot {
        let subscription = CmuxEventSubscription(
            names: names,
            categories: categories,
            scope: scope,
            maxPendingEvents: maxPendingEventsPerSubscription
        )

        lock.lock()
        let oldestSequence = Self.int64(retained.first?["seq"]) ?? nextSequence
        let latestSequence = nextSequence - 1
        let replay = retained.filter { event in
            let seq = Self.int64(event["seq"]) ?? 0
            let after = afterSequence ?? latestSequence
            return seq > after && subscription.accepts(event, allowDynamicWindowWorkspaceIds: false)
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
                "categories": Array(categories).sorted(),
                "scope": scope.ackPayload
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
