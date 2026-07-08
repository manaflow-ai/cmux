public import CoreGraphics
public import CmuxWindowing

/// Resolves a persisted window frame onto the displays available at launch.
///
/// Faithful lift of the `AppDelegate.resolvedWindowFrame(...)` /
/// `resolvedStartupPrimaryWindowFrame(...)` `nonisolated static` family from
/// the AppDelegate god file. The decision tree is unchanged: prefer the exact
/// saved frame when its origin display is still attached and large enough,
/// otherwise clamp into an intersecting display, then remap proportionally
/// from the saved display to the fallback display, then center as a last
/// resort. Sub-minimum or non-finite frames are rejected (returns `nil`).
///
/// Pure value math, so a `Sendable` struct, not an actor: it reads only its
/// injected minimum-size floors and the geometry values handed to each call.
/// The app builds ``CmuxWindowing/SessionDisplayGeometry`` values from live
/// `NSScreen` state and maps its `Codable` frame/display DTOs into the
/// `CGRect` / ``SessionSourceDisplaySnapshot`` inputs here, so the on-disk wire
/// format stays owned by the app target.
public struct SessionWindowFrameResolver: Sendable {
    private let minimumWindowWidth: CGFloat
    private let minimumWindowHeight: CGFloat

    /// Creates a resolver with the minimum acceptable restored-window size.
    ///
    /// - Parameters:
    ///   - minimumWindowWidth: Frames narrower than this are rejected and the
    ///     clamp floor for surviving frames (the app passes
    ///     `SessionPersistencePolicy.minimumWindowWidth`).
    ///   - minimumWindowHeight: Frames shorter than this are rejected and the
    ///     clamp floor for surviving frames (the app passes
    ///     `SessionPersistencePolicy.minimumWindowHeight`).
    public init(
        minimumWindowWidth: CGFloat = 300,
        minimumWindowHeight: CGFloat = 200
    ) {
        self.minimumWindowWidth = minimumWindowWidth
        self.minimumWindowHeight = minimumWindowHeight
    }

    /// Resolves the startup primary window frame, preferring the primary
    /// snapshot's frame and falling back to the persisted last-window
    /// geometry when the primary snapshot has no usable frame.
    public func resolvedStartupPrimaryWindowFrame(
        primaryFrame: CGRect?,
        primaryDisplay: SessionSourceDisplaySnapshot?,
        fallbackFrame: CGRect?,
        fallbackDisplay fallbackDisplaySnapshot: SessionSourceDisplaySnapshot?,
        availableDisplays: [SessionDisplayGeometry],
        fallbackDisplay: SessionDisplayGeometry?
    ) -> CGRect? {
        if let primary = resolvedWindowFrame(
            from: primaryFrame,
            display: primaryDisplay,
            availableDisplays: availableDisplays,
            fallbackDisplay: fallbackDisplay
        ) {
            return primary
        }

        return resolvedWindowFrame(
            from: fallbackFrame,
            display: fallbackDisplaySnapshot,
            availableDisplays: availableDisplays,
            fallbackDisplay: fallbackDisplay
        )
    }

    /// Resolves a saved frame onto the currently available displays, or
    /// returns `nil` when the saved frame is non-finite or below the minimum
    /// acceptable size.
    public func resolvedWindowFrame(
        from frame: CGRect?,
        display displaySnapshot: SessionSourceDisplaySnapshot?,
        availableDisplays: [SessionDisplayGeometry],
        fallbackDisplay: SessionDisplayGeometry?
    ) -> CGRect? {
        guard let frame else { return nil }
        guard frame.width.isFinite,
              frame.height.isFinite,
              frame.origin.x.isFinite,
              frame.origin.y.isFinite else {
            return nil
        }

        let minWidth = minimumWindowWidth
        let minHeight = minimumWindowHeight
        guard frame.width >= minWidth,
              frame.height >= minHeight else {
            return nil
        }

        guard !availableDisplays.isEmpty else { return frame }

        if let targetDisplay = Self.display(for: displaySnapshot, in: availableDisplays) {
            if Self.shouldPreserveExactFrame(
                frame: frame,
                displaySnapshot: displaySnapshot,
                targetDisplay: targetDisplay
            ) {
                return frame
            }
            return Self.resolvedWindowFrame(
                frame: frame,
                displaySnapshot: displaySnapshot,
                availableDisplays: availableDisplays,
                targetDisplay: targetDisplay,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        if let intersectingDisplay = availableDisplays.first(where: { $0.visibleFrame.intersects(frame) }) {
            return Self.clampFrame(
                frame,
                within: intersectingDisplay.visibleFrame,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        guard let fallbackDisplay else { return frame }
        if let sourceReference = displaySnapshot?.visibleFrame ?? displaySnapshot?.frame {
            return Self.remappedFrame(
                frame,
                from: sourceReference,
                to: fallbackDisplay.visibleFrame,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        return Self.centeredFrame(
            frame,
            in: fallbackDisplay.visibleFrame,
            minWidth: minWidth,
            minHeight: minHeight
        )
    }

    private static func resolvedWindowFrame(
        frame: CGRect,
        displaySnapshot: SessionSourceDisplaySnapshot?,
        availableDisplays: [SessionDisplayGeometry],
        targetDisplay: SessionDisplayGeometry,
        minWidth: CGFloat,
        minHeight: CGFloat
    ) -> CGRect {
        if targetDisplay.visibleFrame.intersects(frame) {
            let fitCore = MainWindowVisibleFrameFitCore()
            return fitCore.fittedFrame(
                for: frame,
                displays: availableDisplays,
                minimumWidth: minWidth,
                minimumHeight: minHeight
            ) ?? frame
        }

        if let sourceReference = displaySnapshot?.visibleFrame ?? displaySnapshot?.frame {
            return remappedFrame(
                frame,
                from: sourceReference,
                to: targetDisplay.visibleFrame,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        return centeredFrame(
            frame,
            in: targetDisplay.visibleFrame,
            minWidth: minWidth,
            minHeight: minHeight
        )
    }

    private static func display(
        for snapshot: SessionSourceDisplaySnapshot?,
        in displays: [SessionDisplayGeometry]
    ) -> SessionDisplayGeometry? {
        guard let snapshot else { return nil }
        if let displayID = snapshot.displayID,
           let exact = displays.first(where: { $0.displayID == displayID }) {
            return exact
        }

        guard let referenceRect = snapshot.visibleFrame ?? snapshot.frame else {
            return nil
        }

        let overlaps = displays.map { display -> (display: SessionDisplayGeometry, area: CGFloat) in
            (display, intersectionArea(referenceRect, display.visibleFrame))
        }
        if let bestOverlap = overlaps.max(by: { $0.area < $1.area }), bestOverlap.area > 0 {
            return bestOverlap.display
        }

        let referenceCenter = CGPoint(x: referenceRect.midX, y: referenceRect.midY)
        return displays.min { lhs, rhs in
            let lhsDistance = distanceSquared(lhs.visibleFrame, referenceCenter)
            let rhsDistance = distanceSquared(rhs.visibleFrame, referenceCenter)
            return lhsDistance < rhsDistance
        }
    }

    private static func remappedFrame(
        _ frame: CGRect,
        from sourceRect: CGRect,
        to targetRect: CGRect,
        minWidth: CGFloat,
        minHeight: CGFloat
    ) -> CGRect {
        let source = sourceRect.standardized
        let target = targetRect.standardized
        guard source.width.isFinite,
              source.height.isFinite,
              source.width > 1,
              source.height > 1,
              target.width.isFinite,
              target.height.isFinite,
              target.width > 0,
              target.height > 0 else {
            return centeredFrame(frame, in: targetRect, minWidth: minWidth, minHeight: minHeight)
        }

        let relativeX = (frame.minX - source.minX) / source.width
        let relativeY = (frame.minY - source.minY) / source.height
        let relativeWidth = frame.width / source.width
        let relativeHeight = frame.height / source.height

        let remapped = CGRect(
            x: target.minX + (relativeX * target.width),
            y: target.minY + (relativeY * target.height),
            width: target.width * relativeWidth,
            height: target.height * relativeHeight
        )
        return clampFrame(remapped, within: target, minWidth: minWidth, minHeight: minHeight)
    }

    private static func centeredFrame(
        _ frame: CGRect,
        in visibleFrame: CGRect,
        minWidth: CGFloat,
        minHeight: CGFloat
    ) -> CGRect {
        let centered = CGRect(
            x: visibleFrame.midX - (frame.width / 2),
            y: visibleFrame.midY - (frame.height / 2),
            width: frame.width,
            height: frame.height
        )
        return clampFrame(centered, within: visibleFrame, minWidth: minWidth, minHeight: minHeight)
    }

    /// Clamps `frame` to sit inside `visibleFrame`, never shrinking below the
    /// given floors (capped to the visible area). The same clamp the
    /// session-restore math uses; also reused by the app's new-window cascade
    /// placement, which passes its own minimum size.
    public static func clampFrame(
        _ frame: CGRect,
        within visibleFrame: CGRect,
        minWidth: CGFloat,
        minHeight: CGFloat
    ) -> CGRect {
        guard visibleFrame.width.isFinite,
              visibleFrame.height.isFinite,
              visibleFrame.width > 0,
              visibleFrame.height > 0 else {
            return frame
        }

        let maxWidth = max(visibleFrame.width, 1)
        let maxHeight = max(visibleFrame.height, 1)
        let widthFloor = min(minWidth, maxWidth)
        let heightFloor = min(minHeight, maxHeight)

        let width = min(max(frame.width, widthFloor), maxWidth)
        let height = min(max(frame.height, heightFloor), maxHeight)
        let maxX = visibleFrame.maxX - width
        let maxY = visibleFrame.maxY - height
        let x = min(max(frame.minX, visibleFrame.minX), maxX)
        let y = min(max(frame.minY, visibleFrame.minY), maxY)

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return max(0, intersection.width) * max(0, intersection.height)
    }

    private static func distanceSquared(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = rect.midX - point.x
        let dy = rect.midY - point.y
        return (dx * dx) + (dy * dy)
    }

    private static func shouldPreserveExactFrame(
        frame: CGRect,
        displaySnapshot: SessionSourceDisplaySnapshot?,
        targetDisplay: SessionDisplayGeometry
    ) -> Bool {
        guard let displaySnapshot else { return false }
        guard let snapshotDisplayID = displaySnapshot.displayID,
              let targetDisplayID = targetDisplay.displayID,
              snapshotDisplayID == targetDisplayID else {
            return false
        }

        let visibleMatches = displaySnapshot.visibleFrame.map {
            rectApproximatelyEqual($0, targetDisplay.visibleFrame)
        } ?? false
        let frameMatches = displaySnapshot.frame.map {
            rectApproximatelyEqual($0, targetDisplay.frame)
        } ?? false
        guard visibleMatches || frameMatches else { return false }

        return frame.width.isFinite
            && frame.height.isFinite
            && frame.origin.x.isFinite
            && frame.origin.y.isFinite
    }

    private static func rectApproximatelyEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = 1
    ) -> Bool {
        let lhsStd = lhs.standardized
        let rhsStd = rhs.standardized
        return abs(lhsStd.origin.x - rhsStd.origin.x) <= tolerance
            && abs(lhsStd.origin.y - rhsStd.origin.y) <= tolerance
            && abs(lhsStd.size.width - rhsStd.size.width) <= tolerance
            && abs(lhsStd.size.height - rhsStd.size.height) <= tolerance
    }
}
