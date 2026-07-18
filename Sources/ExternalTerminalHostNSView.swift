import AppKit
import CmuxTerminal

/// Interaction-only terminal host for a renderer owned by the persistent backend.
///
/// Input, IME, focus, drag-and-drop, copy mode, and accessibility behavior stay
/// inherited from `GhosttyNSView`. The plain backing layer is the structural
/// boundary that prevents this process from allocating Ghostty renderer state.
final class ExternalTerminalHostNSView: GhosttyNSView {
    override var renderOwnership: TerminalSurfaceRenderOwnership {
        .externalCompositor
    }

    override func makeBackingLayer() -> CALayer {
        let hostLayer = CALayer()
        hostLayer.isOpaque = false
        return hostLayer
    }
}
