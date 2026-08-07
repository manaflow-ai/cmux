import Foundation

struct AgentWaitCoordinator {
    struct Preparation {
        let afterSequence: Int64
        let surface: AgentWaitSurfaceSnapshot?
    }

    private static let eventNames: Set<String> = [
        "agent.state.changed",
        "surface.closed",
    ]
    private static let peerCheckInterval: TimeInterval = 15

    private let eventBus: CmuxEventBus
    private let onSubscribe: (CmuxEventSubscription) -> Void
    private let shouldContinue: () -> Bool
    private let monotonicNow: () -> TimeInterval

    init(
        eventBus: CmuxEventBus,
        onSubscribe: @escaping (CmuxEventSubscription) -> Void = { _ in },
        shouldContinue: @escaping () -> Bool = { true },
        monotonicNow: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.eventBus = eventBus
        self.onSubscribe = onSubscribe
        self.shouldContinue = shouldContinue
        self.monotonicNow = monotonicNow
    }

    func wait(
        until: AgentWaitUntil,
        timeoutMilliseconds: Int64?,
        prepare: () -> Preparation,
        routingSnapshot: ((UUID) -> AgentWaitSurfaceSnapshot?)? = nil
    ) -> Result<AgentWaitResult, AgentWaitError> {
        let preparation = prepare()
        guard var surface = preparation.surface else {
            return .failure(.surfaceNotFound)
        }
        guard surface.hasAuthoritativeLiveLifecycle else {
            return .failure(.liveLifecycleUnavailable)
        }
        let lifecycleSurfaceID = surface.surfaceID
        let subscriptionSnapshot = eventBus.subscribe(
            afterSequence: preparation.afterSequence,
            names: Self.eventNames,
            categories: [],
            surfaceIDs: [lifecycleSurfaceID.uuidString]
        )
        onSubscribe(subscriptionSnapshot.subscription)
        defer {
            eventBus.unsubscribe(subscriptionSnapshot.subscription)
        }
        guard !subscriptionSnapshot.subscription.isClosed else {
            return .failure(.subscriptionClosed)
        }
        if let resume = subscriptionSnapshot.ack["resume"] as? [String: Any],
           resume["gap"] as? Bool == true {
            return .failure(.subscriptionClosed)
        }
        guard let occupant = surface.occupant else {
            return .failure(.noAgent)
        }

        func refreshSurfaceRouting() -> AgentWaitSurfaceSnapshot {
            if let refreshed = routingSnapshot?(lifecycleSurfaceID) {
                surface = refreshed
            }
            return surface
        }

        var replayIndex = 0
        func nextEvent(timeout: TimeInterval) -> [String: Any]? {
            if replayIndex < subscriptionSnapshot.replay.count {
                defer { replayIndex += 1 }
                return subscriptionSnapshot.replay[replayIndex]
            }
            return subscriptionSnapshot.subscription.next(timeout: timeout)
        }

        var pinnedState = occupant.publicState
        if until.isSatisfied(by: pinnedState) {
            return .success(
                result(
                    status: .satisfied,
                    until: until,
                    state: pinnedState,
                    occupant: occupant,
                    surface: refreshSurfaceRouting()
                )
            )
        }

        let deadline = timeoutMilliseconds.map {
            monotonicNow() + Double($0) / 1_000
        }
        func timeoutResultIfExpired() -> AgentWaitResult? {
            guard let deadline, monotonicNow() >= deadline else { return nil }
            return result(
                status: .timedOut,
                until: until,
                state: pinnedState,
                occupant: occupant,
                surface: refreshSurfaceRouting()
            )
        }
        while true {
            guard shouldContinue() else {
                return .failure(.subscriptionClosed)
            }
            let waitInterval: TimeInterval
            if let deadline {
                waitInterval = min(
                    Self.peerCheckInterval,
                    max(0, deadline - monotonicNow())
                )
            } else {
                waitInterval = Self.peerCheckInterval
            }

            if let event = nextEvent(timeout: waitInterval) {
                if event["name"] as? String == "surface.closed" {
                    guard let closedRouting = routing(from: event),
                          closedRouting.surfaceID == lifecycleSurfaceID else {
                        if let timeout = timeoutResultIfExpired() {
                            return .success(timeout)
                        }
                        continue
                    }
                    surface = closedRouting
                    let payload = event["payload"] as? [String: Any]
                    if payload?["origin"] as? String == "detach" {
                        if let refreshed = routingSnapshot?(lifecycleSurfaceID),
                           refreshed.surfaceID == lifecycleSurfaceID {
                            surface = refreshed
                            guard refreshed.hasAuthoritativeLiveLifecycle else {
                                return .failure(.liveLifecycleUnavailable)
                            }
                        }
                        if let timeout = timeoutResultIfExpired() {
                            return .success(timeout)
                        }
                        continue
                    }
                    return .success(
                        result(
                            status: .surfaceClosed,
                            until: until,
                            state: pinnedState,
                            occupant: occupant,
                            surface: refreshSurfaceRouting()
                        )
                    )
                }
                guard let transition = transition(from: event) else {
                    if let timeout = timeoutResultIfExpired() {
                        return .success(timeout)
                    }
                    continue
                }
                guard transition.routing?.surfaceID == lifecycleSurfaceID else {
                    if let timeout = timeoutResultIfExpired() {
                        return .success(timeout)
                    }
                    continue
                }
                guard transition.record.identifiesSameOccupant(as: occupant) else {
                    if let timeout = timeoutResultIfExpired() {
                        return .success(timeout)
                    }
                    continue
                }
                if let routing = transition.routing,
                   routing.surfaceID == lifecycleSurfaceID {
                    surface = routing
                }
                pinnedState = transition.state
                if until.isSatisfied(by: pinnedState) {
                    return .success(
                        result(
                            status: .satisfied,
                            until: until,
                            state: pinnedState,
                            occupant: occupant,
                            surface: refreshSurfaceRouting()
                        )
                    )
                }
                if pinnedState == .exit {
                    return .failure(.noAgent)
                }
                if let timeout = timeoutResultIfExpired() {
                    return .success(timeout)
                }
                continue
            }

            if subscriptionSnapshot.subscription.isClosed {
                return .failure(.subscriptionClosed)
            }
            if let timeout = timeoutResultIfExpired() {
                return .success(timeout)
            }
        }
    }

    private func transition(
        from event: [String: Any]
    ) -> (
        record: AgentLifecycleRecord,
        state: AgentLifecyclePublicState,
        routing: AgentWaitSurfaceSnapshot?
    )? {
        guard event["name"] as? String == "agent.state.changed",
              let payload = event["payload"] as? [String: Any],
              let agent = payload["agent"] as? String,
              let stateRaw = payload["state"] as? String,
              let state = AgentLifecyclePublicState(rawValue: stateRaw),
              let revisionValue = CmuxEventBus.int64(payload["revision"]),
              revisionValue >= 0 else {
            return nil
        }
        let sessionID = payload["session_id"] as? String
        let lifecycle: AgentHibernationLifecycleState
        switch state {
        case .unknown:
            lifecycle = .unknown
        case .running:
            lifecycle = .running
        case .idle:
            lifecycle = .idle
        case .needsInput:
            lifecycle = .needsInput
        case .exit:
            lifecycle = .unknown
        }
        return (
            AgentLifecycleRecord(
                agent: agent,
                state: lifecycle,
                sessionID: sessionID,
                revision: UInt64(revisionValue)
            ),
            state,
            routing(from: event)
        )
    }

    private func routing(from event: [String: Any]) -> AgentWaitSurfaceSnapshot? {
        guard let workspaceID = (event["workspace_id"] as? String).flatMap(UUID.init(uuidString:)),
              let surfaceID = (event["surface_id"] as? String).flatMap(UUID.init(uuidString:)) else {
            return nil
        }
        return AgentWaitSurfaceSnapshot(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            paneID: (event["pane_id"] as? String).flatMap(UUID.init(uuidString:)),
            occupant: nil
        )
    }

    private func result(
        status: AgentWaitStatus,
        until: AgentWaitUntil,
        state: AgentLifecyclePublicState,
        occupant: AgentLifecycleRecord,
        surface: AgentWaitSurfaceSnapshot
    ) -> AgentWaitResult {
        AgentWaitResult(
            status: status,
            until: until,
            state: state,
            agent: occupant.agent,
            sessionID: occupant.sessionID,
            workspaceID: surface.workspaceID,
            surfaceID: surface.surfaceID,
            paneID: surface.paneID
        )
    }
}
