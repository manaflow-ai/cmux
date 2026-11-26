public import CMUXMobileCore
import Sentry

/// Links a rare Feed callback stall to Sentry's existing masked replay context.
@MainActor
public struct MobileFeedScrollSentryReporter {
    private let consent: any AnalyticsConsentProviding
    private let capture: @MainActor (Event) -> String?

    /// Uses the already configured SDK and shared consent gate; never starts replay itself.
    public init(consent: any AnalyticsConsentProviding) {
        self.init(consent: consent) { event in
            guard SentrySDK.isEnabled else { return nil }
            return SentrySDK.capture(event: event).sentryIdString
        }
    }

    init(consent: any AnalyticsConsentProviding, capture: @escaping @MainActor (Event) -> String?) {
        self.consent = consent
        self.capture = capture
    }

    /// Captures numeric context after scrolling settles and returns a cross-platform event ID.
    ///
    /// The SDK may attach its sampled replay; replay availability is not guaranteed.
    /// No exception or captured user content is manufactured for the event.
    public func report(_ anomaly: MobileFeedScrollAnomaly) -> String? {
        guard consent.isTelemetryEnabled else { return nil }
        let event = Event(level: .error)
        event.message = SentryMessage(formatted: "Feed scroll callback stall")
        event.fingerprint = ["ios-feed-scroll-callback-stall-v1"]
        event.tags = ["feature": "feed", "measurement": "display_link_callback_gap"]
        event.context = ["feed_performance": [
            "window_id": anomaly.windowID,
            "callback_gap_max_ms": anomaly.maxGapMilliseconds,
            "callback_count": anomaly.callbackCount,
            "item_count": anomaly.itemCount,
        ]]
        return capture(event)
    }
}
