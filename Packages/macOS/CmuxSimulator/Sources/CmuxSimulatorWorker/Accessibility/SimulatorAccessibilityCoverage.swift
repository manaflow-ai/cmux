import AppKit

/// Tracks frames already represented by the bounded accessibility traversal.
struct SimulatorAccessibilityCoverage {
    private var leafRects: [NSRect] = []
    private var frameKeys: Set<SimulatorAccessibilityFrameKey> = []

    mutating func insertLeaf(_ rect: NSRect) {
        guard rect.isFiniteAndVisible else { return }
        if frameKeys.insert(SimulatorAccessibilityFrameKey(rect)).inserted {
            leafRects.append(rect)
        }
    }

    mutating func insertContainer(_ rect: NSRect) {
        guard rect.isFiniteAndVisible else { return }
        frameKeys.insert(SimulatorAccessibilityFrameKey(rect))
    }

    func contains(_ rect: NSRect) -> Bool {
        frameKeys.contains(SimulatorAccessibilityFrameKey(rect))
    }

    func contains(_ point: CGPoint) -> Bool {
        leafRects.contains(where: { $0.contains(point) })
    }
}
