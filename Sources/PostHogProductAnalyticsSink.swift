import CMUXMobileCore
import CmuxProductAnalytics
import Foundation

/// Sends ``ProductAnalytics`` output through the app's PostHog SDK, which
/// owns batching, retries and the on-disk queue for offline launches.
struct PostHogProductAnalyticsSink: AnalyticsEmitting {
    let analytics: PostHogAnalytics

    func capture(_ event: String, _ properties: [String: AnalyticsValue]) {
        analytics.capture(event, properties: Self.plain(properties))
    }

    /// The PostHog person and its team group (identify, group, reset) have
    /// one owner, the sign-in identity observer, which uses the same Stack
    /// user id: a group lasts until `reset()`, so only that owner can clear it
    /// on sign-out. Product analytics only adds events and context.
    func identify(userId: String?, alias: String?, properties: [String: AnalyticsValue]) {}

    func setSuperProperties(_ properties: [String: AnalyticsValue]) {
        analytics.register(Self.plain(properties))
    }

    func flush() async {}

    static func plain(_ properties: [String: AnalyticsValue]) -> [String: Any] {
        properties.mapValues { $0.jsonObject }
    }
}
