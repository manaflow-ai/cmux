import AppKit
import CmuxNextDesign

/// A layout change that shows in one commit (a split, a close, a zoom, an unzoom) tells the shown Chromium page its new
/// size in the change's own turn, so the frame that shows the zoom shows the page laid out at the zoomed size, not its
/// old frame at the old size beside the page's backdrop while Chromium lays out again (Lawrence 2026-11-20, the AWS
/// console: two to four white frames and a relayout in each zoom).
///
/// - With a resize fence (fork API 34, a hosted page: ``CEFLayerHosting/joinsResizeFence``) the page takes the size only
///   in the pass that shows the change, and that resize joins the window's fence (``CEFLayerHosting/paneCommitWillResize(_:)``):
///   the render server shows the commit with the page's first frame at its new size. The page is ready at once.
/// - Without one (fork API 33, the engine that ships today), a page whose pane gets larger takes the size now, ahead of
///   the commit, the way the change's terminals draw ahead: it holds that size at the top-left corner of this view, which
///   clips it to the pane's old size (``holdPageAtRest(_:)``), so the old layout keeps showing the page's old frame while
///   Chromium lays out. The page is ready once it laid out there (``CEFCommitPageWait``), at most
///   ``CEFCommitPageWait/readyFrames`` display frames later; it asks the commit to wait that long for it
///   (``commitWaitTicks``), so the commit never shows the pane's ground. The commit then gives this view the size the
///   page already has, and the hold ends.
///
/// A pane that gets smaller keeps its own picture through its motion and takes its size at the end
/// (`PaneCommitMotionPicture`), so nothing is drawn ahead for it. Neither path makes the main thread wait for a page.
extension CEFTabContentView: PaneCommitSurface {
    func commitWillResize(by change: CGSize, ready: @escaping @MainActor () -> Void) {
        // A later change replaces an earlier one, whose report is void.
        commitWait?.cancel()
        commitWait = nil
        guard window != nil, let tab, tab.host.hostView.superview === self else {
            endCommitAhead()
            return ready()
        }
        let hosting = tab.host.hostView.layerHosting
        // Only a page that can join the fence owes its resize to it; any other draws ahead below.
        hosting.paneCommitWillResize(change != .zero && hosting.joinsResizeFence)
        let size = CGSize(width: bounds.width + change.width, height: bounds.height + change.height)
        guard !hosting.joinsResizeFence, change != .zero, change.width >= 0, change.height >= 0,
              let scale = window?.backingScaleFactor, scale > 0,
              // Another hold (a drag's, a key resize's, a spring's rest) keeps the size it holds.
              heldPageSize == nil || commitAheadSize != nil, pageMotionHold == nil, !pageRestHold,
              holdPageAtRest(size) else {
            endCommitAhead()
            return ready()
        }
        commitAheadSize = size
        // The page window takes the size in this turn, so Chromium lays out while the old layout shows.
        layoutContent()
        commitWait = CEFCommitPageWait(tab: tab, view: self, pixels: CGSize(width: size.width * scale, height: size.height * scale),
                                       using: tab.host.commitLayoutWait, ready: ready) { [weak self] in self?.endCommitAhead() }
    }

    /// A page that took its next size ahead and has not laid out there asks its commit to wait for it longer than the
    /// commit's own bound (``CEFCommitPageWait/commitTicks``); any other asks for no more.
    var commitWaitTicks: Int? {
        commitWait?.owesReport == true ? CEFCommitPageWait.commitTicks : nil
    }

    /// The page lets the size it took ahead go and lays out at this view's size: the commit showed (this view took its
    /// new size), the change went, or the commit never showed (``CEFCommitPageWait/releaseFrames``). A report still owed
    /// comes from the wait.
    func endCommitAhead() {
        guard commitAheadSize != nil else { return }
        commitAheadSize = nil
        commitWait?.holdEnded()
        dropHold()
        layoutContent()
    }

    /// The page hides or leaves its pane while it took a size ahead: it draws nothing more for that commit, so it reports
    /// now and lets the size go.
    func leaveCommitAhead() {
        let wait = commitWait
        commitWait = nil
        endCommitAhead()
        wait?.report()
    }
}
