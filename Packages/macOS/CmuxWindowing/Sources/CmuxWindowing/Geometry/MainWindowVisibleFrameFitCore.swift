public import CoreGraphics

/// Pure decision core for fitting main-window frames into current visible displays.
///
/// Callers use this after a real display-topology change, or while restoring
/// stale persisted geometry onto a different display arrangement. A frame that
/// already fits fully inside any current visible display is always a no-op.
public struct MainWindowVisibleFrameFitCore: Sendable {
    /// Creates a visible-frame fit core.
    public init() {}

    /// Returns an order-independent signature for display-topology changes.
    ///
    /// - Parameter displays: Display geometry snapshots in any order.
    /// - Returns: A sorted signature that excludes side and bottom Dock insets.
    public func topologySignature(
        of displays: [SessionDisplayGeometry]
    ) -> [MainWindowVisibleFrameTopologySignatureEntry] {
        displays
            .map { display in
                MainWindowVisibleFrameTopologySignatureEntry(
                    displayID: display.displayID,
                    frame: display.frame,
                    visibleFrame: display.visibleFrame
                )
            }
            .sorted { lhs, rhs in
                let lhsID = Self.displayIDSortValue(lhs.displayID)
                let rhsID = Self.displayIDSortValue(rhs.displayID)
                if lhsID != rhsID { return lhsID < rhsID }
                if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
                if lhs.frame.minY != rhs.frame.minY { return lhs.frame.minY < rhs.frame.minY }
                if lhs.frame.width != rhs.frame.width { return lhs.frame.width < rhs.frame.width }
                if lhs.frame.height != rhs.frame.height { return lhs.frame.height < rhs.frame.height }
                return lhs.topInset < rhs.topInset
            }
    }

    /// Returns fit decisions for `frames`, preserving input order.
    ///
    /// - Parameters:
    ///   - frames: Window frames in global screen coordinates.
    ///   - displays: Current display geometry snapshots.
    ///   - minimumWidth: Minimum width to enforce when an offscreen frame must be clamped.
    ///   - minimumHeight: Minimum height to enforce when an offscreen frame must be clamped.
    /// - Returns: A fitted frame for each input, or `nil` when that frame must not move.
    public func fittedFrames(
        for frames: [CGRect],
        displays: [SessionDisplayGeometry],
        minimumWidth: CGFloat,
        minimumHeight: CGFloat
    ) -> [CGRect?] {
        frames.map { frame in
            fittedFrame(
                for: frame,
                displays: displays,
                minimumWidth: minimumWidth,
                minimumHeight: minimumHeight
            )
        }
    }

    /// Returns a fitted frame, or `nil` when `frame` already fits a visible display.
    ///
    /// - Parameters:
    ///   - frame: Window frame in global screen coordinates.
    ///   - displays: Current display geometry snapshots.
    ///   - minimumWidth: Minimum width to enforce when clamping.
    ///   - minimumHeight: Minimum height to enforce when clamping.
    /// - Returns: The clamped/shrunk frame, or `nil` for a strict no-op.
    public func fittedFrame(
        for frame: CGRect,
        displays: [SessionDisplayGeometry],
        minimumWidth: CGFloat,
        minimumHeight: CGFloat
    ) -> CGRect? {
        let standardizedFrame = frame.standardized
        guard Self.isUsableRect(standardizedFrame) else { return nil }

        let usableDisplays = displays.filter { Self.isUsableRect($0.visibleFrame) }
        guard !usableDisplays.isEmpty else { return nil }
        if usableDisplays.contains(where: { Self.contains($0.visibleFrame, standardizedFrame) }) {
            return nil
        }

        let targetDisplay = targetDisplay(for: standardizedFrame, in: usableDisplays)
            ?? usableDisplays[0]
        let fitted = clampFrame(
            standardizedFrame,
            within: targetDisplay.visibleFrame,
            minimumWidth: minimumWidth,
            minimumHeight: minimumHeight
        )
        return Self.rectApproximatelyEqual(fitted, standardizedFrame) ? nil : fitted
    }

    private func targetDisplay(
        for frame: CGRect,
        in displays: [SessionDisplayGeometry]
    ) -> SessionDisplayGeometry? {
        let overlaps = displays.map { display in
            (display: display, area: intersectionArea(frame, display.visibleFrame))
        }
        if let best = overlaps.max(by: { $0.area < $1.area }), best.area > 0 {
            return best.display
        }

        let center = CGPoint(x: frame.midX, y: frame.midY)
        return displays.min { lhs, rhs in
            distanceSquared(lhs.visibleFrame, center) < distanceSquared(rhs.visibleFrame, center)
        }
    }

    private func clampFrame(
        _ frame: CGRect,
        within visibleFrame: CGRect,
        minimumWidth: CGFloat,
        minimumHeight: CGFloat
    ) -> CGRect {
        let maxWidth = max(visibleFrame.width, 1)
        let maxHeight = max(visibleFrame.height, 1)
        let widthFloor = min(minimumWidth, maxWidth)
        let heightFloor = min(minimumHeight, maxHeight)

        let width = min(max(frame.width, widthFloor), maxWidth)
        let height = min(max(frame.height, heightFloor), maxHeight)
        let maxX = visibleFrame.maxX - width
        let maxY = visibleFrame.maxY - height
        let x = min(max(frame.minX, visibleFrame.minX), maxX)
        let y = min(max(frame.minY, visibleFrame.minY), maxY)

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return max(0, intersection.width) * max(0, intersection.height)
    }

    private func distanceSquared(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = rect.midX - point.x
        let dy = rect.midY - point.y
        return (dx * dx) + (dy * dy)
    }

    private static func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
        outer.minX <= inner.minX
            && outer.minY <= inner.minY
            && outer.maxX >= inner.maxX
            && outer.maxY >= inner.maxY
    }

    private static func isUsableRect(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.width > 0
            && rect.height > 0
    }

    private static func rectApproximatelyEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = 0.5
    ) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private static func displayIDSortValue(_ displayID: UInt32?) -> UInt64 {
        displayID.map(UInt64.init) ?? UInt64.max
    }
}
