public import Foundation

/// Stable identity for one browser-automation navigation transaction.
public struct BrowserAutomationNavigationTicket: Sendable, Hashable {
    /// Identity of the WebView instance that owns the transaction.
    public let instanceID: UUID

    let transactionID: UUID
    let transaction: BrowserAutomationNavigationTransaction

    @MainActor
    init(instanceID: UUID, transactionID: UUID = UUID()) {
        self.instanceID = instanceID
        self.transactionID = transactionID
        self.transaction = BrowserAutomationNavigationTransaction()
    }

    /// Returns whether two tickets identify the same navigation transaction.
    public static func == (
        lhs: BrowserAutomationNavigationTicket,
        rhs: BrowserAutomationNavigationTicket
    ) -> Bool {
        lhs.transactionID == rhs.transactionID
    }

    /// Hashes the stable identity of this navigation transaction.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(transactionID)
    }
}
