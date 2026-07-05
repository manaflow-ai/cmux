public import Foundation

/// User-safe connector status returned to Settings, CLI, socket, and UI callers.
public struct InboxConnectorStatus: Codable, Equatable, Identifiable, Sendable {
    /// Source service.
    public let source: InboxSource
    /// Optional source account id.
    public let accountID: String?
    /// Optional display name.
    public let displayName: String?
    /// Status code.
    public let status: InboxAccountStatus
    /// User-safe status message.
    public let message: String?
    /// Redacted credential state.
    public let credentialState: InboxCredentialState
    /// Supported connector capabilities.
    public let capabilities: Set<InboxConnectorCapability>
    /// Last successful sync timestamp.
    public let lastSyncAt: Date?

    /// Stable identity for SwiftUI lists.
    public var id: String { "\(source.rawValue):\(accountID ?? "*")" }

    /// Creates a connector status.
    public init(
        source: InboxSource,
        accountID: String? = nil,
        displayName: String? = nil,
        status: InboxAccountStatus,
        message: String? = nil,
        credentialState: InboxCredentialState = .missing,
        capabilities: Set<InboxConnectorCapability>,
        lastSyncAt: Date? = nil
    ) {
        self.source = source
        self.accountID = accountID
        self.displayName = displayName
        self.status = status
        self.message = message
        self.credentialState = credentialState
        self.capabilities = capabilities
        self.lastSyncAt = lastSyncAt
    }
}
