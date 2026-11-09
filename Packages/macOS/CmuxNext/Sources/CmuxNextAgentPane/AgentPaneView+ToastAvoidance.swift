public import AppKit
public import CmuxNextDesign

/// A toast never covers the composer, and the composer never moves for a toast (Leo, 2026-11-07:
/// "The composer should never ever rise up because there's some sort of ... tooltip type thing";
/// earlier, 2026-11-06, a machine toast drawn over his queued prompt). Toasts rest bottom-center over
/// the window, over this pane's foot, where its bottom stack floats (a question, the tray, queued
/// prompts, the composer card). The page reports that stack's box (`pane.toastAvoidance`, webviews
/// toastAvoidance.ts) and the toast host lifts every toast above it, as over Home's message box; the
/// page's layout never hears of a toast.
extension AgentPaneView: CmuxToastAvoiding {
    /// The page's bottom stack in this view's coordinates; empty while the page reports none or is
    /// held away (a move in progress).
    public var toastAvoidanceRect: NSRect {
        guard !holdsPageAway, let box = model.toastAvoidance else { return .zero }
        return Self.sessionInfoOverlayRect(box, page: page?.frame ?? webView.frame,
                                           zoom: max(0.25, CGFloat(uiPointerPageZoom)), flipped: isFlipped)
    }

    /// The stack or the pane moved, or the pane was hidden or shown (a workspace switch hides an
    /// ancestor and leaves every frame as it was): the window's shown toasts move clear of where it
    /// is now. A hidden pane avoids nothing, so a toast shown while it was away moves up when it comes
    /// back. A move to another window counts even at the same frame: the toasts there move above
    /// the composer, and those of the window it left come back down. Says nothing when its window
    /// and its rect there are unchanged, so a layout pass with no move costs no toast work.
    func toastAvoidanceMoved() {
        let rect = window == nil || isHiddenOrHasHiddenAncestor ? NSRect.zero : convert(toastAvoidanceRect, to: nil)
        let left = lastToastAvoidanceWindow
        guard rect != lastToastAvoidance || left !== window else { return }
        lastToastAvoidance = rect
        lastToastAvoidanceWindow = window
        if let left, left !== window { CmuxToastAvoidance.avoidanceChanged(in: left) }
        if let window { CmuxToastAvoidance.avoidanceChanged(in: window) }
    }
}
