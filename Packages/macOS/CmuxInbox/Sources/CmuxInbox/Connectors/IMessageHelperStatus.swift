public import Foundation

/// Parsed status returned by the `cmux-imsg` helper.
public struct IMessageHelperStatus: Codable, Equatable, Sendable {
    /// Whether the helper can read and send.
    public var ok: Bool
    /// User-safe status message.
    public var message: String?
    /// Last helper sync timestamp.
    public var lastSyncAt: Date?
    /// Whether the helper reported denied Messages permissions.
    public var permissionDenied: Bool

    /// Creates a helper status.
    public init(ok: Bool, message: String? = nil, lastSyncAt: Date? = nil, permissionDenied: Bool = false) {
        self.ok = ok
        self.message = message
        self.lastSyncAt = lastSyncAt
        self.permissionDenied = permissionDenied
    }
}
