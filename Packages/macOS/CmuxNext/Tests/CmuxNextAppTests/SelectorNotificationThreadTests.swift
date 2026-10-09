import AppKit
import Testing

/// AppKit's notification names are usually posted on the main thread, but
/// NotificationCenter does not guarantee that. Every UI observer in CmuxNext
/// therefore uses this main-queue delivery contract.
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
    private final class MainQueueProbe: NSObject {
        private let center: NotificationCenter
        private var callbackThreads: [Bool] = []
        private var observers: [NSObjectProtocol] = []

        init(center: NotificationCenter, names: [Notification.Name]) {
            self.center = center
            super.init()
            observers = names.map { name in
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    // main-proof: NotificationCenter delivers this block on the main operation queue.
                    MainActor.assumeIsolated { self?.received(note) }
                }
            }
        }

        private func received(_ note: Notification) {
            callbackThreads.append(Thread.isMainThread)
        }

        func callbackThreadsSnapshot() -> [Bool] { callbackThreads }

        deinit { observers.forEach(center.removeObserver) }
    }

    /// A detached post must still deliver every observed notification on main.
    @Test func observedNotificationsPostedOffMainDeliverOnMain() async {
        let center = NotificationCenter()
        let probe = MainQueueProbe(center: center, names: Self.selectorNotificationNames)
        await Self.postFromBackground(Self.selectorNotificationNames, on: center)
        let callbacks = probe.callbackThreadsSnapshot()
        #expect(callbacks.count == Self.selectorNotificationNames.count)
        #expect(callbacks.allSatisfy { $0 })
    }
}
