import Foundation

/// Checks whether a surface binding still belongs to the hook session being reconciled.
struct AgentSurfaceResumeBindingOwnership {
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
