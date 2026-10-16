import Foundation

/// Canonical lookup key for one managed agent session owner.
struct LiveAgentSessionOwnerSessionKey: Hashable, Sendable {
    let kind: String
    let sessionID: String

    init(kind: String, sessionID: String) {
        let normalizedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = normalizedKind
        self.sessionID = ManagedAgentSessionIdentity.canonicalSessionID(
            kind: normalizedKind,
            sessionID: sessionID
        )
    }
}
