internal import Foundation
#if DEBUG
internal import CMUXDebugLog
#endif

/// Orchestrates find-in-page for one `BrowserPanel` over a ``BrowserFindService``.
///
/// The coordinator owns the find-in-page flow that does not depend on the panel's
/// reactive state directly: it runs searches/clears through the service, applies
/// the returned ``BrowserFindMatchCount`` back into the find bar, sequences the
/// focus-request lease (the monotonic generation that decides which async focus
/// post wins), and replays the search across navigations. Everything it cannot own
/// from the package, the `@Published` find bar state, the published focus-request
/// generation, the panel's semantic focus intent, and the panel-id-scoped
/// `NotificationCenter` posts, it reaches through the app-side ``BrowserFindHosting``.
///
/// `@MainActor` because the find service is `@MainActor` (WebKit evaluation is
/// main-thread only) and the panel that owns this coordinator is `@MainActor`, so
/// every call stays a plain main-actor call.
@MainActor
public final class BrowserFindCoordinator {
    /// The side-effecting find capability: generates the find scripts, evaluates
    /// them against the panel's live web view, and parses match counts.
    private let service: BrowserFindService

    /// The app-side host that owns the find bar state, focus generation, and
    /// notification posts. Weak because the host (`BrowserPanel`) owns this
    /// coordinator strongly and outlives it, so this is non-nil whenever a method
    /// runs.
    public weak var host: (any BrowserFindHosting)?

    /// Creates a find coordinator over a find service.
    /// - Parameter service: The find service this coordinator drives.
    public init(service: BrowserFindService) {
        self.service = service
    }

    // MARK: - Start / hide / next / previous

    /// Opens the find bar and claims find-field focus (legacy `startFind`).
    ///
    /// Exits browser focus mode, points the panel's focus intent at the find field,
    /// ensures the find bar state exists (recovering the last needle), clears any
    /// pending address-bar focus, then begins a focus-request lease and posts the
    /// focus notification immediately and again on the next two main-queue turns to
    /// beat the portal overlay mount racing first-responder focus.
    public func startFind() {
        guard let host else { return }
        host.clearBrowserFocusMode(reason: "startFind")
        host.setPreferredFocusToFindField()
        let shouldSelectAll = host.prepareFindSearchStateForStart()
        host.clearPendingAddressBarFocusForFind()
        let generation = beginSearchFocusRequest(reason: "startFind")
        host.postBrowserSearchFocusNotification(reason: "immediate", generation: generation, selectAll: shouldSelectAll)
        // Re-post because portal overlay mount can race first responder focus.
        DispatchQueue.main.async { [weak self] in
            self?.host?.postBrowserSearchFocusNotification(reason: "async0", generation: generation, selectAll: shouldSelectAll)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.host?.postBrowserSearchFocusNotification(reason: "async50ms", generation: generation, selectAll: shouldSelectAll)
        }
    }

    /// Advances to the next match and applies the resulting count (legacy `findNext`).
    public func findNext() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.applyFindMatchCount(await self.service.next())
        }
    }

    /// Moves to the previous match and applies the resulting count (legacy `findPrevious`).
    public func findPrevious() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.applyFindMatchCount(await self.service.previous())
        }
    }

    /// Closes the find bar, restoring web-view focus when the find field held it
    /// (legacy `hideFind`). Clearing the state triggers the panel's own highlight
    /// teardown and lease invalidation via its state `didSet`.
    public func hideFind() {
        guard let host else { return }
        let shouldRestoreWebViewFocus = host.hasFindSearchState && host.prefersFindFieldFocus
        invalidateSearchFocusRequests(reason: "hideFind")
        host.clearFindSearchState()
        if shouldRestoreWebViewFocus { host.focus() }
    }

    // MARK: - Search execution

    /// Restores find-in-page after a navigation (legacy `restoreFindStateAfterNavigation`).
    ///
    /// Clears the stale match counters, optionally replays the active search against
    /// the new DOM, and re-posts the find-field focus notification for the current
    /// lease so the bar keeps focus through the load.
    public func restoreFindStateAfterNavigation(replaySearch: Bool) {
        guard let host, let needle = host.findSearchNeedle else { return }
        host.setFindMatchTotal(nil)
        host.setFindMatchSelected(nil)
        if replaySearch, !needle.isEmpty {
            executeFindSearch(needle)
        }
        host.postBrowserSearchFocusNotification(
            reason: "restoreAfterNavigation",
            generation: host.searchFocusRequestGeneration,
            selectAll: false
        )
    }

    /// Runs a search for `needle`, applying the resulting count (legacy
    /// `executeFindSearch`). An empty needle clears highlights and resets the
    /// counters instead of searching.
    public func executeFindSearch(_ needle: String) {
        guard !needle.isEmpty else {
            executeFindClear()
            host?.setFindMatchSelected(nil)
            host?.setFindMatchTotal(nil)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.applyFindMatchCount(await self.service.search(needle: needle))
        }
    }

    /// Removes all find highlights from the page (legacy `executeFindClear`).
    public func executeFindClear() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.service.clear()
        }
    }

    /// Writes a non-nil match count into the find bar state (legacy `applyFindMatchCount`).
    private func applyFindMatchCount(_ count: BrowserFindMatchCount?) {
        guard let count, let host else { return }
        host.setFindMatchTotal(count.total)
        host.setFindMatchSelected(count.selected)
    }

    // MARK: - Focus-request lease

    /// Claims a new focus-request lease by bumping the host generation, returning
    /// the new generation (legacy `beginSearchFocusRequest`).
    @discardableResult
    public func beginSearchFocusRequest(reason: String) -> UInt64 {
        guard let host else { return 0 }
        host.searchFocusRequestGeneration &+= 1
#if DEBUG
        CMUXDebugLog.logDebugEvent(
            "browser.find.focusLease.begin panel=\(host.findDebugPanelIDPrefix) " +
            "generation=\(host.searchFocusRequestGeneration) reason=\(reason)"
        )
#endif
        return host.searchFocusRequestGeneration
    }

    /// Invalidates any outstanding focus-request lease by bumping the host
    /// generation (legacy `invalidateSearchFocusRequests`).
    public func invalidateSearchFocusRequests(reason: String) {
        guard let host else { return }
        host.searchFocusRequestGeneration &+= 1
#if DEBUG
        CMUXDebugLog.logDebugEvent(
            "browser.find.focusLease.invalidate panel=\(host.findDebugPanelIDPrefix) " +
            "generation=\(host.searchFocusRequestGeneration) reason=\(reason)"
        )
#endif
    }

    /// Whether a focus post for `generation` may still apply: it is the current
    /// non-zero lease, the find bar is shown, and the panel wants find-field focus
    /// (legacy `canApplySearchFocusRequest`).
    public func canApplySearchFocusRequest(_ generation: UInt64) -> Bool {
        guard let host else { return false }
        return generation != 0 &&
            generation == host.searchFocusRequestGeneration &&
            host.hasFindSearchState &&
            host.prefersFindFieldFocus
    }
}
