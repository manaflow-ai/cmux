import Foundation

/// Errors a ``StoreKitClient`` normalizes from StoreKit.
public enum StoreKitClientError: Error, Sendable, Equatable {
    /// The product id is not available in this storefront or build.
    case productUnavailable
    /// The user cancelled a StoreKit prompt.
    case userCancelled
    /// The device cannot make payments (Screen Time, MDM).
    case purchasesNotAllowed
    /// StoreKit could not reach the App Store.
    case network
    /// Any other StoreKit failure.
    case system
}
