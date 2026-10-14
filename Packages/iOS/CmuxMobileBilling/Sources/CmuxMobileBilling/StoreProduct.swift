import Foundation

/// A StoreKit product as the plans screen needs it.
///
/// ``displayPrice`` comes from StoreKit in the buyer's storefront currency;
/// the app never hardcodes a price.
public struct StoreProduct: Sendable, Equatable, Hashable, Identifiable {
    /// The App Store product id.
    public let id: String
    /// The App Store display name.
    public let displayName: String
    /// The App Store description.
    public let productDescription: String
    /// The localized price string, such as `$74.99`.
    public let displayPrice: String
    /// The localized renewal period, such as `month`; nil when unknown.
    public let periodUnitName: String?

    /// Creates a product value.
    /// - Parameters:
    ///   - id: The product id.
    ///   - displayName: The display name.
    ///   - productDescription: The description.
    ///   - displayPrice: The localized price.
    ///   - periodUnitName: The localized renewal period, when known.
    public init(
        id: String,
        displayName: String,
        productDescription: String,
        displayPrice: String,
        periodUnitName: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.productDescription = productDescription
        self.displayPrice = displayPrice
        self.periodUnitName = periodUnitName
    }
}
