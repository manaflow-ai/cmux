import AppKit

/// Tracks frames already represented by the bounded accessibility traversal.
struct SimulatorAccessibilityCoverage {
    private struct FrameKey: Hashable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int

        init(_ rect: NSRect) {
            x = Int(rect.origin.x.rounded())
            y = Int(rect.origin.y.rounded())
            width = Int(rect.width.rounded())
            height = Int(rect.height.rounded())
        }
    }

    private var leafRects: [NSRect] = []
    private var frameKeys: Set<FrameKey> = []

    mutating func insertLeaf(_ rect: NSRect) {
        guard rect.isFiniteAndVisible else { return }
        if frameKeys.insert(FrameKey(rect)).inserted {
            leafRects.append(rect)
        }
    }

    mutating func insertContainer(_ rect: NSRect) {
        guard rect.isFiniteAndVisible else { return }
        frameKeys.insert(FrameKey(rect))
    }

    func contains(_ rect: NSRect) -> Bool {
        frameKeys.contains(FrameKey(rect))
    }

    func contains(_ point: CGPoint) -> Bool {
        leafRects.contains(where: { $0.contains(point) })
    }
}
