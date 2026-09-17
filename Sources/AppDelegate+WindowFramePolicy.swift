import AppKit

extension AppDelegate {
    nonisolated static func shouldPreserveAccessibleFrame(
        frame: CGRect,
        targetDisplay: SessionDisplayGeometry
    ) -> Bool {
        let standardizedFrame = frame.standardized
        guard standardizedFrame.width.isFinite,
              standardizedFrame.height.isFinite,
              standardizedFrame.intersects(targetDisplay.frame) else {
            return false
        }
        // Single source of truth for "is a grabbable slice of the titlebar
        // visible" -- shared with the runtime constrain veto so the restore-time
        // clamp and the sleep/wake constrain pass agree on reachability.
        return CmuxMainWindow.isTitlebarReachable(
            frame: standardizedFrame,
            visibleFrame: targetDisplay.visibleFrame
        )
    }

    nonisolated static func clampFrame(
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

    /// Decides how a live main-window frame should be corrected after a display
    /// reconfiguration (monitor connect/disconnect, resolution change, lid
    /// open/close). Returns `nil` when the window needs no change -- either a
    /// grabbable slice of its titlebar is already reachable on some display, or
    /// there are no displays to reason about.
    ///
    /// This is the reactive counterpart to `CmuxMainWindow.constrainFrameRect`:
    /// a cmux main window sets `isMovable = false` for its custom titlebar drag
    /// handling, and a non-movable `NSWindow` is excluded from AppKit's automatic
    /// on-screen constraining when displays change -- so `constrainFrameRect` is
    /// never invoked on that path and nothing pulls a stranded window back. When
    /// an external monitor that sat above the built-in display is disconnected,
    /// the window is left with its titlebar in the now-gone monitor's coordinate
    /// space, above every remaining screen and unreachable (the user cannot drag
    /// it back because the only drag affordance is that off-screen titlebar).
    ///
    /// Pure and `nonisolated` so it is unit-testable without live `NSScreen`s.
    nonisolated static func reconciledFrameAfterScreenChange(
        frame: CGRect,
        availableDisplays: [SessionDisplayGeometry]
    ) -> CGRect? {
        guard frame.width.isFinite,
              frame.height.isFinite,
              frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.width > 0,
              frame.height > 0,
              !availableDisplays.isEmpty else {
            return nil
        }

        // Already reachable on some display? Leave it untouched so windows on
        // displays the reconfiguration did not affect are not disturbed.
        for display in availableDisplays
        where shouldPreserveAccessibleFrame(frame: frame, targetDisplay: display) {
            return nil
        }

        // Clamp onto the display the window most overlaps (or is nearest to) so
        // its titlebar becomes reachable again.
        guard let targetDisplay = bestDisplayForFrame(frame, in: availableDisplays) else {
            return nil
        }
        let clamped = clampFrame(
            frame,
            within: targetDisplay.visibleFrame,
            minWidth: CGFloat(SessionPersistencePolicy.minimumWindowWidth),
            minHeight: CGFloat(SessionPersistencePolicy.minimumWindowHeight)
        )
        // Avoid emitting a redundant setFrame.
        return clamped.equalTo(frame.standardized) ? nil : clamped
    }

    private nonisolated static func bestDisplayForFrame(
        _ frame: CGRect,
        in displays: [SessionDisplayGeometry]
    ) -> SessionDisplayGeometry? {
        if let bestOverlap = displays
            .map({ ($0, intersectionArea(frame, $0.visibleFrame)) })
            .max(by: { $0.1 < $1.1 }), bestOverlap.1 > 0 {
            return bestOverlap.0
        }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return displays.min {
            distanceSquared($0.visibleFrame, center) < distanceSquared($1.visibleFrame, center)
        }
    }

    nonisolated static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return max(0, intersection.width) * max(0, intersection.height)
    }

    nonisolated static func distanceSquared(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = rect.midX - point.x
        let dy = rect.midY - point.y
        return (dx * dx) + (dy * dy)
    }
}
