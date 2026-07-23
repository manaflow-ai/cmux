/// Pure ordering rules shared by every CLI lane that observes a Codex approval.
struct CodexPermissionTransitionMachine {
    private static let maximumResolvedIdentities = 16
    private static let maximumStartedIdentities = 16

    static func reduce(
        current: CodexPermissionState?,
        event: CodexPermissionEvent,
        identity: CodexPermissionSignalIdentity,
        runtime: CodexPermissionRuntimeGeneration
    ) -> CodexPermissionTransition {
        if let current, !current.runtime.matches(runtime) {
            return CodexPermissionTransition(state: current, effect: .none, accepted: false)
        }

        switch event {
        case .permissionRequested:
            return acceptNeedsInput(current: current, identity: identity, runtime: runtime)
        case .toolStarted:
            return acceptToolStarted(current: current, identity: identity, runtime: runtime)
        case .toolCompleted:
            return acceptToolCompleted(current: current, identity: identity, runtime: runtime)
        }
    }

    private static func acceptNeedsInput(
        current: CodexPermissionState?,
        identity: CodexPermissionSignalIdentity,
        runtime: CodexPermissionRuntimeGeneration
    ) -> CodexPermissionTransition {
        let identity = identity.correlatedToUniqueActiveToolStart(
            in: current?.startedIdentities ?? [],
            excluding: current?.resolvedIdentities ?? []
        )
        if let current {
            if current.resolvedIdentities.contains(where: { $0.exactlyMatches(identity) })
                || (current.phase == .resumed && current.identity.exactlyMatches(identity)) {
                return CodexPermissionTransition(state: current, effect: .none, accepted: false)
            }
            if current.phase == .needsInput, current.identity.exactlyMatches(identity) {
                return CodexPermissionTransition(state: current, effect: .projectNeedsInput, accepted: true)
            }
            if !identity.isScoped {
                if current.phase == .needsInput, !current.identity.isScoped {
                    return CodexPermissionTransition(state: current, effect: .projectNeedsInput, accepted: true)
                }
                return CodexPermissionTransition(state: current, effect: .none, accepted: false)
            }
        }

        let state = CodexPermissionState(
            phase: .needsInput,
            identity: identity,
            runtime: runtime,
            revision: nextRevision(after: current),
            resolvedIdentities: current?.resolvedIdentities ?? [],
            startedIdentities: current?.startedIdentities ?? []
        )
        return CodexPermissionTransition(state: state, effect: .projectNeedsInput, accepted: true)
    }

    private static func acceptToolStarted(
        current: CodexPermissionState?,
        identity: CodexPermissionSignalIdentity,
        runtime: CodexPermissionRuntimeGeneration
    ) -> CodexPermissionTransition {
        guard identity.isScoped else {
            return ignoredTransition(current: current, identity: identity, runtime: runtime)
        }
        var started = current?.startedIdentities ?? []
        appendBounded(identity, to: &started, maximumCount: maximumStartedIdentities)
        let preservesPendingPermission = current?.phase == .needsInput
        let currentIdentity = current?.identity ?? identity
        let state = CodexPermissionState(
            phase: preservesPendingPermission ? .needsInput : .toolStarted,
            identity: preservesPendingPermission ? currentIdentity : identity,
            runtime: runtime,
            revision: nextRevision(after: current),
            resolvedIdentities: current?.resolvedIdentities ?? [],
            startedIdentities: started
        )
        return CodexPermissionTransition(state: state, effect: .none, accepted: true)
    }

    private static func acceptToolCompleted(
        current: CodexPermissionState?,
        identity: CodexPermissionSignalIdentity,
        runtime: CodexPermissionRuntimeGeneration
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
        let resolvesPendingPermission = current?.phase == .needsInput
            && current?.identity.exactlyMatches(identity) == true
        let preservesDifferentPermission = current?.phase == .needsInput
            && !resolvesPendingPermission
        let currentIdentity = current?.identity ?? identity
        let state = CodexPermissionState(
            phase: preservesDifferentPermission ? .needsInput : .resumed,
            identity: preservesDifferentPermission ? currentIdentity : identity,
            runtime: runtime,
            revision: nextRevision(after: current),
            resolvedIdentities: resolved,
            startedIdentities: current?.startedIdentities ?? []
        )
        return CodexPermissionTransition(
            state: state,
            effect: resolvesPendingPermission ? .resolveNeedsInput : .none,
            accepted: true
        )
    }

    private static func ignoredTransition(
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

    private static func appendBounded(
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

    private static func nextRevision(after current: CodexPermissionState?) -> UInt64 {
        (current?.revision ?? 0) == UInt64.max ? UInt64.max : (current?.revision ?? 0) + 1
    }
}
