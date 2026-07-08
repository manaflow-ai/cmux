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
                    stableID: display.stableID,
                    frame: display.frame,
                    visibleFrame: display.visibleFrame
                )
            }
            .sorted { lhs, rhs in
                let lhsID = lhs.stableID ?? ""
                let rhsID = rhs.stableID ?? ""
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
        guard isUsableRect(standardizedFrame) else { return nil }

        let usableDisplays = displays.filter { isUsableRect($0.visibleFrame) }
        guard !usableDisplays.isEmpty else { return nil }
        if isFullyCovered(standardizedFrame, by: usableDisplays.map(\.visibleFrame)) {
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
        return rectApproximatelyEqual(fitted, standardizedFrame) ? nil : fitted
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
            distanceSquared(from: center, to: lhs.visibleFrame)
                < distanceSquared(from: center, to: rhs.visibleFrame)
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

    private func distanceSquared(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let nearestX = min(max(point.x, rect.minX), rect.maxX)
        let nearestY = min(max(point.y, rect.minY), rect.maxY)
        let dx = nearestX - point.x
        let dy = nearestY - point.y
        return (dx * dx) + (dy * dy)
    }

    private func isFullyCovered(_ frame: CGRect, by visibleFrames: [CGRect]) -> Bool {
        var uncovered = [frame]
        for visibleFrame in visibleFrames {
            uncovered = uncovered.flatMap { rect in
                uncoveredPieces(of: rect, afterCoveringWith: visibleFrame)
            }
            if uncovered.isEmpty { return true }
        }
        return false
    }

    private func uncoveredPieces(of rect: CGRect, afterCoveringWith cover: CGRect) -> [CGRect] {
        let intersection = rect.intersection(cover)
        guard isUsableRect(intersection) else { return [rect] }

        var pieces: [CGRect] = []
        if intersection.minY > rect.minY {
            pieces.append(CGRect(
                x: rect.minX,
                y: rect.minY,
                width: rect.width,
                height: intersection.minY - rect.minY
            ))
        }
        if intersection.maxY < rect.maxY {
            pieces.append(CGRect(
                x: rect.minX,
                y: intersection.maxY,
                width: rect.width,
                height: rect.maxY - intersection.maxY
            ))
        }

        let middleMinY = max(rect.minY, intersection.minY)
        let middleMaxY = min(rect.maxY, intersection.maxY)
        if middleMaxY > middleMinY {
            if intersection.minX > rect.minX {
                pieces.append(CGRect(
                    x: rect.minX,
                    y: middleMinY,
                    width: intersection.minX - rect.minX,
                    height: middleMaxY - middleMinY
                ))
            }
            if intersection.maxX < rect.maxX {
                pieces.append(CGRect(
                    x: intersection.maxX,
                    y: middleMinY,
                    width: rect.maxX - intersection.maxX,
                    height: middleMaxY - middleMinY
                ))
            }
        }

        return pieces.filter { isUsableRect($0) }
    }

    private func isUsableRect(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.width > 0
            && rect.height > 0
    }

    private func rectApproximatelyEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = 0.5
    ) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

}
