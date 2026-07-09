internal import Foundation

/// Stable identity for one logical attachment generation within a remote PTY session.
struct RemotePTYLifecycleKey: Hashable, Sendable {
    let sessionID: String
    let lifecycleID: String

    init(sessionID: String, lifecycleID: String) {
        self.sessionID = Self.normalized(sessionID)
        self.lifecycleID = Self.normalized(lifecycleID)
    }

    private static func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return UUID(uuidString: trimmed)?.uuidString.lowercased() ?? trimmed
    }
}
