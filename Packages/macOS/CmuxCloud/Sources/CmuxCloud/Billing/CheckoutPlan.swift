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

/// The billing period a checkout asks for. The raw value is the server's
/// `interval` query parameter. Pro is the only plan sold yearly; monthly is
/// the server default, so it sends no parameter.
public enum CheckoutInterval: String, Sendable {
    case month
    case year

    static let queryParam = "interval"

    /// `url` with this interval for `plan`: `interval=year` only for a
    /// yearly Pro checkout, and no `interval` otherwise.
    public nonisolated func applying(to url: URL, plan: CheckoutPlan) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == Self.queryParam }
        if self == .year && plan == .pro {
            queryItems.append(URLQueryItem(name: Self.queryParam, value: rawValue))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url ?? url
    }
}
