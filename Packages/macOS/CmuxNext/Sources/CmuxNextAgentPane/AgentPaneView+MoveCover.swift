public import AppKit
import CmuxNextPages
import CmuxNextWakeups

/// A page moved into another view (a parked New Tab spare adopted, cx-21zkz): WebKit shows nothing
/// there until the page draws again. The page stays clear until its next frame, or
/// ``revealMovedPage()``.
extension AgentPaneView {
    /// Keeps this view's page clear until its next frame; `drawn` runs then, in the transaction that shows it.
    /// A page whose frame is never reported (a hung web process) shows after `limit` all the same.
    /// `overPicture`: the page's picture stands in under this view until then, so the chat's ground stays out too.
    public func hideMovedPage(limit: Duration = .seconds(3), overPicture: Bool = false, until drawn: @escaping () -> Void) {
        pageContent.alphaValue = 0
        if overPicture { ground.isHidden = true }
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
        ground.isHidden = false
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

    /// A moved page held outside the window until it drew at `size`, the size its pane rests at.
    @MainActor
    final class ChromiumMoveWait {
        let move: ChromiumMove
        /// The size the page waits for; another one when its pane rests at another size during the hold.
        var size: CGSize
        /// Shows the page after the move cover's limit when it never reports its frame; one per hold.
        let deadline = DemandTimer(owner: "newTab.chromiumMove.deadline")
        /// The page drew at `size` while its pane was still on its spring: it shows in the layout the pane lands in.
        var drewAtRest = false

        init(move: ChromiumMove, size: CGSize) {
            self.move = move
            self.size = size
        }
    }

    /// Places this view's Chromium page at its first layout in its new pane. A page already laid out at
    /// the pane's size, in a pane at rest, shows there in that layout's frame; one of another size waits outside
    /// the window, at the size its pane rests at, until it drew a frame there and the pane is at that size, so no
    /// frame at the old size or at a size of the pane's spring shows. `moved` runs
    /// each time the page changes place (by default: its window follows, ``PageWebView/chromiumWindowMoved()``).
    public func placeMovedChromiumPage(moved: (@MainActor () -> Void)? = nil) {
        let follow = moved ?? { [weak self] in self?.page?.chromiumWindowMoved() }
        chromiumMove = ChromiumMove(parkedSize: pageContent.frame.size, moved: follow)
        needsLayout = true
    }

    /// `frame` (where the page draws in this view now) at the size it has once its pane rests. A split's new pane gets
    /// its chat while it is on the split's spring: the chat's first layout there is at a size the pane leaves in the
    /// next frame, and the pane tells the size it will rest at (`RestingPlacement.restContentSizeChange`; the chrome
    /// around the page does not change size in a spring). `frame` itself at rest or outside a pane.
    func restingFrame(of frame: NSRect) -> NSRect {
        guard let change = enclosingRestSizeChange else { return frame }
        return NSRect(x: frame.minX, y: frame.minY, width: max(0, frame.width + change.width), height: max(0, frame.height + change.height))
    }

    /// Where a held page lies while its place in this view is `frame`: outside the window, at the size its pane rests
    /// at. A page that waits for its frame keeps that wait's size to the point, so a spring frame's rounding gives it
    /// no new size.
    func heldPageFrame(of frame: NSRect) -> NSRect {
        var rest = restingFrame(of: frame)
        if let wait = chromiumMoveWait, Self.near(wait.size, rest.size, within: 1) { rest.size = wait.size }
        return Self.awayFrame(of: rest)
    }

    /// Called from ``layout()`` with the page's frame in this view: acts on a pending move once in a window, and on a
    /// held move whose pane landed or now rests at another size (a second split or a close during the hold).
    ///
    /// The held page takes the size its pane will REST at, once, waits for its frame at that size, and shows when the
    /// pane is at that size (SPLIT OPEN, 2026-11-10; Chrome sends a page its final size once and shows it when its
    /// frame at that size came). It waited for a frame at the first layout's size before: in a split that is a size of
    /// the spring (242 pt of 459 in the films of #39993), the page got each later size and never drew one at the first,
    /// and the new pane showed no chat until the wait's bound of 60 frames (75 to 84 frames at 120 Hz, about 650 ms).
    func placeChromiumMove(at frame: NSRect) {
        guard chromiumMove != nil || chromiumMoveWait != nil else { return }
        let rest = restingFrame(of: frame)
        let landed = Self.near(frame.size, rest.size, within: 0.5)
        if let wait = chromiumMoveWait, holdsPageAway {
            if !Self.near(wait.size, rest.size, within: 1) {
                // The pane rests at another size now: the page is laid out there (``layout()``) and the wait follows it.
                // The hold's first deadline stays, so a size that changes in every frame cannot keep the page away.
                askFrame(of: wait, at: rest.size)
            } else if wait.drewAtRest, landed {
                showMovedChromiumPage(wait)
            }
            return
        }
        guard let move = chromiumMove, window != nil, frame.width > 0, frame.height > 0, page != nil else { return }
        chromiumMove = nil
        let drawn = Self.near(rest.size, move.parkedSize, within: 0.5)
        guard !(drawn && landed) else {
            pageContent.layoutSubtreeIfNeeded()
            move.moved()
            return
        }
        holdsPageAway = true
        pageContent.frame = Self.awayFrame(of: rest)
        pageContent.layoutSubtreeIfNeeded()
        move.moved()
        waitForChromiumMove(move, at: rest.size, drawn: drawn)
    }

    private static func near(_ a: CGSize, _ b: CGSize, within limit: CGFloat) -> Bool {
        abs(a.width - b.width) <= limit && abs(a.height - b.height) <= limit
    }

    /// Holds the page until it drew a frame at `size` and its pane is at that size. `drawn`: it is laid out at `size`
    /// already (parked there), so only its pane's landing is waited for. A page that never reports its frame, or a
    /// pane that never lands, shows after the move cover's limit all the same.
    private func waitForChromiumMove(_ move: ChromiumMove, at size: CGSize, drawn: Bool) {
        guard page != nil else { return }
        let wait = ChromiumMoveWait(move: move, size: size)
        chromiumMoveWait = wait
        wait.deadline.schedule(after: .seconds(3)) { @MainActor [weak self, weak wait] in
            guard let self, let wait else { return }
            showMovedChromiumPage(wait)
        }
        if drawn { wait.drewAtRest = true } else { askFrame(of: wait, at: size) }
    }

    /// Asks the page of `wait` for its frame at `size`, the size the wait is for from now. The answer for a size the
    /// wait left is dropped.
    private func askFrame(of wait: ChromiumMoveWait, at size: CGSize) {
        (wait.size, wait.drewAtRest) = (size, false)
        page?.afterFrame(at: size) { [weak self, weak wait] in
            guard let self, let wait, chromiumMoveWait === wait, wait.size == size else { return }
            // Still on its spring: the page keeps its one size outside the window and shows in the layout the pane
            // lands in (``placeChromiumMove(at:)``), not at a size of the spring.
            let frame = topBar.pageFrame(in: bounds)
            guard Self.near(frame.size, restingFrame(of: frame).size, within: 0.5) else {
                wait.drewAtRest = true
                return
            }
            showMovedChromiumPage(wait)
        }
    }

    /// Brings the page of `wait` back in place; nothing for a wait another one replaced.
    private func showMovedChromiumPage(_ wait: ChromiumMoveWait) {
        guard chromiumMoveWait === wait else { return }
        chromiumMoveWait = nil
        wait.deadline.cancel()
        guard holdsPageAway else { return }
        holdsPageAway = false
        pageContent.frame = topBar.pageFrame(in: bounds)
        applyNativeRects() // the tab row's holes, taken while it was away, follow it back
        pageContent.layoutSubtreeIfNeeded()
        wait.move.moved()
        needsLayout = true
    }
}
