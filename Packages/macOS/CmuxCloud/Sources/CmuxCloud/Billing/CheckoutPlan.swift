import Foundation

/// Which subscription a checkout starts. The raw value is the server's
/// `plan` query parameter on `/api/billing/checkout`; Pro is the server
/// default, so it sends no parameter and older web deploys keep working.
public enum CheckoutPlan: String, Sendable {
    case go
    case pro
    case max

    static let queryParam = "plan"

    /// `url` with this plan's `plan` query item (none for Pro).
    public nonisolated func applying(to url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == Self.queryParam }
        if self != .pro {
            queryItems.append(URLQueryItem(name: Self.queryParam, value: rawValue))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url ?? url
    }
}
