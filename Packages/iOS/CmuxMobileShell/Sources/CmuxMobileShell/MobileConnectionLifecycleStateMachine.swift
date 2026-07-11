import Foundation

/// Reduces every app, network, presence, and transport recovery trigger into one owned episode.
struct MobileConnectionLifecycleStateMachine {
    private(set) var isForegroundActive = true
    private(set) var inactiveSince: Date?
    private(set) var activeEpisode: MobileConnectionLifecycleEpisode?
    private(set) var generation: UInt64 = 0
    private var pendingTriggers: Set<MobileConnectionLifecycleTrigger> = []

    mutating func becameInactive(at date: Date) {
        guard isForegroundActive else { return }
        isForegroundActive = false
        inactiveSince = date
    }

    mutating func becameActive(
        at date: Date,
        shortDwellThreshold: TimeInterval,
        health: MobileConnectionLifecycleHealthSnapshot
    ) -> MobileConnectionLifecycleEffect? {
        guard !isForegroundActive else { return nil }
        isForegroundActive = true
        let dwell = inactiveSince.map { date.timeIntervalSince($0) } ?? shortDwellThreshold
        inactiveSince = nil

        let deferred = pendingTriggers
        pendingTriggers.removeAll()
        if let trigger = highestPriorityTrigger(in: deferred) {
            return request(trigger, health: health)
        }
        guard dwell >= shortDwellThreshold || !health.hasHealthyEventStream else {
            return nil
        }
        return request(.foregroundResume, health: health)
    }

    mutating func request(
        _ trigger: MobileConnectionLifecycleTrigger,
        health: MobileConnectionLifecycleHealthSnapshot
    ) -> MobileConnectionLifecycleEffect? {
        guard isForegroundActive else {
            pendingTriggers.insert(trigger)
            return nil
        }
        let requestedKind = recoveryKind(for: trigger, health: health)
        if let activeEpisode {
            if activeEpisode.kind == .streamRepair, requestedKind == .reconnect {
                pendingTriggers.insert(trigger)
            }
            return nil
        }

        generation &+= 1
        let episode = MobileConnectionLifecycleEpisode(
            id: generation,
            kind: requestedKind,
            triggers: [trigger]
        )
        activeEpisode = episode
        return .start(episode)
    }

    mutating func complete(
        id: UInt64,
        health: MobileConnectionLifecycleHealthSnapshot
    ) -> MobileConnectionLifecycleEffect? {
        guard activeEpisode?.id == id else { return nil }
        activeEpisode = nil
        let deferred = pendingTriggers
        pendingTriggers.removeAll()
        guard let trigger = highestPriorityTrigger(in: deferred) else { return nil }
        return request(trigger, health: health)
    }

    mutating func reset() {
        generation &+= 1
        activeEpisode = nil
        pendingTriggers.removeAll()
    }

    func ownsEpisode(_ id: UInt64) -> Bool {
        activeEpisode?.id == id
    }

    private func recoveryKind(
        for trigger: MobileConnectionLifecycleTrigger,
        health: MobileConnectionLifecycleHealthSnapshot
    ) -> MobileConnectionLifecycleRecoveryKind {
        switch trigger {
        case .networkPathChanged, .presenceRoutesChanged, .manualRetry, .storedMacReconnect:
            return health.canReconnectPersistedMac ? .reconnect : .streamRepair
        case .foregroundResume, .eventStreamLost:
            return health.connected && health.hasClient ? .streamRepair : .reconnect
        }
    }

    private func highestPriorityTrigger(
        in triggers: Set<MobileConnectionLifecycleTrigger>
    ) -> MobileConnectionLifecycleTrigger? {
        let priority: [MobileConnectionLifecycleTrigger] = [
            .manualRetry,
            .presenceRoutesChanged,
            .networkPathChanged,
            .storedMacReconnect,
            .eventStreamLost,
            .foregroundResume,
        ]
        return priority.first(where: triggers.contains)
    }
}
