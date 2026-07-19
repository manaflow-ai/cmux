import CmuxWindowing
import CoreGraphics
import Foundation

/// Resolves one floating window against current display geometry while
/// preserving exact per-configuration positions and relative screen placement.
struct WorkspaceFloatingDockScreenPlacement {
    private static let minimumSize = CGSize(width: 320, height: 220)

    static func resolvedFrame(
        currentSignature: String?,
        configFrames: SessionConfigFrameRing,
        fallbackFrame: CGRect?,
        fallbackDisplay: SessionDisplaySnapshot?,
        availableDisplays: [SessionDisplayGeometry],
        fallbackDisplayGeometry: SessionDisplayGeometry?
    ) -> CGRect? {
        let remembered = currentSignature.flatMap(configFrames.entry(for:))
        guard let sourceFrame = remembered?.frame.cgRect ?? fallbackFrame else { return nil }
        let sourceDisplay = remembered?.display ?? fallbackDisplay
        guard isUsable(sourceFrame) else { return nil }
        guard !availableDisplays.isEmpty else { return sourceFrame }

        let targetDisplay = matchingDisplay(for: sourceDisplay, in: availableDisplays)
            ?? displayContainingMost(of: sourceFrame, in: availableDisplays)
            ?? fallbackDisplayGeometry
            ?? availableDisplays.first
        guard let targetDisplay else { return sourceFrame }

        let sourceVisibleFrame = sourceDisplay?.visibleFrame?.cgRect
            ?? sourceDisplay?.frame?.cgRect
        if let sourceVisibleFrame, approximatelyEqual(sourceVisibleFrame, targetDisplay.visibleFrame) {
            return fitted(sourceFrame, within: targetDisplay.visibleFrame)
        }
        if let sourceVisibleFrame, isUsable(sourceVisibleFrame) {
            return remappedPreservingSize(
                sourceFrame,
                from: sourceVisibleFrame,
                to: targetDisplay.visibleFrame
            )
        }
        return fitted(sourceFrame, within: targetDisplay.visibleFrame)
    }

    private static func matchingDisplay(
        for snapshot: SessionDisplaySnapshot?,
        in displays: [SessionDisplayGeometry]
    ) -> SessionDisplayGeometry? {
        guard let snapshot else { return nil }
        if let stableID = snapshot.stableID, !stableID.isEmpty {
            let stableMatches = displays.filter { $0.stableID == stableID }
            if stableMatches.count == 1 { return stableMatches[0] }
            if let geometryMatch = displayMatchingGeometry(snapshot, in: stableMatches) {
                return geometryMatch
            }
        }
        if let displayID = snapshot.displayID,
           let exact = displays.first(where: { $0.displayID == displayID }) {
            return exact
        }
        return displayMatchingGeometry(snapshot, in: displays)
    }

    private static func displayMatchingGeometry(
        _ snapshot: SessionDisplaySnapshot,
        in displays: [SessionDisplayGeometry]
    ) -> SessionDisplayGeometry? {
        guard let reference = snapshot.visibleFrame?.cgRect ?? snapshot.frame?.cgRect else {
            return nil
        }
        return displayContainingMost(of: reference, in: displays)
    }

    private static func displayContainingMost(
        of frame: CGRect,
        in displays: [SessionDisplayGeometry]
    ) -> SessionDisplayGeometry? {
        let overlaps = displays.map { display in
            (display: display, area: frame.intersection(display.visibleFrame).area)
        }
        if let best = overlaps.max(by: { $0.area < $1.area }), best.area > 0 {
            return best.display
        }
        return nil
    }

    private static func remappedPreservingSize(
        _ frame: CGRect,
        from sourceVisibleFrame: CGRect,
        to targetVisibleFrame: CGRect
    ) -> CGRect {
        let source = sourceVisibleFrame.standardized
        let target = targetVisibleFrame.standardized
        guard isUsable(source), isUsable(target) else {
            return fitted(frame, within: targetVisibleFrame)
        }
        let relativeCenterX = (frame.midX - source.minX) / source.width
        let relativeCenterY = (frame.midY - source.minY) / source.height
        let remapped = CGRect(
            x: target.minX + relativeCenterX * target.width - frame.width / 2,
            y: target.minY + relativeCenterY * target.height - frame.height / 2,
            width: frame.width,
            height: frame.height
        )
        return fitted(remapped, within: target)
    }

    private static func fitted(_ frame: CGRect, within visibleFrame: CGRect) -> CGRect {
        let visible = visibleFrame.standardized
        guard isUsable(visible) else { return frame }
        let width = min(max(frame.width, minimumSize.width), visible.width)
        let height = min(max(frame.height, minimumSize.height), visible.height)
        let maxX = visible.maxX - width
        let maxY = visible.maxY - height
        return CGRect(
            x: min(max(frame.minX, visible.minX), maxX),
            y: min(max(frame.minY, visible.minY), maxY),
            width: width,
            height: height
        )
    }

    private static func approximatelyEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = 1
    ) -> Bool {
        let lhs = lhs.standardized
        let rhs = rhs.standardized
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        rect.minX.isFinite
            && rect.minY.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.width > 0
            && rect.height > 0
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }
}
