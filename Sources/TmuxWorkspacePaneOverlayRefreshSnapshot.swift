import AppKit

/// Includes AppKit geometry with the domain inputs before deciding to render.
struct TmuxWorkspacePaneOverlayRefreshSnapshot: Equatable {
    let inputs: TmuxWorkspacePaneOverlayInputs
    let window: ObjectIdentifier
    let referenceView: ObjectIdentifier?
    let referenceBounds: CGRect?
    let exactRects: [UUID: CGRect]
}
