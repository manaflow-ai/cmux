import AppKit
import Foundation

@MainActor
protocol BrowserHiddenWebViewDiscardEventSubscriber: AnyObject {
    func discardPolicyDidChange(_ policy: BrowserHiddenWebViewDiscardPolicy.ResolvedPolicy)
    func systemWillSleep()
    func systemDidWake()
}

/// Shared event fan-out for hidden-webview discard managers.
///
/// Replaces per-panel observers from issue #7596: roughly 224 hidden browser
/// panes used to install 3 observers each, all re-resolving identical global
/// discard policy state for every defaults write.
@MainActor
final class BrowserHiddenWebViewDiscardEventCenter {
    static let shared = BrowserHiddenWebViewDiscardEventCenter()

    private final class WeakSubscriber {
        weak var value: BrowserHiddenWebViewDiscardEventSubscriber?

        init(_ value: BrowserHiddenWebViewDiscardEventSubscriber) {
            self.value = value
        }
    }

    private let defaults: UserDefaults
    private let defaultsNotificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private let observerQueue: OperationQueue?
    private var defaultsObserver: NSObjectProtocol?
    private var sleepObservers: [NSObjectProtocol] = []
    private var policyState: BrowserHiddenWebViewDiscardPolicy.ResolvedPolicy
    private var subscribers: [WeakSubscriber] = []

    init(
        defaults: UserDefaults = .standard,
        defaultsNotificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        observerQueue: OperationQueue? = .main
    ) {
        self.defaults = defaults
        self.defaultsNotificationCenter = defaultsNotificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.observerQueue = observerQueue
        self.policyState = BrowserHiddenWebViewDiscardPolicy.resolved(defaults: defaults)
        installObservers()
    }

    func add(_ subscriber: BrowserHiddenWebViewDiscardEventSubscriber) {
        compactSubscribers()
        guard !subscribers.contains(where: { $0.value === subscriber }) else { return }
        subscribers.append(WeakSubscriber(subscriber))
    }

    func remove(_ subscriber: BrowserHiddenWebViewDiscardEventSubscriber) {
        subscribers.removeAll { $0.value == nil || $0.value === subscriber }
    }

    var subscriberCountForTesting: Int {
        compactSubscribers()
        return subscribers.count
    }

    var observerInstallCountForTesting: (defaults: Int, workspace: Int) {
        (defaultsObserver == nil ? 0 : 1, sleepObservers.count)
    }

    private func installObservers() {
        defaultsObserver = defaultsNotificationCenter.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: observerQueue
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleDefaultsChanged()
            }
        }
        sleepObservers = [
            workspaceNotificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: observerQueue
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.notifySystemWillSleep()
                }
            },
            workspaceNotificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: observerQueue
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.notifySystemDidWake()
                }
            }
        ]
    }

    private func handleDefaultsChanged() {
        let nextPolicyState = BrowserHiddenWebViewDiscardPolicy.resolved(defaults: defaults)
        guard nextPolicyState != policyState else { return }
        policyState = nextPolicyState
        for subscriber in liveSubscribers() {
            subscriber.discardPolicyDidChange(nextPolicyState)
        }
    }

    private func notifySystemWillSleep() {
        for subscriber in liveSubscribers() {
            subscriber.systemWillSleep()
        }
    }

    private func notifySystemDidWake() {
        for subscriber in liveSubscribers() {
            subscriber.systemDidWake()
        }
    }

    private func liveSubscribers() -> [BrowserHiddenWebViewDiscardEventSubscriber] {
        compactSubscribers()
        return subscribers.compactMap(\.value)
    }

    private func compactSubscribers() {
        subscribers.removeAll { $0.value == nil }
    }
}
