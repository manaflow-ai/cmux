import Foundation

/// The load state of the account-token response.
public enum BillingAccountState: Sendable, Equatable {
    /// Not loaded yet.
    case idle
    /// A load is running and nothing was loaded before.
    case loading
    /// The latest successful load.
    case loaded(BillingAccount)
    /// The load failed and nothing was loaded before.
    case failed(BillingFailure)

    /// The loaded account, if any.
    public var account: BillingAccount? {
        if case .loaded(let account) = self { return account }
        return nil
    }
}
