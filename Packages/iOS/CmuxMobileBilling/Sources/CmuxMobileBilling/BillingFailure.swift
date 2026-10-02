import Foundation

/// A billing failure, classified for the plans screen and analytics.
public enum BillingFailure: Error, Sendable, Equatable {
    /// No cmux session.
    case notSignedIn
    /// The App Store or the cmux server was unreachable.
    case network
    /// The cmux server rejected the request.
    case server(statusCode: Int)
    /// A response did not match the contract.
    case invalidResponse
    /// StoreKit could not verify the transaction's signature.
    case unverified
    /// The product is not on sale in this storefront or build.
    case productUnavailable
    /// The device cannot make payments.
    case purchasesNotAllowed
    /// The server does not allow App Store purchases for this account.
    case notEligible
    /// Any other StoreKit failure.
    case store

    /// Classifies an error thrown by a ``BillingAPI`` or ``StoreKitClient``.
    /// - Parameter error: The thrown error.
    public init(_ error: any Error) {
        switch error {
        case let failure as BillingFailure:
            self = failure
        case let api as BillingAPIError:
            switch api {
            case .notSignedIn: self = .notSignedIn
            case .transport: self = .network
            case .rejected(let status): self = .server(statusCode: status)
            case .invalidURL, .invalidResponse: self = .invalidResponse
            }
        case let store as StoreKitClientError:
            switch store {
            case .productUnavailable: self = .productUnavailable
            case .purchasesNotAllowed: self = .purchasesNotAllowed
            case .network: self = .network
            case .userCancelled, .system: self = .store
            }
        default:
            self = .store
        }
    }

    /// A short stable code for the analytics `reason` property.
    public var analyticsReason: String {
        switch self {
        case .notSignedIn: "not_signed_in"
        case .network: "network"
        case .server(let status): "server_\(status)"
        case .invalidResponse: "invalid_response"
        case .unverified: "unverified"
        case .productUnavailable: "product_unavailable"
        case .purchasesNotAllowed: "purchases_not_allowed"
        case .notEligible: "not_eligible"
        case .store: "store"
        }
    }
}
