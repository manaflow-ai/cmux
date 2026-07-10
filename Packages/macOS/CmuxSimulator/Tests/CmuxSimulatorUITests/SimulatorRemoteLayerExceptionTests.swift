import QuartzCore
import Testing
@testable import CmuxSimulatorUI

@Suite("Simulator remote layer exception containment")
@MainActor
struct SimulatorRemoteLayerExceptionTests {
    @Test("An Objective-C remote-context exception cannot escape into cmux")
    func objectiveCExceptionIsContained() {
        let layer = ThrowingRemoteContextLayer()

        #expect(!SimulatorRemoteLayerContextSetter().set(contextID: 42, on: layer))
    }
}

private final class ThrowingRemoteContextLayer: CALayer {
    override func setValue(_ value: Any?, forKey key: String) {
        NSException(
            name: .internalInconsistencyException,
            reason: "Injected remote layer failure"
        ).raise()
    }
}
