import Foundation

/// A failed call to the billing routes.
public enum BillingAPIError: Error, Sendable, Equatable {
    /// No Stack session; the call was not sent.
    case notSignedIn
    /// The configured origin or path is not a valid URL.
    case invalidURL
    /// The request did not reach the server or got no response.
    case transport
    /// The server answered with a non-2xx status.
    case rejected(statusCode: Int)
    /// `403 account_mismatch`: the transaction's subscription belongs to
    /// another cmux account.
    case accountMismatch
    /// The server's 2xx body did not match the contract.
    case invalidResponse
}
