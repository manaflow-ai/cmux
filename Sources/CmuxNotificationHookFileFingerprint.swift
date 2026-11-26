import Foundation

/// Captures metadata and a content digest used to invalidate cached hook configuration.
struct CmuxNotificationHookFileFingerprint: Equatable {
    let path: String
    let exists: Bool
    let fileSize: UInt64
    let modificationDate: Date?
    let fileIdentifier: UInt64?
    let contentDigest: Data?
}
