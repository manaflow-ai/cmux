import CoreGraphics
import CmuxTerminalCore

/// The drawable geometry identity used by the renderer presentation gate.
struct TerminalRendererPresentationGeometry: Equatable, Sendable {
    let size: CGSize?
    let backingScale: CGFloat?

    /// Creates a geometry identity from a committed pane geometry.
    init(_ geometry: TerminalPaneGeometry?) {
        size = geometry?.size
        backingScale = geometry?.backingScale
    }
}
