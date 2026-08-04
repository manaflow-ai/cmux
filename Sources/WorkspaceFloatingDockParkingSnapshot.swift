import AppKit

/// Immutable screen geometry for one parked workspace floating window.
///
/// The interaction policy is informed by Loop's Stash feature at revision
/// `3b632db585ceeb5208c7e4ec4a43cf9c05804b34`. cmux independently implements
/// the geometry and native-window lifecycle for its workspace-owned panels.
struct WorkspaceFloatingDockParkingSnapshot: Equatable {
    /// Keeps the real window identifiable at rest while exposing less than the
    /// full native traffic-light cluster.
    static let restingPeekWidth: CGFloat = 48
    static let maximumRestingPeekFraction: CGFloat = 0.2
    static let hoverActivationDistance: CGFloat = 96
    static let hoverRevealDistance: CGFloat = 96
    static let hoverExitTolerance: CGFloat = 15
    static let preferredTargetHeight: CGFloat = 100

    let restoreFrame: CGRect
    let visibleScreenFrame: CGRect
    let parkedFrame: CGRect
    let revealedFrame: CGRect
    let restingVisibleFrame: CGRect
    let hoverActivationFrame: CGRect
    let hoverExitFrame: CGRect

    init(
        restoreFrame: CGRect,
        visibleScreenFrame: CGRect,
        availableScreenFrames _: [CGRect] = [],
        parkedMinY: CGFloat? = nil,
        hoverTargetMinY: CGFloat? = nil,
        hoverTargetHeight: CGFloat? = nil
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
        let parkedFrame = Self.parkedFrame(
            windowSize: restoreFrame.size,
            minY: y,
            visibleWidth: parkedVisibleWidth,
            visibleScreenFrame: visibleScreenFrame
        )
        let revealedFrame = Self.parkedFrame(
            windowSize: restoreFrame.size,
            minY: y,
            visibleWidth: revealedVisibleWidth,
            visibleScreenFrame: visibleScreenFrame
        )
        self.restoreFrame = restoreFrame
        self.visibleScreenFrame = visibleScreenFrame
        self.parkedFrame = parkedFrame
        self.revealedFrame = revealedFrame
        let visibleSlice = parkedFrame.intersection(visibleScreenFrame)
        self.restingVisibleFrame = visibleSlice
        let hoverTargetFrame: CGRect
        if let hoverTargetMinY, let hoverTargetHeight {
            hoverTargetFrame = CGRect(
                x: visibleSlice.minX,
                y: hoverTargetMinY,
                width: visibleSlice.width,
                height: hoverTargetHeight
            ).intersection(visibleScreenFrame)
        } else {
            hoverTargetFrame = visibleSlice
        }
        self.hoverActivationFrame = hoverTargetFrame
            .insetBy(dx: -Self.hoverActivationDistance, dy: 0)
            .intersection(visibleScreenFrame)
        let revealedVisibleFrame = revealedFrame.intersection(visibleScreenFrame)
        self.hoverExitFrame = CGRect(
            x: revealedVisibleFrame.minX,
            y: hoverTargetFrame.minY,
            width: revealedVisibleFrame.width,
            height: hoverTargetFrame.height
        ).insetBy(
            dx: -Self.hoverExitTolerance,
            dy: -Self.hoverExitTolerance
        )
    }

    func containsHoverActivationPoint(_ point: CGPoint) -> Bool {
        !hoverActivationFrame.isNull && hoverActivationFrame.contains(point)
    }

    func containsRevealedPoint(_ point: CGPoint) -> Bool {
        hoverExitFrame.contains(point)
    }

    func migrated(
        toVisibleScreenFrame targetVisibleScreenFrame: CGRect,
        availableScreenFrames: [CGRect] = []
    ) -> Self {
        Self(
            restoreFrame: WorkspaceFloatingDockScreenPlacement.remappedFramePreservingSize(
                restoreFrame,
                from: visibleScreenFrame,
                to: targetVisibleScreenFrame
            ),
            visibleScreenFrame: targetVisibleScreenFrame,
            availableScreenFrames: availableScreenFrames
        )
    }

    static func arranged(
        restoreFrames: [CGRect],
        visibleScreenFrame: CGRect,
        availableScreenFrames: [CGRect] = []
    ) -> [WorkspaceFloatingDockParkingSnapshot] {
        guard restoreFrames.count > 1 else {
            return restoreFrames.map {
                WorkspaceFloatingDockParkingSnapshot(
                    restoreFrame: $0,
                    visibleScreenFrame: visibleScreenFrame,
                    availableScreenFrames: availableScreenFrames
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
                availableScreenFrames: availableScreenFrames,
                parkedMinY: arrangedOrigins[index],
                hoverTargetMinY: targetStackMinY + (CGFloat(index) * targetHeight),
                hoverTargetHeight: targetHeight
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

    private static func parkedFrame(
        windowSize: CGSize,
        minY: CGFloat,
        visibleWidth: CGFloat,
        visibleScreenFrame: CGRect
    ) -> CGRect {
        CGRect(
            x: visibleScreenFrame.maxX - visibleWidth,
            y: minY,
            width: windowSize.width,
            height: windowSize.height
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
