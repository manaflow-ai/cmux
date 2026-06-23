import AppKit
import SwiftUI
import CmuxCanvas

/// Command+scroll canvas panning and the one-time discovery hint that teaches
/// it. Split out of CanvasRootView to keep the core view file focused.
extension CanvasRootView {
    func installCommandScrollMonitor() {
        guard commandScrollEventRouter == nil else { return }
        let router = CanvasCommandScrollEventRouter(
            rootView: self,
            scrollView: scrollView,
            paneViewAtRootPoint: { [weak self] point in
                self?.paneView(at: point)
            },
            handleMagnify: { [weak self] in
                self?.updateMinimap(reveal: true)
            },
            handleOptionScroll: { [weak self] event in
                self?.zoomByScroll(event)
            },
            handlePlainScrollInPane: { [weak self] in
                self?.noteInPaneScrollForHint()
            }
        )
        router.install()
        commandScrollEventRouter = router
    }

    /// Zooms toward the scroll event's cursor location from an option+scroll.
    /// Scroll up/away zooms in. Precise (trackpad) deltas are in points;
    /// line-based (mouse wheel) deltas are coarser, so each is scaled
    /// separately to a gentle per-event multiplier.
    private func zoomByScroll(_ event: NSEvent) {
        let precise = event.hasPreciseScrollingDeltas
        let delta = precise ? event.scrollingDeltaY : event.deltaY
        guard delta != 0 else { return }
        let sensitivity: CGFloat = precise ? 0.005 : 0.10
        let factor = 1 + delta * sensitivity
        zoom(by: factor, towardWindowLocation: event.locationInWindow)
        scheduleZoomSettle()
    }

    /// Settles portals ~160ms after the last option+scroll zoom event, since
    /// the synthesized magnification never fires `didEndLiveMagnify`.
    private func scheduleZoomSettle() {
        zoomSettleTask?.cancel()
        zoomSettleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.callbacks.onViewportSettled(self.window)
            }
        }
    }

    /// The pane view under a point in this view's coordinates, if any.
    func paneView(at point: CGPoint) -> CanvasPaneView? {
        let docPoint = documentView.convert(point, from: self)
        for pane in model.layout.panes.reversed() {
            if let view = paneViews[pane.id], view.frame.contains(docPoint) {
                return view
            }
        }
        return nil
    }

    func removeCommandScrollMonitor() {
        commandScrollEventRouter?.remove()
        commandScrollEventRouter = nil
    }

    // MARK: Command+scroll discovery hint

    /// Debounced trigger: after ~1.2s of scrolling inside a pane, show a
    /// one-time hint that Command+scroll pans the canvas. Cancellable Task
    /// (no banned asyncAfter); re-entry restarts the debounce.
    func noteInPaneScrollForHint() {
        guard !Self.didShowCommandScrollHintThisSession else { return }
        guard commandScrollHintHost == nil else { return }
        commandScrollHintTask?.cancel()
        commandScrollHintTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.presentCommandScrollHint() }
        }
    }

    func presentCommandScrollHint() {
        presentCommandScrollHint(markSessionShown: true, replacingExisting: false)
    }

    func presentCommandScrollHint(markSessionShown: Bool, replacingExisting: Bool) {
        if replacingExisting {
            commandScrollHintHost?.removeFromSuperview()
            commandScrollHintHost = nil
        } else {
            guard commandScrollHintHost == nil else { return }
        }

        if markSessionShown {
            guard !Self.didShowCommandScrollHintThisSession else { return }
            Self.didShowCommandScrollHintThisSession = true
        }

        let host = NSHostingView(rootView: CanvasCommandScrollHint(text: commandScrollHintText))
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        addSubview(host, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: centerXAnchor),
            host.topAnchor.constraint(equalTo: topAnchor, constant: 24),
        ])
        commandScrollHintHost = host

        // Auto-dismiss after a few seconds (cancellable, lifecycle-tied).
        commandScrollHintTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_400_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.dismissCommandScrollHint() }
        }
    }

    func dismissCommandScrollHint() {
        guard let host = commandScrollHintHost else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            host.animator().alphaValue = 0
        }, completionHandler: { [weak host] in
            Task { @MainActor [weak host] in
                host?.removeFromSuperview()
            }
        })
        commandScrollHintHost = nil
    }
}
