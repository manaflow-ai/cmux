import AppKit
import SwiftUI
import CmuxCanvas

/// Command+scroll canvas panning and the one-time discovery hint that teaches
/// it. Split out of CanvasRootView to keep the core view file focused.
extension CanvasRootView {
    func installCommandScrollMonitor() {
        guard commandScrollMonitor == nil else { return }
        commandScrollMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .magnify, .keyDown, .keyUp, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self,
                  let window = self.window,
                  event.window === window else {
                return event
            }
            switch event.type {
            case .keyDown, .keyUp, .leftMouseDown, .leftMouseDragged, .leftMouseUp:
                return self.handleSpacePanEvent(event)
            default:
                break
            }
            let location = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(location) else { return event }

            // Trackpad pinch zooms the canvas no matter what the cursor is
            // over. Without intercepting, a pane swallows the magnify gesture
            // (e.g. Ghostty's own font zoom), so pinching on a terminal would
            // never zoom the canvas. Forward to the scroll view's native
            // magnifier: it anchors at the gesture point, respects the
            // magnification range, and fires didEndLiveMagnify so portals
            // settle through the normal path.
            if event.type == .magnify {
                self.scrollView.magnify(with: event)
                return nil
            }

            if event.modifierFlags.contains(.command) {
                self.scrollView.scrollWheel(with: event)
                return nil
            }

            // Option+scroll is the mouse-wheel equivalent of pinch: a mouse
            // has no magnify gesture, so this zooms toward the cursor. Cmd
            // stays pan; plain scroll stays pane content.
            if event.modifierFlags.contains(.option) {
                self.zoomByScroll(event)
                return nil
            }

            // A plain scroll that lands on a pane is consumed by the pane's
            // content (the canvas doesn't pan), so this is the teachable
            // moment for the command-scroll hint. Empty-canvas scrolls
            // already pan and need no hint.
            if self.paneView(at: location) != nil {
                self.noteInPaneScrollForHint()
            }
            return event
        }
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
        if let commandScrollMonitor {
            NSEvent.removeMonitor(commandScrollMonitor)
        }
        commandScrollMonitor = nil
    }

    // MARK: Scroll discovery hint

    /// Debounced trigger: after ~1.2s of scrolling inside a pane, show a
    /// one-time hint for the current canvas-hosted mode. Cancellable Task
    /// (no banned asyncAfter); re-entry restarts the debounce.
    func noteInPaneScrollForHint() {
        guard !didShowCurrentScrollHint else { return }
        commandScrollHintTask?.cancel()
        commandScrollHintTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.presentCommandScrollHint() }
        }
    }

    func presentCommandScrollHint() {
        guard !didShowCurrentScrollHint, commandScrollHintHost == nil else { return }
        markCurrentScrollHintShown()

        let host = NSHostingView(rootView: CanvasCommandScrollHint(
            text: currentScrollHintText,
            style: currentScrollHintStyle
        ))
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
            Task { @MainActor in
                host?.removeFromSuperview()
            }
        })
        commandScrollHintHost = nil
    }

    private var currentScrollHintStyle: CanvasScrollHintStyle {
        .commandPan
    }

    private var currentScrollHintText: String {
        commandScrollHintText
    }

    private var didShowCurrentScrollHint: Bool {
        Self.didShowCommandScrollHintThisSession
    }

    private func markCurrentScrollHintShown() {
        Self.didShowCommandScrollHintThisSession = true
    }
}
