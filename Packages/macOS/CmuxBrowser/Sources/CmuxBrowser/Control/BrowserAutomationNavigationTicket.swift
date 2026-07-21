public import Foundation

/// Stable identity for one browser-automation navigation transaction.
public struct BrowserAutomationNavigationTicket: Sendable, Hashable {
    /// Identity of the WebView instance that owns the transaction.
    public let instanceID: UUID

    let transactionID: UUID

    init(instanceID: UUID, transactionID: UUID = UUID()) {
        self.instanceID = instanceID
        self.transactionID = transactionID
    }
}
