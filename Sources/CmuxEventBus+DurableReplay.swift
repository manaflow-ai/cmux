import Foundation

extension CmuxEventBus {
    func subscribe(
        afterSequence: Int64?,
        names: Set<String>,
        categories: Set<String>
    ) -> CmuxEventSubscriptionSnapshot {
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
                subscription: subscription
            )
            return makeSubscriptionSnapshot(
                subscription: subscription,
                replay: replayState.replay,
                afterSequence: afterSequence,
                oldestSequence: replayState.oldestSequence,
                latestSequence: latestSequence,
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
            gapReason: gapReason,
            names: names,
            categories: categories,
            bootId: context.bootId
        )
    }

    private func durableReplayState(
        durableSnapshot: CmuxEventLogReplayStore.Snapshot,
        retainedSnapshot: [[String: Any]],
        latestSequence: Int64,
        afterSequence: Int64?,
        subscription: CmuxEventSubscription
    ) -> (replay: [[String: Any]], oldestSequence: Int64, gapReason: String?) {
        var eventsByID: [String: [String: Any]] = [:]
        var anonymousEvents: [[String: Any]] = []
        for event in durableSnapshot.events + retainedSnapshot {
            guard let sequence = CmuxEventBus.int64(event["seq"]), sequence <= latestSequence else { continue }
            if let id = event["id"] as? String, !id.isEmpty {
                eventsByID[id] = event
            } else {
                anonymousEvents.append(event)
            }
        }

        let events = (Array(eventsByID.values) + anonymousEvents).sorted { lhs, rhs in
            let lhsSequence = CmuxEventBus.int64(lhs["seq"]) ?? 0
            let rhsSequence = CmuxEventBus.int64(rhs["seq"]) ?? 0
            if lhsSequence != rhsSequence { return lhsSequence < rhsSequence }
            let lhsID = lhs["id"] as? String ?? ""
            let rhsID = rhs["id"] as? String ?? ""
            return lhsID < rhsID
        }
        let availableSequences = Array(Set(events.compactMap { CmuxEventBus.int64($0["seq"]) })).sorted()
        let oldestSequence = availableSequences.first ?? nextSequenceAfter(latestSequence)
        let requestedAfter = afterSequence ?? latestSequence
        let replay = events.filter { event in
            let sequence = CmuxEventBus.int64(event["seq"]) ?? 0
            return sequence > requestedAfter && subscription.accepts(event)
        }

        let gapReason: String? = afterSequence.flatMap { after in
            if after < oldestSequence - 1 {
                return "requested sequence is older than the durable event log"
            }
            if after > latestSequence {
                return "requested sequence is newer than this cmux process; cmux probably restarted"
            }
            if durableSequenceGap(
                afterSequence: after,
                latestSequence: latestSequence,
                availableSequences: availableSequences
            ) {
                return "durable event log has a sequence gap"
            }
            return nil
        }
        return (replay, oldestSequence, gapReason)
    }

    private func durableSequenceGap(
        afterSequence: Int64,
        latestSequence: Int64,
        availableSequences: [Int64]
    ) -> Bool {
        guard afterSequence < latestSequence else { return false }
        var expected = nextSequenceAfter(afterSequence)
        for sequence in availableSequences where sequence >= expected && sequence <= latestSequence {
            if sequence > expected { return true }
            expected = nextSequenceAfter(sequence)
        }
        return expected <= latestSequence
    }

    private func nextSequenceAfter(_ sequence: Int64) -> Int64 {
        sequence == Int64.max ? Int64.max : sequence + 1
    }

    private func makeSubscriptionSnapshot(
        subscription: CmuxEventSubscription,
        replay: [[String: Any]],
        afterSequence: Int64?,
        oldestSequence: Int64,
        latestSequence: Int64,
        gapReason: String?,
        names: Set<String>,
        categories: Set<String>,
        bootId: String
    ) -> CmuxEventSubscriptionSnapshot {
        var resume: [String: Any] = [
            "after_seq": afterSequence.map { NSNumber(value: $0) } ?? NSNull(),
            "requested_after_seq": NSNumber(value: afterSequence ?? latestSequence),
            "oldest_seq": NSNumber(value: oldestSequence),
            "latest_seq": NSNumber(value: latestSequence),
            "next_seq": NSNumber(value: nextSequenceAfter(latestSequence)),
            "gap": gapReason != nil
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
}
