import Foundation

/// Pure ordering rules shared by every CLI lane that observes a Codex approval.
struct CodexPermissionTransitionMachine {
    private static let maximumResolvedIdentities = 16
    private static let maximumStartedIdentities = 16

    static func reduce(
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

    private static func acceptNeedsInput(
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
        if let current {
            if current.resolvedIdentities.contains(where: { $0.exactlyMatches(identity) })
                || (current.phase == .resumed && current.identity.exactlyMatches(identity)) {
                return CodexPermissionTransition(state: current, effect: .none, accepted: false)
            }
            if current.phase == .needsInput, current.identity.exactlyMatches(identity) {
                return reprojectNeedsInput(current, notificationID: notificationID)
            }
            if !identity.isScoped {
                if current.phase == .needsInput, !current.identity.isScoped {
                    return reprojectNeedsInput(current, notificationID: notificationID)
                }
                return CodexPermissionTransition(state: current, effect: .none, accepted: false)
            }
        }

        let state = CodexPermissionState(
            phase: .needsInput,
            identity: identity,
            runtime: runtime,
            revision: nextRevision(after: current, watermark: revisionWatermark),
            notificationID: notificationID,
            resolvedIdentities: current?.resolvedIdentities ?? [],
            startedIdentities: current?.startedIdentities ?? []
        )
        return CodexPermissionTransition(state: state, effect: .projectNeedsInput, accepted: true)
    }

    private static func reprojectNeedsInput(
        _ current: CodexPermissionState,
        notificationID: UUID?
    ) -> CodexPermissionTransition {
        var state = current
        if state.notificationID == nil { state.notificationID = notificationID }
        return CodexPermissionTransition(state: state, effect: .projectNeedsInput, accepted: true)
    }

    private static func acceptToolStarted(
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
        let preservesPendingPermission = current?.phase == .needsInput
        let currentIdentity = current?.identity ?? identity
        let state = CodexPermissionState(
            phase: preservesPendingPermission ? .needsInput : .toolStarted,
            identity: preservesPendingPermission ? currentIdentity : identity,
            runtime: runtime,
            revision: nextRevision(after: current, watermark: revisionWatermark),
            notificationID: current?.notificationID,
            resolvedIdentities: current?.resolvedIdentities ?? [],
            startedIdentities: started
        )
        return CodexPermissionTransition(state: state, effect: .none, accepted: true)
    }

    private static func acceptToolCompleted(
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
        let resolvesPendingPermission = current?.phase == .needsInput
            && current?.identity.exactlyMatches(identity) == true
        let preservesDifferentPermission = current?.phase == .needsInput
            && !resolvesPendingPermission
        let currentIdentity = current?.identity ?? identity
        let state = CodexPermissionState(
            phase: preservesDifferentPermission ? .needsInput : .resumed,
            identity: preservesDifferentPermission ? currentIdentity : identity,
            runtime: runtime,
            revision: nextRevision(after: current, watermark: revisionWatermark),
            notificationID: current?.notificationID,
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

    private static func nextRevision(
        after current: CodexPermissionState?,
        watermark: UInt64?
    ) -> UInt64 {
        let revision = max(current?.revision ?? 0, watermark ?? 0)
        return revision == UInt64.max ? UInt64.max : revision + 1
    }
}
