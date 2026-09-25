import CMUXDebugLog
import Foundation
import OSLog
public import WebKit

private let browserTrackingPreventionLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "BrowserTrackingPrevention"
)

/// Applies an explicit opt-out of WebKit's tracking prevention to a browser store.
///
/// The system policy is preserved unless the user opts out. WebKit exposes no
/// public equivalent, so the private accessors are checked before invocation.
/// The store itself is retained, preserving profile identity and existing data.
@MainActor
public struct BrowserTrackingPreventionPolicy {
    private let disabled: Bool

    /// Creates the policy used when preparing a browser's website data store.
    /// - Parameter disabled: Whether the user explicitly disabled tracking prevention.
    public init(disabled: Bool) {
        self.disabled = disabled
    }

    /// Applies the opt-out before a web view begins using the store.
    ///
    /// Restart the app after changing the preference: already-created stores
    /// and their network processes may otherwise retain the previous policy.
    /// - Parameter store: The existing default, named, or ephemeral profile store.
    /// - Returns: Whether the requested policy could be applied. Unsupported
    ///   WebKit versions retain their existing policy and return `false`.
    @discardableResult
    public func apply(to store: WKWebsiteDataStore) -> Bool {
        guard disabled else { return true }

        let getter = NSSelectorFromString("_resourceLoadStatisticsEnabled")
        let setter = NSSelectorFromString("_setResourceLoadStatisticsEnabled:")
        guard store.responds(to: getter), store.responds(to: setter),
              let getterImplementation = store.method(for: getter),
              let setterImplementation = store.method(for: setter) else {
            browserTrackingPreventionLogger.error("WebKit does not support the tracking prevention override")
            return false
        }

        typealias GetEnabled = @convention(c) (AnyObject, Selector) -> Bool
        typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool) -> Void
        let getEnabled = unsafeBitCast(getterImplementation, to: GetEnabled.self)
        let setEnabled = unsafeBitCast(setterImplementation, to: SetEnabled.self)
        setEnabled(store, setter, false)
        let applied = !getEnabled(store, getter)
        if !applied {
            browserTrackingPreventionLogger.error("WebKit did not apply the tracking prevention override")
        }
#if DEBUG
        CMUXDebugLog.logDebugEvent(
            "browser.trackingPrevention disabled=\(applied ? 1 : 0) " +
            "persistent=\(store.isPersistent ? 1 : 0) profile=\(store.identifier?.uuidString ?? "default")"
        )
#endif
        return applied
    }
}
