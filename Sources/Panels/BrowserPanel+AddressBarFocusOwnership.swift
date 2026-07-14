import Foundation

extension BrowserPanel {
    func beginSuppressWebViewFocusForAddressBar() {
        let enteringAddressBar = !hasAddressBarFocusSuppression
        if enteringAddressBar {
#if DEBUG
            cmuxDebugLog("browser.focus.addressBarSuppress.begin panel=\(id.uuidString.prefix(5))")
#endif
            invalidateAddressBarPageFocusRestoreAttempts()
        }
        suppressWebViewFocusForAddressBarIntent = true
        if enteringAddressBar {
            captureAddressBarPageFocusIfNeeded()
        }
    }

    func endSuppressWebViewFocusForAddressBar() {
        if hasAddressBarFocusSuppression {
#if DEBUG
            cmuxDebugLog("browser.focus.addressBarSuppress.end panel=\(id.uuidString.prefix(5))")
#endif
        }
        suppressWebViewFocusForAddressBarIntent = false
        addressBarViewFocusLeaseOwners.removeAll()
    }

    func endAddressBarFocusIntentSuppression() {
        suppressWebViewFocusForAddressBarIntent = false
    }

    /// End an explicit address-bar-to-WebKit handoff as one panel-wide state
    /// transition. Overlapping SwiftUI view lifetimes can temporarily hold more
    /// than one owner lease, so a handoff must revoke every lease and notify every
    /// mounted view instead of releasing only the initiating view's owner.
    func endAddressBarFocusForWebViewHandoff(reason: String) {
        pendingAddressBarFocusRequestId = nil
        pendingAddressBarFocusSelectionIntent = .preserveFieldEditorSelection
        endSuppressWebViewFocusForAddressBar()
        invalidateAddressBarPageFocusRestoreAttempts()
        AppDelegate.shared?.clearBrowserAddressBarFocus(panelId: id, reason: reason)
        NotificationCenter.default.post(name: .browserDidBlurAddressBar, object: id)
    }

    /// Register one view lifetime as the newest address-bar presentation. A
    /// repeated SwiftUI `onAppear` for the same lifetime is intentionally a no-op,
    /// so an outgoing view cannot reclaim ownership after its replacement mounts.
    @discardableResult
    func registerAddressBarViewPresentation(owner: UUID) -> Bool {
        guard !addressBarViewPresentationOwners.contains(owner) else { return false }
        addressBarViewPresentationOwners.append(owner)
        currentAddressBarViewPresentationOwner = owner
        return true
    }

    /// Remove only the disappearing view lifetime. Unregistering a stale owner
    /// cannot clear its replacement; removing the newest owner promotes the most
    /// recent surviving presentation.
    @discardableResult
    func unregisterAddressBarViewPresentation(owner: UUID) -> Bool {
        guard let index = addressBarViewPresentationOwners.firstIndex(of: owner) else { return false }
        let wasCurrent = currentAddressBarViewPresentationOwner == owner
        addressBarViewPresentationOwners.remove(at: index)
        if wasCurrent {
            currentAddressBarViewPresentationOwner = addressBarViewPresentationOwners.last
        }
        return true
    }

    /// Transfer active address-bar focus from a view-local SwiftUI lifetime into
    /// model-owned suppression. Owner identity makes overlapping unmount/remount
    /// transitions safe: an old view can release only its own lease.
    @discardableResult
    func acquireAddressBarViewFocusLease(owner: UUID, reason: String) -> Bool {
        let enteringAddressBar = !hasAddressBarFocusSuppression
        guard addressBarViewFocusLeaseOwners.insert(owner).inserted else { return false }
        if enteringAddressBar {
            invalidateAddressBarPageFocusRestoreAttempts()
            captureAddressBarPageFocusIfNeeded()
        }
#if DEBUG
        cmuxDebugLog(
            "browser.focus.addressBarLease.acquire panel=\(id.uuidString.prefix(5)) " +
            "owner=\(owner.uuidString.prefix(8)) count=\(addressBarViewFocusLeaseOwners.count) " +
            "reason=\(reason)"
        )
#endif
        if addressBarViewFocusLeaseOwners.count == 1 {
            NotificationCenter.default.post(name: .browserDidFocusAddressBar, object: id)
        }
        return true
    }

    /// Release one mounted view's address-bar focus lease. Global responder
    /// tracking is cleared only after the final owner leaves, so a stale view
    /// disappearing after its replacement cannot blur the replacement.
    @discardableResult
    func relinquishAddressBarViewFocusLease(owner: UUID, reason: String) -> Bool {
        guard addressBarViewFocusLeaseOwners.remove(owner) != nil else { return false }
#if DEBUG
        cmuxDebugLog(
            "browser.focus.addressBarLease.release panel=\(id.uuidString.prefix(5)) " +
            "owner=\(owner.uuidString.prefix(8)) count=\(addressBarViewFocusLeaseOwners.count) " +
            "reason=\(reason)"
        )
#endif
        if addressBarViewFocusLeaseOwners.isEmpty {
            invalidateAddressBarPageFocusRestoreAttempts()
            AppDelegate.shared?.clearBrowserAddressBarFocus(panelId: id, reason: reason)
            NotificationCenter.default.post(name: .browserDidBlurAddressBar, object: id)
        }
        return true
    }

    var hasAddressBarFocusSuppression: Bool {
        suppressWebViewFocusForAddressBarIntent || !addressBarViewFocusLeaseOwners.isEmpty
    }
}
