import Foundation

/// Reduces every app, network, presence, and transport recovery trigger into one owned episode.
struct MobileConnectionLifecycleStateMachine {
    private struct PendingRequest {
        var id: UInt64?
        var trigger: MobileConnectionLifecycleTrigger
        var reconnectStackUserID: String?
    }

    private(set) var isForegroundActive = true
    private(set) var inactiveSince: Date?
    private(set) var activeEpisode: MobileConnectionLifecycleEpisode?
    private(set) var generation: UInt64 = 0
    private var requestGeneration: UInt64 = 0
    private var pendingRequests: [PendingRequest] = []
    private var completedRequestIDs: Set<UInt64> = []

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

        if !pendingRequests.isEmpty {
            return startNextPendingEpisode(health: health)
        }
        guard dwell >= shortDwellThreshold || !health.hasHealthyEventStream else {
            return nil
        }
        return request(.foregroundResume, health: health)
    }

    mutating func request(
        _ trigger: MobileConnectionLifecycleTrigger,
        health: MobileConnectionLifecycleHealthSnapshot,
        reconnectStackUserID: String? = nil
    ) -> MobileConnectionLifecycleEffect? {
        enqueue(
            PendingRequest(
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
        requestGeneration &+= 1
        let requestID = requestGeneration
        let effect = enqueue(
            PendingRequest(
                id: requestID,
                trigger: .storedMacReconnect,
                reconnectStackUserID: stackUserID
            ),
            health: health
        )
        return MobileConnectionLifecycleOwnedRequest(id: requestID, effect: effect)
    }

    private mutating func enqueue(
        _ request: PendingRequest,
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
        health: MobileConnectionLifecycleHealthSnapshot
    ) -> MobileConnectionLifecycleEffect? {
        guard activeEpisode?.id == id else { return nil }
        completedRequestIDs.formUnion(activeEpisode?.requestIDs ?? [])
        activeEpisode = nil
        return startNextPendingEpisode(health: health)
    }

    mutating func reset() {
        completedRequestIDs.formUnion(activeEpisode?.requestIDs ?? [])
        completedRequestIDs.formUnion(pendingRequests.compactMap(\.id))
        generation &+= 1
        activeEpisode = nil
        pendingRequests.removeAll()
    }

    mutating func drainCompletedRequestIDs() -> Set<UInt64> {
        defer { completedRequestIDs.removeAll() }
        return completedRequestIDs
    }

    func ownsEpisode(_ id: UInt64) -> Bool {
        activeEpisode?.id == id
    }

    private mutating func appendPending(_ request: PendingRequest) {
        if request.id == nil,
           pendingRequests.contains(where: { $0.id == nil && $0.trigger == request.trigger }) {
            return
        }
        pendingRequests.append(request)
    }

    private mutating func startNextPendingEpisode(
        health: MobileConnectionLifecycleHealthSnapshot
    ) -> MobileConnectionLifecycleEffect? {
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

        var absorbed: [PendingRequest] = []
        let requests = pendingRequests
        pendingRequests.removeAll()
        for request in requests {
            let kind = recoveryKind(for: request.trigger, health: health)
            let shouldAbsorb: Bool
            switch selectedKind {
            case .streamRepair:
                shouldAbsorb = kind == .streamRepair
            case .reconnect:
                shouldAbsorb = kind == .streamRepair
                    || request.reconnectStackUserID == selectedStackUserID
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
        case (.streamRepair, .streamRepair), (.reconnect, .streamRepair):
            return true
        case (.streamRepair, .reconnect):
            return false
        case (.reconnect, .reconnect):
            return reconnectStackUserID == requestedStackUserID
        }
    }
}
