import AppKit
import Testing

/// Selector-based NotificationCenter observers run synchronously on the posting
/// thread. AppKit's notification names are usually posted on the main thread,
/// but that is not part of NotificationCenter's contract. Keep this probe
/// deliberately actor-isolated: it is the regression that selector observers
/// must pass after they are converted to a main-queue delivery path.
@MainActor
@Suite(.serialized)
struct SelectorNotificationThreadTests {
    private static let selectorNotificationNames: [Notification.Name] = [
        NSWindow.didBecomeKeyNotification,
        NSWindow.didResignKeyNotification,
        NSWindow.willCloseNotification,
        NSView.boundsDidChangeNotification,
        NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
        NSWindow.didChangeOcclusionStateNotification,
        NSView.frameDidChangeNotification,
        NSScroller.preferredScrollerStyleDidChangeNotification,
        NSMenu.willSendActionNotification,
    ]

    /// A reusable posting helper for selector and block observer tests. The
    /// main turn is scheduled only after the background post returns, so an
    /// observer that explicitly hops to main has completed before this returns.
    private static func postFromBackground(
        _ names: [Notification.Name],
        on center: NotificationCenter
    ) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                for name in names { center.post(name: name, object: nil) }
                DispatchQueue.main.async { done.resume() }
            }
        }
    }

    @MainActor
    private final class SelectorProbe: NSObject {
        private let center: NotificationCenter
        private let lock = NSLock()
        nonisolated(unsafe) private var callbackThreads: [Bool] = []

        init(center: NotificationCenter, names: [Notification.Name]) {
            self.center = center
            super.init()
            for name in names {
                center.addObserver(self, selector: #selector(received(_:)), name: name, object: nil)
            }
        }

        @objc private func received(_ note: Notification) {
            lock.lock()
            callbackThreads.append(Thread.isMainThread)
            lock.unlock()
        }

        func callbackThreadsSnapshot() -> [Bool] {
            lock.lock()
            defer { lock.unlock() }
            return callbackThreads
        }

        deinit { center.removeObserver(self) }
    }

    /// This is intentionally red on the current selector registrations: every
    /// callback is delivered on the detached posting thread. Once the app's
    /// selector observers use `queue: .main` (or `MainDelivery`), this contract
    /// protects all nine notification names in one focused test.
    @Test func selectorNotificationsPostedOffMainDeliverOnMain() async {
        let center = NotificationCenter()
        let probe = SelectorProbe(center: center, names: Self.selectorNotificationNames)
        await Self.postFromBackground(Self.selectorNotificationNames, on: center)
        let callbacks = probe.callbackThreadsSnapshot()
        #expect(callbacks.count == Self.selectorNotificationNames.count)
        #expect(callbacks.allSatisfy { $0 })
    }
}
