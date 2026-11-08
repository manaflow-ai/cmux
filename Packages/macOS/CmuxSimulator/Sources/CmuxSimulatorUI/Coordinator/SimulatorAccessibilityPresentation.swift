import CmuxSimulator
import Foundation

struct SimulatorAccessibilityPresentationRow: Identifiable, Equatable {
    let id: String
    let depth: Int
    let node: SimulatorAccessibilityNode
}

extension SimulatorPaneCoordinator {
    func applyAccessibilitySnapshot(_ snapshot: SimulatorAccessibilitySnapshot) {
        guard accessibilitySnapshot != snapshot else { return }
        accessibilitySnapshot = snapshot
        accessibilityRows = simulatorAccessibilityPresentationRows(snapshot.roots)
    }
}

func simulatorAccessibilityPresentationRows(
    _ roots: [SimulatorAccessibilityNode]
) -> [SimulatorAccessibilityPresentationRow] {
    var rows: [SimulatorAccessibilityPresentationRow] = []
    rows.reserveCapacity(min(roots.count * 4, 500))
    var pending = roots.enumerated().reversed().map { index, node in
        (node: node, path: "root.\(index)", depth: 0)
    }
    while let current = pending.popLast(), rows.count < 500 {
        rows.append(SimulatorAccessibilityPresentationRow(
            id: current.path,
            depth: current.depth,
            node: current.node
        ))
        for (index, child) in current.node.children.enumerated().reversed() {
            pending.append((
                node: child,
                path: "\(current.path).\(index)",
                depth: current.depth + 1
            ))
        }
    }
    return rows
}
