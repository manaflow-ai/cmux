import CMUXMobileCore
import CmuxProductAnalytics
import Foundation

/// Sends ``ProductAnalytics`` output through the app's PostHog SDK, which
/// owns batching, retries and the on-disk queue for offline launches.
struct PostHogProductAnalyticsSink: ProductAnalyticsSink {
    let analytics: PostHogAnalytics

    func capture(_ event: String, _ properties: [String: AnalyticsValue]) {
        analytics.capture(event, properties: Self.plain(properties))
    }

    /// The PostHog person (identify on sign-in, reset on sign-out) has one
    /// owner, the sign-in identity observer, which uses the same Stack user
    /// id. Product analytics only adds the team group and context.
    func identify(userId: String?, alias: String?, properties: [String: AnalyticsValue]) {}

    func setSuperProperties(_ properties: [String: AnalyticsValue]) {
        analytics.register(Self.plain(properties))
    }

    func flush() async {}

    func group(type: String, key: String) {
        analytics.group(type: type, key: key)
    }

    static func plain(_ properties: [String: AnalyticsValue]) -> [String: Any] {
        properties.mapValues { $0.jsonObject }
    }
}
