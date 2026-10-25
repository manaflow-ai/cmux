public import AppKit

/// Trackpad and wheel input on a canvas screen (plans/cmux-next/canvas-layout.md):
/// a scroll over the empty canvas pans it, momentum included; a pinch zooms about the
/// pointer. Over a pane, `layout.scrollModifier` decides as on a column strip
/// (`LayoutRootView+Scroll`): with `command` a plain scroll is the pane's and Command +
/// scroll pans the canvas on both axes; with `none` the first dominant axis decides
/// (horizontal pans, vertical scrolls the pane). A scroll from a Chromium page's window is the
/// page's even where the layout's point is empty canvas (a page window trails its pane during a
/// pan or zoom), except Command + scroll under `command`.
extension LayoutRootView {
    /// The frames `screen` shows now, in its view's points, and that view's
    /// size: what a new canvas starts from, so the screen looks the same in
    /// canvas mode (`LayoutModel.toggleCanvas`). Nil for a screen not drawn yet.
    public func canvasSeed(for screen: ScreenID) -> (frames: [PaneID: CGRect], viewport: CGSize)? {
        guard let view = screenViews[screen] else { return nil }
        // A hidden screen resized since it last showed has not laid out at its size yet.
        view.reconcileIfDeferred()
        var frames: [PaneID: CGRect] = [:]
        for pane in view.geometry.panes.keys {
            if let rect = view.displayedFrame(of: pane) { frames[pane] = rect }
        }
        return (frames, view.frame.size)
    }

    /// The active screen's view when it shows a canvas under `locationInWindow`.
    private func activeCanvasView(at locationInWindow: NSPoint) -> ScreenContentView? {
        guard bounds.contains(convert(locationInWindow, from: nil)), let active = model.activeScreenID,
              let view = screenViews[active], view.isCanvas, !view.isHidden else { return nil }
        return view
    }

    /// Routes one scroll event over a canvas. True: consumed; false: the
    /// event goes on to the pane; nil: not a canvas event, the strip rules apply.
    /// `decides`: this event decides its gesture's owner (`decidesGestureOwner`). `fromPageWindow`:
    /// the event came from a page window (`LayoutRootView.scrollOrigin(of:at:in:)`).
    func handleCanvasScroll(_ event: NSEvent, at locationInWindow: NSPoint, decides: Bool, fromPageWindow: Bool) -> Bool? {
        let delta = CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)
        if !event.momentumPhase.isEmpty {
            guard case let .canvasCoast(view) = scrollLock else { return nil }
            let ended = event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled)
            view.canvasPan(by: delta, ended: ended)
            if ended { scrollLock = .idle }
            updateVisibility()
            return true
        }
        // A page window's scroll starts nothing on the canvas but Command + scroll under `command`.
        let mayStart = !fromPageWindow || (model.scrollModifier == .command && event.modifierFlags.contains(.command))
        let phase = event.phase
        if phase.isEmpty {
            // A mouse wheel: it pans over the empty canvas, or sideways (Shift) anywhere.
            guard mayStart, let view = activeCanvasView(at: locationInWindow) else { return nil }
            let overPane = view.pane(at: view.convert(locationInWindow, from: nil)) != nil
            switch model.scrollModifier {
            case .command: guard !overPane || event.modifierFlags.contains(.command) else { return nil }
            case .noModifier: guard !overPane || abs(delta.width) > abs(delta.height) else { return nil }
            }
            let notch: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            view.canvasPan(by: CGSize(width: delta.width * notch, height: delta.height * notch), ended: true)
            updateVisibility()
            return true
        }
        if decides {
            guard mayStart, let view = activeCanvasView(at: locationInWindow) else { return nil }
            let overPane = view.pane(at: view.convert(locationInWindow, from: nil)) != nil
            switch model.scrollModifier {
            case .command:
                // A plain gesture over a pane is the pane's: the strip rules pass it through.
                guard !overPane || event.modifierFlags.contains(.command) else { return nil }
                scrollLock = .canvas(view)
            case .noModifier:
                scrollLock = overPane ? .canvasUndecided(view) : .canvas(view)
            }
        }
        let ended = phase.contains(.ended) || phase.contains(.cancelled)
        switch scrollLock {
        case let .canvas(view):
            // At the end the gesture is over; the canvas keeps the momentum that may follow.
            if ended { scrollLock = .canvasCoast(view) }
            view.canvasPan(by: delta, ended: ended)
            updateVisibility()
            return true
        case let .canvasUndecided(view):
            if ended {
                scrollLock = .idle
                return false
            }
            guard abs(delta.width) + abs(delta.height) > 0 else { return false }
            if abs(delta.width) > abs(delta.height) {
                scrollLock = .canvas(view)
                view.canvasPan(by: delta, ended: false)
                updateVisibility()
                return true
            }
            scrollLock = .passthrough
            focusPaneForPassThroughScroll(at: locationInWindow)
            return false
        default:
            return nil
        }
    }

    /// A pinch over a canvas zooms it about the pointer. Returns true when consumed.
    func handleCanvasMagnify(_ event: NSEvent) -> Bool {
        guard let view = activeCanvasView(at: event.locationInWindow) else { return false }
        let ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)
        view.canvasMagnify(by: 1 + event.magnification, at: event.locationInWindow, ended: ended || event.phase.isEmpty)
        updateVisibility()
        return true
    }
}
