import Foundation

/// Authenticated host response retained for offline Feed restoration.
struct AgentFeedCachedSnapshot: Codable, Sendable {
    let ownerKey: String
    let macDeviceID: String
    let instanceTag: String?
    let displayName: String
    let responseData: Data
    let cachedAt: Date
}
