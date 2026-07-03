import CoreGraphics
import CmuxWindowing

/// Decision core for rescuing main windows stranded by a display-topology
/// change (monitor unplug, clamshell close, menu-bar arrangement change).
/// Pure so the behavior is testable deterministically on CI
/// regardless of the host's display configuration; `MainWindowScreenChangeRescue`
/// is the live observer shell.
struct MainWindowScreenRescueCore {
    private let frameGeometry: WindowFrameGeometry

    init(frameGeometry: WindowFrameGeometry = WindowFrameGeometry()) {
        self.frameGeometry = frameGeometry
    }

    /// One display's identity, full frame, and top inset (the menu-bar band:
    /// `frame.maxY - visibleFrame.maxY`). The rest of `visibleFrame` is
    /// deliberately omitted: Dock and side-inset resizes cannot strand a
    /// titlebar and must not read as topology changes. The top inset IS
    /// included because a menu bar appearing on (or moving to) a display
    /// shrinks the visible area from the top and can newly cover a flush-top
    /// window's drag band — that must trigger a rescue pass.
    struct TopologySignatureEntry: Equatable {
        let displayID: UInt32?
        let frame: CGRect
        let topInset: CGFloat
    }

    /// Order-independent signature of the current display topology. Two
    /// signatures compare equal exactly when the same displays sit at the same
    /// frames with the same top insets — the gate that keeps sleep/wake (same
    /// topology, same notification) and Dock resizes from ever triggering a
    /// rescue.
    func topologySignature(
        of displays: [SessionDisplayGeometry]
    ) -> [TopologySignatureEntry] {
        displays
            .map { display in
                TopologySignatureEntry(
                    displayID: display.displayID,
                    frame: display.frame,
                    topInset: display.frame.maxY - display.visibleFrame.maxY
                )
            }
            .sorted { lhs, rhs in
                if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
                if lhs.frame.minY != rhs.frame.minY { return lhs.frame.minY < rhs.frame.minY }
                return (lhs.displayID ?? .max) < (rhs.displayID ?? .max)
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
    func rescuedFrames(
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
