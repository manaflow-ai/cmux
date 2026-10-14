public import CMUXMobileCore

/// Where ``ProductAnalytics`` sends events: the shared ``AnalyticsEmitting``
/// seam plus PostHog group analytics for teams. The app's sink forwards to the
/// PostHog SDK; tests use a recording sink.
///
/// `identify(userId: nil, ...)` means sign-out. A sink that owns the person
/// identity resets it there; the Mac app's sink leaves identity to the app's
/// sign-in identity observer and ignores both calls.
public protocol ProductAnalyticsSink: AnalyticsEmitting {
    /// Associates later events with a group, such as `stack_team`.
    func group(type: String, key: String)
}
