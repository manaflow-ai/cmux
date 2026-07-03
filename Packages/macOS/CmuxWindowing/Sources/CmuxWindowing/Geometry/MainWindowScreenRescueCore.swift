public import CoreGraphics

/// Decision core for rescuing main windows stranded by a display-topology
/// change (monitor unplug, clamshell close, menu-bar arrangement change).
///
/// The app target owns the AppKit observer shell; this type keeps the rescue
/// decision pure so tests can run without depending on live display hardware.
public struct MainWindowScreenRescueCore: Sendable {
    private let frameGeometry: WindowFrameGeometry

    /// Creates a rescue decision core.
    ///
    /// - Parameter frameGeometry: Geometry math used to choose and clamp target frames.
    public init(frameGeometry: WindowFrameGeometry = WindowFrameGeometry()) {
        self.frameGeometry = frameGeometry
    }

    /// Order-independent signature of the current display topology and visible
    /// reachability bounds. Full-frame/top-inset differences select strict
    /// rescue; visible-frame-only differences select the lenient constrain-veto
    /// thresholds so Dock side/bottom changes can rescue newly unreachable
    /// edge-parked windows without disturbing veto-protected placements.
    /// Returns an order-independent signature of the current displays.
    ///
    /// - Parameter displays: Display geometry snapshots in any order.
    /// - Returns: A sorted signature that omits volatile display IDs.
    public func topologySignature(
        of displays: [SessionDisplayGeometry]
    ) -> [MainWindowDisplayTopologySignatureEntry] {
        displays
            .map { display in
                MainWindowDisplayTopologySignatureEntry(
                    frame: display.frame,
                    visibleFrame: display.visibleFrame
                )
            }
            .sorted { lhs, rhs in
                if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
                if lhs.frame.minY != rhs.frame.minY { return lhs.frame.minY < rhs.frame.minY }
                if lhs.frame.width != rhs.frame.width { return lhs.frame.width < rhs.frame.width }
                if lhs.frame.height != rhs.frame.height { return lhs.frame.height < rhs.frame.height }
                if lhs.topInset != rhs.topInset { return lhs.topInset < rhs.topInset }
                if lhs.visibleFrame.minX != rhs.visibleFrame.minX {
                    return lhs.visibleFrame.minX < rhs.visibleFrame.minX
                }
                if lhs.visibleFrame.minY != rhs.visibleFrame.minY {
                    return lhs.visibleFrame.minY < rhs.visibleFrame.minY
                }
                if lhs.visibleFrame.width != rhs.visibleFrame.width {
                    return lhs.visibleFrame.width < rhs.visibleFrame.width
                }
                return lhs.visibleFrame.height < rhs.visibleFrame.height
            }
    }

    /// Returns whether two signatures represent the same physical arrangement.
    ///
    /// This ignores visible-frame-only changes so callers can distinguish
    /// strict topology changes from Dock/safe-area changes that only need the
    /// lenient constrain-veto rescue thresholds.
    ///
    /// - Parameters:
    ///   - lhs: First display signature.
    ///   - rhs: Second display signature.
    /// - Returns: `true` when display frames and top insets match.
    public func signaturesHaveSameArrangement(
        _ lhs: [MainWindowDisplayTopologySignatureEntry],
        _ rhs: [MainWindowDisplayTopologySignatureEntry]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { lhsEntry, rhsEntry in
            lhsEntry.hasSameArrangement(as: rhsEntry)
        }
    }

    /// For each window frame, the frame the window should move to so its drag
    /// band becomes reachable, or nil when the window must not move (top strip
    /// reachable per `thresholds`, or no displays available).
    ///
    /// `thresholds` selects how aggressive the pass is: strict drag-band
    /// visibility for a genuinely changed arrangement, or `.constrainVeto` for
    /// a settled-back transient where only windows the constrain veto itself
    /// would abandon may be moved.
    ///
    /// Placement reuses the session-restore geometry: pick the display with the
    /// greatest body overlap (else the nearest by center distance), then clamp
    /// into its visible frame with the same floors session restore applies.
    public func rescuedFrames(
        for windowFrames: [CGRect],
        displays: [SessionDisplayGeometry],
        thresholds: WindowTitlebarReachabilityThresholds,
        minimumWidth: CGFloat,
        minimumHeight: CGFloat
    ) -> [CGRect?] {
        guard !displays.isEmpty else { return windowFrames.map { _ in nil } }
        let visibleFrames = displays.map(\.visibleFrame)
        let titlebarReachability = WindowTitlebarReachability(thresholds: thresholds)
        return windowFrames.map { frame in
            if titlebarReachability.isTopStripReachable(
                frame,
                onAnyOf: visibleFrames
            ) {
                return nil
            }
            let target = targetDisplay(for: frame, in: displays) ?? displays[0]
            return frameGeometry.clampFrame(
                frame,
                within: target.visibleFrame,
                minWidth: minimumWidth,
                minHeight: minimumHeight
            )
        }
    }

    /// Greatest body-overlap display, else nearest by center distance —
    /// mirroring `AppDelegate.display(for:in:)`'s selection order.
    private func targetDisplay(
        for frame: CGRect,
        in displays: [SessionDisplayGeometry]
    ) -> SessionDisplayGeometry? {
        let overlaps = displays.map { display in
            (display: display, area: frameGeometry.intersectionArea(frame, display.visibleFrame))
        }
        if let best = overlaps.max(by: { $0.area < $1.area }), best.area > 0 {
            return best.display
        }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return displays.min { lhs, rhs in
            frameGeometry.distanceSquared(lhs.visibleFrame, center)
                < frameGeometry.distanceSquared(rhs.visibleFrame, center)
        }
    }
}
