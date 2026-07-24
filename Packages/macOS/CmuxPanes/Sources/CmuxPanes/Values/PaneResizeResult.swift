public import CoreGraphics

/// Outcome of a pane-size command shared by shortcut, palette, and automation entry points.
public enum PaneResizeResult: Equatable, Sendable {
    /// The requested resize was applied without reaching a layout bound.
    case applied(actualShare: CGFloat)
    /// The resize was applied after clamping an infeasible requested share.
    case clamped(requestedShare: CGFloat, actualShare: CGFloat)
    /// The focused pane has no split ancestor on the requested axis.
    case noMatchingSplit
    /// The selected layout is managed by a different geometry system.
    case unsupportedLayout
    /// The command could not be applied for the supplied reason.
    case rejected(reason: String)

    public var didApply: Bool {
        switch self {
        case .applied, .clamped:
            return true
        case .noMatchingSplit, .unsupportedLayout, .rejected:
            return false
        }
    }
}
