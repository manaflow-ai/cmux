import Foundation

/// Composite provider and native-session identity used by movable session markers.
struct ArtifactSessionIdentity: Equatable, Sendable {
    let provider: String?
    let sessionID: String?

    init(provider: String?, sessionID: String?) {
        let trimmedProvider = provider?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.provider = trimmedProvider?.isEmpty == false ? trimmedProvider?.lowercased() : nil
        let trimmedSessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sessionID = trimmedSessionID?.isEmpty == false ? trimmedSessionID : nil
    }
}
