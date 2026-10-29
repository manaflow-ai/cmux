@testable import CmuxNextApp
import CmuxNextSettings
import Foundation
import ObjectiveC
import QuartzCore
import Testing

/// `debug.terminal_display` and `debug.damage` share one display-pass probe: arms nest,
/// neither tool resets or ends the other's counts, and the last disarm puts the original IMP back (R4).
@MainActor
struct DebugTerminalDisplayProbeTests {
    /// Stands in for Ghostty's `IOSurfaceLayer`; the probe times this class's own `display`.
    nonisolated final class TestLayer: CALayer {
        var displays = 0
        override func display() { displays += 1 }
    }

    /// A real message send, so the replaced IMP runs.
    private func display(_ layer: TestLayer, times: Int = 1) {
        for _ in 0..<times { _ = layer.perform(#selector(CALayer.display)) }
    }

    @Test func armsNestAndTheLastDisarmPutsTheOriginalImpBack() throws {
        let probe = DebugTerminalDisplayProbe(layerClassName: NSStringFromClass(TestLayer.self))
        let layer = TestLayer()
        let method = try #require(class_getInstanceMethod(TestLayer.self, #selector(CALayer.display)))
        let original = method_getImplementation(method)

        // A damage window arms first, then a debug.terminal_display session starts inside it.
        #expect(probe.armPasses())
        #expect(method_getImplementation(method) != original)
        display(layer)
        #expect(probe.handle(["action": .string("start")])["armed"]?.boolValue == true)
        display(layer, times: 2)
        #expect(probe.passCount == 3)
        // The window ends: the session keeps counting.
        probe.disarmPasses()
        #expect(!probe.isRestored)
        display(layer)
        let session = probe.handle(["action": .string("stop")])
        #expect(session["calls"]?.intValue == 3)
        #expect(session["truncated"]?.boolValue == false)
        #expect(method_getImplementation(method) == original)
        #expect(probe.isRestored)
        display(layer)
        #expect(probe.passCount == 4)

        // The other order: a session's start and stop leave a window's arm and its count alone.
        #expect(probe.armPasses())
        #expect(probe.handle(["action": .string("start")])["armed"]?.boolValue == true)
        display(layer)
        #expect(probe.handle(["action": .string("stop")])["calls"]?.intValue == 1)
        #expect(!probe.isRestored)
        display(layer)
        #expect(probe.passCount == 6)
        probe.disarmPasses()
        #expect(method_getImplementation(method) == original)
        #expect(layer.displays == 7)
    }

    /// No such class: nothing is armed and nothing is held.
    @Test func aMissingLayerClassArmsNothing() {
        let probe = DebugTerminalDisplayProbe(layerClassName: "CmuxNoSuchDisplayProbeLayer")
        #expect(!probe.armPasses())
        #expect(probe.handle(["action": .string("start")])["armed"]?.boolValue == false)
        #expect(probe.isRestored)
    }
}
