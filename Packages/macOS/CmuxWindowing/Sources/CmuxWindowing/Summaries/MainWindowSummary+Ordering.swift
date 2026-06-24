public import Foundation

extension Sequence<MainWindowSummary> {
    /// Returns the window summaries ordered for presentation as window
    /// move/switch targets: the reference window first, then key windows,
    /// then visible windows, with a stable `windowId` tiebreak.
    ///
    /// A pure deterministic sort over the summary value type with no live
    /// AppKit access, so it can be unit-tested and reused wherever an ordered
    /// list of windows is presented. The app target supplies the live
    /// summaries (via its own `NSApp`-reading collector) and the reference
    /// window id.
    public func orderedForMoveTargets(referenceWindowId: UUID?) -> [MainWindowSummary] {
        sorted { lhs, rhs in
            let lhsIsReference = lhs.windowId == referenceWindowId
            let rhsIsReference = rhs.windowId == referenceWindowId
            if lhsIsReference != rhsIsReference { return lhsIsReference }
            if lhs.isKeyWindow != rhs.isKeyWindow { return lhs.isKeyWindow }
            if lhs.isVisible != rhs.isVisible { return lhs.isVisible }
            return lhs.windowId.uuidString < rhs.windowId.uuidString
        }
    }
}
