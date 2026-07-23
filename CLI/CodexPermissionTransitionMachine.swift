/// Pure ordering rules shared by every CLI lane that observes a Codex approval.
struct CodexPermissionTransitionMachine {
    private static let maximumResolvedIdentities = 16

    static func reduce(
        current: CodexPermissionState?,
        phase: CodexPermissionPhase,
        identity: CodexPermissionSignalIdentity,
        runtime: CodexPermissionRuntimeGeneration
    ) -> CodexPermissionTransition {
        if let current, !current.runtime.matches(runtime) {
            return CodexPermissionTransition(state: current, effect: .none, accepted: false)
        }

        switch phase {
        case .needsInput:
            return acceptNeedsInput(current: current, identity: identity, runtime: runtime)
        case .resumed:
            return acceptResume(current: current, identity: identity, runtime: runtime)
        }
    }

    private static func acceptNeedsInput(
        current: CodexPermissionState?,
        identity: CodexPermissionSignalIdentity,
        runtime: CodexPermissionRuntimeGeneration
    ) -> CodexPermissionTransition {
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
            resolvedIdentities: current?.resolvedIdentities ?? []
        )
        return CodexPermissionTransition(state: state, effect: .projectNeedsInput, accepted: true)
    }

    private static func acceptResume(
        current: CodexPermissionState?,
        identity: CodexPermissionSignalIdentity,
        runtime: CodexPermissionRuntimeGeneration
    ) -> CodexPermissionTransition {
        guard identity.isScoped else {
            if let current {
                return CodexPermissionTransition(state: current, effect: .none, accepted: false)
            }
            let ignored = CodexPermissionState(
                phase: .resumed,
                identity: identity,
                runtime: runtime,
                revision: 0
            )
            return CodexPermissionTransition(state: ignored, effect: .none, accepted: false)
        }

        if let current, current.phase == .needsInput,
           !current.identity.exactlyMatches(identity) {
            return CodexPermissionTransition(state: current, effect: .none, accepted: false)
        }
        if let current,
           current.resolvedIdentities.contains(where: { $0.exactlyMatches(identity) }) {
            return CodexPermissionTransition(state: current, effect: .none, accepted: false)
        }

        var resolved = current?.resolvedIdentities ?? []
        resolved.removeAll { $0.exactlyMatches(identity) }
        resolved.append(identity)
        if resolved.count > maximumResolvedIdentities {
            resolved.removeFirst(resolved.count - maximumResolvedIdentities)
        }
        let effect: CodexPermissionTransitionEffect = current?.phase == .needsInput
            ? .resolveNeedsInput
            : .none
        let state = CodexPermissionState(
            phase: .resumed,
            identity: identity,
            runtime: runtime,
            revision: nextRevision(after: current),
            resolvedIdentities: resolved
        )
        return CodexPermissionTransition(state: state, effect: effect, accepted: true)
    }

    private static func nextRevision(after current: CodexPermissionState?) -> UInt64 {
        (current?.revision ?? 0) == UInt64.max ? UInt64.max : (current?.revision ?? 0) + 1
    }
}
