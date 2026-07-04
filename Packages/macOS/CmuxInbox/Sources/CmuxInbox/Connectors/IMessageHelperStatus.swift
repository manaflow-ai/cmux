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
    /// Whether the helper binary is installed and executable. Drives the
    /// missing-helper UI state through a typed field instead of message text.
    public var helperInstalled: Bool
    /// Whether the data source is unavailable on this OS version (e.g. macOS 26
    /// no longer keeps a readable notification database). Distinct from a
    /// permission problem: no user action can resolve it.
    public var unsupported: Bool

    /// Creates a helper status.
    public init(
        ok: Bool,
        message: String? = nil,
        lastSyncAt: Date? = nil,
        permissionDenied: Bool = false,
        helperInstalled: Bool = true,
        unsupported: Bool = false
    ) {
        self.ok = ok
        self.message = message
        self.lastSyncAt = lastSyncAt
        self.permissionDenied = permissionDenied
        self.helperInstalled = helperInstalled
        self.unsupported = unsupported
    }
}
