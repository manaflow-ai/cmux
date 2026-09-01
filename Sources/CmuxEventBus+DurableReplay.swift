import Foundation

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

extension CmuxEventBus {
    /// Registers a subscription and captures a replay/live cutover boundary.
    func subscribe(
        afterSequence: Int64?,
        names: Set<String>,
        categories: Set<String>
    ) -> CmuxEventSubscriptionSnapshot {
        ensureDurableSequenceSeeded()
        let context = makeSubscriptionContext(names: names, categories: categories)
        let subscription = context.subscription
        let latestSequence = context.latestSequence
        let retainedSnapshot = context.retained

        if let durableReplayStore = context.durableReplayStore {
            let durableSnapshot = durableReplayStore.snapshot()
            let replayState = durableReplayState(
                durableSnapshot: durableSnapshot,
                retainedSnapshot: retainedSnapshot,
                latestSequence: latestSequence,
                afterSequence: afterSequence,
                subscription: subscription,
                sequenceFloorGap: context.sequenceFloorGap
            )
            return makeSubscriptionSnapshot(
                subscription: subscription,
                replay: replayState.replay,
                afterSequence: afterSequence,
                oldestSequence: replayState.oldestSequence,
                latestSequence: latestSequence,
                nextSequence: context.nextSequence,
                gapReason: replayState.gapReason,
                names: names,
                categories: categories,
                bootId: context.bootId
            )
        }

        let oldestSequence = CmuxEventBus.int64(retainedSnapshot.first?["seq"]) ?? nextSequenceAfter(latestSequence)
        let requestedAfter = afterSequence ?? latestSequence
        let replay = retainedSnapshot.filter { event in
            let sequence = CmuxEventBus.int64(event["seq"]) ?? 0
            return sequence > requestedAfter && subscription.accepts(event)
        }
        let gapReason: String? = afterSequence.flatMap { after in
            if !retainedSnapshot.isEmpty, after < oldestSequence - 1 {
                return "requested sequence is older than the retained in-memory event log"
            }
            if after > latestSequence {
                return "requested sequence is newer than this cmux process; cmux probably restarted"
            }
            return nil
        }
        return makeSubscriptionSnapshot(
            subscription: subscription,
            replay: replay,
            afterSequence: afterSequence,
            oldestSequence: oldestSequence,
            latestSequence: latestSequence,
            nextSequence: context.nextSequence,
            gapReason: gapReason,
            names: names,
            categories: categories,
            bootId: context.bootId
        )
    }

    private enum ReplaySource {
        case durable
        case retained
    }

    /// Merges the ordered durable cache with the retained tail in one pass.
    private func durableReplayState(
        durableSnapshot: CmuxEventLogReplayStore.Snapshot,
        retainedSnapshot: [[String: Any]],
        latestSequence: Int64,
        afterSequence: Int64?,
        subscription: CmuxEventSubscription,
        sequenceFloorGap: Bool
    ) -> (replay: [[String: Any]], oldestSequence: Int64, gapReason: String?) {
        let requestedAfter = afterSequence ?? latestSequence
        let retainedOldestSequence = retainedSnapshot.first.flatMap { CmuxEventBus.int64($0["seq"]) }
        let oldestSequence: Int64 = {
            switch (durableSnapshot.sequences.first, retainedOldestSequence) {
            case let (durable?, retained?): return min(durable, retained)
            case let (durable?, nil): return durable
            case let (nil, retained?): return retained
            case (nil, nil): return nextSequenceAfter(latestSequence)
            }
        }()

        // The retained tail is small and may contain writes that have not made
        // it to disk yet. Index only that tail; the durable index is maintained
        // by CmuxEventLogReplayStore and is never rebuilt for a subscription.
        var durableOverlapIDs = Set<String>()
        var retainedAnonymousSequences = Set<Int64>()
        for event in retainedSnapshot {
            guard let sequence = CmuxEventBus.int64(event["seq"]),
                  sequence >= 1,
                  sequence <= latestSequence else { continue }
            if let id = event["id"] as? String, !id.isEmpty {
                if durableSnapshot.eventsByID[id] != nil {
                    durableOverlapIDs.insert(id)
                }
            } else {
                retainedAnonymousSequences.insert(sequence)
            }
        }

        let mergeAfter = afterSequence ?? latestSequence
        var durableIndex = durableSnapshot.firstEventIndex(after: mergeAfter)
        var retainedIndex = firstRetainedEventIndex(after: mergeAfter, in: retainedSnapshot)
        var seenRetainedIDs = Set<String>()
        var previousSequence: Int64? = afterSequence
        var sequenceGap = false
        var replay: [[String: Any]] = []

        while true {
            while durableIndex < durableSnapshot.events.count {
                let event = durableSnapshot.events[durableIndex]
                guard let sequence = CmuxEventBus.int64(event["seq"]),
                      sequence >= 1,
                      sequence <= latestSequence else {
                    durableIndex += 1
                    continue
                }
                break
            }
            while retainedIndex < retainedSnapshot.count {
                let event = retainedSnapshot[retainedIndex]
                guard let sequence = CmuxEventBus.int64(event["seq"]),
                      sequence >= 1,
                      sequence <= latestSequence else {
                    retainedIndex += 1
                    continue
                }
                break
            }

            let durableEvent = durableIndex < durableSnapshot.events.count
                ? durableSnapshot.events[durableIndex]
                : nil
            let retainedEvent = retainedIndex < retainedSnapshot.count
                ? retainedSnapshot[retainedIndex]
                : nil
            guard durableEvent != nil || retainedEvent != nil else { break }

            var consumedDurableAtSameSequence = false
            let candidate: (source: ReplaySource, event: [String: Any], sequence: Int64)?
            switch (durableEvent, retainedEvent) {
            case let (durable?, retained?):
                let durableSequence = CmuxEventBus.int64(durable["seq"]) ?? 0
                let retainedSequence = CmuxEventBus.int64(retained["seq"]) ?? 0
                if durableSequence < retainedSequence {
                    candidate = (source: .durable, event: durable, sequence: durableSequence)
                    durableIndex += 1
                } else {
                    // Prefer the in-memory copy at an equal sequence so a
                    // just-published event wins while the durable duplicate is
                    // consumed in the same step.
                    candidate = (source: .retained, event: retained, sequence: retainedSequence)
                    retainedIndex += 1
                    if durableSequence == retainedSequence {
                        durableIndex += 1
                        consumedDurableAtSameSequence = true
                    }
                }
            case let (durable?, nil):
                candidate = (
                    source: .durable,
                    event: durable,
                    sequence: CmuxEventBus.int64(durable["seq"]) ?? 0
                )
                durableIndex += 1
            case let (nil, retained?):
                candidate = (
                    source: .retained,
                    event: retained,
                    sequence: CmuxEventBus.int64(retained["seq"]) ?? 0
                )
                retainedIndex += 1
            case (nil, nil):
                candidate = nil
            }

            guard let candidate else { break }
            let source = candidate.source
            let event = candidate.event
            let sequence = candidate.sequence
            guard sequence >= 1, sequence <= latestSequence else { continue }
            let id = (event["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if source == .durable {
                // The retained tail is authoritative for duplicate IDs,
                // including a pending write whose disk copy is already visible.
                if let id, durableOverlapIDs.contains(id) { continue }
                if id == nil, retainedAnonymousSequences.contains(sequence) { continue }
            } else if let id {
                guard seenRetainedIDs.insert(id).inserted else { continue }
            } else if !consumedDurableAtSameSequence,
                      containsSortedSequence(durableSnapshot.sequences, sequence) {
                // A sequence without an ID still represents one stream
                // position; the durable index already contains that position.
                continue
            }

            if let previousSequence {
                // A sequence identifies one stream position. Keep the first
                // merged event at a position and derive gaps from the ordered
                // walk instead of constructing a Set for every subscription.
                if sequence <= previousSequence { continue }
                let expected = nextSequenceAfter(previousSequence)
                if sequence > expected,
                   expected <= latestSequence,
                   sequence > requestedAfter,
                   requestedAfter >= oldestSequence - 1 {
                    sequenceGap = true
                }
            }
            previousSequence = sequence

            if sequence > requestedAfter, subscription.accepts(event) {
                replay.append(event)
            }
        }

        if let previousSequence,
           afterSequence != nil,
           previousSequence < latestSequence,
           nextSequenceAfter(previousSequence) <= latestSequence,
           latestSequence > requestedAfter {
            sequenceGap = true
        }

        let gapReason: String? = afterSequence.flatMap { after in
            if after > latestSequence {
                return "requested sequence is newer than this cmux process; cmux probably restarted"
            }
            if (sequenceFloorGap || durableSnapshot.hasUnavailableRange),
               after < latestSequence || durableSnapshot.events.isEmpty {
                return "durable event log has a sequence gap"
            }
            if after < oldestSequence - 1 {
                return "requested sequence is older than the durable event log"
            }
            if sequenceGap,
               after < latestSequence {
                return "durable event log has a sequence gap"
            }
            return nil
        }
        return (replay, oldestSequence, gapReason)
    }

    /// Advances a sequence without overflowing at the representable maximum.
    private func nextSequenceAfter(_ sequence: Int64) -> Int64 {
        sequence == Int64.max ? Int64.max : sequence + 1
    }

    /// Tests membership in the store's sorted sequence index.
    private func containsSortedSequence(_ sequences: [Int64], _ value: Int64) -> Bool {
        var lower = 0
        var upper = sequences.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if sequences[middle] < value {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower < sequences.count && sequences[lower] == value
    }

    /// Finds the first retained event after a cursor without walking its prefix.
    private func firstRetainedEventIndex(after sequence: Int64, in events: [[String: Any]]) -> Int {
        var lower = 0
        var upper = events.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let middleSequence = CmuxEventBus.int64(events[middle]["seq"]) ?? Int64.max
            if middleSequence <= sequence {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    /// Builds the protocol acknowledgement and replay payload for a subscription.
    private func makeSubscriptionSnapshot(
        subscription: CmuxEventSubscription,
        replay: [[String: Any]],
        afterSequence: Int64?,
        oldestSequence: Int64,
        latestSequence: Int64,
        nextSequence: Int64,
        gapReason: String?,
        names: Set<String>,
        categories: Set<String>,
        bootId: String
    ) -> CmuxEventSubscriptionSnapshot {
        let resume: [String: Any] = {
            var value: [String: Any] = [
                "after_seq": afterSequence.map { NSNumber(value: $0) } ?? NSNull(),
                "requested_after_seq": NSNumber(value: afterSequence ?? latestSequence),
                "oldest_seq": NSNumber(value: oldestSequence),
                "latest_seq": NSNumber(value: latestSequence),
                "next_seq": NSNumber(value: nextSequence),
                "gap": gapReason != nil
            ]
            if let gapReason {
                value["gap_reason"] = gapReason
            }
            return value
        }()

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
}
