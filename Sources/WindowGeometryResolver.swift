import CoreGraphics

struct SessionDisplayGeometry {
    let displayID: UInt32?
    let frame: CGRect
    let visibleFrame: CGRect
}

enum WindowGeometryResolver {
    static func resolvedStartupPrimaryWindowFrame(
        primarySnapshot: SessionWindowSnapshot?,
        fallbackFrame: SessionRectSnapshot?,
        fallbackDisplaySnapshot: SessionDisplaySnapshot?,
        availableDisplays: [SessionDisplayGeometry],
        fallbackDisplay: SessionDisplayGeometry?,
        sharedGeometryHint: SharedWindowGeometryHint? = nil
    ) -> CGRect {
        if let primary = resolvedWindowFrame(
            from: primarySnapshot?.frame,
            display: primarySnapshot?.display,
            availableDisplays: availableDisplays,
            fallbackDisplay: fallbackDisplay
        ) {
            return primary
        }

        if let fallback = resolvedWindowFrame(
            from: fallbackFrame,
            display: fallbackDisplaySnapshot,
            availableDisplays: availableDisplays,
            fallbackDisplay: fallbackDisplay
        ) {
            return fallback
        }

        return resolvedFreshMainWindowFrame(
            sharedGeometryHint: sharedGeometryHint,
            availableDisplays: availableDisplays,
            fallbackDisplay: fallbackDisplay
        )
    }

    static func resolvedFreshMainWindowFrame(
        sharedGeometryHint: SharedWindowGeometryHint?,
        availableDisplays: [SessionDisplayGeometry],
        fallbackDisplay: SessionDisplayGeometry?
    ) -> CGRect {
        if let hintFrame = resolvedWindowFrame(
            from: sharedGeometryHint?.frame,
            display: sharedGeometryHint?.display,
            availableDisplays: availableDisplays,
            fallbackDisplay: fallbackDisplay
        ), isUsableFreshWindowFrame(
            hintFrame,
            availableDisplays: availableDisplays,
            fallbackDisplay: fallbackDisplay
        ) {
            return hintFrame
        }

        return defaultFreshMainWindowFrame(
            availableDisplays: availableDisplays,
            fallbackDisplay: fallbackDisplay
        )
    }

    static func resolvedWindowFrame(
        from frameSnapshot: SessionRectSnapshot?,
        display displaySnapshot: SessionDisplaySnapshot?,
        availableDisplays: [SessionDisplayGeometry],
        fallbackDisplay: SessionDisplayGeometry?
    ) -> CGRect? {
        guard let frameSnapshot else { return nil }
        let frame = frameSnapshot.cgRect
        guard frame.width.isFinite,
              frame.height.isFinite,
              frame.origin.x.isFinite,
              frame.origin.y.isFinite else {
            return nil
        }

        let minWidth = CGFloat(SessionPersistencePolicy.minimumWindowWidth)
        let minHeight = CGFloat(SessionPersistencePolicy.minimumWindowHeight)
        guard frame.width >= minWidth,
              frame.height >= minHeight else {
            return nil
        }

        guard !availableDisplays.isEmpty else { return frame }

        if let targetDisplay = display(for: displaySnapshot, in: availableDisplays) {
            if shouldPreserveExactFrame(
                frame: frame,
                displaySnapshot: displaySnapshot,
                targetDisplay: targetDisplay
            ) {
                return frame
            }
            return resolvedWindowFrame(
                frame: frame,
                displaySnapshot: displaySnapshot,
                targetDisplay: targetDisplay,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        if let intersectingDisplay = availableDisplays.first(where: { $0.visibleFrame.intersects(frame) }) {
            return clampFrame(
                frame,
                within: intersectingDisplay.visibleFrame,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        guard let fallbackDisplay else { return frame }
        if let sourceReference = displaySnapshot?.visibleFrame?.cgRect ?? displaySnapshot?.frame?.cgRect {
            return remappedFrame(
                frame,
                from: sourceReference,
                to: fallbackDisplay.visibleFrame,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        return centeredFrame(
            frame,
            in: fallbackDisplay.visibleFrame,
            minWidth: minWidth,
            minHeight: minHeight
        )
    }

    static func clampFrame(
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

    private static func isUsableFreshWindowFrame(
        _ frame: CGRect,
        availableDisplays: [SessionDisplayGeometry],
        fallbackDisplay: SessionDisplayGeometry?
    ) -> Bool {
        let displays = availableDisplays.isEmpty ? Array([fallbackDisplay].compactMap { $0 }) : availableDisplays
        let visibleFrame = displays
            .map(\.visibleFrame)
            .filter { !$0.isNull && !$0.isEmpty }
            .max { lhs, rhs in
                intersectionArea(lhs, frame) < intersectionArea(rhs, frame)
            } ?? fallbackDisplay?.visibleFrame
        let maximumWidth = visibleFrame?.standardized.width ?? frame.width
        let maximumHeight = visibleFrame?.standardized.height ?? frame.height
        let minimumWidth = min(CGFloat(SessionPersistencePolicy.minimumFreshWindowWidth), maximumWidth)
        let minimumHeight = min(CGFloat(SessionPersistencePolicy.minimumFreshWindowHeight), maximumHeight)
        return frame.width >= minimumWidth && frame.height >= minimumHeight
    }

    private static func defaultFreshMainWindowFrame(
        availableDisplays: [SessionDisplayGeometry],
        fallbackDisplay: SessionDisplayGeometry?
    ) -> CGRect {
        let display = fallbackDisplay ?? availableDisplays.first
        guard let visibleFrame = display?.visibleFrame.standardized,
              visibleFrame.width.isFinite,
              visibleFrame.height.isFinite,
              visibleFrame.width > 0,
              visibleFrame.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1_000, height: 700)
        }

        let minWidth = min(CGFloat(SessionPersistencePolicy.minimumFreshWindowWidth), visibleFrame.width)
        let minHeight = min(CGFloat(SessionPersistencePolicy.minimumFreshWindowHeight), visibleFrame.height)
        let targetWidth = min(visibleFrame.width, max(minWidth, visibleFrame.width * 0.8))
        let targetHeight = min(visibleFrame.height, max(minHeight, visibleFrame.height * 0.8))
        let requestedFrame = CGRect(
            x: visibleFrame.midX - targetWidth / 2,
            y: visibleFrame.midY - targetHeight / 2,
            width: targetWidth,
            height: targetHeight
        )

        return clampFrame(
            requestedFrame,
            within: visibleFrame,
            minWidth: minWidth,
            minHeight: minHeight
        )
    }

    private static func resolvedWindowFrame(
        frame: CGRect,
        displaySnapshot: SessionDisplaySnapshot?,
        targetDisplay: SessionDisplayGeometry,
        minWidth: CGFloat,
        minHeight: CGFloat
    ) -> CGRect {
        if targetDisplay.visibleFrame.intersects(frame) {
            if shouldPreserveAccessibleFrame(
                frame: frame,
                targetDisplay: targetDisplay
            ) {
                return frame
            }
            return clampFrame(
                frame,
                within: targetDisplay.visibleFrame,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        if let sourceReference = displaySnapshot?.visibleFrame?.cgRect ?? displaySnapshot?.frame?.cgRect {
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

    private static func shouldPreserveAccessibleFrame(
        frame: CGRect,
        targetDisplay: SessionDisplayGeometry,
        minimumVisibleTopStripWidth: CGFloat = 120,
        topStripHeight: CGFloat = 64,
        minimumVisibleTopStripHeight: CGFloat = 24
    ) -> Bool {
        let standardizedFrame = frame.standardized
        guard standardizedFrame.width.isFinite,
              standardizedFrame.height.isFinite,
              standardizedFrame.width > 0,
              standardizedFrame.height > 0,
              standardizedFrame.intersects(targetDisplay.frame) else {
            return false
        }

        let stripHeight = min(topStripHeight, standardizedFrame.height)
        let topStrip = CGRect(
            x: standardizedFrame.minX,
            y: standardizedFrame.maxY - stripHeight,
            width: standardizedFrame.width,
            height: stripHeight
        )
        let visibleTopStrip = topStrip.intersection(targetDisplay.visibleFrame)
        guard !visibleTopStrip.isNull else { return false }

        let requiredWidth = min(minimumVisibleTopStripWidth, standardizedFrame.width)
        let requiredHeight = min(minimumVisibleTopStripHeight, stripHeight)
        return visibleTopStrip.width >= requiredWidth
            && visibleTopStrip.height >= requiredHeight
    }

    private static func display(
        for snapshot: SessionDisplaySnapshot?,
        in displays: [SessionDisplayGeometry]
    ) -> SessionDisplayGeometry? {
        guard let snapshot else { return nil }
        if let displayID = snapshot.displayID,
           let exact = displays.first(where: { $0.displayID == displayID }) {
            return exact
        }

        guard let referenceRect = (snapshot.visibleFrame ?? snapshot.frame)?.cgRect else {
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
        displaySnapshot: SessionDisplaySnapshot?,
        targetDisplay: SessionDisplayGeometry
    ) -> Bool {
        guard let displaySnapshot else { return false }
        guard let snapshotDisplayID = displaySnapshot.displayID,
              let targetDisplayID = targetDisplay.displayID,
              snapshotDisplayID == targetDisplayID else {
            return false
        }

        let visibleMatches = displaySnapshot.visibleFrame.map {
            rectApproximatelyEqual($0.cgRect, targetDisplay.visibleFrame)
        } ?? false
        let frameMatches = displaySnapshot.frame.map {
            rectApproximatelyEqual($0.cgRect, targetDisplay.frame)
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
        tolerance: CGFloat = 0.5
    ) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= tolerance
            && abs(lhs.origin.y - rhs.origin.y) <= tolerance
            && abs(lhs.size.width - rhs.size.width) <= tolerance
            && abs(lhs.size.height - rhs.size.height) <= tolerance
    }
}
