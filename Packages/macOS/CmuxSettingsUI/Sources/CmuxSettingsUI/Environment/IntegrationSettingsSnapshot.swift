import Foundation

public enum IntegrationSettingsSource: String, CaseIterable, Identifiable, Sendable, Hashable {
    case agent
    case gmail
    case slack
    case discord
    case imessage
    case generic

    public var id: String { rawValue }

    /// Whether this source offers a native one-click sign-in (vs. token paste).
    public var supportsNativeSignIn: Bool { self == .gmail }
}

/// Outcome of a native provider sign-in (e.g. Google OAuth).
public enum IntegrationSignInResult: Sendable, Equatable {
    /// Sign-in completed and the account is connected.
    case connected(IntegrationAccountSettingsSnapshot)
    /// The user cancelled or closed the browser flow.
    case cancelled
    /// This source has no native sign-in flow.
    case unsupported
    /// The flow could not start; the message explains what to configure.
    case unavailable(String)
    /// The flow started but failed; the message is user-safe.
    case failed(String)
}

public struct IntegrationAccountSettingsSnapshot: Identifiable, Equatable, Sendable {
    public let source: IntegrationSettingsSource
    public let accountID: String
    public let displayName: String
    public let status: String
    public let statusMessage: String?
    public let credentialState: String
    public let capabilities: [String]
    public let lastSyncDescription: String?
    public let notificationsEnabled: Bool

    public var id: String { "\(source.rawValue):\(accountID)" }

    public init(
        source: IntegrationSettingsSource,
        accountID: String,
        displayName: String,
        status: String,
        statusMessage: String?,
        credentialState: String,
        capabilities: [String],
        lastSyncDescription: String?,
        notificationsEnabled: Bool
    ) {
        self.source = source
        self.accountID = accountID
        self.displayName = displayName
        self.status = status
        self.statusMessage = statusMessage
        self.credentialState = credentialState
        self.capabilities = capabilities
        self.lastSyncDescription = lastSyncDescription
        self.notificationsEnabled = notificationsEnabled
    }
}

public struct IntegrationSettingsSnapshot: Equatable, Sendable {
    public let accounts: [IntegrationAccountSettingsSnapshot]
    public let unreadCounts: [IntegrationSettingsSource: Int]

    public init(
        accounts: [IntegrationAccountSettingsSnapshot] = [],
        unreadCounts: [IntegrationSettingsSource: Int] = [:]
    ) {
        self.accounts = accounts
        self.unreadCounts = unreadCounts
    }

    public func accounts(for source: IntegrationSettingsSource) -> [IntegrationAccountSettingsSnapshot] {
        accounts.filter { $0.source == source }
    }

    public func unreadCount(for source: IntegrationSettingsSource) -> Int {
        unreadCounts[source] ?? 0
    }
}
