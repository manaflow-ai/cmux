import AppKit
import Testing
@testable import CmuxSimulatorWorker

@Suite("Simulator accessibility discovery")
struct SimulatorAccessibilityDiscoveryTests {
    @Test("Scalar private properties are boxed without object retention")
    func scalarPrivatePropertyABI() {
        let target = SimulatorScalarPropertyDouble()

        let value = objectProperty(target, selectorName: "pid") as? NSNumber

        #expect(value?.int32Value == 4_877)
    }

    @Test("Traversal matches serve-sim's bounded node and depth limits")
    func boundedTraversalLimits() {
        let bridge = SimulatorAccessibilityBridge()
        var remaining = SimulatorAccessibilityBridge.maximumNodeCount
        var visited: Set<ObjectIdentifier> = []
        var coverage = SimulatorAccessibilityCoverage()
        var truncated = false
        var accepted = 0

        let objects = (0...SimulatorAccessibilityBridge.maximumNodeCount).map { _ in NSObject() }
        for (index, object) in objects.enumerated() {
            if bridge.serialize(
                object, path: "\(index)", token: "", depth: 0,
                remaining: &remaining, visited: &visited, coverage: &coverage,
                traversalTruncated: &truncated
            ) != nil {
                accepted += 1
            }
        }

        #expect(SimulatorAccessibilityBridge.maximumNodeCount == 500)
        #expect(SimulatorAccessibilityBridge.maximumDepth == 80)
        #expect(accepted == 500)
        #expect(remaining == 0)
        #expect(truncated)

        remaining = 1
        visited = []
        truncated = false
        #expect(bridge.serialize(
            NSObject(), path: "deep", token: "",
            depth: SimulatorAccessibilityBridge.maximumDepth + 1,
            remaining: &remaining, visited: &visited, coverage: &coverage,
            traversalTruncated: &truncated
        ) == nil)
        #expect(truncated)
    }

    @Test("Accessibility strings remain valid UTF-8 within the worker frame budget")
    func boundedAccessibilityStrings() {
        let value = String(repeating: "🙂", count: 1_000)

        let bounded = boundedSimulatorAccessibilityText(value)

        #expect(bounded.utf8.count <= SimulatorAccessibilityBridge.maximumTextUTF8ByteCount)
        #expect(bounded.allSatisfy { $0 == "🙂" })
        #expect(bounded.count == SimulatorAccessibilityBridge.maximumTextUTF8ByteCount / 4)
    }

    @Test("Grid covers the full display while respecting its hard point cap")
    func boundedFullDisplayGrid() throws {
        let bounds = NSRect(x: 120, y: 40, width: 1_366, height: 1_024)

        let grid = SimulatorAccessibilityGrid()
        let points = grid.points(in: bounds)

        #expect(!points.isEmpty)
        #expect(points.count <= grid.maximumPointCount)
        #expect(points.allSatisfy(bounds.contains))
        let quadrants = Set(points.map { point in
            "\(point.x < bounds.midX ? "left" : "right")-\(point.y < bounds.midY ? "bottom" : "top")"
        })
        #expect(quadrants.count == 4)
    }

    @Test("Leaf coverage skips redundant points but containers remain discoverable")
    func leafAndContainerCoverage() {
        var coverage = SimulatorAccessibilityCoverage()
        let leaf = NSRect(x: 10, y: 20, width: 80, height: 40)
        let container = NSRect(x: 0, y: 0, width: 400, height: 800)

        coverage.insertLeaf(leaf)
        coverage.insertContainer(container)

        #expect(coverage.contains(leaf))
        #expect(coverage.contains(container))
        #expect(coverage.contains(CGPoint(x: 30, y: 30)))
        #expect(!coverage.contains(CGPoint(x: 300, y: 300)))
    }

    @Test("Invalid and empty displays produce no probe points")
    func invalidBounds() {
        let grid = SimulatorAccessibilityGrid()
        #expect(grid.points(in: .zero).isEmpty)
        #expect(grid.points(
            in: NSRect(x: 0, y: 0, width: CGFloat.infinity, height: 10)
        ).isEmpty)
    }
}
