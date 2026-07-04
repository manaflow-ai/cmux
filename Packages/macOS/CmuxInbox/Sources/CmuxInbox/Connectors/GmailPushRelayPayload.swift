import Foundation

/// Minimal trusted relay payload for Gmail Pub/Sub notifications.
public struct GmailPushRelayPayload: Codable, Equatable, Sendable {
    /// Local Gmail account id.
    public let accountID: String
    /// Gmail history id that the Mac should fetch directly.
    public let historyID: String

    /// Creates a Gmail relay payload.
    public init(accountID: String, historyID: String) {
        self.accountID = accountID
        self.historyID = historyID
    }
}
