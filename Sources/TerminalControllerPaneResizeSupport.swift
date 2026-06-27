import CoreGraphics
import Foundation
import Bonsplit
import CmuxPanes

extension TerminalController {
    enum V2PaneResizeDirection: String {
        case left
        case right
        case up
        case down

        var splitOrientation: String {
            switch self {
            case .left, .right:
                return "horizontal"
            case .up, .down:
                return "vertical"
            }
        }

        /// A split controls the target pane's right/bottom edge when target is first child,
        /// and left/top edge when target is second child.
        var requiresPaneInFirstChild: Bool {
            switch self {
            case .right, .down:
                return true
            case .left, .up:
                return false
            }
        }

        /// Positive value moves divider toward second child (right/down).
        var dividerDeltaSign: CGFloat {
            requiresPaneInFirstChild ? 1 : -1
        }
    }

    func v2SetAbsolutePaneSize(
        workspace: Workspace,
        paneUUID: UUID,
        axis: String,
        targetPixels: CGFloat
    ) -> (splitId: UUID, oldPosition: CGFloat, newPosition: CGFloat)? {
        guard targetPixels > 0 else { return nil }
        let orientationName: String
        switch axis.lowercased() {
        case "horizontal":
            orientationName = "horizontal"
        case "vertical":
            orientationName = "vertical"
        default:
            return nil
        }

        var candidates: [ResizeSplitCandidate] = []
        let trace = workspace.bonsplitController.treeSnapshot().collectResizeCandidates(
            targetPaneId: paneUUID.uuidString,
            candidates: &candidates
        )
        guard trace.containsTarget,
              let candidate = candidates.first(where: { $0.orientation == orientationName }) else {
            return nil
        }

        let targetFraction = targetPixels / candidate.axisPixels
        let requested = candidate.paneInFirstChild ? targetFraction : (1 - targetFraction)
        let clamped = min(max(requested, 0.1), 0.9)
        guard workspace.bonsplitController.setDividerPosition(
            clamped,
            forSplit: candidate.splitId,
            fromExternal: true
        ) else {
            return nil
        }
        return (candidate.splitId, candidate.dividerPosition, clamped)
    }
}
