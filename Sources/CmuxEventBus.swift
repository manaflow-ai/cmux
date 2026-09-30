import Foundation
import os
nonisolated private let cmuxEventBusLogger = Logger(subsystem: "com.cmuxterm.app", category: "events")
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
    private var replayQueueCount = 0

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
        } else if queue.count - replayQueueCount >= maxPendingEvents {
            closed = true
            closedReason = "pending event buffer exceeded \(maxPendingEvents) events"
            queue.removeAll()
            replayQueueCount = 0
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

    /// Enqueues the bounded restored window without applying the live-event
    /// backpressure limit. Restored history is finite and must be delivered in
    /// full before a subscription is considered a slow consumer.
    func enqueueReplay(_ event: [String: Any]) -> Bool {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return false
        }
        if let waiter = asyncWaiters.first {
            asyncWaiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: event)
            return true
        }
        queue.append(event)
        replayQueueCount += 1
        lock.unlock()
        semaphore.signal()
        return true
    }

    /// Awaits the next event without tying up a thread in a semaphore wait.
    /// Cancellation closes the subscription so the waiter is always resumed.
    func nextAsync() async -> [String: Any]? {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                lock.lock()
                if !queue.isEmpty {
                    let event = queue.removeFirst()
                    if replayQueueCount > 0 { replayQueueCount -= 1 }
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
            if replayQueueCount > 0 { replayQueueCount -= 1 }
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
        let event = queue.removeFirst()
        if replayQueueCount > 0 { replayQueueCount -= 1 }
        return event
    }

    func close(reason: String? = nil) {
        lock.lock()
        closed = true
        if let reason {
            closedReason = reason
        }
        queue.removeAll()
        replayQueueCount = 0
        let waiters = asyncWaiters
        asyncWaiters.removeAll(keepingCapacity: true)
        lock.unlock()
        semaphore.signal()
        waiters.forEach { $0.resume(returning: nil) }
    }
}

// Sendable safety: event state is protected by `lock`; disk appends are delegated to `CmuxEventLogWriter`.
final class CmuxEventBus: @unchecked Sendable {
    private struct PersistedEventRestore {
        let events: [[String: Any]]
        let allEvents: [[String: Any]]
        let nextSequence: Int64
        let gap: Bool
        let needsRewrite: Bool
    }

    // Sendable safety: payload values are sanitized immutable Foundation values before enqueue.
    private struct PendingPublish: @unchecked Sendable {
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
    private let eventLogURL: URL?
    private let maxEventLogBytes: UInt64
    private let maxEventLineBytes: Int
    private let maxPendingEventsPerSubscription: Int
    private let eventLogWriter: CmuxEventLogWriter?
    private let sequenceStore: CmuxEventSequenceStore?
    // Serializes durable sequence allocation and event publication off caller threads.
    private let publicationQueue: DispatchQueue
    private let bootId = UUID().uuidString
    private var restorePending: Bool
    private var restoreGap = false
    private var restoreTask: Task<Void, Never>?
    private var nextSequence: Int64 = 1
    private var retained: [[String: Any]] = []
    private var subscriptions: [UUID: CmuxEventSubscription] = [:]
    private var pendingPublishes: [PendingPublish] = []
    private var pendingSubscriptions: [UUID: PendingSubscription] = [:]
    private var sequenceAllocationFailureLogged = false

    init(
        retainedEventLimit: Int = CmuxEventBus.defaultRetainedEventLimit,
        eventLogURL: URL? = nil,
        maxEventLogBytes: UInt64 = CmuxEventBus.defaultMaxEventLogBytes,
        maxEventLineBytes: Int = CmuxEventBus.defaultMaxEventLineBytes,
        maxPendingEventLogLines: Int = CmuxEventBus.defaultMaxPendingEventLogLines,
        maxPendingEventsPerSubscription: Int = CmuxEventBus.defaultMaxPendingEventsPerSubscription
    ) {
        self.retainedEventLimit = max(1, retainedEventLimit)
        self.eventLogURL = eventLogURL
        self.maxEventLogBytes = max(1, maxEventLogBytes)
        self.maxEventLineBytes = max(1, maxEventLineBytes)
        self.maxPendingEventsPerSubscription = max(1, maxPendingEventsPerSubscription)
        self.restorePending = eventLogURL != nil
        self.restoreTask = nil
        self.sequenceStore = eventLogURL.map { CmuxEventSequenceStore(eventLogURL: $0) }
        self.publicationQueue = DispatchQueue(
            label: "com.cmuxterm.event-publish.\(UUID().uuidString)",
            qos: .utility
        )
        self.eventLogWriter = eventLogURL.map {
            CmuxEventLogWriter(
                eventLogURL: $0,
                maxEventLogBytes: maxEventLogBytes,
                maxPendingLines: maxPendingEventLogLines
            )
        }

        if let eventLogURL {
            let maxEventLogBytes = self.maxEventLogBytes
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
        guard sequenceStore != nil else {
            publishInMemory(pending)
            return
        }

#if DEBUG
        if restoreTask == nil {
            publishDurableOnPublicationQueue(pending)
            return
        }
#endif
        publicationQueue.async { [weak self] in
            self?.publishDurableOnPublicationQueue(pending)
        }
    }

    private func publishInMemory(_ pending: PendingPublish) {
        lock.lock()
        let sequence = nextSequence
        nextSequence += 1
        let publication = appendEventLocked(pending, sequence: sequence)
        lock.unlock()
        deliver(publication)
    }
    private func publishDurableOnPublicationQueue(_ pending: PendingPublish) {
        guard let sequenceStore,
              let sequence = sequenceStore.allocate() else {
            lock.lock()
            let shouldLog = !sequenceAllocationFailureLogged
            sequenceAllocationFailureLogged = true
            lock.unlock()
            if shouldLog {
                cmuxEventBusLogger.error("Dropped durable event because sequence range reservation failed")
            }
            return
        }

        lock.lock()
        let publication = appendEventLocked(pending, sequence: sequence)
        lock.unlock()
        deliver(publication)
    }
    /// The caller must hold ``lock`` while appending the event.
    private func appendEventLocked(_ pending: PendingPublish, sequence: Int64) -> EventPublication {
        nextSequence = max(nextSequence, sequence + 1)
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
        _ restored: PersistedEventRestore
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

        sequenceStore?.raiseHighWater(to: restored.nextSequence - 1)
        if restored.needsRewrite, let eventLogURL {
            Self.rewritePersistedEvents(
                restored.allEvents,
                eventLogURL: eventLogURL,
                maxEventLogBytes: maxEventLogBytes
            )
        }

        var publishesToEnqueue: [PendingPublish] = []
        while true {
            lock.lock()
            let subscriptionsToReplay = Array(pendingSubscriptions.values)
            pendingSubscriptions.removeAll()
            let publishesToFlush = pendingPublishes
            pendingPublishes.removeAll()
            let replayWindow = retained
            lock.unlock()

            for pending in subscriptionsToReplay {
                let afterSequence = pending.liveOnly
                    ? restored.nextSequence - 1
                    : (pending.afterSequence ?? restored.nextSequence - 1)
                let replay = replayWindow.filter { event in
                    let sequence = Self.int64(event["seq"]) ?? 0
                    return sequence > afterSequence && pending.subscription.accepts(event)
                }
                for event in replay where !pending.subscription.enqueueReplay(event) {
                    removeSubscriptionIfStillActive(pending.subscription)
                    break
                }
            }

            publishesToEnqueue.append(contentsOf: publishesToFlush)

            lock.lock()
            let hasMorePendingWork = !pendingSubscriptions.isEmpty || !pendingPublishes.isEmpty
            if !hasMorePendingWork {
                for pending in publishesToEnqueue {
                    publicationQueue.async { [weak self] in
                        self?.publishDurableOnPublicationQueue(pending)
                    }
                }
                restorePending = false
            }
            lock.unlock()
            if !hasMorePendingWork { break }
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
        restoreTask = nil
        publicationQueue.sync {}
        lock.lock()
        restorePending = false
        restoreGap = false
        nextSequence = 1
        retained.removeAll()
        let active = Array(subscriptions.values)
        subscriptions.removeAll()
        pendingPublishes.removeAll()
        pendingSubscriptions.removeAll()
        sequenceAllocationFailureLogged = false
        lock.unlock()
        active.forEach { $0.close() }
        sequenceStore?.resetForTesting()
        eventLogWriter?.resetForTesting()
    }

    func flushEventLogForTesting() {
        publicationQueue.sync {}
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
    /// segment repeats a sequence, rebase only that duplicate onto the restored
    /// high-water mark. Leased ranges can be written out of order by different
    /// processes, so unique lower sequences must remain intact and are sorted for replay.
    private static func loadPersistedEvents(
        eventLogURL: URL,
        maxEventLogBytes: UInt64,
        retainedEventLimit: Int
    ) -> PersistedEventRestore {
        let rotatedURL = eventLogURL.appendingPathExtension("1")
        var segments: [[[String: Any]]] = []
        var gap = false
        var needsRewrite = false

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

            var segment: [[String: Any]] = []
            for line in text.split(whereSeparator: \.isNewline) {
                guard let lineData = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      object["type"] as? String == "event",
                      let sequence = int64(object["seq"]),
                      sequence > 0 else {
                    gap = true
                    needsRewrite = true
                    continue
                }
                segment.append(object)
            }
            segments.append(segment)
        }

        var loaded = segments.flatMap { $0 }
        let sequenceStore = CmuxEventSequenceStore(eventLogURL: eventLogURL)
        let persistedHighWater = sequenceStore.current()
        var originalSequences = Set<Int64>()
        var duplicateCount = 0
        var originalMaximum: Int64 = 0
        for event in loaded {
            guard let sequence = int64(event["seq"]) else { continue }
            if !originalSequences.insert(sequence).inserted {
                duplicateCount += 1
            }
            originalMaximum = max(originalMaximum, sequence)
        }
        let rebaseRange = duplicateCount > 0
            ? sequenceStore.reserve(count: duplicateCount, minimum: max(originalMaximum, persistedHighWater))
            : nil
        var normalizedEvents: [[String: Any]] = []
        var seenSequences = Set<Int64>()
        var highestSequence: Int64 = 0
        var nextRebaseSequence = rebaseRange?.start
        for var event in loaded {
            guard let originalSequence = int64(event["seq"]) else { continue }
            let normalizedSequence: Int64
            if seenSequences.contains(originalSequence) {
                guard let rebaseSequence = nextRebaseSequence else {
                    gap = true
                    needsRewrite = true
                    continue
                }
                normalizedSequence = rebaseSequence
                nextRebaseSequence = rebaseSequence < Int64.max ? rebaseSequence + 1 : nil
            } else {
                normalizedSequence = originalSequence
            }
            if normalizedSequence != originalSequence {
                event["legacy_seq"] = NSNumber(value: originalSequence)
                event["seq"] = NSNumber(value: normalizedSequence)
                needsRewrite = true
            }
            normalizedEvents.append(event)
            seenSequences.insert(normalizedSequence)
            highestSequence = max(highestSequence, normalizedSequence)
        }
        loaded = normalizedEvents

        loaded.sort { lhs, rhs in
            (int64(lhs["seq"]) ?? 0) < (int64(rhs["seq"]) ?? 0)
        }

        let nextSequence = max(highestSequence, persistedHighWater) + 1

        return PersistedEventRestore(
            events: Array(loaded.suffix(max(1, retainedEventLimit))),
            allEvents: loaded,
            nextSequence: nextSequence,
            gap: gap,
            needsRewrite: needsRewrite
        )
    }

    private static func rewritePersistedEvents(
        _ events: [[String: Any]],
        eventLogURL: URL,
        maxEventLogBytes: UInt64
    ) {
        let fileManager = FileManager.default
        var segments: [[String]] = [[]]
        var currentSize: UInt64 = 0

        for event in events {
            var persistedEvent = event
            persistedEvent.removeValue(forKey: "legacy_seq")
            guard let line = encodeLine(persistedEvent) else { return }
            let lineBytes = UInt64(line.utf8.count) + 1
            guard lineBytes <= maxEventLogBytes else { return }
            if currentSize > 0, currentSize + lineBytes > maxEventLogBytes {
                segments.append([])
                currentSize = 0
            }
            segments[segments.count - 1].append(line)
            currentSize += lineBytes
        }

        if segments.count > 2 {
            segments = Array(segments.suffix(2))
        }

        do {
            try fileManager.createDirectory(
                at: eventLogURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let rotatedURL = eventLogURL.appendingPathExtension("1")
            if segments.count == 2 {
                try Data((segments[0].joined(separator: "\n") + "\n").utf8)
                    .write(to: rotatedURL, options: .atomic)
            } else if fileManager.fileExists(atPath: rotatedURL.path) {
                try fileManager.removeItem(at: rotatedURL)
            }
            let current = segments.last ?? []
            try Data((current.isEmpty ? "" : current.joined(separator: "\n") + "\n").utf8)
                .write(to: eventLogURL, options: .atomic)
        } catch {
            // Recovery remains usable in memory; the next restore will retry the rewrite.
        }
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
