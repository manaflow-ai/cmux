import AppKit
import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextSidebar

/// The window's chrome resizing the content area over several frames. Only the
/// sidebar does this today: every frame of its width animation moves the
/// content edge, so Auto Layout resizes every pane beside it even though no
/// pane is on a layout spring of its own. Content whose resize is costly (a
/// terminal's PTY grid and shell redraw) holds it until the landing, exactly as
/// it does inside a pane's own spring (`RestingPlacement`).
extension WindowRootView {
    /// Whether the chrome is resizing the content area now. `ShellWindow`
    /// answers `ContentAreaMotionHosting` from this, and `NSView.isInPaneMotion`
    /// reads it through the window, so it holds for every view in the window.
    var isContentAreaInMotion: Bool { sidebar.isWidthAnimating }

    /// Tells the window's content when the sidebar's motion lands, so what held
    /// a costly resize does it once, now. The whole window and not only the
    /// content host: the motion is window-scoped, so a terminal anywhere in it
    /// held its grid and would otherwise hold it for good.
    func wireContentAreaMotion() {
        sidebar.onWidthMotionChange = { [weak self] animating in
            guard let self else { return }
            guard !animating else { return onContentAreaMotionChange?(true) ?? () }
            // The held content takes the card's size once, in the same pass as everything else at the landed width.
            releaseContentHold()
            // Flush layout at the landed width before content hears the motion ended: the
            // workspace sizes its layout in `layout()` (an empty autoresizing mask), so the subtree is
            // laid out now, or a terminal would settle at a stale width and report a stale grid.
            layoutSubtreeIfNeeded()
            onContentAreaMotionChange?(false)
            notifyPaneMotionSettled()
        }
    }
}

/// The content the sidebar's slide holds at one size: the workspace (or top page) in the main pane card keeps the width
/// it lands at for the whole slide and only moves with the card, which clips it, instead of laying out every pane, page
/// and terminal again at a new width on every frame (an Auto Layout re-solve of the whole content and a layout of each
/// view in it: 8 to 11 ms of each slide frame, cmux21, 60 Hz). A show (the card narrows) keeps the width the card had and
/// lets the card's edge slide over its right side; a hide (the card widens) lays the content out once at the width it
/// lands at, on the slide's first frame, and the card's edge uncovers it. The landing lays it out at the card's size,
/// which is then the size it already has for a hide. Terminals already hold their grid through the slide
/// (`isInPaneMotion`), so their text does not reflow mid-slide either way.
struct ContentAreaHold {
    /// Each held view and the autoresizing mask it had.
    var views: [(view: NSView, mask: NSView.AutoresizingMask)]
    /// The width the views are held at.
    var width: CGFloat
}

extension WindowRootView {
    /// Each frame the card moves while the sidebar slides: the first one holds the content at the width it lands at;
    /// later ones only follow the card, unless the card got wider than the hold (a slide turned around mid-way into a
    /// hide), which widens the hold once. Chromium pages are child windows: they are told the card moved, so their
    /// windows follow it (geometry only, no clip shape changed).
    func followContentAreaMotion() {
        guard sidebar.isWidthAnimating else { return }
        let card = contentHost.bounds
        if var hold = contentHold {
            if card.width > hold.width + 0.5 || hold.views.contains(where: { $0.view.frame.height != card.height }) {
                hold.width = max(hold.width, card.width)
                for held in hold.views where held.view.superview === contentHost { held.view.frame = NSRect(x: 0, y: 0, width: hold.width, height: card.height) }
                contentHold = hold
            }
        } else {
            startContentHold(card: card)
        }
        if contentHold != nil, let window {
            NotificationCenter.default.post(name: Notification.Name.browserChildWindowPagesNeedUpdate, object: window,
                                            userInfo: [browserPagesGeometryOnlyKey: true])
        }
    }

    /// Holds the card's content at the larger of its width now and the width it lands at. Only while the card clips (the
    /// curved main pane, the default): a flat card would let the held content draw past it, over a right sidebar or, for
    /// a Chromium page's child window, past the window's edge. Not for side-by-side workspaces (`arrangeContent`).
    private func startContentHold(card: NSRect) {
        guard contentHost.layer?.masksToBounds == true, contentHost.arrangeContent == nil, card.width > 0,
              let toGo = sidebar.widthStillToGo else { return }
        let landing = card.width - CGFloat(toGo)
        let views = contentHost.subviews.filter { !$0.isHidden && $0.autoresizingMask.contains(.width) }
        guard !views.isEmpty else { return }
        let width = max(card.width, landing)
        let held = views.map { (view: $0, mask: $0.autoresizingMask) }
        for view in views {
            view.autoresizingMask = [.height]
            view.frame = NSRect(x: 0, y: 0, width: width, height: card.height)
        }
        contentHold = ContentAreaHold(views: held, width: width)
    }

    /// The slide landed (or stopped): the held content takes the card's size and its own mask back.
    func releaseContentHold() {
        guard let hold = contentHold else { return }
        contentHold = nil
        for held in hold.views where held.view.superview === contentHost {
            held.view.autoresizingMask = held.mask
            held.view.frame = contentHost.bounds
        }
        if let window { NotificationCenter.default.post(name: Notification.Name.browserChildWindowPagesNeedUpdate, object: window) }
    }
}
