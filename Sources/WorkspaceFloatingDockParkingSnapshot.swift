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
        availableScreenFrames: [CGRect] = [],
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
        let neighboringScreenFrames = Self.neighboringScreenFrames(
            visibleScreenFrame: visibleScreenFrame,
            availableScreenFrames: availableScreenFrames
        )
        let parkedFrame = Self.parkedFrame(
            windowSize: restoreFrame.size,
            minY: y,
            visibleWidth: parkedVisibleWidth,
            visibleScreenFrame: visibleScreenFrame,
            neighboringScreenFrames: neighboringScreenFrames
        )
        let revealedFrame = Self.parkedFrame(
            windowSize: restoreFrame.size,
            minY: y,
            visibleWidth: revealedVisibleWidth,
            visibleScreenFrame: visibleScreenFrame,
            neighboringScreenFrames: neighboringScreenFrames
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
        visibleScreenFrame: CGRect,
        neighboringScreenFrames: [CGRect]
    ) -> CGRect {
        let offscreenFrame = CGRect(
            x: visibleScreenFrame.maxX - visibleWidth,
            y: minY,
            width: windowSize.width,
            height: windowSize.height
        )
        guard intersectionArea(of: offscreenFrame, with: neighboringScreenFrames) > 0 else {
            return offscreenFrame
        }
        // A full-size window cannot live beyond an internal display boundary
        // without appearing on the neighboring monitor. Keep the actual window
        // on the owner's right edge and compact only its parked presentation;
        // `restoreFrame` remains the user's full-size geometry.
        return CGRect(
            x: visibleScreenFrame.maxX - visibleWidth,
            y: minY,
            width: visibleWidth,
            height: windowSize.height
        )
    }

    private static func neighboringScreenFrames(
        visibleScreenFrame: CGRect,
        availableScreenFrames: [CGRect]
    ) -> [CGRect] {
        availableScreenFrames.filter { frame in
            intersectionArea(visibleScreenFrame, frame) == 0
        }
    }

    private static func intersectionArea(of frame: CGRect, with screens: [CGRect]) -> CGFloat {
        screens.reduce(0) { $0 + intersectionArea(frame, $1) }
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
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
