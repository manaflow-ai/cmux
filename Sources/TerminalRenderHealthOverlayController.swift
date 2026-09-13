import AppKit
import CmuxTerminal

/// Owns one pane's render-health subscription and diagnostic overlay.
@MainActor
final class TerminalRenderHealthOverlayController {
    private weak var host: NSView?
    private weak var surface: TerminalSurface?
    private var overlay: TerminalRenderHealthOverlayView?
    private var latestFrame: NSRect?

    func attach(host: NSView, surface: TerminalSurface) {
        self.host = host
        self.surface?.onRenderHealthChanged = nil
        self.surface = surface
        surface.onRenderHealthChanged = { [weak self] health in
            Task { @MainActor [weak self] in
                self?.apply(health)
            }
        }
        apply(surface.renderHealth)
    }

    deinit {
        surface?.onRenderHealthChanged = nil
    }

    func updateFrame(_ frame: NSRect) {
        latestFrame = frame
        overlay?.frame = frame
    }

    private func apply(_ health: TerminalSurfaceRenderHealth) {
        guard let host else { return }
        guard health == .notRendering || health == .shellExited else {
            overlay?.isHidden = true
            return
        }

        let overlay: TerminalRenderHealthOverlayView
        if let existing = self.overlay {
            overlay = existing
        } else {
            overlay = TerminalRenderHealthOverlayView(frame: host.bounds)
            self.overlay = overlay
            host.addSubview(overlay, positioned: .above, relativeTo: nil)
        }
        overlay.frame = latestFrame ?? host.bounds
        overlay.apply(health)
    }
}
