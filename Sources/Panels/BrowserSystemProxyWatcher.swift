import Foundation
import SystemConfiguration

extension Notification.Name {
    /// Posted on the main thread whenever the macOS system proxy settings
    /// change.
    static let browserSystemProxySettingsDidChange =
        Notification.Name("cmux.browser.systemProxySettingsDidChange")
}

/// Watches the SystemConfiguration dynamic store for system proxy changes so
/// local-workspace browser panes can refresh their mirrored proxy
/// configuration live (e.g. the user toggles a global proxy app on or off
/// while cmux is running, or the active network location changes).
///
/// Without this, a pane would hold a stale mirror until its next webview
/// rebind: a cleared system proxy would leave traffic pointed at a dead
/// proxy, and a newly enabled one would reintroduce the loopback bug
/// (https://github.com/manaflow-ai/cmux/issues/5888).
@MainActor
final class BrowserSystemProxyWatcher {
    static let shared = BrowserSystemProxyWatcher()

    private var dynamicStore: SCDynamicStore?

    /// Starts posting `.browserSystemProxySettingsDidChange`; safe to call
    /// repeatedly.
    func startObserving() {
        guard dynamicStore == nil else { return }

        // @convention(c) trampoline required by the SCDynamicStore C API. It
        // captures no state: the store delivers on the main queue (set
        // below), and interested parties react through NotificationCenter.
        let callback: SCDynamicStoreCallBack = { _, _, _ in
            NotificationCenter.default.post(
                name: .browserSystemProxySettingsDidChange,
                object: nil
            )
        }

        guard let store = SCDynamicStoreCreate(
            nil,
            "cmux.browser.system-proxy-watch" as CFString,
            callback,
            nil
        ) else { return }

        let proxiesKey = SCDynamicStoreKeyCreateProxies(nil)
        guard SCDynamicStoreSetNotificationKeys(store, [proxiesKey] as CFArray, nil),
              SCDynamicStoreSetDispatchQueue(store, .main) else {
            // No queue is set when this path runs today (the queue call is
            // the last to fail); defensive teardown for future reordering.
            SCDynamicStoreSetDispatchQueue(store, nil)
            return
        }
        dynamicStore = store
    }

    /// Stops watching and releases the dynamic-store session.
    func stopObserving() {
        guard let store = dynamicStore else { return }
        SCDynamicStoreSetDispatchQueue(store, nil)
        dynamicStore = nil
    }
}
