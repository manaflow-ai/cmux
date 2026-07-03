import CoreGraphics

/// One display's geometry contribution to the main-window rescue gate.
///
/// `visibleFrame` is included so side/bottom Dock changes can trigger a
/// lenient reachability pass for edge-parked windows. Display IDs are
/// deliberately omitted because dock/KVM/Sidecar wake paths can re-enumerate
/// the same physical arrangement with new `NSScreenNumber` values.
struct MainWindowDisplayTopologySignatureEntry: Equatable {
    let frame: CGRect
    let visibleFrame: CGRect

    var topInset: CGFloat {
        frame.maxY - visibleFrame.maxY
    }

    func hasSameArrangement(as other: MainWindowDisplayTopologySignatureEntry) -> Bool {
        frame == other.frame && topInset == other.topInset
    }
}
