import AppKit
import CmuxTerminal
import CmuxTerminalFrontend

/// Compatibility interaction adapter for a persistent frontend panel.
///
/// Input, IME, focus, drag-and-drop, copy mode, and accessibility behavior stay
/// inherited from `GhosttyNSView` while renderer pixels live under the
/// Ghostty-free `TerminalFrontendSurfaceView`. This adapter disappears when
/// the remaining interaction behavior moves into `CmuxTerminalFrontend`.
final class ExternalTerminalHostNSView: GhosttyNSView {
    private(set) var frontendPanel: TerminalFrontendPanel?

    override var renderOwnership: TerminalSurfaceRenderOwnership {
        .externalCompositor
    }

    func installFrontendPanel(_ panel: TerminalFrontendPanel) {
        if let frontendPanel {
            precondition(
                frontendPanel === panel,
                "An external interaction adapter cannot change terminal identity"
            )
            return
        }
        frontendPanel = panel
        let surfaceView = panel.surfaceView
        surfaceView.removeFromSuperview()
        surfaceView.frame = bounds
        surfaceView.autoresizingMask = [.width, .height]
        addSubview(surfaceView, positioned: .below, relativeTo: nil)
    }

    override func layout() {
        super.layout()
        frontendPanel?.surfaceView.frame = bounds
    }

    override func makeBackingLayer() -> CALayer {
        let hostLayer = CALayer()
        hostLayer.isOpaque = false
        return hostLayer
    }
}
