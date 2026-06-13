import AppKit
import SwiftUI
import CmuxCanvas

/// Command+scroll canvas panning and the one-time discovery hint that teaches
/// it. Split out of CanvasRootView to keep the core view file focused.
extension CanvasRootView {
    func installCommandScrollMonitor() {
        guard commandScrollMonitor == nil else { return }
        commandScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  let window = self.window,
                  event.window === window else {
                return event
            }
            let location = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(location) else { return event }

            if event.modifierFlags.contains(.command) {
                self.scrollView.scrollWheel(with: event)
                return nil
            }

            // A plain scroll that lands on a pane is consumed by the pane's
            // content (the canvas doesn't pan), so this is the teachable
            // moment for Command+scroll. Empty-canvas scrolls already pan and
            // need no hint.
            if self.paneView(at: location) != nil {
                self.noteInPaneScrollForHint()
            }
            return event
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

    // MARK: Command+scroll discovery hint

    /// Debounced trigger: after ~1.2s of scrolling inside a pane, show a
    /// one-time hint that Command+scroll pans the canvas. Cancellable Task
    /// (no banned asyncAfter); re-entry restarts the debounce.
    func noteInPaneScrollForHint() {
        guard !Self.didShowCommandScrollHintThisSession else { return }
        commandScrollHintTask?.cancel()
        commandScrollHintTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.presentCommandScrollHint() }
        }
    }

    func presentCommandScrollHint() {
        guard !Self.didShowCommandScrollHintThisSession, commandScrollHintHost == nil else { return }
        Self.didShowCommandScrollHintThisSession = true

        let host = NSHostingView(rootView: CanvasCommandScrollHint(text: commandScrollHintText))
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        addSubview(host, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: centerXAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
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
            host?.removeFromSuperview()
        })
        commandScrollHintHost = nil
    }
}
