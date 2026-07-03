public import CoreGraphics

/// One display's geometry contribution to the main-window rescue gate.
///
/// `visibleFrame` is included so side/bottom Dock changes can trigger a
/// lenient reachability pass for edge-parked windows. Display IDs are
/// deliberately omitted because dock/KVM/Sidecar wake paths can re-enumerate
/// the same physical arrangement with new `NSScreenNumber` values.
public struct MainWindowDisplayTopologySignatureEntry: Equatable, Sendable {
    /// The display's full frame in global screen coordinates.
    public let frame: CGRect
    /// The display's visible frame after menu bar and Dock exclusions.
    public let visibleFrame: CGRect

    /// Height excluded from the display's top edge.
    public var topInset: CGFloat {
        frame.maxY - visibleFrame.maxY
    }

    func hasSameArrangement(as other: MainWindowDisplayTopologySignatureEntry) -> Bool {
        frame == other.frame && topInset == other.topInset
    }
}
