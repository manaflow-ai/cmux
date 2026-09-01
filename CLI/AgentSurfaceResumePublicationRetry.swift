import Foundation

/// Chooses a safe second publication attempt from app-owned binding generations.
struct AgentSurfaceResumePublicationRetry {
    enum BindingGeneration: Equatable {
        case missing
        /// A token minted by the app for the current surface owner generation.
        case owner(UUID)
        /// Compatibility fallback for apps that predate owner-generation payloads.
        case updatedAt(Double)
    }

    struct Preflight {
        let params: [String: Any]
        let generation: BindingGeneration
    }

    enum Decision {
        case alreadyApplied
        case retry(params: [String: Any])
        case superseded
    }

    func preflight(
        desiredParams: [String: Any],
        currentPayload: [String: Any]
    ) -> Preflight? {
        guard let current = currentBinding(in: currentPayload) else { return nil }
        return Preflight(
            params: guardedParams(desiredParams, generation: current.generation),
            generation: current.generation
        )
    }

    func decision(
        desiredParams: [String: Any],
        currentPayload: [String: Any],
        baselineGeneration: BindingGeneration
    ) -> Decision {
        guard let current = currentBinding(in: currentPayload) else {
            return .superseded
        }
        if let binding = current.binding,
           matchesDesiredSession(binding, desiredParams: desiredParams),
           current.generation != baselineGeneration {
            return .alreadyApplied
        }
        guard baselineGeneration != .missing else {
            return .superseded
        }
        guard current.generation == baselineGeneration else {
            return .superseded
        }
        return .retry(params: guardedParams(desiredParams, generation: baselineGeneration))
    }

    private func currentBinding(
        in payload: [String: Any]
    ) -> (generation: BindingGeneration, binding: [String: Any]?)? {
        let ownerGeneration: UUID?
        switch payload["resume_binding_generation"] {
        case nil, is NSNull:
            ownerGeneration = nil
        case let value as String:
            guard let parsed = UUID(uuidString: value) else { return nil }
            ownerGeneration = parsed
        default:
            return nil
        }
        switch payload["resume_binding"] {
        case .some(let binding as [String: Any]):
            if let ownerGeneration {
                return (.owner(ownerGeneration), binding)
            }
            guard let number = binding["updated_at"] as? NSNumber else { return nil }
            let updatedAt = number.doubleValue
            guard updatedAt.isFinite else { return nil }
            return (.updatedAt(updatedAt), binding)
        case .some(let value) where value is NSNull:
            return (
                ownerGeneration.map { BindingGeneration.owner($0) } ?? .missing,
                nil
            )
        default:
            return nil
        }
    }

    private func guardedParams(
        _ desiredParams: [String: Any],
        generation: BindingGeneration
    ) -> [String: Any] {
        var params = desiredParams
        switch generation {
        case .missing:
            params["_cmux_expect_missing_binding"] = true
            params.removeValue(forKey: "_cmux_expected_binding_updated_at")
            params.removeValue(forKey: "_cmux_expected_binding_generation")
        case .owner(let generation):
            params["_cmux_expected_binding_generation"] = generation.uuidString
            params.removeValue(forKey: "_cmux_expect_missing_binding")
            params.removeValue(forKey: "_cmux_expected_binding_updated_at")
        case .updatedAt(let updatedAt):
            params["_cmux_expected_binding_updated_at"] = updatedAt
            params.removeValue(forKey: "_cmux_expect_missing_binding")
            params.removeValue(forKey: "_cmux_expected_binding_generation")
        }
        return params
    }

    private func matchesDesiredSession(
        _ binding: [String: Any],
        desiredParams: [String: Any]
    ) -> Bool {
        ["kind", "checkpoint_id", "source"].allSatisfy { key in
            normalized(binding[key] as? String) == normalized(desiredParams[key] as? String)
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

/// Evaluates whether a surface binding still names the hook session whose
/// launch evidence is being reconciled.
struct AgentSurfaceResumeBindingOwnership {
    enum Match: Equatable {
        case matches
        case doesNotMatch
        case unavailable
    }

    private let kind: String
    private let sessionId: String

    init(kind: String, sessionId: String) {
        self.kind = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.sessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func evaluate(_ binding: [String: Any]) -> Match {
        guard let source = normalized(binding["source"] as? String)?.lowercased(),
              source == "agent-hook" else {
            return .doesNotMatch
        }
        guard let currentKind = normalized(binding["kind"] as? String)?.lowercased(),
              let currentSessionId = normalized(binding["checkpoint_id"] as? String) else {
            return .unavailable
        }
        return currentKind == kind && currentSessionId == sessionId
            ? .matches
            : .doesNotMatch
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
