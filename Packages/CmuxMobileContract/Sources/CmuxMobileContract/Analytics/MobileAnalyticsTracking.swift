import Foundation

/// A seam for capturing mobile analytics events.
///
/// Consumers depend on this protocol rather than the concrete client so analytics can be faked
/// or no-oped in tests and previews.
@MainActor
public protocol MobileAnalyticsTracking {
    /// Captures an analytics event with its property bag.
    ///
    /// - Parameters:
    ///   - event: The event name to capture.
    ///   - properties: The property bag attached to the event.
    func capture(event: MobileAnalyticsEventName, properties: MobileAnalyticsProperties)
}
