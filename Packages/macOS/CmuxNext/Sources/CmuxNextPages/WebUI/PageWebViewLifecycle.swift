import AppKit
package import CmuxNextHibernation

/// A ``PageWebView`` as the lifecycle drives it. A hide keeps the page's last frame, encoded
/// (``PageWebView/keepHideSnapshot(encoder:)``), so a discard has nothing left to ask or encode.
/// Freeze and thaw are the view's (``PageWebView/freezePage()``: Chromium SetPageFrozen, WebKit
/// hidden in its window); the discard ends the document and thaw brings a discarded page back behind
/// that picture (PageWebView+Discard.swift).
package struct PageWebViewLifecycle: PageLifecycleTarget {
    package private(set) weak var view: PageWebView?
    private let encoder: PageSnapshotEncoder

    /// - Parameters:
    ///   - view: The page.
    ///   - encoder: Encodes its hide-time frame as it comes, and decodes it for the cover a discarded
    ///     page shows when it comes back (the app's one, on its lanes).
    package init(_ view: PageWebView, encoder: PageSnapshotEncoder) {
        self.view = view
        self.encoder = encoder
    }

    package var object: AnyObject? { view }

    package var lifecycleGroup: String? { view?.descriptor.processGroup.rawValue }

    /// Loading while its document loads (``PageLoadState``: Chrome's kLoading reads the
    /// page's loading state, which also ends while the page is hidden), focused while it holds its
    /// window's first responder, a page call while a host call waits for its answer
    /// (``PageWebView/callPageScript(_:arguments:)``), the reasons of ``PageKeepReasons``: its document's
    /// `cmux.page.keepAlive` and the host's holds (a confirmation sheet, a menu or popup, a drop it
    /// reads, Web Inspector, dictation), each of which tells the lifecycle when it starts or ends, and
    /// preload while it is the pool's parked spare (the pool owns its life; a claimed pooled host is a
    /// page like any other).
    package var lifecycleKeepReasons: Set<PageLifecyclePlanner.KeepReason> {
        guard let view else { return [] }
        var reasons = view.keepReasons.current
        if view.isParkedSpare { reasons.insert(.preload) }
        if view.loadState.isLoading { reasons.insert(.loading) }
        if view.pushes.callsInFlight > 0 { reasons.insert(.pageCall) }
        if let responder = view.window?.firstResponder as? NSView, responder.isDescendant(of: view) { reasons.insert(.focused) }
        return reasons
    }

    package func reportsReasonChanges(to lifecycle: PageLifecycle) {
        view?.loadState.lifecycle = lifecycle
        view?.keepReasons.lifecycle = lifecycle
    }

    package func keepHideSnapshot() { view?.keepHideSnapshot(encoder: encoder) }
    package func dropHideSnapshot() { view?.hideState.drop() }
    package func freeze() -> Bool { view?.freezePage() ?? false }
    /// Thaws a frozen page, or brings a discarded one back; each step does nothing on a page in the
    /// other state.
    package func thaw() {
        view?.thawPage()
        view?.restoreDiscardedPage()
    }
    package func discard() -> Bool { view?.discardPage(decoder: encoder) ?? false }
    /// A page still waiting for its first show has no document yet, and a discarded one has none left.
    package var holdsEnginePage: Bool { view.map { !$0.awaitsFirstShow && !$0.isDiscarded } ?? false }
}
