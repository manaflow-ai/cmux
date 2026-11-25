import Foundation

/// The state of the current purchase attempt.
public enum BillingPurchasePhase: Sendable, Equatable {
    /// No purchase attempt to show.
    case idle
    /// The App Store purchase sheet is up, or the server is verifying.
    case purchasing(productID: String)
    /// The purchase waits for approval (Ask to Buy). The result arrives
    /// through the transaction listener.
    case pending(productID: String)
    /// The server accepted the purchase and granted the plan.
    case completed(BillingPlanID)
    /// The App Store completed the purchase but the server has not accepted
    /// it yet. It stays unfinished and is retried; the plan applies then.
    case awaitingServer(productID: String)
    /// The purchase failed.
    case failed(BillingFailure)

    /// True while a pending or server-awaiting purchase of `productID` waits
    /// for its transaction to be delivered.
    func isWaiting(for productID: String) -> Bool {
        switch self {
        case .pending(let waiting), .awaitingServer(let waiting): waiting == productID
        default: false
        }
    }

    /// True while a purchase call is running.
    public var isPurchasing: Bool {
        if case .purchasing = self { return true }
        return false
    }
}
