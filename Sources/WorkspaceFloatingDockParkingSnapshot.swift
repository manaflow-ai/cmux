import AppKit

enum WorkspaceFloatingDockParkingEdge: Equatable {
    case leading
    case trailing
}

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
    let edge: WorkspaceFloatingDockParkingEdge
    let parkedFrame: CGRect
    let revealedFrame: CGRect
    let restingVisibleFrame: CGRect
    let restingHitFrame: CGRect
    let hoverExitFrame: CGRect

    init(
        restoreFrame: CGRect,
        visibleScreenFrame: CGRect,
        availableScreenFrames: [CGRect] = [],
        edge requestedEdge: WorkspaceFloatingDockParkingEdge? = nil,
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
        let edge = requestedEdge ?? Self.preferredEdge(
            windows: [(size: restoreFrame.size, minY: y)],
            visibleScreenFrame: visibleScreenFrame,
            availableScreenFrames: availableScreenFrames
        )
        let parkedFrame = Self.parkedFrame(
            windowSize: restoreFrame.size,
            minY: y,
            visibleWidth: parkedVisibleWidth,
            visibleScreenFrame: visibleScreenFrame,
            edge: edge
        )
        let revealedFrame = Self.parkedFrame(
            windowSize: restoreFrame.size,
            minY: y,
            visibleWidth: revealedVisibleWidth,
            visibleScreenFrame: visibleScreenFrame,
            edge: edge
        )
        self.restoreFrame = restoreFrame
        self.visibleScreenFrame = visibleScreenFrame
        self.edge = edge
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
        let revealedVisibleFrame = revealedFrame.intersection(visibleScreenFrame)
        self.hoverExitFrame = CGRect(
            x: revealedVisibleFrame.minX,
            y: restingHitFrame.minY,
            width: revealedVisibleFrame.width,
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
        let edge = preferredEdge(
            windows: restoreFrames.indices.map { index in
                (size: restoreFrames[index].size, minY: arrangedOrigins[index])
            },
            visibleScreenFrame: visibleScreenFrame,
            availableScreenFrames: availableScreenFrames
        )

        return restoreFrames.indices.map { index in
            WorkspaceFloatingDockParkingSnapshot(
                restoreFrame: restoreFrames[index],
                visibleScreenFrame: visibleScreenFrame,
                availableScreenFrames: availableScreenFrames,
                edge: edge,
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

    private static func preferredEdge(
        windows: [(size: CGSize, minY: CGFloat)],
        visibleScreenFrame: CGRect,
        availableScreenFrames: [CGRect]
    ) -> WorkspaceFloatingDockParkingEdge {
        let neighboringScreenFrames = screenFramesExcludingOwner(
            visibleScreenFrame: visibleScreenFrame,
            availableScreenFrames: availableScreenFrames
        )
        guard !neighboringScreenFrames.isEmpty else { return .trailing }

        let leadingOverlap = overlapArea(
            for: .leading,
            windows: windows,
            visibleScreenFrame: visibleScreenFrame,
            neighboringScreenFrames: neighboringScreenFrames
        )
        let trailingOverlap = overlapArea(
            for: .trailing,
            windows: windows,
            visibleScreenFrame: visibleScreenFrame,
            neighboringScreenFrames: neighboringScreenFrames
        )
        return leadingOverlap < trailingOverlap ? .leading : .trailing
    }

    private static func overlapArea(
        for edge: WorkspaceFloatingDockParkingEdge,
        windows: [(size: CGSize, minY: CGFloat)],
        visibleScreenFrame: CGRect,
        neighboringScreenFrames: [CGRect]
    ) -> CGFloat {
        windows.reduce(0) { overlap, window in
            overlap + intersectionArea(
                of: parkedFrame(
                    windowSize: window.size,
                    minY: window.minY,
                    visibleWidth: parkedVisibleWidth(for: window.size.width),
                    visibleScreenFrame: visibleScreenFrame,
                    edge: edge
                ),
                with: neighboringScreenFrames
            )
        }
    }

    private static func parkedFrame(
        windowSize: CGSize,
        minY: CGFloat,
        visibleWidth: CGFloat,
        visibleScreenFrame: CGRect,
        edge: WorkspaceFloatingDockParkingEdge
    ) -> CGRect {
        let minX: CGFloat = switch edge {
        case .leading:
            visibleScreenFrame.minX - windowSize.width + visibleWidth
        case .trailing:
            visibleScreenFrame.maxX - visibleWidth
        }
        return CGRect(origin: CGPoint(x: minX, y: minY), size: windowSize)
    }

    private static func screenFramesExcludingOwner(
        visibleScreenFrame: CGRect,
        availableScreenFrames: [CGRect]
    ) -> [CGRect] {
        let overlaps = availableScreenFrames.enumerated().map { index, frame in
            (index: index, area: intersectionArea(visibleScreenFrame, frame))
        }
        guard let owner = overlaps.max(by: { $0.area < $1.area }), owner.area > 0 else {
            return availableScreenFrames
        }
        return availableScreenFrames.enumerated().compactMap { index, frame in
            index == owner.index ? nil : frame
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
