import AppKit

extension AppEvents {
    /// Calls `handler` each time the app becomes active (`NSApplication.didBecomeActiveNotification`),
    /// for subscribers in layers that import no AppKit (CmuxNextSettings' managed-settings backstop).
    ///
    /// - Returns: The subscription; keep it, releasing it ends the subscription.
    public func subscribeToActivation(owner: String, _ handler: @escaping @MainActor () -> Void) -> EventSubscription {
        // raw-observer-allow: the AppEvents subscription recipe R-notif asks for (the app's one observer); only the notice's name matches
        subscribe(NSApplication.didBecomeActiveNotification, owner: owner, handler)
    }
}
