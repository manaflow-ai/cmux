import Foundation

/// Exact process generation carried by Codex permission evidence.
struct CodexPermissionRuntimeGeneration: Codable, Equatable, Sendable {
    let pid: Int
    let pidStartSeconds: Int64?
    let pidStartMicroseconds: Int64?

    func matches(_ other: Self) -> Bool {
        guard pid == other.pid else { return false }
        if let pidStartSeconds,
           let pidStartMicroseconds,
           let otherSeconds = other.pidStartSeconds,
           let otherMicroseconds = other.pidStartMicroseconds {
            return pidStartSeconds == otherSeconds && pidStartMicroseconds == otherMicroseconds
        }
        return true
    }
}

/// The strongest request scope Codex exposed on a hook payload.
struct CodexPermissionSignalIdentity: Codable, Equatable, Sendable {
    let turnID: String?
    let requestID: String?

    var isScoped: Bool { turnID != nil || requestID != nil }

    func exactlyMatches(_ other: Self) -> Bool {
        guard isScoped, other.isScoped else { return false }
        if requestID != nil || other.requestID != nil {
            guard requestID == other.requestID else { return false }
            if let turnID, let otherTurnID = other.turnID {
                return turnID == otherTurnID
            }
            return true
        }
        return turnID == other.turnID
    }
}

enum CodexPermissionPhase: String, Codable, Equatable, Sendable {
    case needsInput
    case resumed
}

/// Persisted permission phase for one Codex session/runtime generation.
struct CodexPermissionState: Codable, Equatable, Sendable {
    var phase: CodexPermissionPhase
    var identity: CodexPermissionSignalIdentity
    var runtime: CodexPermissionRuntimeGeneration
    var revision: UInt64
    var resolvedIdentities: [CodexPermissionSignalIdentity]

    init(
        phase: CodexPermissionPhase,
        identity: CodexPermissionSignalIdentity,
        runtime: CodexPermissionRuntimeGeneration,
        revision: UInt64 = 1,
        resolvedIdentities: [CodexPermissionSignalIdentity] = []
    ) {
        self.phase = phase
        self.identity = identity
        self.runtime = runtime
        self.revision = revision
        self.resolvedIdentities = resolvedIdentities
    }
}

enum CodexPermissionTransitionEffect: Equatable, Sendable {
    case none
    case projectNeedsInput
    case resolveNeedsInput
}

struct CodexPermissionTransition: Equatable, Sendable {
    let state: CodexPermissionState
    let effect: CodexPermissionTransitionEffect
    let accepted: Bool
}

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
