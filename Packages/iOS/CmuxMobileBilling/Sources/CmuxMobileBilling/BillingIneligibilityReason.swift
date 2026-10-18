import Foundation

/// Why the server does not let this account buy through the App Store.
///
/// The server sends a stable code; the app localizes it. Unknown codes keep
/// their raw value so the plans screen can still hide purchase buttons.
public enum BillingIneligibilityReason: Sendable, Equatable, Codable {
    /// The account already pays through a web (Stripe) subscription.
    case stripeSubscriptionActive
    /// A team pays for the account; its admin manages billing.
    case teamBilling
    /// This build's purchases would grant no plan (a TestFlight build against
    /// the production server), so nothing is on sale.
    case purchasesUnavailable
    /// A code this build does not know.
    case other(String)

    /// Creates a reason from the server's code.
    /// - Parameter code: The `reason` string from the account-token response.
    public init(code: String) {
        switch code {
        case "stripe_subscription_active": self = .stripeSubscriptionActive
        case "team_billing": self = .teamBilling
        case "purchases_unavailable": self = .purchasesUnavailable
        default: self = .other(code)
        }
    }

    /// The server's code for this reason.
    public var code: String {
        switch self {
        case .stripeSubscriptionActive: "stripe_subscription_active"
        case .teamBilling: "team_billing"
        case .purchasesUnavailable: "purchases_unavailable"
        case .other(let code): code
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(code: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(code)
    }
}
