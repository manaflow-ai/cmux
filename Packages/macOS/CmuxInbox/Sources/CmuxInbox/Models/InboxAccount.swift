public import Foundation

/// A local account record for one inbox source.
public struct InboxAccount: Codable, Equatable, Identifiable, Sendable {
    /// Source service for this account.
    public let source: InboxSource
    /// Source-specific account id, such as an email address, workspace id, or helper id.
    public let accountID: String
    /// Human-readable account name shown in UI.
    public var displayName: String
    /// Current account or connector status.
    public var status: InboxAccountStatus
    /// Optional user-safe explanation for the current status.
    public var statusMessage: String?
    /// Last successful sync timestamp.
    public var lastSyncAt: Date?
    /// Capabilities supported by this account.
    public var capabilities: Set<InboxConnectorCapability>
    /// Whether cmux-native notifications are enabled for this source account.
    public var notificationsEnabled: Bool

    /// Stable identity for SwiftUI and JSON clients.
    public var id: String { "\(source.rawValue):\(accountID)" }

    /// Creates an account status record.
    /// - Parameters:
    ///   - source: Source service for this account.
    ///   - accountID: Source-specific account id.
    ///   - displayName: Human-readable account name.
    ///   - status: Current account or connector status.
    ///   - statusMessage: Optional user-safe explanation for the current status.
    ///   - lastSyncAt: Last successful sync timestamp.
    ///   - capabilities: Capabilities supported by this account.
    ///   - notificationsEnabled: Whether cmux-native notifications are enabled.
    public init(
        source: InboxSource,
        accountID: String,
        displayName: String,
        status: InboxAccountStatus,
        statusMessage: String? = nil,
        lastSyncAt: Date? = nil,
        capabilities: Set<InboxConnectorCapability>,
        notificationsEnabled: Bool = true
    ) {
        self.source = source
        self.accountID = accountID
        self.displayName = displayName
        self.status = status
        self.statusMessage = statusMessage
        self.lastSyncAt = lastSyncAt
        self.capabilities = capabilities
        self.notificationsEnabled = notificationsEnabled
    }
}
