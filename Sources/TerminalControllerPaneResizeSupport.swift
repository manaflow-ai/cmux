import CoreGraphics
import Foundation
import Bonsplit

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

    struct V2PaneResizeCandidate {
        let splitId: UUID
        let orientation: String
        let paneInFirstChild: Bool
        let dividerPosition: CGFloat
        let axisPixels: CGFloat
    }

    struct V2PaneResizeTrace {
        let containsTarget: Bool
        let bounds: CGRect
    }

    func v2PaneResizeCollectCandidates(
        node: ExternalTreeNode,
        targetPaneId: String,
        candidates: inout [V2PaneResizeCandidate]
    ) -> V2PaneResizeTrace {
        switch node {
        case .pane(let pane):
            let bounds = CGRect(
                x: pane.frame.x,
                y: pane.frame.y,
                width: pane.frame.width,
                height: pane.frame.height
            )
            return V2PaneResizeTrace(containsTarget: pane.id == targetPaneId, bounds: bounds)

        case .split(let split):
            let first = v2PaneResizeCollectCandidates(
                node: split.first,
                targetPaneId: targetPaneId,
                candidates: &candidates
            )
            let second = v2PaneResizeCollectCandidates(
                node: split.second,
                targetPaneId: targetPaneId,
                candidates: &candidates
            )

            let combinedBounds = first.bounds.union(second.bounds)
            let containsTarget = first.containsTarget || second.containsTarget

            if containsTarget,
               let splitUUID = UUID(uuidString: split.id) {
                let orientation = split.orientation.lowercased()
                let axisPixels: CGFloat = orientation == "horizontal"
                    ? combinedBounds.width
                    : combinedBounds.height
                candidates.append(V2PaneResizeCandidate(
                    splitId: splitUUID,
                    orientation: orientation,
                    paneInFirstChild: first.containsTarget,
                    dividerPosition: CGFloat(split.dividerPosition),
                    axisPixels: max(axisPixels, 1)
                ))
            }

            return V2PaneResizeTrace(containsTarget: containsTarget, bounds: combinedBounds)
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

        var candidates: [V2PaneResizeCandidate] = []
        let trace = v2PaneResizeCollectCandidates(
            node: workspace.bonsplitController.treeSnapshot(),
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
