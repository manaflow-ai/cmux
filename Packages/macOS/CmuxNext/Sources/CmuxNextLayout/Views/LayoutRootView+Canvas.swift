public import AppKit

/// Trackpad and wheel input on a canvas screen (plans/cmux-next/canvas-layout.md):
/// a scroll over the empty canvas pans it, momentum included; over a pane the
/// first dominant axis decides (horizontal pans, vertical scrolls the pane, as on
/// a column strip); a pinch zooms about the pointer.
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
    func handleCanvasScroll(_ event: NSEvent, at locationInWindow: NSPoint) -> Bool? {
        let delta = CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)
        if !event.momentumPhase.isEmpty {
            guard case let .canvas(view) = scrollLock else { return nil }
            let ended = event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled)
            view.canvasPan(by: delta, ended: ended)
            if ended { scrollLock = .idle }
            updateVisibility()
            return true
        }
        let phase = event.phase
        if phase.isEmpty {
            // A mouse wheel: it pans over the empty canvas, or sideways (Shift) anywhere.
            guard let view = activeCanvasView(at: locationInWindow) else { return nil }
            let overPane = view.pane(at: view.convert(locationInWindow, from: nil)) != nil
            guard !overPane || abs(delta.width) > abs(delta.height) else { return nil }
            let notch: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            view.canvasPan(by: CGSize(width: delta.width * notch, height: delta.height * notch), ended: true)
            updateVisibility()
            return true
        }
        if phase.contains(.mayBegin) || phase.contains(.began) {
            guard let view = activeCanvasView(at: locationInWindow) else { return nil }
            let overPane = view.pane(at: view.convert(locationInWindow, from: nil)) != nil
            scrollLock = overPane ? .canvasUndecided(view) : .canvas(view)
        }
        let ended = phase.contains(.ended) || phase.contains(.cancelled)
        switch scrollLock {
        case let .canvas(view):
            // The lock stays through the momentum that may follow; the next gesture replaces it.
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
