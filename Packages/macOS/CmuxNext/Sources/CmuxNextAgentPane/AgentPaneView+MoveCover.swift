public import AppKit
import CmuxNextPages
import CmuxNextWakeups

/// A page moved into another view (a parked New Tab spare adopted, cx-21zkz): WebKit shows nothing
/// there until the page draws again. The page stays clear until its next frame, or
/// ``revealMovedPage()``.
extension AgentPaneView {
    /// Keeps this view's page clear until its next frame; `drawn` runs then, in the transaction that shows it.
    /// A page whose frame is never reported (a hung web process) shows after `limit` all the same.
    public func hideMovedPage(limit: Duration = .seconds(3), until drawn: @escaping () -> Void) {
        pageContent.alphaValue = 0
        let deadline = DemandTimer(owner: "newTab.moveCover.deadline")
        deadline.schedule(after: limit) { @MainActor [weak self] in
            withExtendedLifetime(deadline) {}
            self?.revealMovedPage()
        }
        redraw.afterNextFrame { [weak self] in
            deadline.cancel()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self?.revealMovedPage()
            drawn()
            CATransaction.commit()
        }
    }

    /// Shows a page ``hideMovedPage(until:)`` keeps clear.
    public func revealMovedPage() {
        guard model.hasPainted else { return }
        pageContent.alphaValue = 1
        PageWebView.syncChromiumVisibility(in: pageContent)
    }
}

/// A parked New Tab spare in Chromium moved into a pane (Cmd-N's new workspace, Cmd-T). Chromium draws
/// the page in its own window over the pane: no cover under it and no alpha hides it, and the window
/// follows its view only when told (`moved`). Leo 2026-11-03: "when i make a new workspace (new tab area)
/// it is blank for a split second then the composer comes for a split second and it grows or shrinks to
/// a size for a split second": the window stayed where the spare was parked until another layout moved
/// it, then showed the page laid out at the parked size before Chromium drew it at the pane's.
extension AgentPaneView {
    /// What the next layout in a window does with a Chromium page moved here (``placeMovedChromiumPage(moved:)``).
    struct ChromiumMove {
        /// The page's size where it waited.
        let parkedSize: CGSize
        /// Tells the page's window to follow its view.
        let moved: @MainActor () -> Void
    }

    /// Places this view's Chromium page at its first layout in its new pane. A page already laid out at
    /// the pane's size shows there in that layout's frame; one of another size waits outside the window,
    /// at the pane's size, until it drew a frame there, so no frame at the old size shows. `moved` runs
    /// each time the page changes place (by default: its window follows, ``PageWebView/chromiumWindowMoved()``).
    public func placeMovedChromiumPage(moved: (@MainActor () -> Void)? = nil) {
        let follow = moved ?? { [weak self] in self?.page?.chromiumWindowMoved() }
        chromiumMove = ChromiumMove(parkedSize: pageContent.frame.size, moved: follow)
        needsLayout = true
    }

    /// Called from ``layout()`` with the page's frame in this view: acts on a pending move once in a window.
    func placeChromiumMove(at frame: NSRect) {
        guard let move = chromiumMove, window != nil, frame.width > 0, frame.height > 0, let page else { return }
        chromiumMove = nil
        guard frame.size != move.parkedSize else {
            pageContent.layoutSubtreeIfNeeded()
            move.moved()
            return
        }
        holdsPageAway = true
        pageContent.frame = Self.awayFrame(of: frame)
        pageContent.layoutSubtreeIfNeeded()
        move.moved()
        let release: @MainActor () -> Void = { [weak self] in
            guard let self, holdsPageAway else { return }
            holdsPageAway = false
            pageContent.frame = topBar.contentFrame(in: bounds)
            pageContent.layoutSubtreeIfNeeded()
            move.moved()
            needsLayout = true
        }
        // A page that never reports its frame shows after the move cover's limit all the same.
        let deadline = DemandTimer(owner: "newTab.chromiumMove.deadline")
        deadline.schedule(after: .seconds(3)) { @MainActor in
            withExtendedLifetime(deadline) {}
            release()
        }
        page.afterFrame(at: frame.size) {
            deadline.cancel()
            release()
        }
    }
}
