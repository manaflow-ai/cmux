import CmuxSettings
import Foundation

/// Checkout attribution query parameters: the upgrade source plus the app's
/// client, release channel, version and build. Mirrors
/// `web/services/analytics/checkoutAttribution.ts`.
/// lint:allow namespace-type: moved unchanged from the app target, where it was an internal static namespace; reshaping it is a separate change from this package move.
public enum CheckoutAttribution: Sendable {
    static let sourceParam = "cmux_source"
    static let clientParam = "cmux_client"
    static let channelParam = "cmux_channel"
    static let appVersionParam = "cmux_app_version"
    static let appBuildParam = "cmux_app_build"
    static let paramNames: [String] = [sourceParam, clientParam, channelParam, appVersionParam, appBuildParam]

    public nonisolated static func queryItems(
        source: ProUpgradeSource,
        flavor: BuildFlavor = BuildFlavor.current,
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: sourceParam, value: source.rawValue),
            URLQueryItem(name: clientParam, value: "mac"),
            URLQueryItem(name: channelParam, value: flavor.rawValue),
        ]
        if let version = infoDictionary["CFBundleShortVersionString"] as? String, !version.isEmpty {
            items.append(URLQueryItem(name: appVersionParam, value: version))
        }
        if let build = infoDictionary["CFBundleVersion"] as? String, !build.isEmpty {
            items.append(URLQueryItem(name: appBuildParam, value: build))
        }
        return items
    }

    /// Replace any attribution already on `url` with this source's.
    public nonisolated static func applying(
        to url: URL,
        source: ProUpgradeSource,
        flavor: BuildFlavor = BuildFlavor.current,
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { paramNames.contains($0.name) }
        queryItems.append(contentsOf: self.queryItems(source: source, flavor: flavor, infoDictionary: infoDictionary))
        components.queryItems = queryItems
        return components.url ?? url
    }

    /// PostHog properties for the Mac-side intent event, so the funnel has a
    /// client-side count of upgrade clicks per surface and channel even before
    /// the web page loads.
    public nonisolated static func intentProperties(
        source: ProUpgradeSource,
        flavor: BuildFlavor = BuildFlavor.current,
        plan: CheckoutPlan = .pro
    ) -> [String: Any] {
        ["source": source.rawValue, "client": "mac", "channel": flavor.rawValue, "plan": plan.rawValue]
    }

    /// The checkout URL for `plan`, attributed to `source`.
    ///
    /// - Parameters:
    ///   - source: The surface that started the upgrade.
    ///   - plan: The subscription to check out; Pro sends no `plan` parameter.
    ///   - base: The checkout endpoint; defaults to this build's billing checkout URL.
    /// - Returns: `base` with the plan and attribution query items applied.
    public nonisolated static func checkoutURL(
        source: ProUpgradeSource,
        plan: CheckoutPlan = .pro,
        base: URL = AuthEnvironment.billingCheckoutURL
    ) -> URL {
        applying(to: plan.applying(to: base), source: source)
    }
}
