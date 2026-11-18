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

    /// Whether first-run setup skips its plans page: the account can't buy in the app (billed
    /// on the web or by a team, or the App Store sells nothing to this build), already pays, or
    /// the account didn't load. Not skipped while it loads: the page shows its own spinner.
    public var setupSkipsPlans: Bool {
        switch self {
        case .idle, .loading: false
        case .failed: true
        case .loaded(let account):
            !account.eligible || account.currentPlan.planID != .free || account.products.isEmpty
        }
    }
}
