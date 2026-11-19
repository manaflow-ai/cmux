import Foundation

/// Which billing system grants the account's current plan.
public enum BillingPlanSource: Sendable, Equatable, Codable {
    /// A web (Stripe) subscription.
    case stripe
    /// An App Store subscription.
    case apple
    /// No paid plan.
    case none
    /// A source this build does not know.
    case other(String)

    /// Creates a source from the server's value.
    /// - Parameter rawValue: The `currentPlan.source` string.
    public init(rawValue: String) {
        switch rawValue {
        case "stripe": self = .stripe
        case "apple": self = .apple
        case "none": self = .none
        default: self = .other(rawValue)
        }
    }

    /// The server's value for this source.
    public var rawValue: String {
        switch self {
        case .stripe: "stripe"
        case .apple: "apple"
        case .none: "none"
        case .other(let value): value
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
