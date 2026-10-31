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
    /// The numeric price in ``currencyCode``, for analytics; nil when unknown.
    public let price: Decimal?
    /// The ISO 4217 currency code of ``price``, such as `USD`; nil when unknown.
    public let currencyCode: String?
    /// For a yearly product, the yearly price divided by 12 in the
    /// storefront's currency format, such as `$58.33`; nil otherwise.
    public let monthlyEquivalentDisplayPrice: String?
    /// The product's free-trial introductory offer; nil when it has none.
    public let introductoryOffer: StoreIntroductoryOffer?

    /// Creates a product value.
    /// - Parameters:
    ///   - id: The product id.
    ///   - displayName: The display name.
    ///   - productDescription: The description.
    ///   - displayPrice: The localized price.
    ///   - periodUnitName: The localized renewal period, when known.
    ///   - price: The numeric price, when known.
    ///   - currencyCode: The ISO 4217 currency code of `price`, when known.
    ///   - monthlyEquivalentDisplayPrice: A yearly product's per-month price.
    ///   - introductoryOffer: The product's introductory offer, when it has one.
    public init(
        id: String,
        displayName: String,
        productDescription: String,
        displayPrice: String,
        periodUnitName: String? = nil,
        price: Decimal? = nil,
        currencyCode: String? = nil,
        monthlyEquivalentDisplayPrice: String? = nil,
        introductoryOffer: StoreIntroductoryOffer? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.productDescription = productDescription
        self.displayPrice = displayPrice
        self.periodUnitName = periodUnitName
        self.price = price
        self.currencyCode = currencyCode
        self.monthlyEquivalentDisplayPrice = monthlyEquivalentDisplayPrice
        self.introductoryOffer = introductoryOffer
    }
}
