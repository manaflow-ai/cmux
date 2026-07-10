import CmuxSimulator
import CoreGraphics
import Testing
@testable import CmuxSimulatorWorker

@Suite("Simulator accessibility highlight geometry")
struct SimulatorFramebufferHighlightTests {
    @Test("Point-space accessibility frames map into a pixel surface with top-origin Y")
    func topOriginConversion() {
        let frame = SimulatorFramebuffer.highlightFrame(
            SimulatorRect(x: 43, y: 100, width: 86, height: 200),
            coordinateSpace: SimulatorRect(x: 0, y: 0, width: 430, height: 932),
            displayBounds: CGRect(x: 0, y: 0, width: 1_290, height: 2_796)
        )

        #expect(frame == CGRect(x: 129, y: 1_896, width: 258, height: 600))
    }
}
