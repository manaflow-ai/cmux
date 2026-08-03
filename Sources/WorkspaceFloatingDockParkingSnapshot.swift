import AppKit

/// Immutable screen geometry for one parked workspace floating window.
///
/// The interaction policy is informed by Loop's Stash feature at revision
/// `3b632db585ceeb5208c7e4ec4a43cf9c05804b34`. cmux independently implements
/// the geometry and native-window lifecycle for its workspace-owned panels.
struct WorkspaceFloatingDockParkingSnapshot: Equatable {
    /// Keeps the real window identifiable at rest by exposing its native titlebar chrome.
    static let restingPeekWidth = WindowChromeMetrics.nativeTrafficLightLeadingInset
    static let maximumRestingPeekFraction: CGFloat = 0.2
    static let hoverRevealDistance: CGFloat = 96
    static let hoverExitTolerance: CGFloat = 15
    static let preferredTargetHeight: CGFloat = 100

    let restoreFrame: CGRect
    let visibleScreenFrame: CGRect
    let parkedFrame: CGRect
    let revealedFrame: CGRect
    let restingVisibleFrame: CGRect
    let restingHitFrame: CGRect
    let hoverExitFrame: CGRect

    init(
        restoreFrame: CGRect,
        visibleScreenFrame: CGRect,
        parkedMinY: CGFloat? = nil,
        restingTargetMinY: CGFloat? = nil,
        restingTargetHeight: CGFloat? = nil
    ) {
        let parkedVisibleWidth = Self.parkedVisibleWidth(for: restoreFrame.width)
        let revealedVisibleWidth = min(
            restoreFrame.width,
            parkedVisibleWidth + Self.hoverRevealDistance
        )
        let y = Self.clampedMinY(
            parkedMinY ?? restoreFrame.minY,
            windowHeight: restoreFrame.height,
            visibleScreenFrame: visibleScreenFrame
        )
        let parkedFrame = CGRect(
            x: visibleScreenFrame.maxX - parkedVisibleWidth,
            y: y,
            width: restoreFrame.width,
            height: restoreFrame.height
        )
        let revealedFrame = CGRect(
            x: visibleScreenFrame.maxX - revealedVisibleWidth,
            y: y,
            width: restoreFrame.width,
            height: restoreFrame.height
        )
        self.restoreFrame = restoreFrame
        self.visibleScreenFrame = visibleScreenFrame
        self.parkedFrame = parkedFrame
        self.revealedFrame = revealedFrame
        let visibleSlice = parkedFrame.intersection(visibleScreenFrame)
        self.restingVisibleFrame = visibleSlice
        if let restingTargetMinY, let restingTargetHeight {
            self.restingHitFrame = CGRect(
                x: visibleSlice.minX,
                y: restingTargetMinY,
                width: visibleSlice.width,
                height: restingTargetHeight
            ).intersection(visibleScreenFrame)
        } else {
            self.restingHitFrame = visibleSlice
        }
        self.hoverExitFrame = CGRect(
            x: revealedFrame.minX,
            y: restingHitFrame.minY,
            width: revealedVisibleWidth,
            height: restingHitFrame.height
        ).insetBy(
            dx: -Self.hoverExitTolerance,
            dy: -Self.hoverExitTolerance
        )
    }

    func containsRestingPoint(_ point: CGPoint) -> Bool {
        !restingHitFrame.isNull && restingHitFrame.contains(point)
    }

    func containsRevealedPoint(_ point: CGPoint) -> Bool {
        hoverExitFrame.contains(point)
    }

    func migrated(toVisibleScreenFrame targetVisibleScreenFrame: CGRect) -> Self {
        Self(
            restoreFrame: WorkspaceFloatingDockScreenPlacement.remappedFramePreservingSize(
                restoreFrame,
                from: visibleScreenFrame,
                to: targetVisibleScreenFrame
            ),
            visibleScreenFrame: targetVisibleScreenFrame
        )
    }

    static func arranged(
        restoreFrames: [CGRect],
        visibleScreenFrame: CGRect
    ) -> [WorkspaceFloatingDockParkingSnapshot] {
        guard restoreFrames.count > 1 else {
            return restoreFrames.map {
                WorkspaceFloatingDockParkingSnapshot(
                    restoreFrame: $0,
                    visibleScreenFrame: visibleScreenFrame
                )
            }
        }

        let maximumOrigins = restoreFrames.map {
            maximumMinY(windowHeight: $0.height, visibleScreenFrame: visibleScreenFrame)
        }
        var spacing = preferredTargetHeight
        for index in restoreFrames.indices.dropFirst() {
            spacing = min(
                spacing,
                max(
                    0,
                    (maximumOrigins[index] - visibleScreenFrame.minY) / CGFloat(index)
                )
            )
        }

        var upperBounds = maximumOrigins
        for index in stride(from: restoreFrames.count - 2, through: 0, by: -1) {
            upperBounds[index] = min(
                upperBounds[index],
                upperBounds[index + 1] - spacing
            )
        }

        var arrangedOrigins: [CGFloat] = []
        arrangedOrigins.reserveCapacity(restoreFrames.count)
        for index in restoreFrames.indices {
            let lowerBound = index == 0
                ? visibleScreenFrame.minY
                : arrangedOrigins[index - 1] + spacing
            arrangedOrigins.append(
                min(
                    max(restoreFrames[index].minY, lowerBound),
                    upperBounds[index]
                )
            )
        }

        let targetHeight = min(
            preferredTargetHeight,
            visibleScreenFrame.height / CGFloat(restoreFrames.count)
        )
        let targetStackHeight = targetHeight * CGFloat(restoreFrames.count)
        let targetStackMinY = min(
            max(arrangedOrigins[0], visibleScreenFrame.minY),
            visibleScreenFrame.maxY - targetStackHeight
        )

        return restoreFrames.indices.map { index in
            WorkspaceFloatingDockParkingSnapshot(
                restoreFrame: restoreFrames[index],
                visibleScreenFrame: visibleScreenFrame,
                parkedMinY: arrangedOrigins[index],
                restingTargetMinY: targetStackMinY + (CGFloat(index) * targetHeight),
                restingTargetHeight: targetHeight
            )
        }
    }

    private static func parkedVisibleWidth(for windowWidth: CGFloat) -> CGFloat {
        max(
            0,
            min(
                windowWidth,
                restingPeekWidth,
                windowWidth * maximumRestingPeekFraction
            )
        )
    }

    private static func clampedMinY(
        _ proposedMinY: CGFloat,
        windowHeight: CGFloat,
        visibleScreenFrame: CGRect
    ) -> CGFloat {
        min(
            max(proposedMinY, visibleScreenFrame.minY),
            maximumMinY(
                windowHeight: windowHeight,
                visibleScreenFrame: visibleScreenFrame
            )
        )
    }

    private static func maximumMinY(
        windowHeight: CGFloat,
        visibleScreenFrame: CGRect
    ) -> CGFloat {
        guard windowHeight < visibleScreenFrame.height else {
            return visibleScreenFrame.minY
        }
        return visibleScreenFrame.maxY - windowHeight
    }
}
