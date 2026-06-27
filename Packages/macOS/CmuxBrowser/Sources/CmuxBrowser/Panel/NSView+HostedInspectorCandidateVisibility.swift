import AppKit

extension NSView {
    /// Whether this view is a viable hosted Web Inspector candidate: shown, opaque
    /// enough to register, and larger than a hairline in both dimensions.
    public var isVisibleHostedInspectorCandidate: Bool {
        !isHidden &&
            alphaValue > 0 &&
            frame.width > 1 &&
            frame.height > 1
    }

    /// Whether this view is a viable sibling (page) candidate next to a hosted
    /// inspector: shown, opaque enough to register, and taller than a hairline.
    /// Width is intentionally not constrained so a nearly collapsed page still
    /// qualifies as the divider's other side.
    public var isVisibleHostedInspectorSiblingCandidate: Bool {
        !isHidden &&
            alphaValue > 0 &&
            frame.height > 1
    }
}
