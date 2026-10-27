public import AppKit
import CmuxNextWakeups

/// What the app's input checks and debug reports read of a hosted page view (task 224 of
/// plans/cmux-next/chrome-parity/p01-process.md). With ``InputTarget/view`` the page has no window
/// of its own: the page view is a view of the cmux window, and AppKit gives it the page's events
/// through that window's `sendEvent`, as Chrome's app shim gives them to `RenderWidgetHostViewCocoa`
/// (content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm). `debug.key` and `debug.mouse`
/// drive it that way; `debug.cef` and `debug.layers` report the context it shows.
extension ChromiumHostPageView {
    /// The view takes the page's input (host mode): no Chromium page window lies over it, and the
    /// cmux window's first responder is this view while the page has the keys.
    public var takesPageInput: Bool { inputTarget == .view }

    /// The Core Animation context id the view shows; 0 while it shows none.
    public var shownContextID: UInt32 { contextID }

    /// The first shown page view in `view`'s tree, `view` included, that takes the page's input; nil without
    /// one. Hidden views and their subtrees are skipped: a pane keeps parked content (another profile's page
    /// host, a retired browser view) hidden in its tree, and that page is not the one the pane shows. A page
    /// view under a hidden ancestor above `view` is own-hidden in its ``pageNode`` (`viewDidHide`).
    public static func firstTakingInput(in view: NSView) -> ChromiumHostPageView? {
        guard !view.isHidden else { return nil }
        if let page = view as? ChromiumHostPageView, page.takesPageInput, page.pageNode.own != .hidden { return page }
        for subview in view.subviews {
            if let page = firstTakingInput(in: subview) { return page }
        }
        return nil
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
// The page view's wire ships in Debug and bench builds only (embed-cef.sh), as the host app does.
extension ChromiumHostPageView {
    /// The page view's side of the wire to the Chromium Host (`debug.cef` `host_pages[]`).
    public struct WireReport: Equatable, Sendable {
        /// The view has a route to the host (its frame sink is set).
        public var hasInputRoute: Bool
        /// Command and Control key-downs sent and held for the host's KEY_UNHANDLED report
        /// (``ChromiumHostKeyDowns``): the page's unacked chords.
        public var heldKeyDowns: Int
        /// The input seq of the last wheel frame sent; 0 before any.
        public var lastWheelSeq: UInt32
        /// Secure event input is on for a focused password field.
        public var passwordInput: Bool
        /// The input method client's answers from pushed state, by their `debug.chromium_host` names.
        public var textInput: [String: Int]
        /// Command and Control chords the view took for the page from the window's key equivalent pass.
        public var keyEquivalentsTaken: Int
    }

    public var wireReport: WireReport {
        WireReport(hasInputRoute: sink != nil, heldKeyDowns: keyDowns.count, lastWheelSeq: lastWheelSeq,
                   passwordInput: passwordInput.isOn, textInput: textInput.stats.report, keyEquivalentsTaken: keyEquivalentsTaken)
    }
}
#endif
