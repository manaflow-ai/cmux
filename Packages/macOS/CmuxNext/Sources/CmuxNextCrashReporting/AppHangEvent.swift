import Foundation
public import Sentry

/// A Sentry app-hang event built from a main-thread watchdog episode
/// (``AppHangReporter``): the main thread's stack sampled while it was still
/// blocked, every other thread's stack, and the debug images that hold them.
///
/// It has the shape of the SDK's own app-hang event (exception type
/// `App Hanging`, mechanism `AppHang`, `SentryANRTrackingIntegration`), so
/// the app-hang issues, alerts and filters that existed while the SDK's ANR
/// thread ran keep working after that thread is off (``CrashReporter/options()``).
public nonisolated struct AppHangEvent: Sendable {
    /// How long the main thread had been blocked when the event was made.
    public let duration: Duration
    /// True when the main thread was still blocked (sent at the threshold);
    /// false when it had answered again and ``duration`` is exact.
    public let ongoing: Bool
    /// The main thread's return addresses, innermost first (the watchdog's sample).
    public let addresses: [UInt]
    /// Every other thread's stack (name, return addresses innermost first).
    public let otherThreads: [(name: String, addresses: [UInt])]

    public init(duration: Duration, ongoing: Bool, addresses: [UInt], otherThreads: [(name: String, addresses: [UInt])] = []) {
        self.duration = duration
        self.ongoing = ongoing
        self.addresses = addresses
        self.otherThreads = otherThreads
    }

    /// The SDK's exception type for an app hang.
    public static let exceptionType = "App Hanging"
    /// The SDK's mechanism type for an app hang.
    public static let mechanismType = "AppHang"

    /// The exception value, worded as the SDK words it.
    public var message: String {
        let ms = Int(duration / .milliseconds(1))
        return ongoing ? "App hanging for at least \(ms) ms." : "App hanging for \(ms) ms."
    }

    /// The event: the watchdog's stacks and images (``MainThreadHangEvent``)
    /// under an app-hang exception.
    public func event() -> Event {
        let event = MainThreadHangEvent(duration: duration, addresses: addresses, otherThreads: otherThreads).event()
        let sampled = event.exceptions?.first
        let hang = Exception(value: message, type: Self.exceptionType)
        hang.mechanism = Mechanism(type: Self.mechanismType)
        hang.stacktrace = sampled?.stacktrace
        hang.threadId = sampled?.threadId
        event.exceptions = [hang]
        var tags = event.tags ?? [:]
        tags["hang_state"] = ongoing ? "ongoing" : "ended"
        event.tags = tags
        return event
    }
}
