#if os(iOS)
import Foundation
import UIKit

/// One held background task assertion, opaque to callers.
public struct BackgroundReplyRuntimeAssertion: Equatable, Sendable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }
}

/// Seam over `UIApplication`'s background task assertions for the inline
/// notification reply lane.
///
/// An inline reply from the lock screen wakes the app in the BACKGROUND; the
/// notification delegate returns as soon as the reply is parked, and without
/// an assertion iOS suspends the process seconds later — before the relay
/// POST and the reply's bounded retry ladder can run. The production
/// conformance is ``SystemBackgroundReplyRuntime``; tests inject a fake to
/// assert the assertion is held exactly while a reply is pending.
public protocol BackgroundReplyRuntimeAsserting: Sendable {
    /// Begin one assertion. Returns `nil` when the system refuses one.
    /// - Parameter expirationHandler: Called on the main actor when the system
    ///   is about to close the window; the holder must release promptly.
    @MainActor func begin(
        expirationHandler: @escaping @MainActor () -> Void
    ) -> BackgroundReplyRuntimeAssertion?

    /// Release a previously begun assertion. Must balance ``begin(expirationHandler:)``.
    @MainActor func end(_ assertion: BackgroundReplyRuntimeAssertion)
}

/// Production ``BackgroundReplyRuntimeAsserting`` backed by
/// `UIApplication.beginBackgroundTask`. This is the default
/// ``MobilePushCoordinator`` uses; the ~30 s window it grants covers the
/// reply's relay POST (a couple of seconds) plus several retry-ladder passes.
public struct SystemBackgroundReplyRuntime: BackgroundReplyRuntimeAsserting {
    public init() {}

    @MainActor
    public func begin(
        expirationHandler: @escaping @MainActor () -> Void
    ) -> BackgroundReplyRuntimeAssertion? {
        let id = UIApplication.shared.beginBackgroundTask(withName: "cmux.push.reply") {
            // UIKit documents the expiration handler on the main thread; the
            // holder must end its task before the handler returns, so hop
            // synchronously instead of scheduling a Task.
            MainActor.assumeIsolated { expirationHandler() }
        }
        guard id != .invalid else { return nil }
        return BackgroundReplyRuntimeAssertion(rawValue: id.rawValue)
    }

    @MainActor
    public func end(_ assertion: BackgroundReplyRuntimeAssertion) {
        UIApplication.shared.endBackgroundTask(
            UIBackgroundTaskIdentifier(rawValue: assertion.rawValue)
        )
    }
}
#endif
