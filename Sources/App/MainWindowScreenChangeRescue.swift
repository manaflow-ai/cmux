import AppKit
import CmuxWindowing

/// Decision core for rescuing main windows stranded by a display-topology
/// change (monitor unplug, clamshell close). Pure and `nonisolated` so the
/// behavior is testable deterministically on CI regardless of the host's
/// display configuration; the live observer/controller shell is added
/// separately.
enum MainWindowScreenRescueCore {
    /// One display's identity and full frame. `visibleFrame` is deliberately
    /// omitted: Dock/menu-bar resizes change only the visible frame and can
    /// never strand a titlebar, so they must not read as topology changes.
    struct TopologySignatureEntry: Equatable {
        let displayID: UInt32?
        let frame: CGRect
    }

    /// Order-independent signature of the current display topology. Two
    /// signatures compare equal exactly when the same displays sit at the same
    /// frames — the gate that keeps sleep/wake (same topology, same
    /// notification) from ever triggering a rescue.
    nonisolated static func topologySignature(
        of displays: [SessionDisplayGeometry]
    ) -> [TopologySignatureEntry] {
        displays
            .map { TopologySignatureEntry(displayID: $0.displayID, frame: $0.frame) }
            .sorted { lhs, rhs in
                if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
                if lhs.frame.minY != rhs.frame.minY { return lhs.frame.minY < rhs.frame.minY }
                return (lhs.displayID ?? .max) < (rhs.displayID ?? .max)
            }
    }

    /// For each window frame, the frame the window should move to so its drag
    /// band becomes reachable, or nil when the window must not move (drag band
    /// already reachable per the strict thresholds, or no displays available).
    nonisolated static func rescuedFrames(
        for windowFrames: [CGRect],
        displays: [SessionDisplayGeometry],
        minimumWidth: CGFloat,
        minimumHeight: CGFloat
    ) -> [CGRect?] {
        // Not implemented yet: the failing tests in
        // MainWindowScreenChangeRescueTests pin the intended behavior.
        windowFrames.map { _ in nil }
    }
}
