import AppKit
import Combine
import CmuxTerminal

/// Owns one pane's render-health subscription and diagnostic overlay.
final class TerminalRenderHealthOverlayController {
    private weak var host: NSView?
    private var overlay: TerminalRenderHealthOverlayView?
    private var cancellable: AnyCancellable?

    func attach(host: NSView, surface: TerminalSurface) {
        self.host = host
        cancellable?.cancel()
        cancellable = surface.$renderHealth.sink { [weak self] health in
            self?.apply(health)
        }
        apply(surface.renderHealth)
    }

    func updateFrame(_ frame: NSRect) {
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
        overlay.frame = host.bounds
        overlay.apply(health)
    }
}
