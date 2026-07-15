import Foundation

/// Captures the file metadata used to invalidate cached notification-hook configuration.
struct CmuxNotificationHookFileFingerprint: Equatable {
    let path: String
    let exists: Bool
    let fileSize: UInt64
    let modificationDate: Date?
    let fileIdentifier: UInt64?
}
