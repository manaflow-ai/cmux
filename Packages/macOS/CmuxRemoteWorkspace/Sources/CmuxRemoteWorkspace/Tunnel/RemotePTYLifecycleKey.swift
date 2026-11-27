internal import Foundation

/// Stable identity for one logical attachment generation within a remote PTY session.
struct RemotePTYLifecycleKey: Hashable, Sendable {
    let sessionID: String
    let lifecycleID: String

    init(sessionID: String, lifecycleID: String) {
        self.sessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.lifecycleID = Self.normalizedLifecycleID(lifecycleID)
    }

    private static func normalizedLifecycleID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return UUID(uuidString: trimmed)?.uuidString.lowercased() ?? trimmed
    }
}
