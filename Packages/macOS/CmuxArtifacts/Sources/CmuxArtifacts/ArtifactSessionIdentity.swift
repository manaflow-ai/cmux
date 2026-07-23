import Foundation

/// Composite provider and native-session identity used by movable session markers.
struct ArtifactSessionIdentity: Equatable, Sendable {
    let provider: String?
    let sessionID: String?

    init(provider: String?, sessionID: String?) {
        self.provider = Self.normalized(provider, lowercased: true)
        self.sessionID = Self.normalized(sessionID, lowercased: false)
    }

    private static func normalized(_ value: String?, lowercased: Bool) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return lowercased ? value.lowercased() : value
    }
}
