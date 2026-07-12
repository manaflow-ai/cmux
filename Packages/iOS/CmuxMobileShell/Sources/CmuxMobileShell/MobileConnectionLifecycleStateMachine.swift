import Foundation

/// Reduces every app, network, presence, and transport recovery trigger into one owned episode.
struct MobileConnectionLifecycleStateMachine {
    private(set) var isForegroundActive = true
    private(set) var inactiveSince: Date?
    private(set) var activeEpisode: MobileConnectionLifecycleEpisode?
    private(set) var generation: UInt64 = 0
    private var requestGeneration: UInt64 = 0
    private var pendingRequests: [MobileConnectionLifecyclePendingRequest] = []
    private var completedRequestIDs: Set<UInt64> = []
    private(set) var recoveryFailed = false
    private(set) var didFinishStoredMacReconnectAttempt = false

    var isRecovering: Bool {
        activeEpisode != nil
    }

    var isReconnectingStoredMac: Bool {
        activeEpisode?.kind == .reconnect
    }

    var resourceSnapshot: MobileConnectionLifecycleResourceSnapshot {
        MobileConnectionLifecycleResourceSnapshot(
            activeEpisodeCount: activeEpisode == nil ? 0 : 1,
            pendingRequestCount: pendingRequests.count
        )
    }

    mutating func becameInactive(at date: Date) {
        guard isForegroundActive else { return }
        isForegroundActive = false
        inactiveSince = date
    }

    mutating func becameActive(
        at date: Date,
        shortDwellThreshold: TimeInterval,
        health: MobileConnectionLifecycleHealthSnapshot,
        reconnectStackUserID: String? = nil
    ) -> MobileConnectionLifecycleEffect? {
        guard !isForegroundActive else { return nil }
        isForegroundActive = true
        let dwell = inactiveSince.map { date.timeIntervalSince($0) } ?? shortDwellThreshold
        inactiveSince = nil
        let shouldRequestForegroundRecovery = dwell >= shortDwellThreshold
            || !health.hasHealthyEventStream

        if activeEpisode != nil {
            guard shouldRequestForegroundRecovery else { return nil }
            return request(
                .foregroundResume,
                health: health,
                reconnectStackUserID: reconnectStackUserID
            )
        }
        if !pendingRequests.isEmpty {
            return startNextPendingEpisode(health: health)
        }
        guard shouldRequestForegroundRecovery else {
            return nil
        }
        return request(
            .foregroundResume,
            health: health,
            reconnectStackUserID: reconnectStackUserID
        )
    }

    mutating func request(
        _ trigger: MobileConnectionLifecycleTrigger,
        health: MobileConnectionLifecycleHealthSnapshot,
        reconnectStackUserID: String? = nil
    ) -> MobileConnectionLifecycleEffect? {
        enqueue(
            MobileConnectionLifecyclePendingRequest(
                id: nil,
                trigger: trigger,
                reconnectStackUserID: reconnectStackUserID
            ),
            health: health
        )
    }

    mutating func requestStoredMacReconnect(
        stackUserID: String?,
        health: MobileConnectionLifecycleHealthSnapshot
    ) -> MobileConnectionLifecycleOwnedRequest {
        didFinishStoredMacReconnectAttempt = false
        requestGeneration &+= 1
        let requestID = requestGeneration
        let effect = enqueue(
            MobileConnectionLifecyclePendingRequest(
                id: requestID,
                trigger: .storedMacReconnect,
                reconnectStackUserID: stackUserID
            ),
            health: health
        )
        return MobileConnectionLifecycleOwnedRequest(id: requestID, effect: effect)
    }

    private mutating func enqueue(
        _ request: MobileConnectionLifecyclePendingRequest,
        health: MobileConnectionLifecycleHealthSnapshot
    ) -> MobileConnectionLifecycleEffect? {
        guard isForegroundActive else {
            appendPending(request)
            return nil
        }
        let requestedKind = recoveryKind(for: request.trigger, health: health)
        if var activeEpisode {
            if activeEpisode.canAbsorb(
                kind: requestedKind,
                reconnectStackUserID: request.reconnectStackUserID
            ) {
                activeEpisode.triggers.insert(request.trigger)
                if let requestID = request.id {
                    activeEpisode.requestIDs.insert(requestID)
                }
                self.activeEpisode = activeEpisode
            } else {
                appendPending(request)
            }
            return nil
        }

        appendPending(request)
        return startNextPendingEpisode(health: health)
    }

    mutating func complete(
        id: UInt64,
        health: MobileConnectionLifecycleHealthSnapshot,
        succeeded: Bool = true
    ) -> MobileConnectionLifecycleEffect? {
        guard activeEpisode?.id == id else { return nil }
        if activeEpisode?.kind == .reconnect {
            didFinishStoredMacReconnectAttempt = true
        }
        completedRequestIDs.formUnion(activeEpisode?.requestIDs ?? [])
        activeEpisode = nil
        recoveryFailed = !succeeded
        guard isForegroundActive else { return nil }
        return startNextPendingEpisode(health: health)
    }

    mutating func markHealthy() {
        recoveryFailed = false
    }

    mutating func markRecoveryFailed() {
        recoveryFailed = true
    }

    mutating func reset() {
        completedRequestIDs.formUnion(activeEpisode?.requestIDs ?? [])
        completedRequestIDs.formUnion(pendingRequests.compactMap(\.id))
        generation &+= 1
        activeEpisode = nil
        pendingRequests.removeAll()
        recoveryFailed = false
        didFinishStoredMacReconnectAttempt = true
    }

    mutating func prepareForStoredMacReconnect() {
        didFinishStoredMacReconnectAttempt = false
    }

    mutating func drainCompletedRequestIDs() -> Set<UInt64> {
        defer { completedRequestIDs.removeAll() }
        return completedRequestIDs
    }

    func ownsEpisode(_ id: UInt64) -> Bool {
        activeEpisode?.id == id
    }

    private mutating func appendPending(_ request: MobileConnectionLifecyclePendingRequest) {
        if request.id == nil,
           pendingRequests.contains(where: { $0.id == nil && $0.trigger == request.trigger }) {
            return
        }
        pendingRequests.append(request)
    }

    private mutating func startNextPendingEpisode(
        health: MobileConnectionLifecycleHealthSnapshot
    ) -> MobileConnectionLifecycleEffect? {
        guard activeEpisode == nil else { return nil }
        guard let selectedTrigger = highestPriorityTrigger(
            in: Set(pendingRequests.map(\.trigger))
        ),
        let selectedIndex = pendingRequests.firstIndex(where: { $0.trigger == selectedTrigger }) else {
            return nil
        }
        let selected = pendingRequests[selectedIndex]
        let selectedKind = recoveryKind(for: selected.trigger, health: health)
        let selectedStackUserID = selectedKind == .reconnect
            ? selected.reconnectStackUserID
            : nil

        var absorbed: [MobileConnectionLifecyclePendingRequest] = []
        let requests = pendingRequests
        pendingRequests.removeAll()
        for request in requests {
            let kind = recoveryKind(for: request.trigger, health: health)
            let shouldAbsorb: Bool
            switch selectedKind {
            case .streamRepair:
                shouldAbsorb = kind == .streamRepair
            case .reconnect:
                shouldAbsorb = kind == .reconnect
                    && request.reconnectStackUserID == selectedStackUserID
            }
            if shouldAbsorb {
                absorbed.append(request)
            } else {
                pendingRequests.append(request)
            }
        }

        generation &+= 1
        let episode = MobileConnectionLifecycleEpisode(
            id: generation,
            kind: selectedKind,
            triggers: Set(absorbed.map(\.trigger)),
            requestIDs: Set(absorbed.compactMap(\.id)),
            reconnectStackUserID: selectedStackUserID
        )
        activeEpisode = episode
        recoveryFailed = false
        return .start(episode)
    }

    private func recoveryKind(
        for trigger: MobileConnectionLifecycleTrigger,
        health: MobileConnectionLifecycleHealthSnapshot
    ) -> MobileConnectionLifecycleRecoveryKind {
        switch trigger {
        case .networkPathChanged, .presenceRoutesChanged, .manualRetry:
            if health.connected, health.hasClient {
                return .streamRepair
            }
            return health.canReconnectPersistedMac ? .reconnect : .streamRepair
        case .storedMacReconnect:
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

private extension MobileConnectionLifecycleEpisode {
    func canAbsorb(
        kind requestedKind: MobileConnectionLifecycleRecoveryKind,
        reconnectStackUserID requestedStackUserID: String?
    ) -> Bool {
        switch (kind, requestedKind) {
        case (.streamRepair, .streamRepair):
            return true
        case (.reconnect, .streamRepair):
            return false
        case (.streamRepair, .reconnect):
            return false
        case (.reconnect, .reconnect):
            return reconnectStackUserID == requestedStackUserID
        }
    }
}
