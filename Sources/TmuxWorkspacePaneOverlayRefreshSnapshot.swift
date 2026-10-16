import AppKit
import Bonsplit

/// Includes AppKit geometry with the domain inputs before deciding to render.
struct TmuxWorkspacePaneOverlayRefreshSnapshot: Equatable {
    let inputs: TmuxWorkspacePaneOverlayInputs
    let window: ObjectIdentifier
    let referenceView: ObjectIdentifier?
    let referenceBounds: CGRect?
    let exactRects: [UUID: CGRect]
    /// The layout actually used by `state(for:)`, normalized to ignore its
    /// sampling timestamp. This catches live Bonsplit geometry that has not
    /// reached the workspace cache yet.
    let effectiveLayout: LayoutSnapshot?
}
