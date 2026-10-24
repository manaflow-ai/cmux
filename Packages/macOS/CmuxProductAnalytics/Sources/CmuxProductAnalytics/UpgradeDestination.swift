/// Where an upgrade click sends the user.
public enum UpgradeDestination: String, Sendable, CaseIterable {
    /// The in-app pricing page, which links to checkout.
    case pricingPage = "pricing_page"
    /// The billing checkout route directly.
    case checkout
}
