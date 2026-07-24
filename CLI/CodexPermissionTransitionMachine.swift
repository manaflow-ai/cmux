import Foundation

/// Pure ordering rules shared by every CLI lane that observes a Codex approval.
struct CodexPermissionTransitionMachine: Sendable {
    private let maximumResolvedIdentities: Int
    private let maximumStartedIdentities: Int
    private let maximumTrackedRequests: Int

    init(
        maximumResolvedIdentities: Int = 16,
        maximumStartedIdentities: Int = 16,
        maximumTrackedRequests: Int = 16
    ) {
        self.maximumResolvedIdentities = max(1, maximumResolvedIdentities)
        self.maximumStartedIdentities = max(1, maximumStartedIdentities)
        self.maximumTrackedRequests = max(1, maximumTrackedRequests)
    }

    func reduce(
        current: CodexPermissionState?,
        event: CodexPermissionEvent,
        identity: CodexPermissionSignalIdentity,
        runtime: CodexPermissionRuntimeGeneration,
        revisionWatermark: UInt64? = nil,
        notificationID: UUID? = nil
    ) -> CodexPermissionTransition {
        if let current, !current.runtime.matches(runtime) {
            return CodexPermissionTransition(state: current, effect: .none, accepted: false)
        }

        switch event {
        case .permissionRequested:
            return acceptNeedsInput(
                current: current,
                identity: identity,
                runtime: runtime,
                revisionWatermark: revisionWatermark,
                notificationID: notificationID
            )
        case .toolStarted:
            return acceptToolStarted(
                current: current,
                identity: identity,
                runtime: runtime,
                revisionWatermark: revisionWatermark
            )
        case .toolCompleted:
            return acceptToolCompleted(
                current: current,
                identity: identity,
                runtime: runtime,
                revisionWatermark: revisionWatermark
            )
        }
    }

    /// Marks every current request as older than a causal prompt or Stop boundary.
    func crossOrderingBoundary(
        current: CodexPermissionState?,
        runtime: CodexPermissionRuntimeGeneration,
        revision: UInt64
    ) -> CodexPermissionState? {
        guard let current, current.runtime.matches(runtime) else { return nil }
        let requests = current.normalizedTrackedRequests.map { request in
            var request = request
            request.blocksInput = false
            return request
        }
        return CodexPermissionState(
            phase: .resumed,
            identity: current.identity,
            runtime: runtime,
            revision: revision,
            notificationID: current.notificationID,
            resolvedIdentities: current.resolvedIdentities,
            startedIdentities: current.startedIdentities ?? [],
            trackedRequests: requests
        )
    }

    private func acceptNeedsInput(
        current: CodexPermissionState?,
        identity: CodexPermissionSignalIdentity,
        runtime: CodexPermissionRuntimeGeneration,
        revisionWatermark: UInt64?,
        notificationID: UUID?
    ) -> CodexPermissionTransition {
        let identity = identity.correlatedToUniqueActiveToolStart(
            in: current?.startedIdentities ?? [],
            excluding: current?.resolvedIdentities ?? []
        )
        var requests = current?.normalizedTrackedRequests ?? []
        if let current {
            if current.resolvedIdentities.contains(where: { $0.exactlyMatches(identity) })
                || (current.phase == .resumed && current.identity.exactlyMatches(identity)) {
                return CodexPermissionTransition(state: current, effect: .none, accepted: false)
            }
            if let requestIndex = requests.firstIndex(where: {
                $0.identity.exactlyMatches(identity)
            }) {
                guard requests[requestIndex].blocksInput else {
                    return CodexPermissionTransition(state: current, effect: .none, accepted: false)
                }
                return reprojectNeedsInput(
                    current,
                    requests: requests,
                    requestIndex: requestIndex,
                    notificationID: notificationID
                )
            }
            if !identity.isScoped {
                if let requestIndex = requests.firstIndex(where: {
                    $0.blocksInput && !$0.identity.isScoped
                }) {
                    return reprojectNeedsInput(
                        current,
                        requests: requests,
                        requestIndex: requestIndex,
                        notificationID: notificationID
                    )
                }
                return CodexPermissionTransition(state: current, effect: .none, accepted: false)
            }
        }

        guard appendTrackedRequest(
            CodexPermissionRequest(
                identity: identity,
                notificationID: notificationID,
                blocksInput: true
            ),
            to: &requests
        ) else {
            if let current {
                return CodexPermissionTransition(state: current, effect: .none, accepted: false)
            }
            return ignoredTransition(current: nil, identity: identity, runtime: runtime)
        }
        let state = CodexPermissionState(
            phase: .needsInput,
            identity: identity,
            runtime: runtime,
            revision: nextRevision(after: current, watermark: revisionWatermark),
            notificationID: notificationID,
            resolvedIdentities: current?.resolvedIdentities ?? [],
            startedIdentities: current?.startedIdentities ?? [],
            trackedRequests: requests
        )
        return CodexPermissionTransition(state: state, effect: .projectNeedsInput, accepted: true)
    }

    private func reprojectNeedsInput(
        _ current: CodexPermissionState,
        requests: [CodexPermissionRequest],
        requestIndex: Int,
        notificationID: UUID?
    ) -> CodexPermissionTransition {
        var requests = requests
        if requests[requestIndex].notificationID == nil {
            requests[requestIndex].notificationID = notificationID
        }
        let request = requests[requestIndex]
        var state = current
        state.phase = .needsInput
        state.identity = request.identity
        state.notificationID = request.notificationID
        state.trackedRequests = requests
        return CodexPermissionTransition(state: state, effect: .projectNeedsInput, accepted: true)
    }

    private func acceptToolStarted(
        current: CodexPermissionState?,
        identity: CodexPermissionSignalIdentity,
        runtime: CodexPermissionRuntimeGeneration,
        revisionWatermark: UInt64?
    ) -> CodexPermissionTransition {
        guard identity.isScoped else {
            return ignoredTransition(current: current, identity: identity, runtime: runtime)
        }
        var started = current?.startedIdentities ?? []
        appendBounded(identity, to: &started, maximumCount: maximumStartedIdentities)
        let requests = current?.normalizedTrackedRequests ?? []
        let pendingRequest = requests.last(where: \.blocksInput)
        let state = CodexPermissionState(
            phase: pendingRequest == nil ? .toolStarted : .needsInput,
            identity: pendingRequest?.identity ?? identity,
            runtime: runtime,
            revision: nextRevision(after: current, watermark: revisionWatermark),
            notificationID: pendingRequest?.notificationID ?? current?.notificationID,
            resolvedIdentities: current?.resolvedIdentities ?? [],
            startedIdentities: started,
            trackedRequests: requests
        )
        return CodexPermissionTransition(state: state, effect: .none, accepted: true)
    }

    private func acceptToolCompleted(
        current: CodexPermissionState?,
        identity: CodexPermissionSignalIdentity,
        runtime: CodexPermissionRuntimeGeneration,
        revisionWatermark: UInt64?
    ) -> CodexPermissionTransition {
        guard identity.isScoped else {
            return ignoredTransition(current: current, identity: identity, runtime: runtime)
        }
        if let current,
           current.resolvedIdentities.contains(where: { $0.exactlyMatches(identity) }) {
            return CodexPermissionTransition(state: current, effect: .none, accepted: false)
        }

        var resolved = current?.resolvedIdentities ?? []
        appendBounded(identity, to: &resolved, maximumCount: maximumResolvedIdentities)
        var requests = current?.normalizedTrackedRequests ?? []
        let resolvedRequest: CodexPermissionRequest? = {
            guard let index = requests.firstIndex(where: {
                $0.identity.exactlyMatches(identity)
            }) else {
                return nil
            }
            return requests.remove(at: index)
        }()
        let pendingRequest = requests.last(where: \.blocksInput)
        let resolvesFinalBlockingRequest = resolvedRequest?.blocksInput == true
            && pendingRequest == nil
        let effect: CodexPermissionTransitionEffect
        if resolvesFinalBlockingRequest {
            effect = .resolveNeedsInput
        } else if resolvedRequest != nil {
            effect = .resolvePermission
        } else {
            effect = .none
        }
        let state = CodexPermissionState(
            phase: pendingRequest == nil ? .resumed : .needsInput,
            identity: pendingRequest?.identity ?? identity,
            runtime: runtime,
            revision: nextRevision(after: current, watermark: revisionWatermark),
            notificationID: pendingRequest?.notificationID ?? resolvedRequest?.notificationID,
            resolvedIdentities: resolved,
            startedIdentities: current?.startedIdentities ?? [],
            trackedRequests: requests
        )
        return CodexPermissionTransition(
            state: state,
            effect: effect,
            accepted: true,
            resolvedNotificationID: resolvedRequest?.notificationID
        )
    }

    private func ignoredTransition(
        current: CodexPermissionState?,
        identity: CodexPermissionSignalIdentity,
        runtime: CodexPermissionRuntimeGeneration
    ) -> CodexPermissionTransition {
        if let current {
            return CodexPermissionTransition(state: current, effect: .none, accepted: false)
        }
        let ignored = CodexPermissionState(
            phase: .toolStarted,
            identity: identity,
            runtime: runtime,
            revision: 0
        )
        return CodexPermissionTransition(state: ignored, effect: .none, accepted: false)
    }

    private func appendBounded(
        _ identity: CodexPermissionSignalIdentity,
        to identities: inout [CodexPermissionSignalIdentity],
        maximumCount: Int
    ) {
        identities.removeAll { $0.exactlyMatches(identity) }
        identities.append(identity)
        if identities.count > maximumCount {
            identities.removeFirst(identities.count - maximumCount)
        }
    }

    private func appendTrackedRequest(
        _ request: CodexPermissionRequest,
        to requests: inout [CodexPermissionRequest]
    ) -> Bool {
        requests.removeAll { $0.identity.exactlyMatches(request.identity) }
        while requests.count >= maximumTrackedRequests,
              let nonblockingIndex = requests.firstIndex(where: { !$0.blocksInput }) {
            requests.remove(at: nonblockingIndex)
        }
        guard requests.count < maximumTrackedRequests else { return false }
        requests.append(request)
        return true
    }

    private func nextRevision(
        after current: CodexPermissionState?,
        watermark: UInt64?
    ) -> UInt64 {
        let revision = max(current?.revision ?? 0, watermark ?? 0)
        return revision == UInt64.max ? UInt64.max : revision + 1
    }
}
